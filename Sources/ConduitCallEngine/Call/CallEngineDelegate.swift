//
//  CallEngineDelegate.swift
//  ConduitCallEngine
//
//  The host's side of the call engine: it resolves incoming targets, observes
//  state transitions and cues, records finished calls, and
//  supplies the bearer for ring-status receipts. Every call is synchronous and on
//  the main actor, in the order the engine makes the change, so a host sees each
//  transition in the same turn as the state assignment.
//

import Foundation

@MainActor
public protocol CallEngineDelegate: AnyObject {
    /// Once per ring push (not for a duplicate of the call in progress, a cancel
    /// push, or a ring whose cancel already arrived), after its
    /// CallKit report is issued: synchronously for a ring
    /// (CallKit may not have accepted the report yet), or once CallKit has answered
    /// the report for a push that arrives during another call. nil means the target is
    /// unknown: once CallKit accepts its report the ring is ended, recorded as
    /// failed with `.unknown`, and the engine returns to idle (an answer before that
    /// does nothing); a ring Focus filtered is still recorded as missed. A
    /// push during a live call is ended as unanswered either way; nil leaves its
    /// caller name and handle uncorrected. No ring-status receipt is ever sent for
    /// a ring whose target resolves to nil. For a ring, the target's
    /// `ringPreparation` and the call's `requestedPreparation` decide how much of it
    /// is prepared before the answer (`RingPreparation`).
    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget?
    /// Only on real assignments, after the engine's own field batch for that transition.
    func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState)
    /// A moment to mark with the host's own sound or speech; see `CallCue` for the
    /// guarantees. Called right after the `didChangeStateFrom:to:` of the change
    /// that caused it, with `engine.repeatingCue` already updated.
    func callEngine(_ engine: CallEngine, cue: CallCue)
    /// The ringing call's preparation moved from `old` to `new` (pre-connect;
    /// `CallEngine.ringPreparationPhase`, already `new` when this is called). Only for a
    /// real change. The phase leaves `.idle` only while `state` is `.incomingRinging`,
    /// and never with a state change. It returns to `.idle` before the transition out
    /// of `.incomingRinging` when the ring is answered, and, when the ring ends
    /// unanswered, after that ring's `callEngine(_:didFinish:)` and before `state` is
    /// `.idle` again. The move to `.fetchingCredentials` comes when CallKit accepts the
    /// ring's report, which can be inside the engine's handling of the VoIP push, so
    /// return promptly. For diagnostics: a host needs it for nothing else.
    func callEngine(
        _ engine: CallEngine,
        didChangeRingPreparationPhaseFrom old: RingPreparationPhase,
        to new: RingPreparationPhase
    )
    /// Once per call that ends, and once per ring that ends without an answer
    /// (declined, busy, filtered by Focus, timed out, cancelled by the caller, or
    /// unable to proceed). Not for a malformed push, a cancel push, or a ring whose
    /// cancel already arrived.
    func callEngine(_ engine: CallEngine, didFinish record: CallRecord)
    /// Asked at send time, only when the push carried a `status_url`.
    func callEngine(_ engine: CallEngine, ringStatusBearerForTarget id: UUID) -> String?
    /// PushKit issued or rotated the VoIP token. Send it to the server that rings
    /// this device; `CallEngine.voipPushToken` is the same value.
    func callEngine(_ engine: CallEngine, didUpdateVoIPPushToken token: Data)
    /// PushKit invalidated the VoIP token: pushes to it no longer arrive, and
    /// `CallEngine.voipPushToken` is nil until PushKit issues a new one, which comes
    /// as `callEngine(_:didUpdateVoIPPushToken:)`. Tell your server to forget it.
    func callEngineDidInvalidateVoIPPushToken(_ engine: CallEngine)
}

extension CallEngineDelegate {
    public func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? { nil }
    public func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState) {}
    public func callEngine(_ engine: CallEngine, cue: CallCue) {}
    public func callEngine(
        _ engine: CallEngine,
        didChangeRingPreparationPhaseFrom old: RingPreparationPhase,
        to new: RingPreparationPhase
    ) {}
    public func callEngine(_ engine: CallEngine, didFinish record: CallRecord) {}
    public func callEngine(_ engine: CallEngine, ringStatusBearerForTarget id: UUID) -> String? { nil }
    public func callEngine(_ engine: CallEngine, didUpdateVoIPPushToken token: Data) {}
    public func callEngineDidInvalidateVoIPPushToken(_ engine: CallEngine) {}
}
