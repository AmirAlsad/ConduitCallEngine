//
//  DailyUnderEngineTests.swift
//  ConduitCallEngineDailyTests
//
//  The real Daily adapter under the real engine (`DailyEngineRig`): the situations
//  in which the engine's expectations of a transport and the adapter's gates meet.
//

import Foundation
import Testing
import ConduitCallEngine
import ConduitCallEngineTesting
@testable import ConduitCallEngineDaily

@MainActor
struct DailyUnderEngineTests {

    // MARK: - Hold before the agent is ready

    /// A hold unsubscribes the agent's audio, and Pipecat sends client-ready only for
    /// playable audio, so an agent that arrives while the call is held cannot become
    /// ready until the resume. The join bound must not fail the call meanwhile.
    @Test(.timeLimit(.minutes(1)))
    func aCallHeldBeforeItsAgentIsReadyConnectsAfterTheResume() async throws {
        let rig = DailyEngineRig()
        let id = try await rig.placeActivatedCall()
        #expect(rig.engine.state == .connecting)
        #expect(rig.sleeper.pendingCount == 1) // the join bound

        await rig.system.setHeldFromSystem(id, onHold: true)
        await drain()
        let pipecat = try #require(rig.pipecat)
        #expect(pipecat.remoteAudio == .unsubscribed)
        pipecat.botJoins()
        await drain()
        #expect(pipecat.sentClientReady == false)

        rig.sleeper.wakeAll() // the bound that was running when the call was held
        await drain()
        #expect(rig.engine.state == .connecting)
        #expect(rig.host.records.isEmpty)

        await rig.system.setHeldFromSystem(id, onHold: false)
        await waitUntil { rig.engine.state.isConnected }

        #expect(rig.engine.state.isConnected)
        #expect(pipecat.remoteAudio == .subscribed)
        #expect(pipecat.sentClientReady)
        #expect(rig.requests.count == 1)
    }

    /// After the resume the bound applies again, from the resume.
    @Test(.timeLimit(.minutes(1)))
    func aHeldCallWhoseAgentNeverComesFailsOnceResumed() async throws {
        let rig = DailyEngineRig()
        let id = try await rig.placeActivatedCall()
        await rig.system.setHeldFromSystem(id, onHold: true)
        rig.sleeper.wakeAll()
        await drain()

        await rig.system.setHeldFromSystem(id, onHold: false)
        await waitUntil { rig.sleeper.pendingCount == 1 }
        #expect(rig.sleeper.requested == [.seconds(30), .seconds(30)])
        rig.sleeper.wakeAll()
        await waitUntil { rig.engine.state.isTerminal }

        #expect(rig.engine.state == .failed(.agentUnreachable))
    }
}
