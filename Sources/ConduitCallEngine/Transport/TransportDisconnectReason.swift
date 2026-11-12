//
//  TransportDisconnectReason.swift
//  ConduitCallEngine
//
//  Why the transport disconnected. The engine branches on this: a
//  `networkDropped` is a candidate for reconnection, while `authFailed` is a
//  terminal failure. Conflating them would turn a recoverable drop into a dead
//  call.
//

import Foundation

/// Why a transport's connection ended, carried by `TransportEvent.disconnected(reason:)`.
///
/// Open: later versions may add cases. End a `switch` over it with `@unknown default`,
/// which keeps it compiling, with a warning that names the new case, when one is added.
public enum TransportDisconnectReason: Equatable, Sendable {
    /// The transport left because the engine called `disconnect()`. The engine
    /// ignores it: its own teardown drives the call's end.
    case requestedByUser
    /// The connection was lost. The engine reconnects a call that had connected, and
    /// fails one that never had (`.transportError`).
    case networkDropped
    /// The server rejected the credentials. The call fails as `.badToken`, in any state.
    case authFailed
    /// The agent deliberately left an established call (or, for a call that never
    /// connected, left before it was ready). The call ends as `.completed`, or
    /// `.noAnswer` if it never connected.
    case botLeft
    /// The transport cannot tell why. The engine treats it as `.networkDropped`.
    case unknown
}
