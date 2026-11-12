import ConduitCallEngine
import Foundation

/// PLACEHOLDER. This is where your own backend goes: the engine only needs a room URL and a
/// token, and how you obtain them (session, API key, your own auth) is up to the host.
enum ExampleBackend {
    /// Replace with your backend.
    static var baseURL = URL(string: "https://your-agent-backend.example.com")!

    private struct Credentials: Decodable {
        let url: URL
        let token: String?
    }

    private struct Registration: Encodable {
        let token: String
        let pushFeatures: [String]
        let callSignals: [String]

        enum CodingKeys: String, CodingKey {
            case token
            case pushFeatures = "push_features"
            case callSignals = "call_signals"
        }
    }

    /// The call-control signals this app's calls carry, sent with every request so the
    /// backend's agent waits for `call-connected` before it speaks (Integration Guide,
    /// "When your agent should start speaking").
    static let callSignals = CallSignal.allCases.map(\.rawValue)

    /// POSTs `{ "call_signals": [...] }` to `<baseURL>/connect` and decodes
    /// `{ "url": ..., "token": ... }`.
    static func fetchConnection() async throws -> CallConnection {
        var request = URLRequest(url: baseURL.appending(path: "connect"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["call_signals": callSignals])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let credentials = try JSONDecoder().decode(Credentials.self, from: data)
        return CallConnection(url: credentials.url, token: credentials.token)
    }

    /// Tells the backend where to send VoIP pushes for this device. Failures are ignored here;
    /// a real host would retry, since PushKit will not issue the token again.
    static func register(voipToken: Data) async {
        var request = URLRequest(url: baseURL.appending(path: "voip-token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let hex = voipToken.map { String(format: "%02x", $0) }.joined()
        request.httpBody = try? JSONEncoder().encode(Registration(
            token: hex,
            pushFeatures: CallEngine.supportedPushFeatures.sorted(),
            callSignals: callSignals
        ))
        _ = try? await URLSession.shared.data(for: request)
    }
}
