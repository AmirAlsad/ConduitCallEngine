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

    /// POSTs to `<baseURL>/connect` and decodes `{ "url": ..., "token": ... }`.
    static func fetchConnection() async throws -> CallConnection {
        var request = URLRequest(url: baseURL.appending(path: "connect"))
        request.httpMethod = "POST"
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
        request.httpBody = try? JSONEncoder().encode(["token": hex])
        _ = try? await URLSession.shared.data(for: request)
    }
}
