//
//  TransportError.swift
//  ConduitCallEngine
//
//  Transport-agnostic error surface. Concrete SDK errors (Daily, LiveKit) are
//  mapped into these by each transport adapter and never leak upward.
//

import Foundation

public enum TransportError: Error, Equatable, Sendable {
    case connectionFailed(String)
    case authenticationFailed
    case timedOut
    case botUnavailable
    case underlying(String)
}
