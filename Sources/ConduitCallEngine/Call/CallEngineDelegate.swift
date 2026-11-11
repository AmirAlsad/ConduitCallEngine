//
//  CallEngineDelegate.swift
//  ConduitCallEngine
//
//  The host's side of the call engine: it resolves incoming targets, observes
//  state transitions, records finished calls, and
//  supplies the bearer for ring-status receipts. Every call is synchronous and on
//  the main actor, in the order the engine makes the change, so a host sees each
//  transition in the same turn as the state assignment.
//

import Foundation

@MainActor
public protocol CallEngineDelegate: AnyObject {
    /// Once per push, after its CallKit report is issued: synchronously for a ring
    /// (CallKit may not have accepted the report yet), or once CallKit accepts it
    /// for a push that arrives during another call. nil means the target is
    /// unknown: the ring fails once CallKit accepts its report (an answer before
    /// that does nothing), and a ring Focus filtered is still recorded as missed. A
    /// push during a live call is ended as unanswered either way; nil only leaves
    /// its caller name and handle uncorrected.
    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget?
    /// Only on real assignments, after the engine's own field batch for that transition.
    func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState)
    func callEngine(_ engine: CallEngine, didFinish record: CallRecord)
    /// Asked at send time, only when the push carried a `status_url`.
    func callEngine(_ engine: CallEngine, ringStatusBearerForTarget id: UUID) -> String?
    func callEngine(_ engine: CallEngine, didUpdateVoIPPushToken token: Data)
}

extension CallEngineDelegate {
    public func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? { nil }
    public func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState) {}
    public func callEngine(_ engine: CallEngine, didFinish record: CallRecord) {}
    public func callEngine(_ engine: CallEngine, ringStatusBearerForTarget id: UUID) -> String? { nil }
    public func callEngine(_ engine: CallEngine, didUpdateVoIPPushToken token: Data) {}
}
