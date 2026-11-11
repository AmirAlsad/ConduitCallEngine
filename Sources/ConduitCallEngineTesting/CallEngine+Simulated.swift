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
    public static func simulated(
        configuration: CallEngineConfiguration = .init(),
        system: SimulatedCallSystem,
        now: @escaping () -> Date = { .now },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> CallEngine {
        let engine = CallEngine(
            configuration: configuration,
            callProvider: system.provider,
            interruptionObserver: system.interruptionObserver,
            ringStatusReporter: system.ringStatusReporter,
            pushRegistry: system.pushRegistry,
            now: now,
            sleep: sleep
        )
        system.engine = engine
        return engine
    }

    /// Show a connected call on the in-call surface without CallKit, a transport,
    /// or any delegate callback — for screenshots.
    public func presentSimulatedConnectedCall(
        _ call: ActiveCall,
        secondsElapsed: TimeInterval = 154,
        botSpeaking: Bool = true
    ) {
        presentConnectedProjection(call, secondsElapsed: secondsElapsed, botSpeaking: botSpeaking)
    }
}
