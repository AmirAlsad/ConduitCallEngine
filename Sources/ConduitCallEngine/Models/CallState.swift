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
//  incomingRinging → connected       (inbound, answered while a pre-connected
//                                     ring's agent was already there)
//  incomingRinging → ended(declined), or → idle when the ring ends without the
//  user taking it (Focus, an unknown target, a report CallKit refused, a provider
//  reset, the ring timing out, or the caller cancelling it)
//

import Foundation

/// Where the call is in its lifecycle (`CallEngine.state`).
///
/// Closed: the package adds no case to this enum within a major version, so a
/// `switch` may list every case.
public enum CallState: Equatable, Sendable {
    /// No call in progress.
    case idle
    /// An incoming call is ringing. CallKit's system UI is primary, so `isActive` is
    /// false until the user answers. It stays so while the ring is being prepared
    /// (`CallEngine.ringPreparationPhase`).
    case incomingRinging
    /// The host placed a call; CallKit is starting it.
    case dialing
    /// CallKit has the call (started, or answered). The target's credentials are
    /// resolved during this state, then the transport joins. An answered ring whose
    /// agent was already there during the ring skips it.
    case connecting
    /// The transport reports the remote party present and media up. `since` is the
    /// first connect of this call; a reconnect keeps it.
    case connected(since: Date)
    /// The media connection dropped while the call is still up. `attempt` (from 1)
    /// counts the engine's own retries, with backoff between them; 0 means the
    /// transport reported it is healing itself and the engine is waiting for it,
    /// for up to 30 seconds before it reconnects on its own (attempt 1).
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
