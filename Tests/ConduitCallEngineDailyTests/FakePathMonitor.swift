//
//  FakePathMonitor.swift
//  ConduitCallEngineDailyTests
//
//  Stands in for `NWPathMonitor`, so tests deliver network-path changes by hand.
//

@testable import ConduitCallEngineDaily

final class FakePathMonitor: NetworkPathMonitoring {
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var handlers: [@Sendable (Bool) -> Void] = []
    private var isRunning = false

    func start(_ handler: @escaping @Sendable (Bool) -> Void) {
        startCount += 1
        handlers.append(handler)
        isRunning = true
    }

    func cancel() {
        cancelCount += 1
        isRunning = false
    }

    /// A delivery from the running monitor.
    func deliver(_ isSatisfied: Bool) {
        guard isRunning, let handler = handlers.last else { return }
        handler(isSatisfied)
    }

    /// A delivery that was already in flight from monitoring run `index`.
    func deliverLate(fromRun index: Int, _ isSatisfied: Bool) {
        handlers[index](isSatisfied)
    }
}
