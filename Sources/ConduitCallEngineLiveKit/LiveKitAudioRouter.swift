//
//  LiveKitAudioRouter.swift
//  ConduitCallEngine
//
//  Audio-route control for `LiveKitTransport`. LiveKit runs in manual-audio
//  mode (it does not manage `AVAudioSession`), so routing goes straight through
//  `AVAudioSession` here — which is also why the native CallKit route button works,
//  since CallKit owns the same session. Device ids are the kind keywords
//  `AudioRouteKind(deviceID:)` recognizes, so a host maps them to kinds exactly as
//  it does the Daily adapter's ids.
//

import AVFoundation
import ConduitCallEngine

enum LiveKitAudioRouter {
    static let speakerID = "speaker"
    static let receiverID = "receiver"
    static let bluetoothID = "bluetooth"
    static let wiredID = "wired"

    static func availableDevices() -> [AudioDeviceInfo] {
        let session = AVAudioSession.sharedInstance()
        var devices = [
            AudioDeviceInfo(id: receiverID, name: "iPhone"),
            AudioDeviceInfo(id: speakerID, name: "Speaker"),
        ]
        if let bt = externalInput(.bluetooth, in: session) {
            devices.append(AudioDeviceInfo(id: bluetoothID, name: bt.portName))
        }
        if let wired = externalInput(.wired, in: session) {
            devices.append(AudioDeviceInfo(id: wiredID, name: wired.portName))
        }
        return devices
    }

    static func selectedDeviceID() -> String? {
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return nil }
        switch AudioRouteKind(portType: output.portType) {
        case .speaker: return speakerID
        case .receiver: return receiverID
        case .bluetooth: return bluetoothID
        case .wired: return wiredID
        case .other: return nil
        }
    }

    static func select(_ id: String) {
        let session = AVAudioSession.sharedInstance()
        do {
            switch AudioRouteKind(deviceID: id) {
            case .speaker:
                try session.setPreferredInput(nil)
                try session.overrideOutputAudioPort(.speaker)
            case .receiver:
                try session.setPreferredInput(nil)
                try session.overrideOutputAudioPort(.none)
            case .bluetooth:
                try session.overrideOutputAudioPort(.none)
                try session.setPreferredInput(externalInput(.bluetooth, in: session))
            case .wired:
                try session.overrideOutputAudioPort(.none)
                try session.setPreferredInput(externalInput(.wired, in: session))
            case .other:
                break
            }
        } catch {
            Log.error(.audio, "LiveKit route select(\(id)) failed: \(error)")
        }
    }

    private static func externalInput(
        _ kind: AudioRouteKind,
        in session: AVAudioSession
    ) -> AVAudioSessionPortDescription? {
        session.availableInputs?.first { AudioRouteKind(portType: $0.portType) == kind }
    }
}
