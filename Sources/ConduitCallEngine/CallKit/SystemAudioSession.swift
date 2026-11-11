//
//  SystemAudioSession.swift
//  ConduitCallEngine
//
//  Real `AudioSessionActivating` over `AVAudioSession`. CallKit owns activation;
//  this only pre-configures the category and mode, without activating, before a
//  call is reported.
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
}
