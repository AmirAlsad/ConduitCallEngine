//
//  AudioRouteKind.swift
//  ConduitCallEngine
//
//  A normalized audio route, derived from the transport's device id (Daily uses
//  stable ids — `speakerphone` / `bluetooth` / `earpiece` / `wired` — while its
//  display NAMES are unreliable, e.g. "Bluetooth Speaker & Mic" contains the word
//  "Speaker"). The engine uses the kind for its hands-free default; the in-call
//  picker maps each device to a kind for its label, icon, and order
//  (`AudioRouteKind+Display`), and the active route is matched against the live
//  `AVAudioSession` route (see `AudioRouteKind+Port`).
//

import Foundation

public enum AudioRouteKind: Equatable, Sendable {
    case receiver
    case speaker
    case bluetooth
    case wired
    case other

    public init(deviceID: String) {
        let id = deviceID.lowercased()
        if id.contains("speaker") && !id.contains("bluetooth") {
            self = .speaker
        } else if id.contains("bluetooth") {
            self = .bluetooth
        } else if id.contains("earpiece") || id.contains("receiver") {
            self = .receiver
        } else if id.contains("wired") || id.contains("headphone") {
            self = .wired
        } else {
            self = .other
        }
    }
}
