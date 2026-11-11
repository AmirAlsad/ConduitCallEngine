//
//  FakeAudioInterruptionObserver.swift
//  ConduitCallEngine
//
//  Fake conforming to `AudioInterruptionObserving`. Lets tests synthesize an
//  interruption begin/end without a live AVAudioSession, and lets the simulator
//  wiring use a no-op observer.
//

import Foundation
import ConduitCallEngine

@MainActor
package final class FakeAudioInterruptionObserver: AudioInterruptionObserving {
    package init() {}

    package weak var delegate: AudioInterruptionObserverDelegate?
    package private(set) var isObserving = false

    package func startObserving() { isObserving = true }
    package func stopObserving() { isObserving = false }

    // MARK: - Test hooks

    package func simulateBegan() { delegate?.audioInterruptionBegan() }
    package func simulateEnded(shouldResume: Bool) { delegate?.audioInterruptionEnded(shouldResume: shouldResume) }
}
