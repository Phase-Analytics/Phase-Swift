#if canImport(UIKit)
    import UIKit

    /// Forwards app background/foreground transitions. Each transition gets an increasing sequence
    /// number taken on the main queue, so handlers that run out of order can discard stale ones.
    /// Background work runs inside a background task so it can finish before suspension.
    internal final class AppLifecycleObserver: Sendable {
        private let observers = ThreadSafeLock<[NSObjectProtocol]>([])
        private let sequence = ThreadSafeLock(0)

        init(
            onBackground: @escaping @Sendable (_ sequence: Int) async -> Void,
            onForeground: @escaping @Sendable (_ sequence: Int) async -> Void
        ) {
            let center = NotificationCenter.default
            let sequence = self.sequence

            let backgroundObserver = center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                let current = sequence.withLock { value -> Int in
                    value += 1
                    return value
                }
                Task { @MainActor in
                    let backgroundTask = BackgroundTask(name: "PhaseAnalytics.flush")
                    await onBackground(current)
                    backgroundTask.end()
                }
            }

            let foregroundObserver = center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                let current = sequence.withLock { value -> Int in
                    value += 1
                    return value
                }
                Task {
                    await onForeground(current)
                }
            }

            observers.withLock { $0 = [backgroundObserver, foregroundObserver] }
        }

        deinit {
            observers.withLock { observers in
                for observer in observers {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
    }

    /// Keeps the app running briefly after it is backgrounded; ends itself on expiration.
    @MainActor
    private final class BackgroundTask {
        private var identifier: UIBackgroundTaskIdentifier = .invalid

        init(name: String) {
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                // Unfinished work stays in the persisted queue and is retried on the next launch.
                self?.end()
            }
        }

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
#endif
