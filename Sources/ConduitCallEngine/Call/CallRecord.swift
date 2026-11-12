//
//  CallRecord.swift
//  ConduitCallEngine
//
//  A finished call (or a ring that never reached the user), reported to the host
//  through `CallEngineDelegate.callEngine(_:didFinish:)`. The host decides what to
//  persist or notify.
//

import Foundation

/// A finished call, or a ring that ended without one, handed to
/// `CallEngineDelegate.callEngine(_:didFinish:)` once per call.
public struct CallRecord: Equatable, Sendable {
    /// The target's id; for a ring whose target the host did not resolve, the
    /// push's `target_id`, which may match nothing of the host's.
    public let targetID: UUID
    public let direction: CallDirection
    /// When the call was placed or the ring arrived.
    public let startedAt: Date
    /// Connected duration in seconds; 0 for a call that never connected.
    public let duration: TimeInterval
    /// How it finished; for a call that reached `.ended(_)`, the same outcome.
    public let outcome: CallOutcome
    /// Why it failed; non-nil exactly when `outcome` is `.failed`.
    public let failureReason: CallFailureReason?
    /// Non-nil for an incoming ring nobody answered or declined: one that never
    /// reached the user (busy, Focus) or one that rang out or that the caller
    /// withdrew. `MissedCallReason.reachedUser` tells them apart.
    public let missedReason: MissedCallReason?

    public init(
        targetID: UUID,
        direction: CallDirection,
        startedAt: Date,
        duration: TimeInterval,
        outcome: CallOutcome,
        failureReason: CallFailureReason? = nil,
        missedReason: MissedCallReason? = nil
    ) {
        self.targetID = targetID
        self.direction = direction
        self.startedAt = startedAt
        self.duration = duration
        self.outcome = outcome
        self.failureReason = failureReason
        self.missedReason = missedReason
    }
}

/// Why an incoming ring was missed. Raw values are stable, so a host can persist them.
///
/// Open: later versions may add cases. End a `switch` over it with `@unknown default`,
/// which keeps it compiling, with a warning that names the new case, when one is added.
public enum MissedCallReason: String, Sendable, Codable {
    /// Another call was live, so the ring was reported and ended at once.
    case busy
    /// Focus / Do Not Disturb suppressed the ring.
    case filteredByFocus
    /// The ring reached its timeout (`CallEngineConfiguration.ringTimeout`, or the
    /// push's shorter `ring_timeout`) without being answered or declined.
    case ringTimedOut
    /// The caller withdrew the ring with a cancel push while it was ringing.
    case canceledByCaller

    /// Whether the phone rang for the user before the ring was missed: true for a
    /// ring that timed out or was cancelled, false for one that was busy or that
    /// Focus filtered, which the user never saw.
    public var reachedUser: Bool {
        switch self {
        case .busy, .filteredByFocus: false
        case .ringTimedOut, .canceledByCaller: true
        }
    }
}
