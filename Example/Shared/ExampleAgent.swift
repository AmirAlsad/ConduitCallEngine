import ConduitCallEngine
import ConduitCallEngineTesting
import Foundation

/// The app's one built-in agent.
enum ExampleAgent {
    /// Stable across launches. The backend's VoIP push carries this as `target_id`.
    static let id = UUID(uuidString: "6F1E0A52-3B7C-4D8E-9A41-2C5D7E9B0A13")!
    static let displayName = "Example Agent"

    /// The agent as a call target. `inline` is the push's own credentials
    /// (`IncomingCall.connection`), used when a ring carried them; otherwise the
    /// target asks the backend.
    static func target(inline: CallConnection? = nil) -> CallTarget {
        CallTarget(
            id: id,
            displayName: displayName,
            // The engine calls this before `connect`, so a CallKit audio activation that
            // lands while credentials are still loading finds a transport to attach to.
            // It must return a new transport every time.
            makeTransport: {
                #if targetEnvironment(simulator)
                return FakeTransport(reportsConnectedAfter: .seconds(1))
                #else
                return makeTransport()
                #endif
            },
            // Runs for the first connect and again before every reconnect attempt; the
            // request says which, and carries an incoming call's id. Inline credentials
            // are reused for reconnects, so they must stay valid for the whole call.
            connect: { request in
                #if targetEnvironment(simulator)
                return CallConnection(url: URL(string: "https://example.invalid/room")!, token: nil)
                #else
                if let inline { return inline }
                return try await ExampleBackend.fetchConnection(for: request)
                #endif
            }
        )
    }
}
