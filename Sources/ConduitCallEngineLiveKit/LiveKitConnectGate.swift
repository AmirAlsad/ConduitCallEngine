//
//  LiveKitConnectGate.swift
//  ConduitCallEngine
//
//  The connection-readiness logic for `LiveKitTransport`, kept pure and SDK-free so
//  the one nontrivial decision is unit-testable. `.connected` is reported once, only
//  when the room is connected AND a remote participant is present — mirroring
//  Daily's transport-ready AND bot-ready rule, so the call never reports connected
//  before the user can be heard. Also decides the disconnect reason.
//

import ConduitCallEngine

struct LiveKitConnectGate {
    private(set) var roomConnected = false
    private(set) var hasRemote = false
    private(set) var reportedConnected = false
    /// Set when the engine initiates the disconnect, so a teardown isn't mistaken for a
    /// network drop (which would trigger the engine's reconnect loop).
    var userRequestedDisconnect = false

    mutating func roomDidConnect() -> TransportEvent? {
        roomConnected = true
        return readyEvent()
    }

    mutating func remoteDidJoin() -> TransportEvent? {
        hasRemote = true
        return readyEvent()
    }

    /// A remote left. `remotesRemain` is whether any remote is still in the room.
    /// Only the last remote leaving an established call is a `.botLeft` disconnect.
    mutating func remoteDidLeave(remotesRemain: Bool) -> TransportEvent? {
        hasRemote = remotesRemain
        guard reportedConnected, !remotesRemain else { return nil }
        return .disconnected(reason: .botLeft)
    }

    func roomDidDisconnect() -> TransportEvent {
        .disconnected(reason: userRequestedDisconnect ? .requestedByUser : .networkDropped)
    }

    private mutating func readyEvent() -> TransportEvent? {
        guard !reportedConnected, roomConnected, hasRemote else { return nil }
        reportedConnected = true
        return .connected
    }
}
