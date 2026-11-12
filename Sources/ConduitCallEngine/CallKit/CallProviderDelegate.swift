//
//  CallProviderDelegate.swift
//  ConduitCallEngine
//
//  The system → engine direction of the CallKit seam. The engine conforms to
//  this; the provider calls it. `providerDidActivate` is the audio-session
//  ownership boundary — the one place media may attach.
//

import Foundation

@MainActor
package protocol CallProviderDelegate: AnyObject {
    /// CallKit activated the audio session. The engine attaches the live call's
    /// transport and applies its mic state; media never attaches before this (a
    /// transport created later attaches at once). Activation sets no route: the
    /// hands-free default follows the transport's connect and device changes.
    func providerDidActivate(_ audioSession: AudioSessionActivating)
    /// CallKit deactivated the audio session. The engine detaches media.
    func providerDidDeactivate(_ audioSession: AudioSessionActivating)
    /// The user answered an incoming call from the system UI. Ignored unless `id`
    /// is the ringing call.
    func providerPerformAnswerCall(_ id: UUID)
    /// The user ended the call from the system UI (lock screen, CarPlay). Also the
    /// decline path for an incoming call that's still ringing.
    func providerPerformEndCall(_ id: UUID)
    /// The user toggled mute from the system UI. Ignored unless `id` is the live call.
    func providerPerformSetMuted(_ id: UUID, muted: Bool)
    /// The user or the system held or resumed the call (for example to take a
    /// phone call). Returns whether the engine performed it; false fails the
    /// CallKit action. Refused unless `id` is the live call and it can be held.
    func providerPerformSetHeld(_ id: UUID, onHold: Bool) -> Bool
    /// The system reset the provider; tear everything down defensively.
    func providerWasReset()
}
