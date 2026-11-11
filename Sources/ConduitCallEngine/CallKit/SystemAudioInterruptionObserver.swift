//
//  SystemAudioInterruptionObserver.swift
//  ConduitCallEngine
//
//  Real `AudioInterruptionObserving` over `AVAudioSession.interruptionNotification`.
//  Decodes the interruption type and the `.shouldResume` option and forwards them to
//  the engine. The simulator never raises real interruptions, so the observed
//  behavior is device-only (the begin/resume logic is unit-tested via the fake).
//

import AVFoundation
import Foundation

@MainActor
final class SystemAudioInterruptionObserver: AudioInterruptionObserving {
    weak var delegate: AudioInterruptionObserverDelegate?

    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    deinit {
        if let token { center.removeObserver(token) }
    }

    func startObserving() {
        guard token == nil else { return }
        token = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handle(note) }
        }
    }

    func stopObserving() {
        guard let token else { return }
        center.removeObserver(token)
        self.token = nil
    }

    private func handle(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            Log.info(.call, "AVAudioSession interruption began")
            delegate?.audioInterruptionBegan()
        case .ended:
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            let shouldResume = options.contains(.shouldResume)
            Log.info(.call, "AVAudioSession interruption ended (shouldResume: \(shouldResume))")
            delegate?.audioInterruptionEnded(shouldResume: shouldResume)
        @unknown default:
            break
        }
    }
}
