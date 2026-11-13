//
//  SystemAudioSession.swift
//  ConduitCallEngine
//
//  Real `AudioSessionActivating` over `AVAudioSession`. CallKit owns activation;
//  this pre-configures the category and mode, without activating, before a call
//  is reported, and describes the session for logs. Configuring or activating the
//  session after CallKit activated it is done only by the experimental recovery
//  after an audio interruption, which is off by default.
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

    var diagnosticDescription: String {
        let route = session.currentRoute
        let inputs = route.inputs.map { "\($0.portType.rawValue)(\($0.portName))" }
        let outputs = route.outputs.map { "\($0.portType.rawValue)(\($0.portName))" }
        return """
        category \(session.category.rawValue), mode \(session.mode.rawValue), \
        options \(Self.describe(session.categoryOptions)), \
        otherAudioPlaying \(session.isOtherAudioPlaying), \
        secondaryAudioShouldBeSilencedHint \(session.secondaryAudioShouldBeSilencedHint), \
        sampleRate \(session.sampleRate), inputAvailable \(session.isInputAvailable), \
        inputs \(inputs), outputs \(outputs)
        """
    }

    func reapplyCallConfiguration() -> String {
        do {
            try prepareForVoIPCall()
            return "setCategory(playAndRecord, voiceChat) ok"
        } catch {
            return "setCategory(playAndRecord, voiceChat) failed: \(error)"
        }
    }

    func activateAgain() -> String {
        do {
            try session.setActive(true)
            return "setActive(true) ok"
        } catch {
            return "setActive(true) failed: \(error)"
        }
    }

    private static func describe(_ options: AVAudioSession.CategoryOptions) -> String {
        let names: [(AVAudioSession.CategoryOptions, String)] = [
            (.mixWithOthers, "mixWithOthers"),
            (.duckOthers, "duckOthers"),
            (.interruptSpokenAudioAndMixWithOthers, "interruptSpokenAudioAndMixWithOthers"),
            (.allowBluetoothHFP, "allowBluetoothHFP"),
            (.allowBluetoothA2DP, "allowBluetoothA2DP"),
            (.allowAirPlay, "allowAirPlay"),
            (.defaultToSpeaker, "defaultToSpeaker"),
            (.overrideMutedMicrophoneInterruption, "overrideMutedMicrophoneInterruption"),
        ]
        let named = names.filter { options.contains($0.0) }.map(\.1)
        return "\(options.rawValue) \(named)"
    }
}
