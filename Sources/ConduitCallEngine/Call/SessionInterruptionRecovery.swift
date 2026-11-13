//
//  SessionInterruptionRecovery.swift
//  ConduitCallEngine
//
//  EXPERIMENTAL, not supported API: exposed only as SPI so a debug build can run the
//  device test that looks for a way to get a call's audio back after a real phone
//  call interrupted it. On one phone (iPhone 17, iOS 27.0) a Daily call and a
//  LiveKit call each had no audio either way once resumed after a phone call,
//  although CallKit had activated the session and the transport was attached; a
//  hold and resume with no other call brought the audio back every time. If the
//  session, rather than either SDK, is what is not usable, something done to the
//  session may help. Every case other than `.off` may change or go away.
//
//    @_spi(InterruptionRecoveryExperiment) import ConduitCallEngine
//    engine.sessionInterruptionRecovery = { .reapplyCategory }
//

/// What the engine does to the audio session, before attaching the transport, when
/// CallKit hands back the audio of a call whose media was detached during an audio
/// interruption. Experimental.
@_spi(InterruptionRecoveryExperiment)
public enum SessionInterruptionRecovery: String, CaseIterable, Sendable {
    /// The default: nothing. The session is still logged.
    case off
    /// E-A: set the call's category, mode and options again (`playAndRecord`,
    /// `voiceChat`) on the session CallKit activated.
    case reapplyCategory = "E-A"
    /// E-B: as E-A, then `AVAudioSession.setActive(true)` once. This breaks the
    /// rule that CallKit alone activates the session, and is only ever done here.
    case reapplyCategoryAndActivate = "E-B"
}
