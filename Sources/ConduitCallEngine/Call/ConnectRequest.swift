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
    public enum Purpose: Equatable, Sendable {
        /// The first connect of a call the host placed with `CallEngine.placeCall(_:)`.
        case outgoing
        /// The first connect of an incoming call, after the user answered it, when
        /// nothing was prepared during the ring or the preparation failed.
        case answered
        /// Pre-connect: credentials for an incoming call that is still ringing
        /// (`RingPreparation`). With `joinsBeforeAnswer` the transport joins the
        /// room during the ring (`.media`), so the agent must wait for
        /// `CallSignal.answered` before it speaks; without it the transport joins
        /// once the user answers (`.credentials`). Credentials fetched for a ring
        /// are used for the call if it is answered; if the preparation fails, the
        /// answer asks again with `.answered`.
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
