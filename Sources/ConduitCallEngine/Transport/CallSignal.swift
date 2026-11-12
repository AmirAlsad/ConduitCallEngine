//
//  CallSignal.swift
//  ConduitCallEngine
//
//  Call-control messages the engine sends to the remote agent through
//  `CallTransport.send(_:)`, so the agent can tell what the user's side of the
//  call is doing (on hold, back from hold) without inferring it from silence.
//

import Foundation

/// A call-control message for the remote agent, sent with `CallTransport.send(_:)`.
///
/// The `rawValue` is the message's name on the wire. The bundled adapters are to
/// carry it as the `t` field of the same RTVI client message as the end-call
/// signal: `{"id": "<8 characters>", "label": "rtvi-ai", "type": "client-message",
/// "data": {"t": "call-held"}}`. Delivery is best effort and a signal may arrive
/// more than once (the engine repeats `held` after every reconnect of a held
/// call), so an agent must treat each one as a statement of the current state, not
/// as a toggle. Agents must ignore names they do not know.
public enum CallSignal: String, CaseIterable, Sendable {
    /// The user answered an incoming call whose push carried `preconnect`, CallKit
    /// has activated its audio, and the transport is connected: the agent may
    /// start speaking. Sent once all three hold, whichever comes last, again after
    /// every reconnect of the call, and at the resume when they come to hold while
    /// the call is on hold. An agent that joined during the ring must stay silent
    /// until it arrives.
    case answered = "call-answered"
    /// The user's side put the call on hold (for example to take a phone call).
    /// The user cannot hear the agent and the mic is closed until `resumed`; the
    /// agent should stop speaking and wait, and keep the session longer than its
    /// usual drop grace window if the connection goes while held.
    case held = "call-held"
    /// The call is back from hold: the user can hear and speak to the agent again.
    case resumed = "call-resumed"
}
