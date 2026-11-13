//
//  DailyInterruptionRecovery.swift
//  ConduitCallEngine
//
//  EXPERIMENTAL, not supported API: exposed only as SPI so a debug build can run the
//  device test that decides how, if at all, `PipecatDailyTransport` can get a call's
//  audio back after a real phone call interrupted it. On one phone (iPhone 17,
//  iOS 27.0) a Daily call resumed after a phone call had no audio either way,
//  although the engine, CallKit and the agent all had the call live; a hold and
//  resume with no other call brought the audio back every time. Nobody knows yet
//  which recovery works. Every case other than `.off` may change or go away.
//
//    @_spi(InterruptionRecoveryExperiment) import ConduitCallEngineDaily
//    PipecatDailyTransport(interruptionRecovery: .restartMedia)
//
//  The engine asks for it with `recoverMediaAfterInterruption()`, after the attach
//  that follows an audio interruption during a hold or deactivation.
//

/// What `PipecatDailyTransport` does when the engine asks it to recover its media
/// after an audio interruption. Experimental.
@_spi(InterruptionRecoveryExperiment)
public enum DailyInterruptionRecovery: String, CaseIterable, Sendable {
    /// The default: nothing, as without this switch. Daily's state is still logged.
    case off
    /// A: turn the microphone input off, unsubscribe from the agent's audio, then
    /// subscribe again and turn the microphone back on if the engine had it on.
    case restartMedia = "A"
    /// B: ask Daily to prefer another audio device and then the call's own again,
    /// each with the microphone input naming it, then unsubscribe from the agent's
    /// audio and subscribe again.
    case reassertAudioDevice = "B"
    /// C: leave the room without the end-call signal, release the Pipecat client,
    /// and join the same room with the same credentials on a new client. The call
    /// shows reconnecting until the agent is ready again.
    case rejoin = "C"
}
