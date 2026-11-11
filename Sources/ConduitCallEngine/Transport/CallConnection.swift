//
//  CallConnection.swift
//  ConduitCallEngine
//
//  The already-resolved room a transport joins: the room (or offer) URL and its
//  token. The engine resolves them through `CallTarget.connect` and hands them to
//  `CallTransport.connect`; a transport never fetches credentials itself.
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
