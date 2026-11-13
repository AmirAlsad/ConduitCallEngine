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
    ///
    /// Its clock and timers run on the machine's time by default, which a simulator
    /// build needs. In a unit test use `simulatedForTesting(configuration:system:now:)`
    /// instead: on a slow or stalled machine real time lets a timer run out by itself.
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

    /// A simulated engine for unit tests, on which nothing depends on the machine's
    /// time: its clock is `now` (`SimulatedCallSystem.testEpoch`, standing still, by
    /// default) and its timers wait on `SimulatedCallSystem.sleepUntilCancelled(_:)`,
    /// so none runs out by itself however slow the machine is. End the one you want
    /// with `SimulatedCallSystem.fireTimer(_:)`, then `awaitPendingWork()`; move time
    /// for `CallRecord.duration` and the outgoing minimum connecting time by passing
    /// a clock of your own as `now`. Otherwise the same as
    /// `simulated(configuration:system:now:sleep:)`.
    public static func simulatedForTesting(
        configuration: CallEngineConfiguration = .init(),
        system: SimulatedCallSystem? = nil,
        now: @escaping @MainActor () -> Date = { SimulatedCallSystem.testEpoch }
    ) -> CallEngine {
        simulated(configuration: configuration, system: system, now: now, sleep: SimulatedCallSystem.sleepUntilCancelled)
    }
}
