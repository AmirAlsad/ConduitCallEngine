//
//  DailyInterruptionReporterTests.swift
//  ConduitCallEngineDailyTests
//
//  The wiring between the network-path seam and the gate: when the monitor runs,
//  that its first delivery is skipped, that deliveries reach the gate on the main
//  actor, and that a cancelled or replaced monitor can no longer emit. The real
//  `NWPathMonitor` is smoke-tested for its initial delivery; how real outages look
//  to it is device-only.
//

import Foundation
import Testing
import ConduitCallEngine
@testable import ConduitCallEngineDaily

private final class FakePathMonitor: NetworkPathMonitoring {
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

@MainActor
private final class EmittedEvents {
    private(set) var events: [TransportEvent] = []
    func append(_ event: TransportEvent) { events.append(event) }
}

@MainActor
struct DailyInterruptionReporterTests {
    private let monitor = FakePathMonitor()
    private let emitted = EmittedEvents()
    private let reporter: DailyInterruptionReporter

    init() {
        let emitted = emitted
        reporter = DailyInterruptionReporter(pathMonitor: monitor) { emitted.append($0) }
    }

    /// Lets the main-actor hops queued by deliveries run.
    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func connectedReporter() async {
        reporter.connectDidStart()
        reporter.callDidConnect()
        monitor.deliver(true) // the monitor's initial delivery
        await drain()
    }

    @Test func pathIsNotWatchedBeforeTheCallConnects() {
        reporter.connectDidStart()

        #expect(monitor.startCount == 0)
    }

    @Test func monitoringStartsOnConnectAndSkipsTheInitialPath() async {
        reporter.connectDidStart()
        reporter.callDidConnect()
        #expect(monitor.startCount == 1)

        monitor.deliver(true)
        await drain()
        #expect(emitted.events.isEmpty)

        monitor.deliver(false)
        await drain()
        monitor.deliver(true)
        await drain()
        #expect(emitted.events == [.reconnecting, .connected])
    }

    @Test func anUnsatisfiedInitialPathIsSkippedToo() async {
        reporter.callDidConnect()

        monitor.deliver(false)
        await drain()
        monitor.deliver(true)
        await drain()

        #expect(emitted.events.isEmpty)
    }

    @Test func aSecondConnectDoesNotRestartMonitoring() async {
        await connectedReporter()

        reporter.callDidConnect()

        #expect(monitor.startCount == 1)
    }

    @Test func hostDisconnectCancelsMonitoringAndSilencesLateDeliveries() async {
        await connectedReporter()
        monitor.deliver(false)
        await drain()

        reporter.userDidRequestDisconnect()
        #expect(monitor.cancelCount == 1)

        monitor.deliverLate(fromRun: 0, true)
        await drain()
        #expect(emitted.events == [.reconnecting])
    }

    @Test func transportDisconnectCancelsMonitoringAndDropsTheLateRecovery() async {
        await connectedReporter()
        monitor.deliver(false)
        await drain()

        reporter.transportDidDisconnect()
        #expect(monitor.cancelCount == 1)

        monitor.deliverLate(fromRun: 0, true)
        await drain()
        #expect(emitted.events == [.reconnecting])
        #expect(reporter.phase == .waitingForConnect)
    }

    @Test func aNewConnectAttemptRestartsFromAFreshGate() async {
        await connectedReporter()
        monitor.deliver(false)
        await drain()

        reporter.connectDidStart()
        #expect(monitor.cancelCount == 1)
        #expect(reporter.phase == .waitingForConnect)

        reporter.callDidConnect()
        #expect(monitor.startCount == 2)
        monitor.deliver(false) // the new run's initial delivery
        await drain()
        #expect(emitted.events == [.reconnecting])

        monitor.deliver(true)
        await drain()
        monitor.deliver(false)
        await drain()
        #expect(emitted.events == [.reconnecting, .reconnecting])
    }

    @Test func aDeliveryFromAnEarlierRunIsNotTakenAsTheNewRunsInitialPath() async {
        await connectedReporter()
        reporter.connectDidStart()
        reporter.callDidConnect()

        monitor.deliverLate(fromRun: 0, false)
        await drain()
        monitor.deliver(true) // still the new run's initial delivery
        await drain()
        monitor.deliver(false)
        await drain()

        #expect(emitted.events == [.reconnecting])
    }

    @Test func releasingTheReporterReleasesItsMonitor() async {
        weak var releasedMonitor: FakePathMonitor?
        do {
            let monitor = FakePathMonitor()
            releasedMonitor = monitor
            let reporter = DailyInterruptionReporter(pathMonitor: monitor) { _ in }
            reporter.callDidConnect()
            #expect(monitor.startCount == 1)
        }

        #expect(releasedMonitor == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func theSystemMonitorDeliversTheCurrentPathFirst() async {
        let monitor = SystemNetworkPathMonitor()
        let (deliveries, continuation) = AsyncStream.makeStream(of: Bool.self)

        monitor.start { continuation.yield($0) }
        var received = false
        for await _ in deliveries {
            received = true
            break
        }
        monitor.cancel()

        #expect(received)
    }
}
