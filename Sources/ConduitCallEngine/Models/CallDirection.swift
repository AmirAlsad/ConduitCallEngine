//
//  CallDirection.swift
//  ConduitCallEngine
//
//  Which way a call was initiated. Outgoing is the user placing the call; incoming
//  is the target's server ringing the user via a VoIP push (see
//  `CallEngine.handleIncomingPush`). Raw values are stable, so a host can persist them.
//

import Foundation

/// Which way a call was initiated.
///
/// Closed: the package adds no case to this enum within a minor version while it is
/// 0.x (from 1.0, within a major version), so a
/// `switch` may list every case.
public enum CallDirection: String, Codable, Sendable {
    /// The host placed it with `CallEngine.placeCall(_:)`.
    case outgoing
    /// The target's server rang the device with a VoIP push.
    case incoming
}
