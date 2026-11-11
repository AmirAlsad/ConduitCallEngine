//
//  AudioRouteKind+Port.swift
//  ConduitCallEngine
//
//  Maps a live `AVAudioSession` output port to an `AudioRouteKind`, to read the
//  route that is actually active. The engine does not make the transport follow a
//  route picked with the native call screen's route button; whether that button
//  moves the audio depends on the transport (it does with the LiveKit adapter,
//  which leaves the session to CallKit, and not with the Daily adapter, whose SDK
//  manages the session itself).
//

import AVFoundation

extension AudioRouteKind {
    public init(portType: AVAudioSession.Port) {
        switch portType {
        case .builtInSpeaker:
            self = .speaker
        case .builtInReceiver:
            self = .receiver
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .carAudio:
            self = .bluetooth
        case .headphones, .headsetMic, .usbAudio:
            self = .wired
        default:
            self = .other
        }
    }

    /// The kind of the current active output route.
    public static var active: AudioRouteKind {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return .other
        }
        return AudioRouteKind(portType: port.portType)
    }
}
