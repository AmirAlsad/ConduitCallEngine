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

    // MARK: - A connect while the client is still in the call

    @Test(arguments: [DailyInterruptionGate.Phase.waitingForConnect, .connected, .interrupted, .closed])
    func aClientOutOfTheCallJoins(interruption: DailyInterruptionGate.Phase) {
        #expect(connectedGate().planConnect(sessionIsInCall: false, interruption: interruption) == .join)
        #expect(DailyConnectionGate().planConnect(sessionIsInCall: false, interruption: interruption) == .join)
    }

    @Test func aConnectedCallWhosePathIsUpHasHealed() {
        #expect(connectedGate().planConnect(sessionIsInCall: true, interruption: .connected) == .reportConnected)
    }

    @Test func aConnectedCallWhosePathIsDownIsStillHealing() {
        #expect(connectedGate().planConnect(sessionIsInCall: true, interruption: .interrupted) == .refuse)
    }

    /// The engine connects again only once it has given up on the join in progress
    /// (its join deadline ran out, or a hold paused the attempt): the join whose bot
    /// never got ready is not the call's any more, and refusing would fail every
    /// later attempt while the client stays in that room.
    @Test(arguments: [DailyInterruptionGate.Phase.waitingForConnect, .connected, .interrupted])
    func aJoinWhoseBotNeverGotReadyIsTakenOver(interruption: DailyInterruptionGate.Phase) {
        var gate = DailyConnectionGate()
        gate.connectDidStart()

        #expect(gate.planConnect(sessionIsInCall: true, interruption: interruption) == .takeOver)
    }

    @Test func anAttemptThatIsOverIsNeverReportedConnectedAgain() {
        var dropped = connectedGate()
        _ = dropped.transportDidDisconnect()
        var botLeft = connectedGate()
        _ = botLeft.botDidLeave()

        #expect(dropped.planConnect(sessionIsInCall: true, interruption: .connected) == .takeOver)
        #expect(botLeft.planConnect(sessionIsInCall: true, interruption: .connected) == .takeOver)
    }

    // MARK: - Presence as ready (experimental ring-join strategies)

    @Test func aDefaultGateDoesNotCountPresenceAsReady() {
        var gate = DailyConnectionGate()
        gate.connectDidStart()

        #expect(gate.transportDidJoin(remotePresent: true) == nil)
        #expect(gate.botDidJoin() == nil)
        #expect(gate.transportDidBecomeReady() == .connected)
    }

    @Test func presenceConnectsOnceJoinedWithTheBotInEitherOrder() {
        var joinedFirst = DailyConnectionGate(readyOnPresence: true)
        joinedFirst.connectDidStart()
        #expect(joinedFirst.transportDidJoin(remotePresent: false) == nil)
        #expect(joinedFirst.botDidJoin() == .connected)

        var botFirst = DailyConnectionGate(readyOnPresence: true)
        botFirst.connectDidStart()
        #expect(botFirst.botDidJoin() == nil)
        #expect(botFirst.transportDidJoin(remotePresent: false) == .connected)

        var alreadyThere = DailyConnectionGate(readyOnPresence: true)
        alreadyThere.connectDidStart()
        #expect(alreadyThere.transportDidJoin(remotePresent: true) == .connected)
    }

    /// The bot becomes ready after the answer subscribes to its audio; the call was
    /// already reported connected on presence.
    @Test func presenceAndLaterReadinessConnectOnce() {
        var gate = DailyConnectionGate(readyOnPresence: true)
        gate.connectDidStart()

        #expect(gate.transportDidJoin(remotePresent: true) == .connected)
        #expect(gate.transportDidJoin(remotePresent: true) == nil)
        #expect(gate.transportDidBecomeReady() == nil)
    }

    @Test func eachAttemptKeepsCountingPresenceAndStartsUnjoined() {
        var gate = DailyConnectionGate(readyOnPresence: true)
        gate.connectDidStart()
        _ = gate.transportDidJoin(remotePresent: true)
        _ = gate.transportDidDisconnect()

        gate.connectDidStart()

        #expect(gate.readyOnPresence)
        #expect(gate.botDidJoin() == nil)
        #expect(gate.transportDidJoin(remotePresent: false) == .connected)
    }

    @Test func presenceAfterTheHostDisconnectedIsNotReported() {
        var gate = DailyConnectionGate(readyOnPresence: true)
        gate.connectDidStart()
        gate.userDidRequestDisconnect()

        #expect(gate.transportDidJoin(remotePresent: true) == nil)
    }
}
