//
//  CallFailureReason.swift
//  ConduitCallEngine
//
//  Why a call ended in `.failed`. `badToken` (credentials rejected) is distinct
//  from `lostConnection` (a mid-call drop that exhausted its reconnection budget),
//  so a host can tell a configuration problem from a network one. Raw values are
//  stable, so a host can persist them.
//

import Foundation

public enum CallFailureReason: String, Equatable, Sendable, Codable {
    case badToken
    /// The transport joined, but the agent was not ready within
    /// `CallEngineConfiguration.joinTimeout` on the call's first connect.
    case agentUnreachable
    case lostConnection
    case transportError
    case unknown
}
