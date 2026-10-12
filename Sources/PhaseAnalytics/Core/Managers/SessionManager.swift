import Foundation

internal struct SessionSnapshot: Sendable {
    let id: String
    /// Wall-clock start sent to the server; events must not be timestamped before it.
    let startedAt: Date
}

internal actor SessionManager {
    private var session: SessionSnapshot?
    private var startedAtUptime: TimeInterval?
    private var pausedAtUptime: TimeInterval?
    private var isPaused = false
    private var lastLifecycleSequence = 0
    private var heartbeatTask: Task<Void, Never>?

    private let sender: BatchSender
    private var deviceID: String

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

    init(sender: BatchSender, deviceID: String) {
        self.sender = sender
        self.deviceID = deviceID
    }

    /// Starts a session unless one is active.
    ///
    /// - Parameter earliestActivity: Timestamp of the oldest event captured before the session
    ///   existed. The session is backdated to it so those events keep their real timestamps.
    @discardableResult
    func start(earliestActivity: Date? = nil) async -> SessionSnapshot {
        if let session {
            return session
        }

        let now = Date()
        let startedAt = min(earliestActivity ?? now, now)

        // State is set before the first suspension so concurrent callers reuse this session.
        let snapshot = SessionSnapshot(id: IDGenerator.generateSessionID(), startedAt: startedAt)
        session = snapshot
        startedAtUptime = monotonicNow() - now.timeIntervalSince(startedAt)

        let payload = CreateSessionRequest(
            sessionId: snapshot.id,
            deviceId: deviceID,
            startedAt: iso8601Timestamp(snapshot.startedAt)
        )
        await sender.enqueue(.session(payload: payload, clientOrder: 0, retryCount: nil))

        startPingInterval()
        return snapshot
    }

    /// Current session, rotated first if it reached the server's maximum duration.
    func currentSession() async -> SessionSnapshot? {
        guard session != nil else { return nil }
        if sessionAge() >= Self.maxSessionAge {
            logger.info("Session reached maximum age. Starting new session.")
            return await rotate()
        }
        return session
    }

    /// Ends the current session without starting another.
    func end() {
        stopPingInterval()
        session = nil
        startedAtUptime = nil
        pausedAtUptime = nil
    }

    /// Ends the session and switches identity; the next `start()` uses the new device.
    func reset(deviceID: String) {
        end()
        self.deviceID = deviceID
    }

    /// Lifecycle transitions carry a sequence number captured when the notification fired, so
    /// out-of-order delivery of the async calls cannot leave the session in the wrong state.
    func pause(sequence: Int) {
        guard sequence > lastLifecycleSequence else { return }
        lastLifecycleSequence = sequence
        guard !isPaused else { return }

        isPaused = true
        pausedAtUptime = monotonicNow()
        stopPingInterval()
        logger.info("Session paused")
    }

    func resume(sequence: Int) async {
        guard sequence > lastLifecycleSequence else { return }
        lastLifecycleSequence = sequence
        guard isPaused else { return }

        isPaused = false
        let pausedAt = pausedAtUptime
        pausedAtUptime = nil

        guard session != nil else { return }

        let inactiveDuration = pausedAt.map { monotonicNow() - $0 } ?? 0
        if sessionAge() >= Self.maxSessionAge {
            logger.info("Session too old (\(Int(sessionAge()))s). Starting new session.")
            await rotate()
        } else if inactiveDuration > Self.inactivityTimeout {
            logger.info("Session inactive for \(Int(inactiveDuration))s. Starting new session.")
            await rotate()
        } else {
            startPingInterval()
            logger.info("Session resumed after \(Int(inactiveDuration))s")
        }
    }

    /// Called after the server accepted activity, which already refreshed the session.
    func markActivity() {
        guard !isPaused, session != nil else { return }
        startPingInterval()
    }

    @discardableResult
    private func rotate() async -> SessionSnapshot {
        end()
        return await start()
    }

    private func sessionAge() -> TimeInterval {
        return startedAtUptime.map { monotonicNow() - $0 } ?? 0
    }

    private func startPingInterval() {
        stopPingInterval()
        guard !isPaused else { return }

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
        let age = sessionAge()

        if age >= Self.longHeartbeatAt {
            return Self.longHeartbeatInterval
        }

        if age >= Self.extendedHeartbeatAt {
            return Self.extendedHeartbeatInterval
        }

        if age >= Self.standardHeartbeatAt {
            return Self.standardHeartbeatInterval
        }

        if age >= Self.earlyHeartbeatAt {
            return Self.earlyHeartbeatInterval
        }

        return Self.initialHeartbeatInterval
    }

    private func sendPing() async {
        guard let current = session, !isPaused else { return }

        if sessionAge() >= Self.maxSessionAge {
            logger.info("Session reached maximum age. Starting new session.")
            await rotate()
            return
        }

        let payload = PingSessionRequest(sessionId: current.id, timestamp: currentISO8601Timestamp())
        await sender.enqueuePing(payload)
    }
}
