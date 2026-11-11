//
//  AudioInterruptionObserving.swift
//  ConduitCallEngine
//
//  Observes AVAudioSession interruptions (Siri, a real phone call, a navigation
//  takeover) during a live call. CallKit owns the session; this only *reports*
//  begin/end so the engine can pause the mic and resume cleanly — it never
//  touches the session itself. The real implementation wraps the interruption
//  notification; the fake drives the callbacks in tests.
//

import Foundation

@MainActor
package protocol AudioInterruptionObserving: AnyObject {
    var delegate: AudioInterruptionObserverDelegate? { get set }
    /// Begin observing interruptions — called when a call starts.
    func startObserving()
    /// Stop observing — called on call teardown.
    func stopObserving()
}

@MainActor
package protocol AudioInterruptionObserverDelegate: AnyObject {
    /// An interruption began: another session took the audio route. The mic should
    /// stop capturing until it ends.
    func audioInterruptionBegan()
    /// An interruption ended. `shouldResume` is the system's hint that audio may
    /// resume (true for a transient interruption like Siri; false when the user
    /// must manually return).
    func audioInterruptionEnded(shouldResume: Bool)
}
