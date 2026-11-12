import ConduitCallEngine
import ConduitCallEngineTesting
import Foundation

/// The app's one built-in agent.
enum ExampleAgent {
    /// Stable across launches. The backend's VoIP push carries this as `target_id`.
    static let id = UUID(uuidString: "6F1E0A52-3B7C-4D8E-9A41-2C5D7E9B0A13")!

    static let target = CallTarget(
        id: id,
        displayName: "Example Agent",
        handle: nil,
        // The engine calls this before `connect`, so a CallKit audio activation that
        // lands while credentials are still loading finds a transport to attach to.
        makeTransport: {
            #if targetEnvironment(simulator)
            let transport = FakeTransport()
            Task {
                try? await Task.sleep(for: .seconds(1))
                transport.emit(.connected)
            }
            return transport
            #else
            return makeTransport()
            #endif
        },
        // Runs for the first connect and again for every reconnect attempt; the
        // request says which, and carries an incoming call's id.
        connect: { _ in
            #if targetEnvironment(simulator)
            return CallConnection(url: URL(string: "https://example.invalid/room")!, token: nil)
            #else
            return try await ExampleBackend.fetchConnection()
            #endif
        }
    )
}
