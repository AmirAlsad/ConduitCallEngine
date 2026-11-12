//
//  CallSignal.swift
//  ConduitCallEngine
//
//  Call-control messages the engine sends to the remote agent through
//  `CallTransport.send(_:)`, so the agent can tell what the user's side of the
//  call is doing (on the line, on hold, back from hold) without inferring it
//  from the session or from silence.
//

import Foundation

/// A call-control message for the remote agent, sent with `CallTransport.send(_:)`.
///
/// The `rawValue` is the message's name on the wire. The bundled adapters are to
/// carry it as the `t` field of the same RTVI client message as the end-call
/// signal: `{"id": "<8 characters>", "label": "rtvi-ai", "type": "client-message",
/// "data": {"t": "call-connected"}}`. Delivery is best effort and a signal may arrive
/// more than once (the engine repeats `held` after every reconnect of a held
/// call, and sends the call's state again when a send did not leave the device;
/// see `CallSignalDelivery`), so an agent must treat each one as a statement of the
/// current state, not as a toggle. Agents must ignore names they do not know.
///
/// A server can only rely on a signal from a client that says it sends it. A host
/// whose transport delivers signals says so by sending the raw values of
/// `CallSignal.allCases` to its server as `call_signals`, with each credential
/// request and with its VoIP push registration (the Integration Guide's "When your
/// agent should start speaking" has the convention and the server's fallback).
///
/// Open: later versions may add cases. End a `switch` over it with `@unknown default`,
/// which keeps it compiling, with a warning that names the new case, when one is added. A transport sends
/// `rawValue` and need not switch at all.
public enum CallSignal: String, CaseIterable, Sendable {
    /// The user is on the line: the call is connected, CallKit has activated its
    /// audio, it is not on hold, and the host is not withholding the mic
    /// (`CallEngine.setMicWithheld(_:)`, typically while its "connected" sound
    /// plays), whichever comes last. An agent should start speaking (greet) when
    /// this arrives, not when the session connects. Sent on every call, placed or
    /// answered, pre-connected or not, again on every new connection after a
    /// reconnect, and again if it could not leave the device. A muted user or one
    /// in push-to-talk mode is on the line too: they hear the agent. A call that
    /// connects while held gets it after the resume, following `resumed`. It
    /// follows the attach and mic commands issued before it, so the mic the host
    /// released is open by then.
    case connected = "call-connected"
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
