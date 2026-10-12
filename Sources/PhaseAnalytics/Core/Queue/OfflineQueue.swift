import Foundation

/// Durable FIFO of batch items. Items leave the queue only when the server has accepted them or
/// rejected them permanently (`remove`), never before a send attempt.
internal actor OfflineQueue {
    private var queue: [BatchItem] = []
    private var nextClientOrder = 0
    private let storage: StorageAdapter

    private var isDirty = false
    private var writer: Task<Bool, Never>?
    private var persistTask: Task<Void, Never>?

    static let maxQueueSize = 1000
    private static let persistDelayNanoseconds: UInt64 = 1_000_000_000

    init(storage: StorageAdapter) {
        self.storage = storage
    }

    func initialize() async {
        let result = await storage.getItem(key: StorageKeys.offlineQueue) as Result<[BatchItem]?, Error>

        if case .success(let items) = result, let items = items, !items.isEmpty {
            // Renumber so clientOrder is unique and increasing regardless of what older SDK versions persisted.
            let ordered = items.sorted { $0.clientOrder < $1.clientOrder }
            queue = ordered.enumerated().map { index, item in
                item.with(clientOrder: index, retryCount: item.retryCount)
            }
            nextClientOrder = queue.count
            logger.info("Loaded \(items.count) items from offline queue")
        } else if case .failure(let error) = result {
            logger.error("Failed to load offline queue. Storage unavailable.", error)
        }
    }

    /// Appends an item with a fresh clientOrder and returns the new queue size.
    @discardableResult
    func enqueue(_ item: BatchItem) -> Int {
        if queue.count >= Self.maxQueueSize {
            dropOldestDisposableItem()
        }

        queue.append(item.with(clientOrder: nextClientOrder, retryCount: nil))
        nextClientOrder += 1
        schedulePersist()
        return queue.count
    }

    /// Keeps at most one pending heartbeat per session; a newer ping supersedes the queued one.
    @discardableResult
    func upsertPing(_ payload: PingSessionRequest) -> Int {
        let existingIndex = queue.firstIndex { item in
            if case .ping(let queued, _, _) = item {
                return queued.sessionId == payload.sessionId
            }
            return false
        }

        guard let index = existingIndex else {
            return enqueue(.ping(payload: payload, clientOrder: 0, retryCount: nil))
        }

        let existing = queue[index]
        queue[index] = .ping(payload: payload, clientOrder: existing.clientOrder, retryCount: existing.retryCount)
        schedulePersist()
        return queue.count
    }

    /// Oldest items in order, stopping where items of a different device begin: the server
    /// rejects a whole batch that mixes devices (e.g. queued data from before `reset()`).
    func peek(limit: Int) -> [BatchItem] {
        var batch: [BatchItem] = []
        var batchDeviceId: String?

        for item in queue {
            guard batch.count < limit else { break }
            if let itemDeviceId = item.deviceId {
                if let batchDeviceId, batchDeviceId != itemDeviceId { break }
                batchDeviceId = itemDeviceId
            }
            batch.append(item)
        }
        return batch
    }

    func remove(clientOrders: Set<Int>) {
        guard !clientOrders.isEmpty else { return }
        queue.removeAll { clientOrders.contains($0.clientOrder) }
        schedulePersist()
    }

    /// Increments retry counts and drops items that exhausted them. Returns the number dropped.
    @discardableResult
    func recordFailedAttempt(clientOrders: Set<Int>, maxRetries: Int) -> Int {
        guard !clientOrders.isEmpty else { return 0 }

        var dropped = 0
        queue = queue.compactMap { item in
            guard clientOrders.contains(item.clientOrder) else { return item }

            let attempts = (item.retryCount ?? 0) + 1
            if attempts > maxRetries {
                dropped += 1
                return nil
            }
            return item.with(clientOrder: item.clientOrder, retryCount: attempts)
        }

        schedulePersist()
        return dropped
    }

    func clear() async {
        queue = []
        // Persisting the empty snapshot through the serialized writer (instead of removing the key)
        // guarantees an in-flight write of the old contents cannot land afterwards.
        isDirty = true
        await persistNow()
    }

    func getSize() -> Int {
        return queue.count
    }

    /// Writes pending changes immediately (used before the app may be suspended).
    func persistNow() async {
        persistTask?.cancel()
        persistTask = nil
        await writeIfDirty()
    }

    private func schedulePersist() {
        isDirty = true
        guard persistTask == nil else { return }

        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.persistScheduled()
        }
    }

    private func persistScheduled() async {
        persistTask = nil
        await writeIfDirty()
    }

    /// Returns once everything changed so far is written (or storage failed). Writes are serialized
    /// so an older snapshot can never land after a newer one.
    private func writeIfDirty() async {
        while true {
            if let writer {
                guard await writer.value else { return }
                continue
            }
            guard isDirty else { return }
            writer = Task { await self.drainWrites() }
        }
    }

    private func drainWrites() async -> Bool {
        defer { writer = nil }

        while isDirty {
            isDirty = false
            let snapshot = queue
            let result = await storage.setItem(key: StorageKeys.offlineQueue, value: snapshot)
            if case .failure(let error) = result {
                isDirty = true
                logger.error("Failed to persist queue. Data may be lost on app crash.", error)
                return false
            }
        }
        return true
    }

    /// Prefers dropping the oldest event or ping so device/session creation items, which later
    /// events depend on, survive overflow.
    private func dropOldestDisposableItem() {
        let disposableIndex = queue.firstIndex { item in
            switch item {
            case .event, .ping: return true
            case .device, .session: return false
            }
        }

        if let index = disposableIndex {
            queue.remove(at: index)
        } else if !queue.isEmpty {
            queue.removeFirst()
        }
        logger.warn("Queue full (\(Self.maxQueueSize)). Dropped oldest item.")
    }
}
