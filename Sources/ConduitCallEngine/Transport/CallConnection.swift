//
//  CallConnection.swift
//  ConduitCallEngine
//
//  The already-resolved room a transport joins: the room (or offer) URL and its
//  token. The engine resolves them through `CallTarget.connect` and hands them to
//  `CallTransport.connect`; a transport never fetches credentials itself.
//

import Foundation

/// The room a transport joins: what `CallTarget.connect` returns and
/// `CallTransport.connect(_:)` receives. Its meaning is the transport's: for Daily a
/// room URL and meeting token, for LiveKit a server URL and access token.
public struct CallConnection: Equatable, Sendable {
    public let url: URL
    /// The credential for `url`; nil for a room that needs none.
    public let token: String?

    public init(url: URL, token: String?) {
        self.url = url
        self.token = token
    }
}
