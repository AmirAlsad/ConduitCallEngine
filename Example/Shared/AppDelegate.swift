import ConduitCallEngine
import ConduitCallEngineTesting
import OSLog
import UIKit

/// Owns the engine and is its delegate. `CallEngine.delegate` is weak, so the host
/// must keep the delegate alive itself; the app delegate lives for the whole process.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, CallEngineDelegate {
    let engine: CallEngine
    #if targetEnvironment(simulator)
    /// Stands in for CallKit and PushKit, which do not run in the simulator. Kept so the
    /// app can do what CallKit would: activate the call's audio.
    private let system = SimulatedCallSystem()
    #endif
    private let log = Logger(subsystem: "com.example.ConduitCallEngineExample", category: "calls")
    /// The token last sent to the backend, to withdraw when PushKit invalidates it
    /// (`voipPushToken` is nil by then). A real host persists it.
    private var registeredToken: Data?

    override init() {
        #if targetEnvironment(simulator)
        engine = CallEngine.simulated(system: system)
        #else
        engine = CallEngine(configuration: CallEngineConfiguration())
        #endif
        super.init()
        engine.delegate = self
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must happen at launch, not when a screen appears: a VoIP push can wake the app
        // in the background, and iOS terminates an app that receives one without reporting a call.
        engine.startPushRegistration()
        // PushKit calls back only when it issues or changes the token; send the one it has.
        if let token = engine.voipPushToken { register(token) }
        return true
    }

    /// Places a call to the agent. In the simulator nothing activates the call's audio,
    /// so this does what CallKit would; without it the call never attaches its
    /// transport, opens the mic or delivers `.moment(.connected)`.
    func placeCall() async {
        await engine.placeCall(ExampleAgent.target())
        #if targetEnvironment(simulator)
        await system.activateAudioSession()
        #endif
    }

    private func register(_ token: Data) {
        registeredToken = token
        Task {
            do { try await ExampleBackend.register(voipToken: token) }
            catch { log.error("VoIP token registration failed: \(error)") }
        }
    }

    // MARK: - CallEngineDelegate

    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? {
        // A ring for anything but this app's agent is ended as an unknown target.
        guard call.targetID == ExampleAgent.id else { return nil }
        return ExampleAgent.target(inline: call.connection)
    }

    func callEngine(_ engine: CallEngine, didFinish record: CallRecord) {
        log.info("Call finished: \(String(describing: record.outcome)), \(record.duration)s")
    }

    func callEngine(_ engine: CallEngine, didUpdateVoIPPushToken token: Data) {
        register(token)
    }

    func callEngineDidInvalidateVoIPPushToken(_ engine: CallEngine) {
        guard let token = registeredToken else { return }
        registeredToken = nil
        Task {
            do { try await ExampleBackend.unregister(voipToken: token) }
            catch { log.error("VoIP token unregistration failed: \(error)") }
        }
    }
}
