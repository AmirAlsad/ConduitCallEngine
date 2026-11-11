//
//  CallDirection.swift
//  ConduitCallEngine
//
//  Which way a call was initiated. Outgoing is the user placing the call; incoming
//  is the target's server ringing the user via a VoIP push (see
//  `CallEngine.handleIncomingPush`). Raw values are stable, so a host can persist them.
//

import Foundation

public enum CallDirection: String, Codable, Sendable {
    case outgoing
    case incoming
}
