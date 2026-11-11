//
//  AudioSessionActivating.swift
//  ConduitCallEngine
//
//  Abstraction over the `AVAudioSession` CallKit activates for a call, exposing
//  only the operations the engine performs during the activation handshake.
//  The real implementation wraps `AVAudioSession`; the fake lets the
//  route-decision logic be unit-tested without a live session.
//
//  Methods here must only be invoked after CallKit has activated the session
//  (i.e. from `providerDidActivate`).
//

import Foundation

@MainActor
package protocol AudioSessionActivating: AnyObject {
    /// Whether an external output (Bluetooth / CarPlay / car) is the current
    /// route, so the engine avoids forcing speaker over a connected car.
    var hasExternalAudioRoute: Bool { get }

    /// Force output to the built-in speaker — the hands-free default when no
    /// car/Bluetooth route is present.
    func overrideOutputToSpeaker() throws

    /// Clear any output override, restoring the system-chosen route.
    func clearOutputOverride() throws
}
