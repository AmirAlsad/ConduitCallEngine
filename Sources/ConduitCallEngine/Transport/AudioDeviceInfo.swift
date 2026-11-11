//
//  AudioDeviceInfo.swift
//  ConduitCallEngine
//
//  A selectable in-call audio route (speaker, earpiece, Bluetooth/AirPods, wired),
//  surfaced by the transport. SDK-agnostic: the Daily adapter maps its device list
//  into these so the in-call route picker never sees an SDK type.
//

import Foundation

public struct AudioDeviceInfo: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
