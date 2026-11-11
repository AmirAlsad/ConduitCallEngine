//
//  AudioRouteKind+Port.swift
//  ConduitCallEngine
//
//  Maps a live `AVAudioSession` output port to an `AudioRouteKind`. Used to read
//  the route that's ACTUALLY active (the source of truth) — for the in-call
//  picker's checkmark, and so the engine can make the transport follow a
//  route the user picks from the native CallKit call screen.
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
