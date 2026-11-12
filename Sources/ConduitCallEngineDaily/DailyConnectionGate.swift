//
//  DailyConnectionGate.swift
//  ConduitCallEngine
//
//  Decides what a Daily connect attempt reports, kept pure and SDK-free so every
//  rule is unit-testable. `.connected` is reported once per attempt, when the
//  Pipecat client is ready or the bot reports ready, or, for a gate that counts
//  presence as ready (an experimental ring-join strategy that holds the agent's audio
//  back, so the bot cannot become ready), once the call is joined with a remote
//  participant in it. The disconnect reason is
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
//  A connect can also arrive while the Pipecat client is still in the call: the
//  engine reconnects by itself when a `.reconnecting` (a lost network path, which
//  Daily heals inside its SDK) is not followed by `.connected` or `.disconnected`
//  within 30 seconds, and it can start an attempt while an earlier join is still
//  waiting for the bot. Pipecat refuses to connect a client in that state, so such
//  a connect does not start an attempt (`planConnect`): if the call is connected
//  and its path is up, the session has healed and is reported `.connected` again;
//  otherwise the connect fails and the attempt in progress keeps reporting, so
//  Daily's recovery (the path coming back, the bot becoming ready) or its drop
//  still reaches the engine.
//

import ConduitCallEngine

struct DailyConnectionGate {
    enum ConnectPlan: Equatable {
        /// Start a fresh attempt and join.
        case join
        /// The session is in the call and usable: report `.connected` again.
        case reportConnected
        /// The session is still in the call and cannot join again: fail this connect
        /// and leave the attempt in progress to report how it ends.
        case refuse
    }

    /// Whether a joined call with a remote participant counts as connected.
    let readyOnPresence: Bool
    private(set) var reportedConnected = false
    private(set) var isJoined = false
    private(set) var hasRemote = false
    private(set) var isAttemptOver = false
    private(set) var userRequestedDisconnect = false

    /// What a connect does. `sessionIsInCall` is whether the Pipecat client is joining
    /// or in a call (it refuses to connect then); `interruption` is the phase of this
    /// attempt's network-path watch.
    func planConnect(sessionIsInCall: Bool, interruption: DailyInterruptionGate.Phase) -> ConnectPlan {
        guard sessionIsInCall else { return .join }
        let healed = reportedConnected && !isAttemptOver && !userRequestedDisconnect && interruption == .connected
        return healed ? .reportConnected : .refuse
    }

    init(readyOnPresence: Bool = false) {
        self.readyOnPresence = readyOnPresence
    }

    mutating func connectDidStart() {
        self = DailyConnectionGate(readyOnPresence: readyOnPresence)
    }

    /// The Daily call is joined; `remotePresent` is whether a remote participant is in it.
    mutating func transportDidJoin(remotePresent: Bool) -> TransportEvent? {
        isJoined = true
        if remotePresent { hasRemote = true }
        return presenceEvent()
    }

    /// A remote participant (the bot) joined the call.
    mutating func botDidJoin() -> TransportEvent? {
        hasRemote = true
        return presenceEvent()
    }

    private mutating func presenceEvent() -> TransportEvent? {
        guard readyOnPresence, isJoined, hasRemote else { return nil }
        return transportDidBecomeReady()
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
