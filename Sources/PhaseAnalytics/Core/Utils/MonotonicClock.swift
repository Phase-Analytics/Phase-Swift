import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Seconds on a monotonic clock that keeps counting while the device sleeps.
///
/// Used for session age and inactivity so wall-clock changes cannot rotate or extend sessions.
/// `ProcessInfo.systemUptime` is not used because it stops while the device is asleep, which
/// would undercount time spent locked in the background.
internal func monotonicNow() -> TimeInterval {
    #if canImport(Darwin)
        return TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    #else
        return ProcessInfo.processInfo.systemUptime
    #endif
}
