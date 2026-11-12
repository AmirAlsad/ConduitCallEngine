//
//  CallProviding.swift
//  ConduitCallEngine
//
//  The engine → system direction of the CallKit seam, abstracting `CXProvider` and
//  `CXCallController`. The real `SystemCallProvider` wraps CallKit; `FakeCallProvider`
//  lets the whole call state machine run in the simulator.
//
//  Reporting maps to CallKit lifecycle: `reportOutgoingCallConnecting` when the
//  transport begins connecting, `reportOutgoingCallConnected` only when media is up
//  AND the remote party is present (this starts the native duration timer).
//

import Foundation

/// Why `reportIncomingCall` did not ring.
package enum IncomingCallReportError: Error, Equatable, Sendable {
    /// The system suppressed the ring (Focus/DND). Not a failure: the caller
    /// records a missed call instead of entering a failed state.
    case filteredByFocus
    /// CallKit already has a call with this id (`callUUIDAlreadyExists`), so the
    /// report created nothing.
    case duplicateCallID
    case failed(String)
}

@MainActor
package protocol CallProviding: AnyObject {
    var delegate: CallProviderDelegate? { get set }

    /// Report an outgoing call to the system. Returns the call's UUID.
    func startOutgoingCall(handle: CallHandle, displayName: String) async throws -> UUID
    /// Report an incoming call to the system (from a VoIP push). The `id` is the
    /// call's UUID (the push's call_id); the system then rings. The report is issued
    /// before this returns — PushKit requires it in the same run-loop turn as the
    /// push — and `completion` runs later on the main actor (nil error = ringing).
    func reportIncomingCall(
        id: UUID,
        handle: CallHandle,
        displayName: String,
        completion: @escaping @MainActor (IncomingCallReportError?) -> Void
    )
    /// Correct how a reported call is shown (caller name and handle).
    func updateCall(_ id: UUID, handle: CallHandle, displayName: String)
    func reportOutgoingCallConnecting(_ id: UUID)
    func reportOutgoingCallConnected(_ id: UUID)
    /// Request the system end the call (an end the host asked for).
    func endCall(_ id: UUID) async
    /// Tell the system the call ended (transport-initiated / failure).
    func reportCallEnded(_ id: UUID, reason: CallEndReason)
    func setMuted(_ id: UUID, muted: Bool) async
}
