//
//  ConnectRequest.swift
//  ConduitCallEngine
//
//  What the engine hands `CallTarget.connect` each time it asks for credentials:
//  why it is asking, and for an incoming call, which ring. A host can pass it on
//  to its backend, for example to tell a reconnect from a new call.
//

import Foundation

/// Why the engine asks a target for credentials, passed to `CallTarget.connect`.
public struct ConnectRequest: Equatable, Sendable {
    /// What the credentials are for.
    ///
    /// Open: later versions may add cases, as 0.2 added `.ringing(joinsBeforeAnswer:)`,
    /// each listed in the changelog. End a `switch` over it with `@unknown default`,
    /// which keeps it compiling, with a warning that names the new case, when one is
    /// added; the new case takes that branch until you handle it. Treat it there as
    /// the first connect of an incoming call, the safest assumption:
    ///
    /// ```swift
    /// switch request.purpose {
    /// case .outgoing: path = "/calls"
    /// case .answered, .ringing: path = "/rings/\(id)/connect"
    /// case .reconnect(let attempt): path = "/calls/\(id)/reconnect?attempt=\(attempt)"
    /// @unknown default: path = "/rings/\(id)/connect"
    /// }
    /// ```
    public enum Purpose: Equatable, Sendable {
        /// The first connect of a call the host placed with `CallEngine.placeCall(_:)`.
        case outgoing
        /// The first connect of an incoming call, after the user answered it, when
        /// nothing was prepared during the ring or the preparation failed, during
        /// the ring or after the answer before the agent was there.
        case answered
        /// Pre-connect: credentials for an incoming call that is still ringing
        /// (`RingPreparation`). With `joinsBeforeAnswer` the transport joins the
        /// room during the ring (`.media`), so the agent must wait for
        /// `CallSignal.connected` before it speaks; without it the transport joins
        /// once the user answers (`.credentials`). Credentials fetched for a ring
        /// are used for the call if it is answered; if the preparation fails (also
        /// after the answer, before the agent was there), the engine asks again with
        /// `.answered`.
        case ringing(joinsBeforeAnswer: Bool)
        /// An engine reconnect attempt of a call that dropped; `attempt` counts
        /// from 1 within the outage, as `CallState.reconnecting(attempt:)` does.
        case reconnect(attempt: Int)
    }

    /// What the credentials are for.
    public let purpose: Purpose
    /// The ring's `call_id` (the CallKit call id the push carried) on every request
    /// for an incoming call, reconnects included; nil for an outgoing call. When you
    /// send it to your server, write it as `uuidString.lowercased()`, the form the
    /// engine's ring-status receipts use (`uuidString` is uppercase).
    ///
    /// The engine guarantees it is never nil when `purpose` is `.answered` or
    /// `.ringing(joinsBeforeAnswer:)`, and always nil for `.outgoing`; for
    /// `.reconnect(attempt:)` it is nil exactly when the call is outgoing. So in
    /// those two cases you can unwrap it (`request.callID!`) or treat nil as a
    /// programming error. The initializer does not enforce this, so tests can build
    /// any request.
    public let callID: UUID?

    /// A request as the engine makes it. The engine never pairs `.answered` or
    /// `.ringing` with a nil `callID`; see `callID`.
    public init(purpose: Purpose, callID: UUID?) {
        self.purpose = purpose
        self.callID = callID
    }
}
