//
//  AudioRouteKind.swift
//  ConduitCallEngine
//
//  A normalized audio route, derived from the transport's device id (Daily uses
//  stable ids — `speakerphone` / `bluetooth` / `earpiece` / `wired` — while its
//  display NAMES are unreliable, e.g. "Bluetooth Speaker & Mic" contains the word
//  "Speaker"). The engine uses the kind for its hands-free default; a host can
//  use it to label and order a route picker. `AudioRouteKind+Port` maps a live
//  `AVAudioSession` port to a kind.
//

import Foundation

/// The kind of an audio route, derived from an `AudioDeviceInfo.id` or an
/// `AVAudioSession` port.
///
/// Closed: the package adds no case to this enum within a minor version while it is
/// 0.x (from 1.0, within a major version), so a
/// `switch` may list every case. A route that fits none of the
/// named kinds is `.other`.
public enum AudioRouteKind: Equatable, Sendable {
    /// The phone's earpiece.
    case receiver
    /// The phone's loudspeaker.
    case speaker
    /// A Bluetooth device (headset, AirPods, car audio).
    case bluetooth
    /// A wired or USB headset or headphones.
    case wired
    /// Anything else.
    case other

    /// Classifies a transport's device id by keyword: `speaker` (without
    /// `bluetooth`), `bluetooth`, `earpiece` or `receiver`, `wired` or `headphone`.
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
