//
//  TransportEvent.swift
//  ConduitCallEngine
//
//  The SDK-agnostic event surface a `CallTransport` emits. Deliberately expressed in
//  the engine's own vocabulary (not Daily/LiveKit/RTVI types) so a second transport
//  drops in behind the same protocol.
//
//  `.connected` means BOTH the transport is ready AND the remote party is
//  present — never raw transport connectivity, or the call would report
//  "connected" before the remote party can hear the user.
//

import Foundation

/// What a transport reports through `CallTransport.events`. The engine's reaction to
/// each is in the Integration Guide, section 12.
///
/// Open: later versions may add cases. End a `switch` over it with `@unknown default`,
/// which keeps it compiling, with a warning that names the new case, when one is added.
public enum TransportEvent: Equatable, Sendable {
    /// The transport started joining. The engine needs no reaction.
    case connecting
    /// The transport is up and the agent is present and ready to hear the user.
    case connected
    /// The connection is interrupted and the transport is healing it itself. Follow it
    /// with `.connected` or `.disconnected`; after 30 seconds without either, the
    /// engine reconnects on its own.
    case reconnecting
    /// The connection ended; the reason decides what the engine does.
    case disconnected(reason: TransportDisconnectReason)
    /// The agent started speaking (`CallEngine.isBotSpeaking`).
    case botStartedSpeaking
    /// The agent stopped speaking.
    case botStoppedSpeaking
    /// The user started speaking. The engine does not expose it in this version.
    case userStartedSpeaking
    /// The user stopped speaking. The engine does not expose it in this version.
    case userStoppedSpeaking
    /// The remote party's audio level, 0...1. The engine does not expose it; it
    /// changes no state a host observes.
    case remoteAudioLevel(Float)
    /// The set of available audio routes changed (e.g. AirPods connected mid-call).
    case audioDevicesChanged
    /// An error. It fails a call that is still connecting; during a call only
    /// `.authenticationFailed` while reconnecting changes anything (`.badToken`).
    case error(TransportError)
    /// An RTVI server message from the agent: the message's `data`, as UTF-8 JSON
    /// (`null` when it had none). Passed to
    /// `CallEngineDelegate.callEngine(_:didReceiveServerMessage:)` while a call is in
    /// progress; dropped during a ring.
    case serverMessage(Data)
    /// Text the agent produced (RTVI `bot-output`). Passed to
    /// `CallEngineDelegate.callEngine(_:didReceiveBotOutput:)` while a call is in
    /// progress; dropped during a ring.
    case botOutput(BotOutput)
    /// What the agent heard the user say (RTVI `user-transcription`). Passed to
    /// `CallEngineDelegate.callEngine(_:didReceiveUserTranscript:)` while a call is in
    /// progress; dropped during a ring.
    case userTranscript(UserTranscript)
}

extension TransportEvent {
    /// The event for a log line: a host message's payload and the words of a
    /// transcript are left out.
    package var logDescription: String {
        switch self {
        case .serverMessage(let data): "serverMessage(\(data.count) bytes)"
        case .botOutput(let output): "botOutput(\(output.text.count) characters)"
        case .userTranscript(let transcript): "userTranscript(\(transcript.text.count) characters, final \(transcript.isFinal))"
        default: String(describing: self)
        }
    }
}
