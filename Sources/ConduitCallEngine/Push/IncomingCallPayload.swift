//
//  IncomingCallPayload.swift
//  ConduitCallEngine
//
//  The parsed contents of a VoIP push: which target is calling, the call's id, how
//  to ring (optional caller name and handle), and OPTIONAL inline room credentials.
//  Hybrid resolution — if `room_url` + `token` are present the app joins directly;
//  otherwise the host resolves its own credentials after the user answers (so
//  they needn't ride the push). See `docs/INBOUND_CALLS.md` for the server contract.
//

import Foundation

package struct IncomingCallPayload: Equatable, Sendable {
    package let targetID: UUID
    package let callID: UUID
    /// The caller name to ring under; nil rings under the unknown-caller name.
    package let displayName: String?
    /// The CallKit handle to ring under; nil rings under `CallTarget.defaultHandle(for:)`.
    package let handle: String?
    package let roomURL: URL?
    package let token: String?
    /// Where to POST the ring's terminal status (answered/declined/busy/
    /// suppressed_by_focus), when the server asked for receipts. Optional —
    /// servers that don't care simply omit it.
    package let statusURL: URL?

    /// Inline room credentials, if the push carried both a room and a token.
    package var inlineConnection: CallConnection? {
        guard let roomURL, let token, !token.isEmpty else { return nil }
        return CallConnection(url: roomURL, token: token)
    }
}

extension IncomingCallPayload {
    /// Parse the PushKit payload dictionary. `target_id` (a UUID; `agent_id` is
    /// accepted as an alias, and `target_id` wins when both are present) is
    /// required; `call_id` becomes the CallKit UUID (a fresh one is minted if
    /// absent). Everything else is optional; empty strings count as absent.
    package init?(dictionary: [AnyHashable: Any]) {
        guard let targetID = Self.uuid(dictionary["target_id"]) ?? Self.uuid(dictionary["agent_id"]) else {
            return nil
        }
        self.targetID = targetID
        self.callID = Self.uuid(dictionary["call_id"]) ?? UUID()
        self.displayName = Self.string(dictionary["display_name"])
        self.handle = Self.string(dictionary["handle"])
        self.roomURL = Self.string(dictionary["room_url"]).flatMap { URL(string: $0) }
        self.token = dictionary["token"] as? String
        self.statusURL = Self.string(dictionary["status_url"]).flatMap { URL(string: $0) }
    }

    private static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
