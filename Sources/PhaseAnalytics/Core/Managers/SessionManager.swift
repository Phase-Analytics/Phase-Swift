import Foundation

internal actor SessionManager {
    private var sessionID: String?
    private var heartbeatTask: Task<Void, Never>?
    private var isOnline = true
    private var pausedAt: Date?
    private var startedAt: Date?

    private let httpClient: HTTPClient
    private let offlineQueue: OfflineQueue
    private let deviceID: String
    private let storage: StorageAdapter

    private var startPromise: Task<String, Never>?

    private static let initialHeartbeatInterval: TimeInterval = 5.0
    private static let earlyHeartbeatInterval: TimeInterval = 10.0
    private static let standardHeartbeatInterval: TimeInterval = 15.0
    private static let extendedHeartbeatInterval: TimeInterval = 20.0
    private static let longHeartbeatInterval: TimeInterval = 30.0
    private static let earlyHeartbeatAt: TimeInterval = 15.0
    private static let standardHeartbeatAt: TimeInterval = 65.0
    private static let extendedHeartbeatAt: TimeInterval = 3 * 60
    private static let longHeartbeatAt: TimeInterval = 5 * 60
    private static let inactivityTimeout: TimeInterval = 5 * 60
    private static let maxSessionAge: TimeInterval = 2 * 60 * 60

    init(httpClient: HTTPClient, offlineQueue: OfflineQueue, deviceID: String, storage: StorageAdapter) {
        self.httpClient = httpClient
        self.offlineQueue = offlineQueue
        self.deviceID = deviceID
        self.storage = storage
    }

    func start(isOnline: Bool) async -> String {
        if let promise = startPromise {
            return await promise.value
        }

        if let existingID = sessionID {
            return existingID
        }

        let promise = Task<String, Never> {
            await doStart(isOnline: isOnline)
        }
        startPromise = promise

        let result = await promise.value
        startPromise = nil
        return result
    }

    private func doStart(isOnline: Bool) async -> String {
        stopPingInterval()

        self.isOnline = isOnline
        sessionID = IDGenerator.generateSessionID()

        if case .failure = Validator.validateSessionID(sessionID!) {
            logger.error("Generated session ID invalid. Retrying.")
            sessionID = IDGenerator.generateSessionID()

            if case .failure = Validator.validateSessionID(sessionID!) {
                logger.error("Failed to generate valid session ID. Using fallback.")
                sessionID = UUID().uuidString
            }
        }

        let startedAt = currentISO8601Timestamp()
        self.startedAt = Date()
        let payload = CreateSessionRequest(
            sessionId: sessionID!,
            deviceId: deviceID,
            startedAt: startedAt
        )

        let persistResult = await storage.setItem(key: StorageKeys.sessionStartedAt, value: startedAt)
        if case .failure = persistResult {
            logger.warn("Failed to persist session start time. Session age checks may not work correctly.")
        }

        if isOnline {
            let result = await httpClient.createSession(payload)
            if case .failure(let error) = result {
                logger.error("Session creation failed. Queuing for retry.", error)
                await offlineQueue.enqueue(.session(payload: payload, clientOrder: 0, retryCount: nil))
            }
        } else {
            await offlineQueue.enqueue(.session(payload: payload, clientOrder: 0, retryCount: nil))
        }

        startPingInterval()

        return sessionID!
    }

    func pause() {
        pausedAt = Date()
        stopPingInterval()
        logger.info("Session paused")
    }

    func resume() async {
        guard sessionID != nil else {
            return
        }

        let sessionStartedResult = await storage.getItem(key: StorageKeys.sessionStartedAt) as Result<String?, Error>
        if case .success(let startedAtString) = sessionStartedResult,
           let startedAtString = startedAtString,
           let startedAtDate = ISO8601DateFormatter().date(from: startedAtString) {
            let sessionAge = Date().timeIntervalSince(startedAtDate)

            if sessionAge > Self.maxSessionAge {
                logger.info(
                    "Session too old (\(Int(sessionAge))s). Starting new session."
                )

                sessionID = nil
                self.startedAt = nil
                self.pausedAt = nil

                _ = await start(isOnline: isOnline)
                return
            }
        }

        guard let pausedAt = pausedAt else {
            startPingInterval()
            return
        }

        let inactiveDuration = Date().timeIntervalSince(pausedAt)

        if inactiveDuration > Self.inactivityTimeout {
            logger.info(
                "Session inactive for \(Int(inactiveDuration))s. Starting new session."
            )

            sessionID = nil
            startedAt = nil
            self.pausedAt = nil

            _ = await start(isOnline: isOnline)
        } else {
            self.pausedAt = nil
            startPingInterval()
            logger.info("Session resumed after \(Int(inactiveDuration))s")
        }
    }

    func getSessionID() -> String? {
        return sessionID
    }

    func updateNetworkState(isOnline: Bool) {
        self.isOnline = isOnline
    }

    func markActivity() {
        guard pausedAt == nil else { return }
        startPingInterval()
    }

    private func startPingInterval() {
        stopPingInterval()

        let interval = heartbeatInterval()
        heartbeatTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await sendPing()

            if !Task.isCancelled {
                startPingInterval()
            }
        }
    }

    private func stopPingInterval() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func heartbeatInterval() -> TimeInterval {
        let sessionAge = startedAt.map { Date().timeIntervalSince($0) } ?? 0

        if sessionAge >= Self.longHeartbeatAt {
            return Self.longHeartbeatInterval
        }

        if sessionAge >= Self.extendedHeartbeatAt {
            return Self.extendedHeartbeatInterval
        }

        if sessionAge >= Self.standardHeartbeatAt {
            return Self.standardHeartbeatInterval
        }

        if sessionAge >= Self.earlyHeartbeatAt {
            return Self.earlyHeartbeatInterval
        }

        return Self.initialHeartbeatInterval
    }

    private func sendPing() async {
        guard let sessionID = sessionID else {
            return
        }

        if let startedAt, Date().timeIntervalSince(startedAt) >= Self.maxSessionAge {
            logger.info("Session reached maximum age. Starting new session.")
            self.sessionID = nil
            self.startedAt = nil
            _ = await start(isOnline: isOnline)
            return
        }

        let payload = PingSessionRequest(
            sessionId: sessionID,
            timestamp: currentISO8601Timestamp()
        )

        if isOnline {
            let result = await httpClient.pingSession(payload)
            if case .failure(let error) = result {
                logger.error("Session ping failed. Queuing for retry.", error)
                await offlineQueue.enqueue(.ping(payload: payload, clientOrder: 0, retryCount: nil))
            }
        } else {
            await offlineQueue.enqueue(.ping(payload: payload, clientOrder: 0, retryCount: nil))
        }
    }
}
