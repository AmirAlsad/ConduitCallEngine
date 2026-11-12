//
//  LiveKitConnectGateTests.swift
//  ConduitCallEngineLiveKitTests
//
//  The pure connection gate for LiveKitTransport: `.connected` only when the room
//  and the agent are both ready, exactly once; the disconnect reason; `.botLeft`
//  when the agent leaves an established call; and SDK reconnect completions, which
//  report `.connected` only for a usable room and otherwise become the drop.
//

import Testing
import ConduitCallEngine
@testable import ConduitCallEngineLiveKit

struct LiveKitConnectGateTests {
    @Test func connectedOnlyWhenRoomAndRemoteBothReady() {
        var gate = LiveKitConnectGate()
        #expect(gate.roomDidConnect() == nil)          // room up, no agent yet
        #expect(gate.remoteDidJoin() == .connected)    // agent joins → connected
    }

    @Test func connectedRegardlessOfArrivalOrder() {
        var gate = LiveKitConnectGate()
        #expect(gate.remoteDidJoin() == nil)           // agent present first
        #expect(gate.roomDidConnect() == .connected)   // room up → connected
    }

    @Test func connectedReportedOnlyOnce() {
        var gate = LiveKitConnectGate()
        _ = gate.roomDidConnect()
        #expect(gate.remoteDidJoin() == .connected)
        // A second remote joining must not re-report connected.
        #expect(gate.remoteDidJoin() == nil)
    }

    @Test func agentLeavingAnEstablishedCallIsBotLeft() {
        var gate = LiveKitConnectGate()
        _ = gate.roomDidConnect()
        _ = gate.remoteDidJoin()
        #expect(gate.remoteDidLeave(remotesRemain: false) == .disconnected(reason: .botLeft))
    }

    @Test func anotherRemoteRemainingIsNotBotLeft() {
        var gate = LiveKitConnectGate()
        _ = gate.roomDidConnect()
        _ = gate.remoteDidJoin()
        #expect(gate.remoteDidLeave(remotesRemain: true) == nil)
    }

    @Test func remoteLeavingBeforeConnectedIsSilent() {
        var gate = LiveKitConnectGate()
        _ = gate.remoteDidJoin()                        // joined but room not up → not connected
        #expect(gate.remoteDidLeave(remotesRemain: false) == nil)
    }

    @Test func disconnectReasonReflectsWhoEndedIt() {
        var dropped = connectedGate()
        #expect(dropped.roomDidDisconnect() == .disconnected(reason: .networkDropped))

        var hungUp = connectedGate()
        hungUp.userRequestedDisconnect = true
        #expect(hungUp.roomDidDisconnect() == .disconnected(reason: .requestedByUser))
    }

    // MARK: - Room disconnects

    private func connectedGate() -> LiveKitConnectGate {
        var gate = LiveKitConnectGate()
        _ = gate.roomDidConnect()
        _ = gate.remoteDidJoin()
        return gate
    }

    @Test func aRoomDisconnectIsReportedOnce() {
        var gate = connectedGate()

        #expect(gate.roomDidDisconnect() == .disconnected(reason: .networkDropped))
        #expect(gate.roomDidDisconnect() == nil)
    }

    @Test func aDisconnectBeforeThisAttemptsRoomConnectedBelongsToAnEarlierSession() {
        var gate = LiveKitConnectGate()

        #expect(gate.roomDidDisconnect() == nil)
        #expect(gate.roomDidConnect() == nil)
        #expect(gate.remoteDidJoin() == .connected)
    }

    @Test func nothingConnectsAfterAReportedDisconnect() {
        var gate = LiveKitConnectGate()
        _ = gate.roomDidConnect()
        #expect(gate.roomDidDisconnect() == .disconnected(reason: .networkDropped))

        #expect(gate.remoteDidJoin() == nil)
        #expect(gate.roomDidConnect() == nil)
        #expect(gate.reconnectDidComplete(roomConnected: true, remotesPresent: true) == nil)
    }

    // MARK: - A dead attempt

    /// A participant-left that the SDK delivers after this attempt's drop belongs to the
    /// dropped room; reporting it as `.botLeft` would end a call the engine is reconnecting.
    @Test func aRemoteLeavingAfterTheDropWasReportedIsNotBotLeft() {
        var gate = connectedGate()
        #expect(gate.roomDidDisconnect() == .disconnected(reason: .networkDropped))

        #expect(gate.remoteDidLeave(remotesRemain: false) == nil)
    }

    @Test func aRemoteLeavingAfterAnAbandonedReconnectIsNotBotLeft() {
        var gate = connectedGate()
        #expect(gate.reconnectDidComplete(roomConnected: false, remotesPresent: false)
            == .disconnected(reason: .networkDropped))

