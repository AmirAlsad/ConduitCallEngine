//
//  DailyInterruptionGateTests.swift
//  ConduitCallEngineDailyTests
//
//  The pure decision behind Daily's inferred interruptions: when a path change
//  becomes `.reconnecting` or `.connected`, and when it must not.
//

import Testing
import ConduitCallEngine
@testable import ConduitCallEngineDaily

struct DailyInterruptionGateTests {
    private func connectedGate() -> DailyInterruptionGate {
        var gate = DailyInterruptionGate()
        gate.callDidConnect()
        return gate
    }

    @Test func pathChangesBeforeConnectAreIgnored() {
        var gate = DailyInterruptionGate()

        #expect(!gate.isWatchingPath)
        #expect(gate.pathDidBecomeUnsatisfied() == nil)
        #expect(gate.pathDidBecomeSatisfied() == nil)
        #expect(gate.phase == .waitingForConnect)
    }

    @Test func interruptionThenRecoveryReportsReconnectingThenConnected() {
        var gate = connectedGate()
        #expect(gate.isWatchingPath)

        #expect(gate.pathDidBecomeUnsatisfied() == .reconnecting)
        #expect(gate.phase == .interrupted)
        #expect(gate.pathDidBecomeSatisfied() == .connected)
        #expect(gate.phase == .connected)
    }

    @Test func eachInterruptionReportsOnce() {
        var gate = connectedGate()

        #expect(gate.pathDidBecomeUnsatisfied() == .reconnecting)
        #expect(gate.pathDidBecomeUnsatisfied() == nil)
        #expect(gate.pathDidBecomeSatisfied() == .connected)
        #expect(gate.pathDidBecomeSatisfied() == nil)
    }

    @Test func laterInterruptionsReportAgain() {
        var gate = connectedGate()
        _ = gate.pathDidBecomeUnsatisfied()
        _ = gate.pathDidBecomeSatisfied()

        #expect(gate.pathDidBecomeUnsatisfied() == .reconnecting)
        #expect(gate.pathDidBecomeSatisfied() == .connected)
    }

    @Test func aSatisfiedPathChangeWhileConnectedIsNotAnInterruption() {
        var gate = connectedGate()

        #expect(gate.pathDidBecomeSatisfied() == nil) // e.g. Wi-Fi to cellular
        #expect(gate.phase == .connected)
    }

    @Test func aDisconnectDuringAnInterruptionSuppressesTheLateRecovery() {
        var gate = connectedGate()
        _ = gate.pathDidBecomeUnsatisfied()

        gate.transportDidDisconnect()

        #expect(!gate.isWatchingPath)
        #expect(gate.pathDidBecomeSatisfied() == nil)
        #expect(gate.pathDidBecomeUnsatisfied() == nil)
    }

    @Test func aDisconnectAfterRecoveryEndsWatching() {
        var gate = connectedGate()
        _ = gate.pathDidBecomeUnsatisfied()
        #expect(gate.pathDidBecomeSatisfied() == .connected)

        gate.transportDidDisconnect()

        #expect(gate.pathDidBecomeUnsatisfied() == nil)
        #expect(gate.phase == .waitingForConnect)
    }

    @Test func nothingIsReportedAfterTheHostDisconnects() {
        var gate = connectedGate()
        _ = gate.pathDidBecomeUnsatisfied()

        gate.userDidRequestDisconnect()

        #expect(gate.phase == .closed)
        #expect(!gate.isWatchingPath)
        #expect(gate.pathDidBecomeSatisfied() == nil)
        gate.callDidConnect()
        gate.transportDidDisconnect()
        #expect(gate.phase == .closed)
        #expect(gate.pathDidBecomeUnsatisfied() == nil)
    }

    @Test func aHostDisconnectBeforeAnyInterruptionReportsNothing() {
        var gate = connectedGate()

        gate.userDidRequestDisconnect()

        #expect(gate.pathDidBecomeUnsatisfied() == nil)
        #expect(gate.pathDidBecomeSatisfied() == nil)
    }

    @Test func aDisconnectBeforeConnectStillLetsTheAttemptConnect() {
        var gate = DailyInterruptionGate()

        gate.transportDidDisconnect()
        gate.callDidConnect()

        #expect(gate.isWatchingPath)
        #expect(gate.pathDidBecomeUnsatisfied() == .reconnecting)
    }

    @Test func aRepeatedConnectDoesNotEndAnInterruption() {
        var gate = connectedGate()
        _ = gate.pathDidBecomeUnsatisfied()

        gate.callDidConnect()

        #expect(gate.phase == .interrupted)
        #expect(gate.pathDidBecomeSatisfied() == .connected)
    }
}
