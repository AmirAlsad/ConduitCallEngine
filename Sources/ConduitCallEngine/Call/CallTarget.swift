//
//  CallTarget.swift
//  ConduitCallEngine
//
//  What the call engine is handed instead of a host model: who is being called
//  (identity for CallKit) and how to reach them. The engine creates the transport
//  once per call via `makeTransport`, BEFORE resolving credentials, so a CallKit
//  activation that lands mid-fetch reaches the transport; `connect` runs for the
//  first connect and again for every reconnect attempt, told which by its
//  `ConnectRequest`.
//

import Foundation

public struct CallTarget {
    public let id: UUID
    public let displayName: String
    /// The CallKit handle; nil falls back to `defaultHandle(for:)`. The engine
    /// reports it to CallKit as an email-address handle (`CXHandle.HandleType
    /// .emailAddress`, the only type its provider supports), whatever its format.
    public let handle: String?
    public let makeTransport: @MainActor () -> any CallTransport
    /// Resolves the room to join: for the call's first connect, and again before
    /// every engine reconnect attempt. The request says which. Throw
    /// `TransportError.authenticationFailed` for credentials the backend rejected,
    /// so the call fails as `.badToken`.
    public let connect: @MainActor (ConnectRequest) async throws -> CallConnection
    /// How much of an incoming call to this target the host lets the engine prepare
    /// while it rings, at most; see `RingPreparation`. The push must ask for it too
    /// (`IncomingCall.requestedPreparation`), so a host can set it per ring from
    /// what the push asked for. Ignored for outgoing calls. Default `.none`.
    public let ringPreparation: RingPreparation

    public init(
        id: UUID,
        displayName: String,
        handle: String?,
        makeTransport: @escaping @MainActor () -> any CallTransport,
        connect: @escaping @MainActor (ConnectRequest) async throws -> CallConnection,
        ringPreparation: RingPreparation = .none
    ) {
        self.id = id
        self.displayName = displayName
        self.handle = handle
        self.makeTransport = makeTransport
        self.connect = connect
        self.ringPreparation = ringPreparation
    }

    /// An email-shaped handle unique to `id`, under the reserved `.invalid` domain.
    public static func defaultHandle(for id: UUID) -> String {
        "\(id.uuidString.lowercased())@calltarget.invalid"
    }
}

/// The live call, as a host's UI shows it.
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
    /// What the push's `preconnect` key asked the engine to prepare while the call
    /// rings; `.none` when it carried none or a value the engine does not know.
    /// The ring gets it only if the target allows it (`CallTarget.ringPreparation`).
    public let requestedPreparation: RingPreparation

    public init(
        callID: UUID,
        targetID: UUID,
        displayName: String,
        handle: String,
        connection: CallConnection?,
        requestedPreparation: RingPreparation = .none
    ) {
        self.callID = callID
        self.targetID = targetID
        self.displayName = displayName
        self.handle = handle
        self.connection = connection
        self.requestedPreparation = requestedPreparation
    }
}
