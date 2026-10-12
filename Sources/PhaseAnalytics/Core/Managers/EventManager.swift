import Foundation

/// An event as captured at the `track()` call site: validated, stamped with its id and time,
/// and already past rate limiting and deduplication, so replaying it later cannot change it.
internal struct CapturedEvent: Sendable {
    let eventId: String
    let name: String
    let params: [String: AnyCodable]?
    let isScreen: Bool
    let timestamp: Date
}

/// Events captured but not yet queued, e.g. before `initialize()`/`identify()` finished.
internal final class CapturedEventBuffer: Sendable {
    private let events = ThreadSafeLock<[CapturedEvent]>([])

    static let maxEvents = 200
    /// Older events would fall outside any session the server accepts.
    static let maxAge: TimeInterval = 60 * 60

    func append(_ event: CapturedEvent) {
        events.withLock { events in
            if events.count >= Self.maxEvents {
                events.removeFirst()
                logger.warn("More than \(Self.maxEvents) events waiting for identify(). Dropped the oldest.")
            }
            events.append(event)
        }
    }

    /// Removes and returns all deliverable events in capture order.
    func drain() -> [CapturedEvent] {
        events.withLock { events in
            let drained = Self.dropExpired(events)
            events = []
            return drained
        }
    }

    /// Puts undelivered events back in front of anything captured since.
    func restore(_ restored: [CapturedEvent]) {
        guard !restored.isEmpty else { return }
        events.withLock { events in
            events = Array((restored + events).suffix(Self.maxEvents))
        }
    }

    func earliestTimestamp() -> Date? {
        events.withLock { events in
            events = Self.dropExpired(events)
            return events.first?.timestamp
        }
    }

    private static func dropExpired(_ events: [CapturedEvent]) -> [CapturedEvent] {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let fresh = events.filter { $0.timestamp >= cutoff }
        if fresh.count < events.count {
            logger.warn("Dropped \(events.count - fresh.count) event(s) captured over an hour before identify().")
        }
        return fresh
    }
}

internal actor EventManager {
    private let buffer: CapturedEventBuffer
    private let sender: BatchSender
    private let getSession: @Sendable () async -> SessionSnapshot?
    private var isDelivering = false

    init(
        buffer: CapturedEventBuffer,
        sender: BatchSender,
        getSession: @escaping @Sendable () async -> SessionSnapshot?
    ) {
        self.buffer = buffer
        self.sender = sender
        self.getSession = getSession
    }

    /// Moves captured events into the offline queue in capture order. Concurrent calls coalesce
    /// into the running loop, which keeps draining until the buffer is empty.
    func deliverPending() async {
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }

        while true {
            let events = buffer.drain()
            guard !events.isEmpty else { return }

            guard let session = await getSession() else {
                buffer.restore(events)
                return
            }

            for event in events {
                await sender.enqueue(.event(payload: payload(for: event, in: session), clientOrder: 0, retryCount: nil))
            }
        }
    }

    private func payload(for event: CapturedEvent, in session: SessionSnapshot) -> CreateEventRequest {
        // The server rejects events timestamped before their session's start (possible when an
        // event was captured just before the session rotated), so pin those to the start.
        let timestamp = max(event.timestamp, session.startedAt)

        return CreateEventRequest(
            sessionId: session.id,
            name: event.name,
            params: event.params,
            isScreen: event.isScreen,
            timestamp: iso8601Timestamp(timestamp),
            eventId: event.eventId
        )
    }
}
