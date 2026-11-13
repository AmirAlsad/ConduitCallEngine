//
//  LiveKitInterruptionRecoveryTests.swift
//  ConduitCallEngineLiveKitTests
//
//  The experimental recoveries after a phone call (`LiveKitInterruptionRecovery`),
//  under the real engine: how each restarts LiveKit's audio engine after the attach
//  that follows the interruption, and before `call-resumed`. Whether any of them
//  brings the audio back is for a device to show.
//

import Foundation
import Testing
import ConduitCallEngine
import ConduitCallEngineTesting
@_spi(InterruptionRecoveryExperiment) @testable import ConduitCallEngineLiveKit

@MainActor
struct LiveKitInterruptionRecoveryTests {

    /// A connected, activated call with `recovery` chosen, and its call id.
    private func connectedCall(_ recovery: LiveKitInterruptionRecovery) async throws -> (LiveKitEngineRig, UUID) {
        let rig = LiveKitEngineRig()
        rig.interruptionRecovery = recovery
        await rig.engine.placeCall(rig.target)
        await waitUntil { rig.engine.state.isConnected }
        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()
        rig.sleeper.wakeAll() // the first connect's bound, stale once connected
        await drain()
        let id = try #require(rig.system.startedCallIDs.first)
        return (rig, id)
    }

    /// iOS holds the call for a phone call, the interruption begins and CallKit
    /// deactivates the session; the call is resumed but not yet activated again.
    private func heldThroughAPhoneCall(_ rig: LiveKitEngineRig, _ id: UUID) async {
        await rig.system.setHeldFromSystem(id, onHold: true)
        rig.system.beginAudioInterruption()
        rig.system.deactivateAudioSession()
        await rig.system.awaitPendingWork()
        await rig.system.setHeldFromSystem(id, onHold: false)
        await rig.system.awaitPendingWork()
    }

    @Test(.timeLimit(.minutes(1)))
    func offOnlyMakesTheEngineAvailableAtTheAttach() async throws {
        let (rig, id) = try await connectedCall(.off)
        await heldThroughAPhoneCall(rig, id)
        let engine = try #require(rig.audioEngines.last)
        let start = engine.availabilityHistory.count

        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()

        #expect(Array(engine.availabilityHistory[start...]) == [true])
        #expect(try #require(rig.room).published.last == "call-resumed")
    }

    @Test(.timeLimit(.minutes(1)))
    func restartEngineMakesItUnavailableAndAvailableAgainAtOnce() async throws {
        let (rig, id) = try await connectedCall(.restartEngine)
        await heldThroughAPhoneCall(rig, id)
        let engine = try #require(rig.audioEngines.last)
        let start = engine.availabilityHistory.count

        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()

        #expect(Array(engine.availabilityHistory[start...]) == [true, false, true])
        #expect(engine.isRunning)
        #expect(rig.transportPauses.filter { $0 < .seconds(1) }.isEmpty)
        #expect(try #require(rig.room).published.last == "call-resumed")
    }

    /// The attach after the phone call is refused, as on the device; L-B's second
    /// restart starts the engine.
    @Test(.timeLimit(.minutes(1)))
    func restartUntilRunningStopsOnceTheEngineRuns() async throws {
        let (rig, id) = try await connectedCall(.restartEngineUntilRunning)
        await heldThroughAPhoneCall(rig, id)
        let engine = try #require(rig.audioEngines.last)
        engine.startsToFail = 2 // the attach's start and the first restart's
        let start = engine.availabilityHistory.count

        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()

        #expect(Array(engine.availabilityHistory[start...]) == [true, false, true, false, true])
        #expect(engine.isRunning)
        #expect(Array(rig.transportPauses.prefix(2)) == [.milliseconds(500), .milliseconds(500)])
        #expect(try #require(rig.room).published.last == "call-resumed")
    }