        #expect(gate.remoteDidLeave(remotesRemain: false) == nil)
    }

    @Test func theAgentLeavingEndsTheAttempt() {
        var gate = connectedGate()
        #expect(gate.remoteDidLeave(remotesRemain: false) == .disconnected(reason: .botLeft))

        #expect(gate.roomDidDisconnect() == nil)
        #expect(gate.reconnectDidComplete(roomConnected: true, remotesPresent: true) == nil)
    }

    @Test func aReconnectStartReportsReconnectingOnlyWhileTheAttemptLives() {
        var gate = connectedGate()
        #expect(gate.reconnectDidStart() == .reconnecting)

        _ = gate.roomDidDisconnect()
        #expect(gate.reconnectDidStart() == nil)

        var hungUp = connectedGate()
        hungUp.userRequestedDisconnect = true
        #expect(hungUp.reconnectDidStart() == nil)
    }

    @Test func nothingConnectsAfterTheHostDisconnected() {
        var gate = LiveKitConnectGate()
        _ = gate.roomDidConnect()
        gate.userRequestedDisconnect = true

        #expect(gate.remoteDidJoin() == nil)
        #expect(gate.roomDidDisconnect() == .disconnected(reason: .requestedByUser))
    }

    @Test func theAgentLeavingAfterTheHostDisconnectedIsNotBotLeft() {
        var gate = connectedGate()
        gate.userRequestedDisconnect = true

        #expect(gate.remoteDidLeave(remotesRemain: false) == nil)
        #expect(gate.roomDidDisconnect() == .disconnected(reason: .requestedByUser))
    }

    // MARK: - SDK reconnect completion

    @Test func aGenuineReconnectWithTheRemotePresentReportsConnected() {
        var gate = connectedGate()

        #expect(gate.reconnectDidComplete(roomConnected: true, remotesPresent: true) == .connected)
        #expect(gate.reconnectDidComplete(roomConnected: true, remotesPresent: true) == .connected)
        #expect(gate.roomDidDisconnect() == .disconnected(reason: .networkDropped))
    }

    @Test func aCompletionWithNoRemoteIsTheDrop() {
        var gate = connectedGate()

        #expect(gate.reconnectDidComplete(roomConnected: true, remotesPresent: false)
            == .disconnected(reason: .networkDropped))
        // The room's own disconnect, once it is reset, is not a second drop.
        #expect(gate.roomDidDisconnect() == nil)
        #expect(gate.remoteDidJoin() == nil)
    }

    /// LiveKit 2.15.1 offline: a failed full reconnect has cleared the remotes, then
    /// the retry loop gives up silently and marks the room connected again.
    @Test func theCompletionOfAnAbandonedReconnectWhileOfflineIsTheDrop() {
        var gate = connectedGate()
        #expect(gate.roomDidConnect() == nil) // the SDK's reconnecting -> connected

        #expect(gate.reconnectDidComplete(roomConnected: true, remotesPresent: false)
            == .disconnected(reason: .networkDropped))
        #expect(gate.hasReportedDisconnect)
    }

    @Test func aFailedReconnectReportsOneDropWhenTheDisconnectArrivesFirst() {
        var gate = connectedGate()

        #expect(gate.roomDidDisconnect() == .disconnected(reason: .networkDropped))
        #expect(gate.reconnectDidComplete(roomConnected: false, remotesPresent: false) == nil)
    }

    @Test func aFailedReconnectReportsOneDropWhenTheCompletionArrivesFirst() {
        var gate = connectedGate()

        #expect(gate.reconnectDidComplete(roomConnected: false, remotesPresent: false)
            == .disconnected(reason: .networkDropped))
        #expect(gate.roomDidDisconnect() == nil)
    }

    @Test func aCompletionAfterTheHostDisconnectedIsSilent() {
        var gate = connectedGate()
        gate.userRequestedDisconnect = true

        #expect(gate.reconnectDidComplete(roomConnected: false, remotesPresent: false) == nil)
        #expect(gate.roomDidDisconnect() == .disconnected(reason: .requestedByUser))
    }

    @Test func aCompletionBeforeTheAgentJoinedKeepsWaitingForIt() {
        var gate = LiveKitConnectGate()
        _ = gate.roomDidConnect()

        #expect(gate.reconnectDidComplete(roomConnected: true, remotesPresent: false) == nil)
        #expect(gate.remoteDidJoin() == .connected)
    }

    @Test func aCompletionBeforeConnectWithTheAgentPresentConnectsOnce() {
        var gate = LiveKitConnectGate()
        _ = gate.roomDidConnect()

        #expect(gate.reconnectDidComplete(roomConnected: true, remotesPresent: true) == .connected)
        #expect(gate.remoteDidJoin() == nil)
    }
}
