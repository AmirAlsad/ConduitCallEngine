//
//  LiveKitInterruptionRecovery.swift
//  ConduitCallEngine
//
//  EXPERIMENTAL, not supported API: exposed only as SPI so a debug build can run the
//  device test that looks for a way to get a LiveKit call's audio back after a real
//  phone call interrupted it. On one phone (iPhone 17, iOS 27.0) a LiveKit call had
//  no audio either way once resumed after a phone call, although CallKit had
//  activated the session and the attach had made LiveKit's audio engine available
//  again; a hold and resume with no other call brought the audio back every time.
//  Every case other than `.off` may change or go away.
//
//    @_spi(InterruptionRecoveryExperiment) import ConduitCallEngineLiveKit
//    LiveKitTransport(interruptionRecovery: .restartEngine)
//
//  The engine asks for it with `recoverMediaAfterInterruption()`, after the attach
//  that follows an audio interruption during a hold or deactivation.
//

/// What `LiveKitTransport` does when the engine asks it to recover its media after
/// an audio interruption. Experimental.
@_spi(InterruptionRecoveryExperiment)
public enum LiveKitInterruptionRecovery: String, CaseIterable, Sendable {
    /// The default: nothing. LiveKit's audio engine state is still logged.
    case off
    /// L-A: make LiveKit's audio engine unavailable and available again at once.
    case restartEngine = "L-A"
    /// L-B: after a short pause, make it unavailable and available again, and repeat
    /// a few times, each after a pause, until LiveKit reports its engine running.
    case restartEngineUntilRunning = "L-B"
    /// L-C: tell WebRTC's audio session that it was activated from outside, as
    /// WebRTC expects of an app that lets CallKit activate the session
    /// (`RTCAudioSessionActivationDelegate.audioSessionDidActivate(_:)`, which the
    /// LiveKit SDK does not call), then restart the engine as L-A does. Strings in
    /// the WebRTC binary LiveKit 2.19.0 ships ("Clearing interrupted state due to
    /// external activation") suggest it clears an interruption whose end iOS never
    /// reported. Reached through the Objective-C runtime, because LiveKit imports
    /// its WebRTC module internally.
    case notifyActivationThenRestart = "L-C"
}
