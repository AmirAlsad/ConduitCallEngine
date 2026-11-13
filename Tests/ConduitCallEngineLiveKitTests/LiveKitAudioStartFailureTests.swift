//
//  LiveKitAudioStartFailureTests.swift
//  ConduitCallEngineLiveKitTests
//
//  A start of LiveKit's audio engine that LiveKit refuses, under the real engine:
//  the transport reports it through `audioStartFailure()`, the engine attaches
//  again, the transport takes the engine down before making it available again,
//  and the agent hears of the call only once the engine runs. On a device LiveKit
//  refused it with -4010 after a phone call.
//

import Foundation
import Testing
import ConduitCallEngine
import ConduitCallEngineTesting
@testable import ConduitCallEngineLiveKit

@MainActor
struct LiveKitAudioStartFailureTests {

    /// A connected, activated call and its call id.
    private func connectedCall() async throws -> (LiveKitEngineRig, UUID) {
        let rig = LiveKitEngineRig()
        await rig.engine.placeCall(rig.target)
        await waitUntil { rig.engine.state.isConnected }
        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()
        rig.sleeper.wakeAll() // the first connect's bound, stale once connected
        await drain()
        let id = try #require(rig.system.startedCallIDs.first)
        return (rig, id)
    }

    /// The first attach of a call is refused: `call-connected` waits for the
    /// attach again, which starts the engine.
    @Test(.timeLimit(.minutes(1)))
    func aRefusedFirstStartIsAttachedAgainBeforeTheAgentIsToldTheUserIsOnTheLine() async throws {
        let rig = LiveKitEngineRig()
        await rig.engine.placeCall(rig.target)
        await waitUntil { rig.engine.state.isConnected }
        let engine = try #require(rig.audioEngines.last)
        let room = try #require(rig.room)
        engine.startsToFail = 1
        let start = engine.availabilityHistory.count

        await rig.system.activateAudioSession()
        await waitUntil { rig.sleeper.requested.last == .milliseconds(500) }

        #expect(Array(engine.availabilityHistory[start...]) == [true])
        #expect(!room.published.contains("call-connected"))

        rig.sleeper.wakeAll()
        await rig.system.awaitPendingWork()

        #expect(Array(engine.availabilityHistory[start...]) == [true, false, true])
        #expect(engine.isRunning)
        #expect(room.published.last == "call-connected")
    }

    /// The engine's start refused at the resume's attach: the engine attaches again,
    /// LiveKit's engine is taken down and made available again, and `call-resumed`
    /// waits until it runs.
    @Test(.timeLimit(.minutes(1)))
    func aRefusedStartIsAttachedAgainBeforeTheAgentHearsOfTheResume() async throws {
        let (rig, id) = try await connectedCall()
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

    /// The engine attaches again a bounded number of times, then tells the agent.
    @Test(.timeLimit(.minutes(1)))
    func theAgentIsToldOnceTheAttemptsAreSpent() async throws {
        let (rig, id) = try await connectedCall()
        await rig.system.setHeldFromSystem(id, onHold: true)
        rig.system.deactivateAudioSession()
        await rig.system.awaitPendingWork()
        await rig.system.setHeldFromSystem(id, onHold: false)
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

        // The first attach, then a take-down and a start for each retry.
        #expect(engine.availabilityHistory.count - start == 1 + 2 * CallEngine.audioStartRetryDelays.count)
        #expect(!engine.isRunning)
        #expect(room.published.last == "call-resumed")
    }

    /// A hold while the engine waits to attach again ends the attempts.
    @Test(.timeLimit(.minutes(1)))
    func aHoldDuringTheWaitStopsTheAttempts() async throws {
        let (rig, id) = try await connectedCall()
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
}
