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
    /// Later versions may add cases, as 0.2 added `.ringing(joinsBeforeAnswer:)`;
    /// each addition is listed in the changelog. A `switch` that lists every case
    /// stops compiling when one is added. End it with `@unknown default`: today that
    /// compiles without a warning, and when a case is added the switch still
    /// compiles, with a warning that names the new case, which takes that branch
    /// until you handle it. Treat it there as the first connect of an incoming call,
    /// the safest assumption:
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
        /// `CallSignal.answered` before it speaks; without it the transport joins
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
    /// for an incoming call, reconnects included; nil for an outgoing call.
    public let callID: UUID?

    public init(purpose: Purpose, callID: UUID?) {
        self.purpose = purpose
        self.callID = callID
    }
}
