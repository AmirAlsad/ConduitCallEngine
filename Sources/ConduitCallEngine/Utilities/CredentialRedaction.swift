//
//  CredentialRedaction.swift
//  ConduitCallEngine
//
//  Removes what could be a credential from text the package logs or puts in an
//  error: the query, fragment and user info of every URL (a room URL can carry its
//  token in the query, a failing request's URL its key), bearer values, JSON Web
//  Tokens, and the value after a key such as `token=` or `api_key:`. SDK and host
//  error descriptions are the text this matters for: the package itself never
//  formats a credential into a message.
//

import Foundation

package enum CredentialRedaction {
    package static let placeholder = "<redacted>"

    package static func redact(_ text: String) -> String {
        guard mayContainCredential(text) else { return text }
        var result = redactURLs(in: text)
        result = replace(bearer, in: result, with: "Bearer \(placeholder)")
        result = replace(jwt, in: result, with: placeholder)
        result = replace(keyedValue, in: result, with: "$1$2\(placeholder)")
        return result
    }

    /// A cheap check that lets most messages through untouched.
    private static func mayContainCredential(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["://", "eyj", "bearer", "token", "key", "secret", "password", "authorization"]
            .contains { lowered.contains($0) }
    }

    /// Keeps each URL's scheme, host and path; drops its user info, and replaces its
    /// query and fragment with the placeholder.
    private static func redactURLs(in text: String) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in url.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += ns.substring(with: match.range(at: 1))
            result += ns.substring(with: match.range(at: 3))
            if match.range(at: 4).location != NSNotFound { result += "?\(placeholder)" }
            if match.range(at: 5).location != NSNotFound { result += "#\(placeholder)" }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func replace(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }

    /// Scheme, user info, host and path, query, fragment.
    private static let url = try! NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z0-9+.\-]*://)([^\s/?#@"'<>]*@)?([^\s?#"'<>]*)(\?[^\s#"'<>]*)?(#[^\s"'<>]*)?"#
    )
    private static let bearer = try! NSRegularExpression(
        pattern: #"(?i)\bbearer\s+[A-Za-z0-9\-._~+/]+=*"#
    )
    private static let jwt = try! NSRegularExpression(
        pattern: #"\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]*)?"#
    )
    /// A credential-named key, its separator, and its value: quoted, wrapped in
    /// `Optional("…")`, or up to the next separator. A key ending in one of the names
    /// counts (`meeting_token`, `dailyToken`, `client_secret`, `x_api_key`).
    private static let keyedValue = try! NSRegularExpression(
        pattern: #"(?i)\b(\w*(?:token|api[_\-]?key|secret|password)|authorization)(["']?\s*[=:]\s*)(Optional\("[^"]*"\)|"[^"]*"|'[^']*'|[^\s&,;)\]}"']+)"#
    )
}
