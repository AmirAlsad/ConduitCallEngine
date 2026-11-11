//
//  CallState.swift
//  ConduitCallEngine
//
//  The call's lifecycle, owned by the call engine. Pure and Equatable so
//  the state machine verifies against fakes
//  at simulator speed.
//
//  idle → dialing → connecting → connected → (reconnecting ⇄ connected) → ended
//                                          ↘ failed
//  incomingRinging → connecting → …  (inbound, after the user answers)
//

import Foundation

public enum CallState: Equatable, Sendable {
    /// No call in progress.
    case idle
    /// An agent-initiated call is ringing. The CallKit system UI is primary here, so
    /// the app shows no surface (isActive == false) until the user answers.
    case incomingRinging
    /// User asked to call; the call is being reported to CallKit.
    case dialing
    /// CallKit has the call; the transport is connecting (token loaded, joining).
    case connecting
    /// Transport ready AND bot ready; the running timer starts at `since`.
    case connected(since: Date)
    /// Media dropped while CallKit still believes the call is up; backing off.
    case reconnecting(attempt: Int)
    /// The call finished normally (or was canceled/ended).
    case ended(CallOutcome)
    /// The call could not be established or could not recover.
    case failed(CallFailureReason)
}

extension CallState {
    /// Whether the app should show its in-call surface. False for `idle` and for
    /// `incomingRinging` (where CallKit's system ring UI is primary).
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
