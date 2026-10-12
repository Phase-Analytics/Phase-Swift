import Foundation

/// Owns delivery of the offline queue: flushes on size, on a timer while items are pending,
/// on demand, and when connectivity returns. Items are removed only after the server answers.
internal actor BatchSender {
    private let httpClient: HTTPClient
    private let offlineQueue: OfflineQueue
    private let onDelivered: @Sendable () async -> Void

    private var isOnline: Bool
    private var lastNetworkSequence = 0
    private var flushTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var backoffUntil: TimeInterval = 0
    private var retryAfterUntil: TimeInterval = 0

    static let flushThreshold = 20
    static let flushInterval: TimeInterval = 10
    /// Kept well below the server's new-device rejection threshold (100 events per batch).
    static let maxBatchItems = 50
    static let maxItemRetries = 5
    private static let baseBackoff: TimeInterval = 2
    private static let maxBackoff: TimeInterval = 300

    private enum Step {
        case next
        case stop
    }

    init(
        httpClient: HTTPClient,
        offlineQueue: OfflineQueue,
        isOnline: Bool,
        onDelivered: @escaping @Sendable () async -> Void = {}
    ) {
        self.httpClient = httpClient
        self.offlineQueue = offlineQueue
        self.isOnline = isOnline
        self.onDelivered = onDelivered
    }

    // MARK: - Enqueue

    func enqueue(_ item: BatchItem) async {
        let size = await offlineQueue.enqueue(item)
        scheduleAfterEnqueue(size: size)
    }

    /// Heartbeats keep realtime presence accurate, so they are sent right away (respecting backoff)
    /// and travel through the queue to stay behind the session they refer to.
    func enqueuePing(_ payload: PingSessionRequest) async {
        await offlineQueue.upsertPing(payload)
        startFlush()
    }

    // MARK: - Flush control

    func flush() async {
        if let running = flushTask {
            await running.value
        }
        await startFlush().value
    }

    /// Starts a flush if none is running and returns without waiting for it.
    func requestFlush() {
        startFlush()
    }

    /// `sequence` increases with every connectivity callback, so updates delivered out of order by
    /// separate tasks cannot leave a stale state behind.
    func updateNetworkState(isOnline: Bool, sequence: Int) async {
        guard sequence > lastNetworkSequence else { return }
        lastNetworkSequence = sequence

        let cameOnline = isOnline && !self.isOnline
        self.isOnline = isOnline
        guard cameOnline else { return }

        // Transport backoff is moot once connectivity returns; a server Retry-After still applies.
        consecutiveFailures = 0
        backoffUntil = 0
        if await offlineQueue.getSize() > 0 {
            logger.info("Network restored, flushing offline queue")
            startFlush()
        }
    }

    func persist() async {
        await offlineQueue.persistNow()
    }

    /// Drops everything queued and returns how many items were discarded.
    @discardableResult
    func clearQueue() async -> Int {
        timerTask?.cancel()
        timerTask = nil
        if let running = flushTask {
            running.cancel()
            await running.value
        }
        consecutiveFailures = 0
        backoffUntil = 0
        retryAfterUntil = 0
        let discarded = await offlineQueue.getSize()
        await offlineQueue.clear()
        return discarded
    }

    private func scheduleAfterEnqueue(size: Int) {
        if size >= Self.flushThreshold {
            startFlush()
        } else {
            scheduleTimer(after: Self.flushInterval)
        }
    }

    @discardableResult
    private func startFlush() -> Task<Void, Never> {
        if let running = flushTask {
            return running
        }

        timerTask?.cancel()
        timerTask = nil

        let task = Task { await self.runFlush() }
        flushTask = task
        return task
    }

    private func scheduleTimer(after delay: TimeInterval) {
        guard timerTask == nil else { return }

        let nanoseconds = UInt64(max(delay, 0.1) * 1_000_000_000)
        timerTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            await self?.timerFired()
        }
    }

    private func timerFired() {
        timerTask = nil
        startFlush()
    }

    // MARK: - Delivery

    private func runFlush() async {
        defer { flushTask = nil }

        var delivered = false
        while !Task.isCancelled, isOnline {
            let wait = max(backoffUntil, retryAfterUntil) - monotonicNow()
            if wait > 0 {
                scheduleTimer(after: wait)
                break
            }

            let batch = await offlineQueue.peek(limit: Self.maxBatchItems)
            if batch.isEmpty {
                break
            }

            let (step, accepted) = await send(batch)
            delivered = delivered || accepted
            if case .stop = step {
                break
            }
        }

        if delivered {
            await onDelivered()
        }

        if !Task.isCancelled, isOnline, await offlineQueue.getSize() > 0 {
            scheduleTimer(after: Self.flushInterval)
        }
    }

    private func send(_ batch: [BatchItem]) async -> (Step, Bool) {
        let orders = Set(batch.map { $0.clientOrder })

        switch await httpClient.sendBatch(BatchRequest(items: batch)) {
        case .failure(let failure):
            if failure.isCancelled {
                return (.stop, false)
            }
            if !failure.isRetryable {
                logger.error("Batch could not be sent. Dropping \(batch.count) item(s).", failure.error)
                await offlineQueue.remove(clientOrders: orders)
                return (.next, false)
            }
            logger.warn("Batch send failed. Will retry.")
            registerFailure(retryAfter: nil)
            return (.stop, false)

        case .success(let response):
            return await handle(response, orders: orders)
        }
    }

    private func handle(_ response: HTTPResponse, orders: Set<Int>) async -> (Step, Bool) {
        let status = response.statusCode

        if (200..<300).contains(status) {
            consecutiveFailures = 0
            guard let body = httpClient.decodeBatchResponse(response.data) else {
                if status == 200 {
                    await offlineQueue.remove(clientOrders: orders)
                    return (.next, true)
                }
                // Partial success we cannot attribute: retry everything (server dedups by id).
                await offlineQueue.recordFailedAttempt(clientOrders: orders, maxRetries: Self.maxItemRetries)
                return (.stop, false)
            }
            return await applyItemResults(body, orders: orders)
        }

        let failure = HTTPFailure.status(response, message: httpClient.errorMessage(response))
        guard failure.isRetryable else {
            consecutiveFailures = 0
            logger.error("Batch rejected with HTTP \(status). Dropping \(orders.count) item(s).", failure.error)
            await offlineQueue.remove(clientOrders: orders)
            return (.next, false)
        }

        // A 500 means the app server failed on this payload; count it against the items so a poison
        // batch cannot block the queue forever. Gateway/availability errors and 408/429 do not count.
        if status >= 500, ![502, 503, 504].contains(status) {
            await offlineQueue.recordFailedAttempt(clientOrders: orders, maxRetries: Self.maxItemRetries)
        }
        logger.warn("Batch failed with HTTP \(status). Will retry.")
        registerFailure(retryAfter: response.retryAfter)
        return (.stop, false)
    }

    private func applyItemResults(_ body: BatchResponse, orders: Set<Int>) async -> (Step, Bool) {
        var retryable = Set<Int>()
        for error in body.errors {
            guard let order = error.clientOrder, orders.contains(order) else { continue }
            if error.retryable == true {
                retryable.insert(order)
            } else {
                logger.warn("Batch item \(order) rejected (\(error.code)): \(error.detail)")
            }
        }

        await offlineQueue.remove(clientOrders: orders.subtracting(retryable))
        let dropped = await offlineQueue.recordFailedAttempt(
            clientOrders: retryable, maxRetries: Self.maxItemRetries)
        if dropped > 0 {
            logger.warn("Dropped \(dropped) item(s) after \(Self.maxItemRetries) failed attempts.")
        }

        let accepted = (body.processed ?? 0) > 0 || !body.results.isEmpty
        // Stop on retryable items so they are retried on the next tick instead of in a hot loop.
        return (retryable.isEmpty ? .next : .stop, accepted)
    }

    private func registerFailure(retryAfter: TimeInterval?) {
        consecutiveFailures += 1
        let now = monotonicNow()

        let exponent = Double(min(consecutiveFailures - 1, 16))
        let ceiling = min(Self.maxBackoff, Self.baseBackoff * pow(2, exponent))
        backoffUntil = now + Double.random(in: (ceiling / 2)...ceiling)

        if let retryAfter {
            retryAfterUntil = now + retryAfter
        }
        scheduleTimer(after: max(backoffUntil, retryAfterUntil) - now)
    }
}
