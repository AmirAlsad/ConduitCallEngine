//
//  TransportDisconnectReason.swift
//  ConduitCallEngine
//
//  Why the transport disconnected. The engine branches on this: a
//  `networkDropped` is a candidate for reconnection, while `authFailed` is a
//  terminal failure. Conflating them would turn a recoverable drop into a dead
//  call.
//

import Foundation

public enum TransportDisconnectReason: Equatable, Sendable {
    case requestedByUser
    case networkDropped
    case authFailed
    case botLeft
    case unknown
}
