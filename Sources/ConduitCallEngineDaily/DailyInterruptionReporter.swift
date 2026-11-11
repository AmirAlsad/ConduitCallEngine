//
//  DailyInterruptionReporter.swift
//  ConduitCallEngine
//
//  Feeds the device's network path into `DailyInterruptionGate` and emits what it
//  decides. The path is watched only while the gate needs it (from the call's
//  connect until a disconnect or the next attempt). The monitor's first delivery
//  after each start describes the path as it already is, not a change, so it is
//  skipped. Deliveries hop to the main actor, and one that arrives after its
//  monitor was cancelled or restarted is dropped.
//

import ConduitCallEngine

@MainActor
final class DailyInterruptionReporter {
    private var gate = DailyInterruptionGate()
    private let pathMonitor: NetworkPathMonitoring
    private let emit: @MainActor (TransportEvent) -> Void
    private var isMonitoring = false
    /// Identifies the current monitoring run, so late deliveries from an earlier
    /// run cannot reach the gate.
    private var run = 0
    private var awaitsInitialPath = false

    init(
        pathMonitor: NetworkPathMonitoring = SystemNetworkPathMonitor(),
        emit: @escaping @MainActor (TransportEvent) -> Void
    ) {
        self.pathMonitor = pathMonitor
        self.emit = emit
    }

    var phase: DailyInterruptionGate.Phase { gate.phase }

    func connectDidStart() {
        gate = DailyInterruptionGate()
        updateMonitoring()
    }

    func callDidConnect() {
        gate.callDidConnect()
        updateMonitoring()
    }

    func transportDidDisconnect() {
        gate.transportDidDisconnect()
        updateMonitoring()
    }

    func userDidRequestDisconnect() {
        gate.userDidRequestDisconnect()
        updateMonitoring()
    }

    private func updateMonitoring() {
        if gate.isWatchingPath, !isMonitoring {
            startMonitoring()
        } else if !gate.isWatchingPath, isMonitoring {
            stopMonitoring()
        }
    }

    private func startMonitoring() {
        isMonitoring = true
        run += 1
        awaitsInitialPath = true
        let run = run
        pathMonitor.start { [weak self] isSatisfied in
            Task { @MainActor in self?.pathDidUpdate(isSatisfied: isSatisfied, run: run) }
        }
    }

    private func stopMonitoring() {
        isMonitoring = false
        run += 1
        pathMonitor.cancel()
    }

    private func pathDidUpdate(isSatisfied: Bool, run: Int) {
        guard run == self.run else { return }
        if awaitsInitialPath {
            awaitsInitialPath = false
            return
        }
        let event = isSatisfied ? gate.pathDidBecomeSatisfied() : gate.pathDidBecomeUnsatisfied()
        if let event { emit(event) }
    }
}
