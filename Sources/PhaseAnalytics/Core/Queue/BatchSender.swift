import Foundation

internal actor BatchSender {
    private let httpClient: HTTPClient
    private let offlineQueue: OfflineQueue
    private var isFlushing = false

    private static let flushTimeoutSeconds: TimeInterval = 5.0

    init(httpClient: HTTPClient, offlineQueue: OfflineQueue) {
        self.httpClient = httpClient
        self.offlineQueue = offlineQueue
    }

    func flush() async {
        guard !isFlushing else {
            logger.warn("Flush already in progress. Skipping duplicate flush.")
            return
        }

        isFlushing = true
        defer { isFlushing = false }

        await flushWithTimeout()
    }

    private func flushWithTimeout() async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.flushTimeoutSeconds * 1_000_000_000))
                    throw PhaseError.timeout
                }

                group.addTask {
                    await self.performFlush()
                }

                try await group.next()
                group.cancelAll()
            }
        } catch {
            logger.error("Flush failed or timed out. Dropping remaining items.", error)
        }
    }

    private func performFlush() async {
        let items = await offlineQueue.dequeueAll()
        guard !items.isEmpty else {
            return
        }

        let deduplicatedItems = deduplicateByTimestamp(items)
        let batches = splitIntoBatches(deduplicatedItems)

        for batch in batches {
            do {
                try await sendBatch(batch)
            } catch {
                logger.error("Batch send error. Dropping batch (fire & forget).", error)
            }
        }
    }

    private func sendBatch(_ items: [BatchItem]) async throws {
        let request = BatchRequest(items: items)
        let result = await httpClient.sendBatch(request)

        if case .failure = result {
            logger.warn("Batch request failed. Dropping batch (fire & forget).")
            return
        }

        if case .success(let response) = result, response.failed > 0 {
            let total = (response.processed ?? 0) + response.failed
            logger.warn("Batch partially failed: \(response.failed)/\(total) items dropped.")
        }
    }

    private func deduplicateByTimestamp(_ items: [BatchItem]) -> [BatchItem] {
        var seenEvents: [String: Date] = [:]
        var dedupedItems: [BatchItem] = []
        let dedupWindow: TimeInterval = 0.05

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for item in items {
            if case .event(let payload, _, _) = item {
                let key = createEventKey(name: payload.name, params: payload.params)

                guard let timestamp = iso8601Formatter.date(from: payload.timestamp) else {
                    logger.warn("Invalid timestamp format. Including event anyway.")
                    dedupedItems.append(item)
                    continue
                }

                if let lastTime = seenEvents[key], timestamp.timeIntervalSince(lastTime) < dedupWindow {
                    logger.warn("Duplicate event in batch detected. Dropping event: \(payload.name)")
                    continue
                }

                seenEvents[key] = timestamp
                dedupedItems.append(item)
            } else {
                dedupedItems.append(item)
            }
        }

        let droppedCount = items.count - dedupedItems.count
        if droppedCount > 0 {
            logger.info("Dropped \(droppedCount) duplicate event(s) from batch based on timestamp.")
        }

        return dedupedItems
    }

    private func createEventKey(name: String, params: [String: AnyCodable]?) -> String {
        guard let params = params else {
            return name
        }

        let sortedParams = params.sorted { $0.key < $1.key }
        if let jsonData = try? JSONSerialization.data(
            withJSONObject: sortedParams.reduce(into: [String: Any]()) { dict, pair in
                dict[pair.key] = pair.value.value
            },
            options: [.sortedKeys]
        ),
            let jsonString = String(data: jsonData, encoding: .utf8)
        {
            return "\(name):\(jsonString)"
        }

        return name
    }

    private func splitIntoBatches(_ items: [BatchItem]) -> [[BatchItem]] {
        let maxSize = ValidationConstants.Batch.maxSize
        var batches: [[BatchItem]] = []

        for i in stride(from: 0, to: items.count, by: maxSize) {
            let endIndex = min(i + maxSize, items.count)
            batches.append(Array(items[i..<endIndex]))
        }

        return batches
    }
}
