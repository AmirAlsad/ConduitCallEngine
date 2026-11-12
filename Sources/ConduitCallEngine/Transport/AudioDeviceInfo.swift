//
//  AudioDeviceInfo.swift
//  ConduitCallEngine
//
//  A selectable in-call audio route (speaker, earpiece, Bluetooth/AirPods, wired),
//  surfaced by the transport. SDK-agnostic: each adapter maps its SDK's devices
//  into these, so a host never sees an SDK type.
//

import Foundation

/// An audio route the user can pick (`CallEngine.audioDevices`).
public struct AudioDeviceInfo: Equatable, Identifiable, Sendable {
    /// The transport's id for the route, which `CallEngine.selectAudioDevice(_:)`
    /// takes. The engine classifies routes by keywords in it (`AudioRouteKind(deviceID:)`).
    public let id: String
    /// A name for a route picker.
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
