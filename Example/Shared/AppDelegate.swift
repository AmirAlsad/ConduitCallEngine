import ConduitCallEngine
import ConduitCallEngineTesting
import OSLog
import UIKit

/// Owns the engine and is its delegate. `CallEngine.delegate` is weak, so the host
/// must keep the delegate alive itself; the app delegate lives for the whole process.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, CallEngineDelegate {
    let engine: CallEngine
    private let log = Logger(subsystem: "com.example.ConduitCallEngineExample", category: "calls")

    override init() {
        #if targetEnvironment(simulator)
        // CallKit and PushKit do not run in the simulator; the Testing product provides a stand-in.
        engine = CallEngine.simulated(system: SimulatedCallSystem())
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
        return true
    }

    // MARK: - CallEngineDelegate

    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? {
        ExampleAgent.target
    }

    func callEngine(_ engine: CallEngine, didFinish record: CallRecord) {
        log.info("Call finished: \(String(describing: record.outcome)), \(record.duration)s")
    }

    func callEngine(_ engine: CallEngine, didUpdateVoIPPushToken token: Data) {
        Task { await ExampleBackend.register(voipToken: token) }
    }
}
