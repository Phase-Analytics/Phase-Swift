import Foundation
import Network

internal final class NetworkMonitor: NetworkAdapter {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.phase.network-monitor")
    private let listeners = ThreadSafeLock<[(UUID, NetworkStateListener)]>([])
    /// Last state reported by the monitor; nil until the first path update arrives.
    private let lastState = ThreadSafeLock<NetworkState?>(nil)

    init() {
        setupPathHandler()
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private func setupPathHandler() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let state = NetworkState(isConnected: path.status == .satisfied)
            self.lastState.withLock { $0 = state }

            let listenersCopy = self.listeners.withLock { Array($0) }
            for (_, listenerFn) in listenersCopy {
                listenerFn(state)
            }
        }
    }

    /// Before the first path update the state is unknown; report connected so delivery is attempted
    /// (a failed send only backs off) rather than stalling until connectivity changes.
    func fetchNetworkState() async -> NetworkState {
        await withCheckedContinuation { continuation in
            queue.async {
                let state = self.lastState.withLock { $0 } ?? NetworkState(isConnected: true)
                continuation.resume(returning: state)
            }
        }
    }

    /// The listener also receives the latest known state, so an update that arrived before
    /// subscribing is not lost.
    func addNetworkListener(_ listener: @escaping NetworkStateListener) -> UnsubscribeFn {
        let id = UUID()

        listeners.withLock { $0.append((id, listener)) }

        // Delivered on the monitor queue so it is ordered with path updates.
        queue.async { [weak self] in
            guard let state = self?.lastState.withLock({ $0 }) else { return }
            listener(state)
        }

        return { [weak self] in
            self?.listeners.withLock { listeners in
                listeners.removeAll { $0.0 == id }
            }
        }
    }
}
