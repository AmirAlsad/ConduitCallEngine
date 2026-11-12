//
//  CallState.swift
//  ConduitCallEngine
//
//  The call's lifecycle, owned by the call engine. Pure and Equatable, so a
//  host can compare and switch on it.
//
//  idle → dialing → connecting → connected → (reconnecting ⇄ connected) → ended
//                                          ↘ failed
//  incomingRinging → connecting → …  (inbound, after the user answers)
//  incomingRinging → ended(declined), or → idle when the ring ends before the
//  user could take it (Focus, an unknown target, a report CallKit refused)
//

import Foundation

public enum CallState: Equatable, Sendable {
    /// No call in progress.
    case idle
    /// An incoming call is ringing. CallKit's system UI is primary, so `isActive` is
    /// false until the user answers.
    case incomingRinging
    /// The host placed a call; CallKit is starting it.
    case dialing
    /// CallKit has the call (started, or answered). The target's credentials are
    /// resolved during this state, then the transport joins.
    case connecting
    /// The transport reports the remote party present and media up. `since` is the
    /// first connect of this call; a reconnect keeps it.
    case connected(since: Date)
    /// The media connection dropped while the call is still up. `attempt` (from 1)
    /// counts the engine's own retries, with backoff between them; 0 means the
    /// transport reported it is healing itself and the engine is waiting for it.
    case reconnecting(attempt: Int)
    /// The call ended; the outcome says how (completed, declined, canceled, ...).
    case ended(CallOutcome)
    /// The call could not be established or could not recover.
    case failed(CallFailureReason)
}

extension CallState {
    /// Whether a call is under way or has just finished, the span a host shows its
    /// in-call UI for. False for `idle` and for `incomingRinging` (where CallKit's
    /// system ring UI is primary).
    public var isActive: Bool {
        switch self {
        case .idle, .incomingRinging: return false
        default: return true
        }
    }

    /// Whether the call has reached a terminal state.
    public var isTerminal: Bool {
        switch self {
        case .ended, .failed: return true
        default: return false
        }
    }
}
