//
//  LiveKitConnectFailure.swift
//  ConduitCallEngine
//
//  Which LiveKit connect errors are rejected credentials, kept pure and SDK-free so
//  the rule is unit-testable. The engine ends a call at once as `.badToken` on
//  `TransportError.authenticationFailed`, even mid-reconnect, so only an exact
//  signal counts: LiveKit's validation request answered 401 or 403, or LiveKit's
//  own insufficient-permissions error.
//
//  After a WebSocket connect fails on a first join, LiveKit asks the server's
//  validation endpoint why, and a 4xx answer (other than 404 and 429) becomes a
//  `.validation` error whose message is "HTTP <status>: <server message>". The status
//  is also stored on the error, but not publicly, so the message's prefix is read.
//  Nothing else about the error is searched: its description includes nested
//  errors' user info, which can carry the failing URL, a host name or a join
//  request, so a network failure could match a word by chance.
//

enum LiveKitConnectFailure {
    /// The parts of a LiveKit connect error the rule reads, mirrored so it is testable
    /// without the SDK.
    enum Kind: Equatable {
        case insufficientPermissions
        /// A `.validation` error and its message.
        case validation(message: String?)
        case other
    }

    static func isRejectedCredentials(_ kind: Kind) -> Bool {
        switch kind {
        case .insufficientPermissions:
            true
        case .validation(let message?):
            message.hasPrefix("HTTP 401:") || message.hasPrefix("HTTP 403:")
        case .validation(nil), .other:
            false
        }
    }
}
