//
//  TransportEvent.swift
//  ConduitCallEngine
//
//  The SDK-agnostic event surface a `CallTransport` emits. Deliberately expressed in
//  the engine's own vocabulary (not Daily/LiveKit/RTVI types) so a second transport
//  drops in behind the same protocol.
//
//  `.connected` means BOTH the transport is ready AND the bot is ready — never
//  raw transport connectivity, or we'd report "connected" before the agent can
//  hear the user.
//

import Foundation

public enum TransportEvent: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected(reason: TransportDisconnectReason)
    case botStartedSpeaking
    case botStoppedSpeaking
    case userStartedSpeaking
    case userStoppedSpeaking
    /// Remote (agent) output level, 0...1, for the listening/speaking glow.
    case remoteAudioLevel(Float)
    /// The set of available audio routes changed (e.g. AirPods connected mid-call).
    case audioDevicesChanged
    case error(TransportError)
}
