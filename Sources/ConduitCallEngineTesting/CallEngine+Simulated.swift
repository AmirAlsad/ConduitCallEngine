//
//  CallEngine+Simulated.swift
//  ConduitCallEngine
//
//  A `CallEngine` over a `SimulatedCallSystem`, for the simulator (CallKit and
//  PushKit don't run there) and for host tests.
//

import Foundation
import ConduitCallEngine

extension CallEngine {
    /// An engine whose CallKit, PushKit, interruption, and receipt services are
    /// `system`'s stand-ins. Keep `system` to drive the engine and read what it
    /// reported; nil gives the engine a system of its own, for a host that only
    /// needs a working engine.
    public static func simulated(
        configuration: CallEngineConfiguration = .init(),
        system: SimulatedCallSystem? = nil,
        now: @escaping @MainActor () -> Date = { .now },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> CallEngine {
        let system = system ?? SimulatedCallSystem()
        let engine = CallEngine(
            configuration: configuration,
            callProvider: system.provider,
            interruptionObserver: system.interruptionObserver,
            ringStatusReporter: system.ringStatusReporter,
            pushRegistry: system.pushRegistry,
            now: now,
            sleep: sleep,
            isSimulated: true
        )
        system.engine = engine
        return engine
    }
}
