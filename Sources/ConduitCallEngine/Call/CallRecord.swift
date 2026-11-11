//
//  CallRecord.swift
//  ConduitCallEngine
//
//  A finished call (or a ring that never reached the user), reported to the host
//  through `CallEngineDelegate.callEngine(_:didFinish:)`. The host decides what to
//  persist or notify.
//

import Foundation

public struct CallRecord: Equatable, Sendable {
    public let targetID: UUID
    public let direction: CallDirection
    public let startedAt: Date
    /// Connected duration in seconds; 0 for a call that never connected.
    public let duration: TimeInterval
    public let outcome: CallOutcome
    public let failureReason: CallFailureReason?
    /// Non-nil only when the ring never reached the user.
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

public enum MissedCallReason: Sendable {
    /// Another call was live, so the ring was reported and ended at once.
    case busy
    /// Focus / Do Not Disturb suppressed the ring.
    case filteredByFocus
}
