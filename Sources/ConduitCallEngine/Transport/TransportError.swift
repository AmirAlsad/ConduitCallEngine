//
//  TransportError.swift
//  ConduitCallEngine
//
//  Transport-agnostic error surface. Concrete SDK errors (Daily, LiveKit) are
//  mapped into these by each transport adapter and never leak upward.
//

import Foundation

/// An error from a transport or from a target's `connect`, in the engine's vocabulary.
/// Throw it from `CallTransport.connect(_:)` or `CallTarget.connect`, or emit it as
/// `TransportEvent.error(_:)`. Only `.authenticationFailed` changes what the engine
/// does; the messages are for logs.
///
/// Open: later versions may add cases. End a `switch` over it with `@unknown default`,
/// which keeps it compiling, with a warning that names the new case, when one is added.
public enum TransportError: Error, Equatable, Sendable {
    /// Joining failed, or the connection could not be used. The message says why.
    case connectionFailed(String)
    /// The server rejected the credentials. Ends the call as `.badToken`, also during
    /// a reconnect attempt, so throw it only for a definite rejection (an HTTP 401 or
    /// 403 from the credential endpoint, or the SDK's equivalent).
    case authenticationFailed
    /// Another error the SDK reported. The message says what.
    case underlying(String)
}
