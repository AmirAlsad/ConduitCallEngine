//
//  IncomingCallPayload.swift
//  ConduitCallEngine
//
//  The parsed contents of a VoIP push. `VoIPPushRequest` says what the push asks
//  for (a ring, or withdrawing one); a ring's `IncomingCallPayload` carries which
//  target is calling, the call's id, how to ring (optional caller name, handle and
//  timeout), and OPTIONAL inline room credentials.
//  When `room_url` and a non-empty `token` are both present they reach the host as
//  `IncomingCall.connection`, for the target it returns to connect with; otherwise
//  that target resolves credentials itself after the user answers, so they need
//  not ride the push.
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
    /// suppressed_by_focus/unanswered/canceled), when the server asked for receipts. Optional —
    /// servers that don't care simply omit it.
    package let statusURL: URL?
    /// The sender's `ring_timeout`, in whole seconds (a positive integer string);
    /// the engine clamps it. nil when absent or invalid.
    package let ringTimeoutSeconds: Int?
    /// What the sender's `preconnect` asks to prepare during the ring: `"credentials"`
    /// or `"media"`; anything else, or no key, is `.none`.
    package let preparation: RingPreparation

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
        self.ringTimeoutSeconds = Self.string(dictionary["ring_timeout"]).flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        switch Self.string(dictionary["preconnect"]) {
        case "credentials": self.preparation = .credentials
        case "media": self.preparation = .media
        default: self.preparation = .none
        }
    }

    fileprivate static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    fileprivate static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}

/// A cancel push: the sender withdraws the ring `callID`. It carries no target.
package struct CancelCallPayload: Equatable, Sendable {
    package let callID: UUID
    /// The caller name to show if the cancel has to be reported as a new call.
    package let displayName: String?
}

/// What a VoIP push asks for, from its `action` key.
package enum VoIPPushRequest: Equatable, Sendable {
    /// `action` absent (or empty, or not a string) or `"ring"`, with a valid
    /// `target_id` or `agent_id`.
    case ring(IncomingCallPayload)
    /// `action` is `"cancel"` with a valid `call_id`. Any `target_id` is ignored.
    case cancel(CancelCallPayload)
    /// Anything else: a ring without a valid target, a cancel without a valid
    /// `call_id`, or an `action` the engine does not know.
    case malformed

    package init(dictionary: [AnyHashable: Any]) {
        switch IncomingCallPayload.string(dictionary["action"]) {
        case nil, "ring":
            self = IncomingCallPayload(dictionary: dictionary).map(VoIPPushRequest.ring) ?? .malformed
        case "cancel":
            guard let callID = IncomingCallPayload.uuid(dictionary["call_id"]) else {
                self = .malformed
                return
            }
            self = .cancel(CancelCallPayload(
                callID: callID,
                displayName: IncomingCallPayload.string(dictionary["display_name"])
            ))
        default:
            self = .malformed
        }
    }
}
