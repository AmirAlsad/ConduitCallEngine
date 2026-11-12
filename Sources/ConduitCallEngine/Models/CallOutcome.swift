//
//  CallOutcome.swift
//  ConduitCallEngine
//
//  How a call finished, as reported in a `CallRecord` and carried by
//  `CallState.ended`, which always agree. Raw values are stable, so a host can
//  persist them.
//

import Foundation

public enum CallOutcome: String, Codable, Sendable {
    /// The call connected, then ended.
    case completed
    case failed
    /// The user declined a ringing incoming call.
    case declined
    /// The remote party left before the call connected, or the ring never reached the user.
    case noAnswer
    /// The user ended a call they placed or answered, before it connected.
    case canceled
}
