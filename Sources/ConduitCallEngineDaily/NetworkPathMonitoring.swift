//
//  NetworkPathMonitoring.swift
//  ConduitCallEngine
//
//  The seam over `NWPathMonitor` that `DailyInterruptionReporter` watches, so
//  tests drive path changes without a network.
//

import Foundation
import Network

protocol NetworkPathMonitoring: AnyObject {
    /// Start watching. `handler` receives whether the path is satisfied, on a queue
    /// of the monitor's choosing: first for the current path, then on each change
    /// (including changes that keep it satisfied, such as Wi-Fi to cellular).
    func start(_ handler: @escaping @Sendable (Bool) -> Void)
    /// Stop watching; no delivery follows that was not already in flight.
    func cancel()
}

final class SystemNetworkPathMonitor: NetworkPathMonitoring {
    private let queue = DispatchQueue(label: "ConduitCallEngineDaily.NetworkPath")
    private var monitor: NWPathMonitor?

    deinit {
        monitor?.cancel()
    }

    func start(_ handler: @escaping @Sendable (Bool) -> Void) {
        monitor?.cancel()
        // A cancelled NWPathMonitor cannot be restarted, so each start gets a new one.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in handler(path.status == .satisfied) }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    func cancel() {
        monitor?.cancel()
        monitor = nil
    }
}
