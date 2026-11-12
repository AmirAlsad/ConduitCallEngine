//
//  DailyConnectionGate.swift
//  ConduitCallEngine
//
//  Decides what a Daily connect attempt reports, kept pure and SDK-free so every
//  rule is unit-testable. `.connected` is reported once per attempt, when the
//  Pipecat client is ready or the bot reports ready. The disconnect reason is
//  `.requestedByUser` after the host's `disconnect()`, otherwise `.networkDropped`;
//  the bot leaving is `.botLeft`.
//
//  An attempt is over once it has reported a disconnect (either kind), its connect
//  has thrown, or the host has asked to disconnect. From then on the gate reports
//  nothing that would steer the engine, except the one `.requestedByUser` that
//  follows the host's disconnect. The engine's next connect runs the host's
//  credential code before it reaches the adapter, and Pipecat and Daily callbacks
//  from the dropped call can still arrive meanwhile: a late bot-left would end a
//  call that is reconnecting, and a second drop would spend another retry. The
//  next connect starts a fresh attempt.
//

import ConduitCallEngine

struct DailyConnectionGate {
    private(set) var reportedConnected = false
    private(set) var isAttemptOver = false
    private(set) var userRequestedDisconnect = false

    mutating func connectDidStart() {
        self = DailyConnectionGate()
    }

    /// The adapter's connect threw; that throw is how this attempt's failure is reported.
    mutating func connectDidFail() {
        isAttemptOver = true
    }

    mutating func userDidRequestDisconnect() {
        userRequestedDisconnect = true
    }

    mutating func transportDidBecomeReady() -> TransportEvent? {
        guard !reportedConnected, !isAttemptOver, !userRequestedDisconnect else { return nil }
        reportedConnected = true
        return .connected
    }

    mutating func transportDidDisconnect() -> TransportEvent? {
        guard !isAttemptOver else { return nil }
        isAttemptOver = true
        return .disconnected(reason: userRequestedDisconnect ? .requestedByUser : .networkDropped)
    }

    /// The bot left. Reported even before ready, so a bot that leaves before the call
    /// connects ends it rather than leaving it connecting.
    mutating func botDidLeave() -> TransportEvent? {
        guard !isAttemptOver, !userRequestedDisconnect else { return nil }
        isAttemptOver = true
        return .disconnected(reason: .botLeft)
    }
}
