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

public enum TransportEvent: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected(reason: TransportDisconnectReason)
    case botStartedSpeaking
    case botStoppedSpeaking
    case userStartedSpeaking
    case userStoppedSpeaking
    /// The remote party's audio level, 0...1. The engine does not expose it; it
    /// changes no state a host observes.
    case remoteAudioLevel(Float)
    /// The set of available audio routes changed (e.g. AirPods connected mid-call).
    case audioDevicesChanged
    case error(TransportError)
}
