//
//  CallTarget.swift
//  ConduitCallEngine
//
//  What the call engine is handed instead of a host model: who is being called
//  (identity for CallKit) and how to reach them. The engine creates the transport
//  once per call via `makeTransport`, BEFORE resolving credentials, so a CallKit
//  activation that lands mid-fetch reaches the transport; `connect` runs for the
//  first connect and again for every reconnect attempt.
//

import Foundation

public struct CallTarget {
    public let id: UUID
    public let displayName: String
    /// The CallKit handle; nil falls back to `defaultHandle(for:)`.
    public let handle: String?
    public let makeTransport: @MainActor () -> any CallTransport
    public let connect: @MainActor () async throws -> CallConnection

    public init(
        id: UUID,
        displayName: String,
        handle: String?,
        makeTransport: @escaping @MainActor () -> any CallTransport,
        connect: @escaping @MainActor () async throws -> CallConnection
    ) {
        self.id = id
        self.displayName = displayName
        self.handle = handle
        self.makeTransport = makeTransport
        self.connect = connect
    }

    public static func defaultHandle(for id: UUID) -> String {
        "\(id.uuidString.lowercased())@calltarget.invalid"
    }
}

/// The live call, as the UI projects it.
public struct ActiveCall: Equatable, Sendable {
    public let targetID: UUID
    public let displayName: String
    public let direction: CallDirection

    public init(targetID: UUID, displayName: String, direction: CallDirection) {
        self.targetID = targetID
        self.displayName = displayName
        self.direction = direction
    }
}

/// An incoming ring as the push described it, handed to the host to resolve.
public struct IncomingCall: Equatable, Sendable {
    public let callID: UUID
    public let targetID: UUID
    public let displayName: String
    public let handle: String
    /// Inline room credentials from the push, when it carried both.
    public let connection: CallConnection?

    public init(callID: UUID, targetID: UUID, displayName: String, handle: String, connection: CallConnection?) {
        self.callID = callID
        self.targetID = targetID
        self.displayName = displayName
        self.handle = handle
        self.connection = connection
    }
}
