//
//  CallConnection.swift
//  ConduitCallEngine
//
//  The already-resolved room a transport joins: the room (or offer) URL and its
//  token. Credentials are resolved before `connect` — the transport never pairs.
//

import Foundation

public struct CallConnection: Equatable, Sendable {
    public let url: URL
    public let token: String?

    public init(url: URL, token: String?) {
        self.url = url
        self.token = token
    }
}
