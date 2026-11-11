//
//  SystemAudioSession.swift
//  ConduitCallEngine
//
//  Real `AudioSessionActivating` over `AVAudioSession`. CallKit owns activation;
//  this only pre-configures the category/mode (without activating) and performs
//  the hands-free route decision once CallKit has activated the session.
//

import AVFoundation
import Foundation

@MainActor
final class SystemAudioSession: AudioSessionActivating {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    /// Configure the session for a VoIP call WITHOUT activating it — CallKit
    /// performs the activation. Called before reporting the call.
    func prepareForVoIPCall() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers]
        )
    }

    var hasExternalAudioRoute: Bool {
        session.currentRoute.outputs.contains { output in
            switch output.portType {
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
                 .carAudio, .airPlay, .headphones, .headsetMic, .usbAudio:
                return true
            default:
                return false
            }
        }
    }

    func overrideOutputToSpeaker() throws {
        try session.overrideOutputAudioPort(.speaker)
    }

    func clearOutputOverride() throws {
        try session.overrideOutputAudioPort(.none)
    }
}
