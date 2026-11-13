import ConduitCallEngine
import Foundation

/// PLACEHOLDER. This is where your own backend goes: the engine only needs a room URL and a
/// token, and how you obtain them (session, API key, your own auth) is up to the host.
enum ExampleBackend {
    /// Replace with your backend.
    static var baseURL = URL(string: "https://your-agent-backend.example.com")!

    /// The call-control signals this app's calls carry, sent with every request so the
    /// backend's agent waits for `call-connected` before it speaks (Integration Guide,
    /// "When your agent should start speaking"). Only `call-connected`: the engine
    /// sends `call-held` and `call-resumed` only with the experimental hold, which
    /// this app leaves off.
    static let callSignals = [CallSignal.connected.rawValue]

    private struct Credentials: Decodable {
        let url: URL
        let token: String?
    }

    private struct ConnectBody: Encodable {
        let targetID: String
        let purpose: String
        let callID: String?
        let callSignals: [String]

        enum CodingKeys: String, CodingKey {
            case targetID = "target_id"
            case purpose
            case callID = "call_id"
            case callSignals = "call_signals"
        }
    }

    /// POSTs the request to `<baseURL>/connect` and decodes `{ "url": ..., "token": ... }`.
    /// A 401 or 403 throws `TransportError.authenticationFailed`, so the call fails as
    /// `.badToken` rather than as a network failure.
    static func fetchConnection(for request: ConnectRequest) async throws -> CallConnection {
        var urlRequest = URLRequest(url: baseURL.appending(path: "connect"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(ConnectBody(
            targetID: ExampleAgent.id.uuidString.lowercased(),
            purpose: describe(request.purpose),
            callID: request.callID?.uuidString.lowercased(),
            callSignals: callSignals
        ))
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: break
        case 401, 403: throw TransportError.authenticationFailed
        case let status: throw TransportError.connectionFailed("HTTP \(status)")
        }
        let credentials = try JSONDecoder().decode(Credentials.self, from: data)
        return CallConnection(url: credentials.url, token: credentials.token)
    }

    private static func describe(_ purpose: ConnectRequest.Purpose) -> String {
        switch purpose {
        case .outgoing: "outgoing"
        case .answered: "answered"
        case .ringing: "ringing"
        case .reconnect: "reconnect"
        @unknown default: "answered" // a purpose added later: treat it as an incoming call's first connect
        }
    }

    private struct Registration: Encodable {
        let token: String
        let bundleID: String
        let apnsEnvironment: String
        let targets: [Target]
        let pushFeatures: [String]
        let callSignals: [String]

        struct Target: Encodable {
            let id: String
            let displayName: String
        }

        enum CodingKeys: String, CodingKey {
            case token
            case bundleID = "bundle_id"
            case apnsEnvironment = "apns_environment"
            case targets
            case pushFeatures = "push_features"
            case callSignals = "call_signals"
        }
    }

    /// The APNs environment of this build's token. It follows the `aps-environment`
    /// entitlement the build is signed with: development-signed builds (the debug
    /// configuration here) get sandbox tokens, TestFlight and App Store builds
    /// production ones.
    private static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    /// Tells the backend where to ring this device: the hex token, the bundle id (the APNs
    /// topic is `<bundle id>.voip`), the APNs environment, the target it rings, and what
    /// the engine understands. Failures are only logged here; a real host retries.
    static func register(voipToken: Data) async throws {
        var request = URLRequest(url: baseURL.appending(path: "voip-token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Registration(
            token: voipToken.map { String(format: "%02x", $0) }.joined(),
            bundleID: Bundle.main.bundleIdentifier ?? "",
            apnsEnvironment: apnsEnvironment,
            targets: [Registration.Target(id: ExampleAgent.id.uuidString.lowercased(), displayName: ExampleAgent.displayName)],
            pushFeatures: CallEngine.supportedPushFeatures.sorted(),
            callSignals: callSignals
        ))
        let (_, response) = try await URLSession.shared.data(for: request)
        try requireSuccess(response)
    }

    /// Tells the backend to stop ringing `voipToken`: PushKit invalidated it.
    static func unregister(voipToken: Data) async throws {
        var request = URLRequest(url: baseURL.appending(path: "voip-token")
            .appending(path: voipToken.map { String(format: "%02x", $0) }.joined()))
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        try requireSuccess(response)
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
    }
}
