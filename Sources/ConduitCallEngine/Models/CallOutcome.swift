//
//  CallOutcome.swift
//  ConduitCallEngine
//
//  How a call finished, as reported in a `CallRecord` and carried by
//  `CallState.ended`, which always agree. Raw values are stable, so a host can
//  persist them.
//

import Foundation

/// How a call finished.
///
/// Closed: the package adds no case to this enum within a minor version while it is
/// 0.x (from 1.0, within a major version), so a
/// `switch` may list every case.
public enum CallOutcome: String, Codable, Sendable {
    /// The call connected, then ended.
    case completed
    /// The call failed; `CallRecord.failureReason` (or `CallState.failed`) says why.
    case failed
    /// The user declined a ringing incoming call.
    case declined
    /// The remote party left before the call connected, or the ring never reached the user.
    case noAnswer
    /// The user ended a call they placed or answered, before it connected.
    case canceled
}
