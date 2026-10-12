import Foundation

public final class PhaseSDK: Sendable {
    public static let shared = PhaseSDK()

    private struct Components: Sendable {
        let sender: BatchSender
        let device: DeviceManager
        let session: SessionManager
        let events: EventManager
    }

    private struct State {
        var components: Components?
        var initializationTask: Task<Void, Error>?
        var resetTask: Task<Void, Never>?
        var isIdentified = false
        /// identify() calls made before initialization finished, merged (the server merges properties too).
        var pendingIdentify: [String: Any]??
    }

    private let state = ThreadSafeLock(State())
    private let storage: StorageAdapter

    // Capture-side state exists before initialization so early track() calls are kept, and rate
    // limiting/deduplication happen once, at call time, never again on replay.
    private let capturedEvents = CapturedEventBuffer()
    private let rateLimiter = RateLimiter()
    private let deduplicator = EventDeduplicator()

    private let networkSequence = ThreadSafeLock(0)
    private let networkUnsubscribe = ThreadSafeLock<UnsubscribeFn?>(nil)
    private let lifecycleObserver = ThreadSafeLock<(any Sendable)?>(nil)

    internal init(storage: StorageAdapter = UserDefaultsStorage()) {
        self.storage = storage
    }

    private var components: Components? {
        state.withLock { $0.components }
    }

    // MARK: - Initialization

    /// Initialize the SDK (required before tracking)
    ///
    /// - Parameters:
    ///   - apiKey: Phase API key (required, starts with `phase_`)
    ///   - baseURL: Custom API endpoint (optional, default: "https://api.phase.sh")
    ///   - logLevel: Logging level (optional, default: `.none`)
    ///   - debugData: Mark identify/events as debug data (optional, default: `false`)
    ///   - deviceInfo: Collect device metadata (optional, default: `true`)
    ///   - userLocale: Collect locale & geolocation (optional, default: `true`)
    ///
    /// - Throws: `PhaseError.invalidAPIKey`
    ///
    /// ## Example
    /// ```swift
    /// try await PhaseSDK.shared.initialize(apiKey: "phase_xxx")
    /// ```
    public func initialize(
        apiKey: String,
        baseURL: String = "https://api.phase.sh",
        logLevel: LogLevel = .none,
        debugData: Bool = false,
        deviceInfo: Bool = true,
        userLocale: Bool = true
    ) async throws {
        let config = PhaseConfig(
            apiKey: apiKey,
            baseURL: baseURL,
            logLevel: logLevel,
            debugData: debugData,
            deviceInfo: deviceInfo,
            userLocale: userLocale
        )

        #if canImport(UIKit)
            try await _initialize(
                config: config,
                getDeviceInfo: getIOSDeviceInfo,
                networkAdapter: NetworkMonitor()
            )
        #else
            try await _initialize(
                config: config,
                getDeviceInfo: {
                    DeviceInfo(
                        osVersion: nil,
                        platform: nil,
                        locale: nil,
                        model: nil,
                        appVersion: nil
                    )
                },
                networkAdapter: NetworkMonitor()
            )
        #endif
    }

    internal func _initialize(
        config: PhaseConfig,
        getDeviceInfo: @escaping @Sendable () async -> DeviceInfo,
        networkAdapter: NetworkAdapter
    ) async throws {
        enum Action {
            case alreadyInitialized
            case wait(Task<Void, Error>)
        }

        let action = state.withLock { state -> Action in
            if state.components != nil {
                return .alreadyInitialized
            }
            if let running = state.initializationTask {
                return .wait(running)
            }
            let task = Task<Void, Error> {
                try await self.doInitialize(
                    config: config, getDeviceInfo: getDeviceInfo, networkAdapter: networkAdapter)
            }
            state.initializationTask = task
            return .wait(task)
        }

        switch action {
        case .alreadyInitialized:
            logger.warn("SDK already initialized. Skipping duplicate initialization.")
        case .wait(let task):
            try await task.value
        }
    }

