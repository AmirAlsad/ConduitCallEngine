//
//  LiveKitConnectGateTests.swift
//  ConduitCallEngineLiveKitTests
//
//  The pure connection gate for LiveKitTransport: `.connected` only when the room
//  and the agent are both ready, exactly once; the disconnect reason; and `.botLeft`
//  when the agent leaves an established call.
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
        var gate = LiveKitConnectGate()
        #expect(gate.roomDidDisconnect() == .disconnected(reason: .networkDropped))
        gate.userRequestedDisconnect = true
        #expect(gate.roomDidDisconnect() == .disconnected(reason: .requestedByUser))
    }
}
