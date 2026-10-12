import Foundation
import ULID

internal struct IDGenerator {
    static func generateDeviceID() -> String {
        return ULID().ulidString
    }

    static func generateSessionID() -> String {
        return ULID().ulidString
    }

    static func generateEventID() -> String {
        return ULID().ulidString
    }
}

// ISO8601DateFormatter is thread-safe; sharing one avoids allocating a formatter per event.
nonisolated(unsafe) private let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

internal func iso8601Timestamp(_ date: Date) -> String {
    return iso8601Formatter.string(from: date)
}

internal func currentISO8601Timestamp() -> String {
    return iso8601Timestamp(Date())
}
