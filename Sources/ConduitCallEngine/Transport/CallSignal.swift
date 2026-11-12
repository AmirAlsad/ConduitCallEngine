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
/// call, and sends the call's state again when a send did not leave the device;
/// see `CallSignalDelivery`), so an agent must treat each one as a statement of the
/// current state, not as a toggle. Agents must ignore names they do not know.
///
/// Open: later versions may add cases. End a `switch` over it with `@unknown default`,
/// which keeps it compiling, with a warning that names the new case, when one is added. A transport sends
/// `rawValue` and need not switch at all.
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

/// What became of a call-control signal handed to `CallTransport.send(_:)`.
///
/// The engine uses it to make the agent converge on the call's real state: a signal
/// that `failed` is sent again, as the call's current state, until one is `sent` or
/// the connection changes. Neither result says the agent acted on the signal; only
/// whether it left the device.
///
/// Closed: the package adds no case to this enum within a major version, so a
/// `switch` may list every case.
public enum CallSignalDelivery: Equatable, Sendable {
    /// Handed to the connection to the agent (for the bundled adapters: published on
    /// LiveKit's reliable data channel, or accepted by Daily's app-message send). It
    /// reaches the agent unless that connection drops, after which the engine tells
    /// the next connection the current state anyway.
    case sent
    /// Not sent: there was no connection to send it on, it was refused, or it could
    /// not be handed over within the transport's bound. The engine sends the call's
    /// current state again after a short wait, a few times, and again on the next
    /// connection.
    case failed
    /// The transport carries no signals. The engine never sends it again.
    case unsupported
}
