//
//  CallFailureReason.swift
//  ConduitCallEngine
//
//  Why a call ended in `.failed`. `badToken` (credentials rejected) is distinct
//  from `lostConnection` (a mid-call drop that exhausted its reconnection budget),
//  so a host can tell a configuration problem from a network one. Raw values are
//  stable, so a host can persist them.
//

import Foundation

/// Why a call failed, carried by `CallState.failed` and `CallRecord.failureReason`.
///
/// Open: later versions may add cases. End a `switch` over it with `@unknown default`,
/// which keeps it compiling, with a warning that names the new case, when one is added.
public enum CallFailureReason: String, Equatable, Sendable, Codable {
    /// The credentials were rejected: `TransportError.authenticationFailed` thrown by
    /// the target's `connect` or the transport's, or the transport reporting
    /// `.disconnected(reason: .authFailed)` (or `.error(.authenticationFailed)` while
    /// connecting or reconnecting).
    case badToken
    /// The transport joined, but the agent was not ready within
    /// `CallEngineConfiguration.joinTimeout` on the call's first connect.
    case agentUnreachable
    /// The call dropped after it connected and every reconnect attempt failed.
    case lostConnection
    /// The call's first connect failed for a reason other than rejected credentials,
    /// or the connection dropped before the call ever connected.
    case transportError
    /// CallKit refused to start the call or reset its provider, or (in a
    /// `CallRecord` only) a ring could not proceed: CallKit refused its report for a
    /// reason other than Focus, or its target is unknown.
    case unknown
}
