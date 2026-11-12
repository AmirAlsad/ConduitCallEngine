//
//  DailyConnectionGateTests.swift
//  ConduitCallEngineDailyTests
//
//  The pure connection gate for PipecatDailyTransport: `.connected` once per attempt,
//  the disconnect reason, and an attempt that is over (it reported a disconnect, its
//  connect threw, or the host disconnected) reporting nothing more, so a late callback
//  from a dropped call cannot steer the engine's reconnect.
//

import Testing
import ConduitCallEngine
@testable import ConduitCallEngineDaily

struct DailyConnectionGateTests {
    private func connectedGate() -> DailyConnectionGate {
        var gate = DailyConnectionGate()
        gate.connectDidStart()
        _ = gate.transportDidBecomeReady()
        return gate
    }

    @Test func readyConnectsOncePerAttempt() {
        var gate = DailyConnectionGate()
        gate.connectDidStart()

        #expect(gate.transportDidBecomeReady() == .connected)
        #expect(gate.transportDidBecomeReady() == nil)
    }

    @Test func disconnectReasonReflectsWhoEndedIt() {
        var dropped = connectedGate()
        #expect(dropped.transportDidDisconnect() == .disconnected(reason: .networkDropped))

        var hungUp = connectedGate()
        hungUp.userDidRequestDisconnect()
        #expect(hungUp.transportDidDisconnect() == .disconnected(reason: .requestedByUser))
    }

    @Test func theBotLeavingIsBotLeftEvenBeforeReady() {
        var connected = connectedGate()
        #expect(connected.botDidLeave() == .disconnected(reason: .botLeft))

        var connecting = DailyConnectionGate()
        connecting.connectDidStart()
        #expect(connecting.botDidLeave() == .disconnected(reason: .botLeft))
    }

    // MARK: - A dead attempt

    @Test func aDisconnectIsReportedOncePerAttempt() {
        var gate = connectedGate()
        #expect(gate.transportDidDisconnect() == .disconnected(reason: .networkDropped))

        #expect(gate.transportDidDisconnect() == nil)
    }

    /// Daily can deliver the bot's participant-left after the call itself dropped. The
    /// engine is reconnecting by then; a `.botLeft` would end the call as completed.
    @Test func theBotLeavingAfterTheDropIsNotBotLeft() {
        var gate = connectedGate()
        _ = gate.transportDidDisconnect()

        #expect(gate.botDidLeave() == nil)
    }

    @Test func aLateReadyAfterTheDropDoesNotConnect() {
        var gate = DailyConnectionGate()
        gate.connectDidStart()
        #expect(gate.transportDidDisconnect() == .disconnected(reason: .networkDropped))

        #expect(gate.transportDidBecomeReady() == nil)
    }

    /// The Pipecat client reports `.disconnected` when its connect fails, and the
    /// adapter's connect also throws. The engine counts the throw as the failed
    /// attempt; a second report of the same failure would spend another retry.
    @Test func aConnectThatThrewReportsNoDisconnect() {
        var gate = DailyConnectionGate()
        gate.connectDidStart()
        gate.connectDidFail()

        #expect(gate.transportDidDisconnect() == nil)
        #expect(gate.botDidLeave() == nil)
        #expect(gate.transportDidBecomeReady() == nil)
    }

    @Test func theBotLeavingEndsTheAttempt() {
        var gate = connectedGate()
        #expect(gate.botDidLeave() == .disconnected(reason: .botLeft))

        #expect(gate.transportDidDisconnect() == nil)
    }

    @Test func nothingButTheRequestedDisconnectFollowsTheHostsDisconnect() {
        var gate = DailyConnectionGate()
        gate.connectDidStart()
        gate.userDidRequestDisconnect()

        #expect(gate.transportDidBecomeReady() == nil)
        #expect(gate.botDidLeave() == nil)
        #expect(gate.transportDidDisconnect() == .disconnected(reason: .requestedByUser))
    }

    @Test func theNextConnectStartsAFreshAttempt() {
        var gate = connectedGate()
        gate.userDidRequestDisconnect()
        _ = gate.transportDidDisconnect()

        gate.connectDidStart()
        #expect(gate.transportDidBecomeReady() == .connected)
        #expect(gate.transportDidDisconnect() == .disconnected(reason: .networkDropped))
    }
}