    private func doInitialize(
        config: PhaseConfig,
        getDeviceInfo: @escaping @Sendable () async -> DeviceInfo,
        networkAdapter: NetworkAdapter
    ) async throws {
        logger.setLogLevel(config.logLevel)

        let trimmedKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, config.apiKey.hasPrefix("phase_") else {
            logger.error("Invalid API key. It is required and must start with 'phase_'.")
            state.withLock { state in
                state.initializationTask = nil
                state.pendingIdentify = nil
            }
            throw PhaseError.invalidAPIKey
        }

        let isOnline = await networkAdapter.fetchNetworkState().isConnected
        logger.info("Initializing Phase SDK (baseURL: \(config.baseURL), isOnline: \(isOnline))")

        let client = HTTPClient(apiKey: config.apiKey, baseURL: config.baseURL, debugData: config.debugData)
        let queue = OfflineQueue(storage: storage)
        await queue.initialize()

        let sender = BatchSender(
            httpClient: client,
            offlineQueue: queue,
            isOnline: isOnline,
            onDelivered: { [weak self] in
                await self?.components?.session.markActivity()
            }
        )

        let device = DeviceManager(sender: sender, storage: storage, getDeviceInfo: getDeviceInfo, config: config)
        let deviceID = await device.initialize()

        let session = SessionManager(sender: sender, deviceID: deviceID)
        let events = EventManager(
            buffer: capturedEvents,
            sender: sender,
            getSession: { await session.currentSession() }
        )
        let components = Components(sender: sender, device: device, session: session, events: events)

        observeNetwork(networkAdapter, sender: sender)
        observeLifecycle(components)

        let pendingIdentify = state.withLock { state -> [String: Any]?? in
            state.components = components
            state.initializationTask = nil
            let pending = state.pendingIdentify
            state.pendingIdentify = nil
            return pending
        }
        logger.info("Phase SDK initialized successfully. Call identify() to start tracking.")

        // Anything left in the queue from a previous launch.
        await sender.requestFlush()

        if let properties = pendingIdentify {
            await identifyNow(components, properties: properties.map { DeviceProperties($0) })
        }
    }

    // MARK: - Identity

    /// Register device and start session
    ///
    /// Safe to call before `initialize()` finishes: the call is remembered and runs right after it.
    ///
    /// - Parameter properties: Custom device attributes (optional, primitives only)
    ///
    /// ## Example
    /// ```swift
    /// // Basic usage
    /// await PhaseSDK.shared.identify()
    ///
    /// // After login
    /// await PhaseSDK.shared.identify(["user_id": "123", "plan": "premium"])
    /// ```
    public func identify(_ properties: DeviceProperties? = nil) async {
        if let resetting = state.withLock({ $0.resetTask }) {
            await resetting.value
        }

        let components = state.withLock { state -> Components? in
            if let components = state.components {
                return components
            }
            let existing = state.pendingIdentify.flatMap { $0 } ?? [:]
            let merged = existing.merging(properties?.dictionary ?? [:]) { _, new in new }
            state.pendingIdentify = .some(merged.isEmpty ? nil : merged)
            return nil
        }

        guard let components else {
            logger.info("SDK not initialized yet. identify() will run after initialization.")
            return
        }

        await identifyNow(components, properties: properties)
    }

    private func identifyNow(_ components: Components, properties: DeviceProperties?) async {
        await components.device.identify(properties: properties)
        await components.session.start(earliestActivity: capturedEvents.earliestTimestamp())

        state.withLock { $0.isIdentified = true }
        logger.info("Device identified and session started")

        await components.events.deliverPending()
        await components.sender.requestFlush()
    }

    /// Forget the current device (e.g. on logout)
    ///
    /// Ends the session, tries to deliver queued data, discards what could not be sent and
    /// generates a new device ID. Call `identify()` again to start tracking the new device.
    /// Events tracked in the meantime are kept and sent after that `identify()`.
    public func reset() async {
        let task = state.withLock { state -> Task<Void, Never> in
            if let running = state.resetTask {
                return running
            }
            let task = Task { await self.performReset() }
            state.resetTask = task
            return task
        }
        await task.value
    }

    private func performReset() async {
        let components = state.withLock { state -> Components? in
            state.isIdentified = false
            state.pendingIdentify = nil
            return state.components
        }

        defer { state.withLock { $0.resetTask = nil } }

        guard let components else {
            logger.warn("reset() called before initialization. Nothing to reset.")
            return
        }

        // Events captured before reset() belong to the old session.
        await components.events.deliverPending()
        await components.session.end()

        await components.sender.flush()
        let discarded = await components.sender.clearQueue()
        if discarded > 0 {
            logger.warn("reset() discarded \(discarded) unsent item(s).")
        }

        let newDeviceID = await components.device.resetIdentity()
        await components.session.reset(deviceID: newDeviceID)
        logger.info("SDK reset. Call identify() to start tracking again.")
    }

    // MARK: - Tracking

