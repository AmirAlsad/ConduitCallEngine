//
//  CallTarget.swift
//  ConduitCallEngine
//
//  What the call engine is handed instead of a host model: who is being called
//  (identity for CallKit) and how to reach them. The engine creates the call's
//  transport via `makeTransport` BEFORE resolving credentials, so a CallKit
//  activation that lands mid-fetch reaches the transport; `connect` runs for the
//  first connect and again for every reconnect attempt, told which by its
//  `ConnectRequest`.
//

import Foundation

/// A call's identity and how to reach it: what the engine is handed instead of a
/// host model, for `CallEngine.placeCall(_:)` and from
/// `CallEngineDelegate.callEngine(_:targetForIncomingCall:)`. A value: Sendable, and
/// its closures are called on the main actor.
// Unchecked only because the package compiles in the Swift 5 mode: every stored
// property is a constant, and both closures are main-actor isolated, a function type
// Swift 6 treats as Sendable (SE-0434).
public struct CallTarget: @unchecked Sendable {
    /// Identifies the target: an incoming push names it as `target_id`, and its
    /// `CallRecord`s carry it. Stable for as long as your server may ring it.
    public let id: UUID
    /// The name CallKit shows for the call, and `ActiveCall.displayName`.
    public let displayName: String
    /// The CallKit handle; nil falls back to `defaultHandle(for:)`. The engine
    /// reports it to CallKit as an email-address handle (`CXHandle.HandleType
    /// .emailAddress`, the only type its provider supports), whatever its format.
    public let handle: String?
    /// Makes the call's transport. Return a new instance every time. The engine calls
    /// it once per call, before it fetches credentials, and every later connect of
    /// that call (reconnect attempts, and the unprepared connect after a ring's
    /// preparation failed following the answer) reuses that instance. The one
    /// exception: for an incoming call whose ring was prepared at the `.media` tier,
    /// it is called during the ring, and if that preparation fails before the
    /// answer, it is called again at the answer, so one call can make two.
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
        handle: String? = nil,
        ringPreparation: RingPreparation = .none,
        makeTransport: @escaping @MainActor () -> any CallTransport,
        connect: @escaping @MainActor (ConnectRequest) async throws -> CallConnection
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

/// The call in progress, as a host's UI shows it (`CallEngine.activeCall`).
public struct ActiveCall: Equatable, Sendable {
    /// The target's id: `CallTarget.id`, or for a ring the push's `target_id`.
    public let targetID: UUID
    /// The resolved target's name, or the name the ring was reported under when its
    /// target is unknown.
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
    /// The ring's `call_id`. Where the engine writes a call id as text (the
    /// ring-status receipts), it uses the lowercase form, `uuidString.lowercased()`.
    public let callID: UUID
    /// The push's `target_id` (or `agent_id`): the `CallTarget.id` to resolve.
    public let targetID: UUID
    /// The name the ring was reported under: the push's `display_name`, or
    /// `CallEngineConfiguration.unknownCallerName`.
    public let displayName: String
    /// The handle the ring was reported under: the push's `handle`, or
    /// `CallTarget.defaultHandle(for:)` of `targetID`.
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
        connection: CallConnection? = nil,
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
