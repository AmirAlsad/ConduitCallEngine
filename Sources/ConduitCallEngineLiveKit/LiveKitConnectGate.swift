//
//  LiveKitConnectGate.swift
//  ConduitCallEngine
//
//  The connection-readiness logic for `LiveKitTransport`, kept pure and SDK-free so
//  its decisions are unit-testable. `.connected` is reported once, only
//  when the room is connected AND a remote participant is present — mirroring
//  Daily's transport-ready AND bot-ready rule, so the call never reports connected
//  before the user can be heard. Also decides the disconnect reason.
//
//  An SDK reconnect that completes goes back through the same rule: the room must
//  be connected and a remote present. A completion with the room not connected is
//  a reconnect LiveKit gave up on: it ends every failed reconnect by cleaning the
//  room up, which reports the disconnect and the completion together, so whichever
//  arrives first is the one drop. A room disconnect is reported at most once per
//  attempt, and only once this attempt's room had connected: a disconnect callback
//  before that belongs to the cleanup of an earlier session (`Room.connect` itself
//  cleans up first).
//
//  A completion with the room connected follows a rejoin that succeeded (LiveKit
//  2.18.0, the package's floor, ends every failed reconnect with the room
//  disconnected). If no remote is in the room then, the agent left while the device
//  was offline, and the call ends as `.botLeft`, as it would had the agent left a
//  connected call or had a quick reconnect brought the news.
//
//  An attempt is over once it has reported a disconnect (a drop, an abandoned
//  reconnect, or the agent leaving) or the host has asked to disconnect. From then
//  on the gate reports nothing that would steer the engine (no `.connected`,
//  `.reconnecting` or further disconnect), because the engine's next connect runs
//  the host's credential code first and SDK callbacks from the dropped room can
//  still arrive meanwhile. The next connect starts a fresh gate.
//

import ConduitCallEngine

struct LiveKitConnectGate {
    private(set) var roomConnected = false
    private(set) var hasRemote = false
    private(set) var reportedConnected = false
    private(set) var hasReportedDisconnect = false
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
        guard reportedConnected, !remotesRemain, !isAttemptOver else { return nil }
        hasReportedDisconnect = true
        return .disconnected(reason: .botLeft)
    }

    mutating func roomDidDisconnect() -> TransportEvent? {
        guard roomConnected, !hasReportedDisconnect else { return nil }
        hasReportedDisconnect = true
        return .disconnected(reason: userRequestedDisconnect ? .requestedByUser : .networkDropped)
    }

    /// The SDK started healing the room itself.
    func reconnectDidStart() -> TransportEvent? {
        isAttemptOver ? nil : .reconnecting
    }

    /// The SDK reports a reconnect complete. `roomConnected` and `remotesPresent` are
    /// the room's state at that moment.
    mutating func reconnectDidComplete(roomConnected isRoomConnected: Bool, remotesPresent: Bool) -> TransportEvent? {
        guard !isAttemptOver else { return nil }
        guard isRoomConnected else { return abandonReconnect() }
        roomConnected = true
        guard reportedConnected else {
            hasRemote = remotesPresent
            return readyEvent()
        }
        guard remotesPresent else {
            hasReportedDisconnect = true
            return .disconnected(reason: .botLeft)
        }
        hasRemote = true
        return .connected
    }

    private mutating func abandonReconnect() -> TransportEvent {
        hasReportedDisconnect = true
        return .disconnected(reason: .networkDropped)
    }

    private var isAttemptOver: Bool {
        hasReportedDisconnect || userRequestedDisconnect
    }

    private mutating func readyEvent() -> TransportEvent? {
        guard !reportedConnected, !isAttemptOver, roomConnected, hasRemote else { return nil }
        reportedConnected = true
        return .connected
    }
}