    /// L-B gives up after three restarts; the engine then attaches again three
    /// times, and tells the agent once those are spent.
    @Test(.timeLimit(.minutes(1)))
    func restartUntilRunningGivesUpAfterThreeRestarts() async throws {
        let (rig, id) = try await connectedCall(.restartEngineUntilRunning)
        await heldThroughAPhoneCall(rig, id)
        let engine = try #require(rig.audioEngines.last)
        let room = try #require(rig.room)
        engine.startsToFail = 100
        let start = engine.availabilityHistory.count

        await rig.system.activateAudioSession()
        for _ in CallEngine.audioStartRetryDelays {
            await waitUntil { rig.sleeper.pendingCount == 1 }
            #expect(room.published.last != "call-resumed")
            rig.sleeper.wakeAll()
        }
        await rig.system.awaitPendingWork()

        #expect(engine.availabilityHistory.count - start == 7 + 2 * CallEngine.audioStartRetryDelays.count)
        #expect(!engine.isRunning)
        #expect(room.published.last == "call-resumed")
    }

    @Test(.timeLimit(.minutes(1)))
    func notifyActivationTellsWebRTCThenRestartsTheEngine() async throws {
        let (rig, id) = try await connectedCall(.notifyActivationThenRestart)
        await heldThroughAPhoneCall(rig, id)
        let engine = try #require(rig.audioEngines.last)
        let start = engine.calls.count

        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()

        #expect(Array(engine.calls[start...]) == ["available", "external activation", "unavailable", "available"])
        #expect(engine.isRunning)
        #expect(try #require(rig.room).published.last == "call-resumed")
    }

    // MARK: - A start LiveKit refuses (not an experiment)

    /// The engine's start refused at the resume's attach: the engine attaches again,
    /// LiveKit's engine is taken down and made available again, and `call-resumed`
    /// waits until it runs.
    @Test(.timeLimit(.minutes(1)))
    func aRefusedStartIsAttachedAgainBeforeTheAgentHearsOfTheResume() async throws {
        let (rig, id) = try await connectedCall(.off)
        await rig.system.setHeldFromSystem(id, onHold: true)
        rig.system.deactivateAudioSession()
        await rig.system.awaitPendingWork()
        await rig.system.setHeldFromSystem(id, onHold: false)
        let engine = try #require(rig.audioEngines.last)
        let room = try #require(rig.room)
        engine.startsToFail = 1
        let start = engine.availabilityHistory.count

        await rig.system.activateAudioSession()
        await waitUntil { rig.sleeper.pendingCount == 1 }

        #expect(Array(engine.availabilityHistory[start...]) == [true])
        #expect(rig.sleeper.requested.last == .milliseconds(500))
        #expect(room.published.last == "call-held")

        rig.sleeper.wakeAll()
        await rig.system.awaitPendingWork()

        #expect(Array(engine.availabilityHistory[start...]) == [true, false, true])
        #expect(engine.isRunning)
        #expect(room.published.last == "call-resumed")
    }

    /// A hold while the engine waits to attach again ends the attempts.
    @Test(.timeLimit(.minutes(1)))
    func aHoldDuringTheWaitStopsTheAttempts() async throws {
        let (rig, id) = try await connectedCall(.off)
        await rig.system.setHeldFromSystem(id, onHold: true)
        rig.system.deactivateAudioSession()
        await rig.system.awaitPendingWork()
        await rig.system.setHeldFromSystem(id, onHold: false)
        let engine = try #require(rig.audioEngines.last)
        engine.startsToFail = 100
        await rig.system.activateAudioSession()
        await waitUntil { rig.sleeper.pendingCount == 1 }
        let start = engine.availabilityHistory.count

        let holding = Task { _ = await rig.system.setHeldFromSystem(id, onHold: true) }
        await drain()
        rig.sleeper.wakeAll()
        await holding.value
        await rig.system.awaitPendingWork()

        #expect(Array(engine.availabilityHistory[start...]) == [false]) // the hold's detach only
        #expect(rig.sleeper.pendingCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHoldWithNoInterruptionRestartsNothing() async throws {
        let (rig, id) = try await connectedCall(.restartEngine)
        await rig.system.setHeldFromSystem(id, onHold: true)
        rig.system.deactivateAudioSession()
        await rig.system.awaitPendingWork()
        await rig.system.setHeldFromSystem(id, onHold: false)
        let engine = try #require(rig.audioEngines.last)
        let start = engine.availabilityHistory.count

        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()

        #expect(Array(engine.availabilityHistory[start...]) == [true])
    }
}
