//
//  CallOutcome.swift
//  ConduitCallEngine
//
//  How a call finished, as reported in a `CallRecord`. Raw values are stable, so a
//  host can persist them.
//

import Foundation

public enum CallOutcome: String, Codable, Sendable {
    case completed
    case failed
    case declined
    case noAnswer
    case canceled
}
