import Foundation
import Network
import Observation

/// Whether the device is online (SPEC 18.2: the traffic layer says when it cannot show anything
/// instead of staying silently empty).
@Observable
final class Connectivity {
    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "spur.connectivity", qos: .utility))
    }

    deinit { monitor.cancel() }
}
