//
//  CallFailureReason.swift
//  ConduitCallEngine
//
//  Why a call ended in `.failed`. Drives the spoken/visible state and how the
//  log row reads. `badToken` (auth) is distinct from `lostConnection` (a
//  recoverable drop whose reconnection budget was exhausted) so the two never
//  get conflated — one is a desk-time fix, the other a road condition.
//

import Foundation

public enum CallFailureReason: String, Equatable, Sendable, Codable {
    case badToken
    case agentUnreachable
    case lostConnection
    case transportError
    case unknown
}