    /// Track custom event
    ///
    /// Events tracked before `initialize()`/`identify()` complete are kept (up to 200, for up to an
    /// hour) with their original timestamps and sent once a session exists.
    ///
    /// - Parameters:
    ///   - name: Event name (required, letters, digits, `_`, `-`, `.`, `/`, space)
    ///   - params: Event parameters (optional, primitives only)
    ///
    /// ## Example
    /// ```swift
    /// PhaseSDK.shared.track("purchase", params: ["amount": 99.99, "currency": "USD"])
    /// ```
    public func track(_ name: String, params: EventParams? = nil) {
        capture(name: name, params: params, isScreen: false)
    }

    /// Track screen view (for SwiftUI, prefer `.phaseScreen()` modifier)
    ///
    /// - Parameters:
    ///   - name: Screen name (required, use path format like "/home")
    ///   - params: Additional parameters (optional, primitives only)
    ///
    /// ## Example
    /// ```swift
    /// PhaseSDK.shared.trackScreen("/profile", params: ["user_id": "123"])
    /// ```
    public func trackScreen(_ name: String, params: EventParams? = nil) {
        capture(name: name, params: params, isScreen: true)
    }

    /// Track custom event (static convenience method)
    public static func track(_ name: String, _ params: [String: Any]? = nil) {
        shared.track(name, params: params.map { EventParams($0) })
    }

    /// Track screen view (static convenience method)
    public static func trackScreen(_ name: String, _ params: [String: Any]? = nil) {
        shared.trackScreen(name, params: params.map { EventParams($0) })
    }

    /// Send queued data now
    ///
    /// Returns when the attempt finishes. Does nothing while offline or while the server asked the
    /// SDK to back off; data stays queued and is retried automatically.
    public func flush() async {
        guard let components else { return }
        await components.events.deliverPending()
        await components.sender.flush()
        await components.sender.persist()
    }

    private func capture(name: String, params: EventParams?, isScreen: Bool) {
        guard case .success = Validator.validateEventName(name) else {
            logger.error("Invalid event name '\(name)'. Use letters, digits, _, -, ., /, or space (max 256).")
            return
        }

        if case .failure(let error) = Validator.validateEventParams(params) {
            logger.error("Invalid event params for '\(name)'.", error)
            return
        }

        guard rateLimiter.canTrack() else {
            return
        }

        guard !deduplicator.isDuplicate(name: name, params: params) else {
            logger.warn("Duplicate event detected. Ignoring: \(name)")
            return
        }

        capturedEvents.append(
            CapturedEvent(
                eventId: IDGenerator.generateEventID(),
                name: name,
                params: params?.dictionary.mapValues { AnyCodable($0) },
                isScreen: isScreen,
                timestamp: Date()
            ))

        // Before identify() the event waits in the buffer and is delivered by identify().
        let ready = state.withLock { $0.isIdentified ? $0.components : nil }
        guard let events = ready?.events else { return }
        Task {
            await events.deliverPending()
        }
    }

    // MARK: - Environment

    private func observeNetwork(_ adapter: NetworkAdapter, sender: BatchSender) {
        let sequence = networkSequence
        let unsubscribe = adapter.addNetworkListener { state in
            let current = sequence.withLock { value -> Int in
                value += 1
                return value
            }
            Task {
                await sender.updateNetworkState(isOnline: state.isConnected, sequence: current)
            }
        }
        networkUnsubscribe.withLock { $0 = unsubscribe }
    }

    private func observeLifecycle(_ components: Components) {
        #if canImport(UIKit)
            let observer = AppLifecycleObserver(
                onBackground: { sequence in
                    await components.session.pause(sequence: sequence)
                    await components.events.deliverPending()
                    // Persist first: suspension can come before the network does.
                    await components.sender.persist()
                    await components.sender.flush()
                    await components.sender.persist()
                },
                onForeground: { sequence in
                    await components.session.resume(sequence: sequence)
                    await components.sender.requestFlush()
                }
            )
            lifecycleObserver.withLock { $0 = observer }
        #endif
    }

    deinit {
        networkUnsubscribe.withLock { $0?() }
    }
}

/// Track custom event
///
/// - Parameters:
///   - name: Event name (required, letters, digits, `_`, `-`, `.`, `/`, space)
///   - params: Event parameters (optional, primitives only)
///
/// ## Example
/// ```swift
/// track("purchase", ["amount": 99.99, "currency": "USD"])
/// ```
public func track(_ name: String, _ params: [String: Any]? = nil) {
    PhaseSDK.track(name, params)
}

/// Track screen view
///
/// - Parameters:
///   - name: Screen name (required, use path format like "/home")
///   - params: Additional parameters (optional, primitives only)
///
/// ## Example
/// ```swift
/// trackScreen("/profile", ["user_id": "123"])
/// ```
public func trackScreen(_ name: String, _ params: [String: Any]? = nil) {
    PhaseSDK.trackScreen(name, params)
}
