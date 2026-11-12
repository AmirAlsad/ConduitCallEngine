//
//  DailyRouteUnderEngineTests.swift
//  ConduitCallEngineDailyTests
//
//  The route a Daily call asks Daily to prefer, with the real engine driving the
//  adapter (`DailyEngineRig`): CallKit's activation before and after the join, the
//  speaker default and the user's pick, a reconnect, a hold, and a ring's join.
//  The rig's session reports the earpiece, as a CallKit call with nothing connected.
//

import Foundation
import Testing
import ConduitCallEngine
import ConduitCallEngineTesting
@testable import ConduitCallEngineDaily

@MainActor
struct DailyRouteUnderEngineTests {
    private func earpieceRig(defaultsToSpeaker: Bool = false, minimumOutgoingConnecting: Duration = .zero) -> DailyEngineRig {
        let rig = DailyEngineRig(minimumOutgoingConnecting: minimumOutgoingConnecting, defaultsToSpeaker: defaultsToSpeaker)
        rig.outputPort = .builtInReceiver
        rig.mics = ["earpiece", "speakerphone"]
        return rig
    }

    private func routeRequests(_ pipecat: FakePipecatTransport) -> [String] {
        pipecat.calls.filter { $0.hasPrefix("prefer") }
    }

    private func connect(_ rig: DailyEngineRig, _ pipecat: FakePipecatTransport) async {
        pipecat.botJoins()
        await waitUntil { rig.engine.state.isConnected }
        await rig.system.awaitPendingWork()
    }

    /// The order of the observed call: CallKit activates the earpiece while the
    /// credentials are still on their way. Daily gets the earpiece before the join
    /// and the join names it, so the connect keeps the earpiece; the engine, with its
    /// speaker default off, changes nothing when the call connects.
    @Test(.timeLimit(.minutes(1)))
    func aCallActivatedBeforeItJoinsJoinsOnTheEarpiece() async throws {
        let rig = earpieceRig()
        rig.holdsCredentials = true
        let placing = Task { await rig.engine.placeCall(rig.target) }
        await waitUntil { rig.isHoldingCredentials }
        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()
        let pipecat = try #require(rig.pipecat)
        #expect(pipecat.calls == ["prefer earpiece"])

        rig.releaseCredentials()
        await placing.value
        await waitUntil { pipecat.calls.count == 2 }
        await connect(rig, pipecat)

        #expect(Array(pipecat.calls.prefix(2)) == ["prefer earpiece", "connect preferring earpiece"])
        #expect(routeRequests(pipecat) == ["prefer earpiece"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallJoinedBeforeItsActivationGetsTheRouteAtTheActivation() async throws {
        let rig = earpieceRig()
        _ = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)
        await rig.system.awaitPendingWork()
        #expect(pipecat.calls == ["connect", "prefer earpiece"])

        await connect(rig, pipecat)

        #expect(routeRequests(pipecat) == ["prefer earpiece"])
    }

    /// With the speaker default on, the engine asks for the speaker once the call
    /// connects; that request wins over the earpiece kept until then.
    @Test(.timeLimit(.minutes(1)))
    func theSpeakerDefaultWinsWhenTheCallConnects() async throws {
        let rig = earpieceRig(defaultsToSpeaker: true)
        _ = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)

        await connect(rig, pipecat)

        #expect(routeRequests(pipecat) == ["prefer earpiece", "prefer speaker"])
    }

    @Test(.timeLimit(.minutes(1)))
    func theUsersPickSurvivesAReconnect() async throws {
        let rig = earpieceRig()
        _ = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)
        await connect(rig, pipecat)
        rig.sleeper.wakeAll() // the first connect's bound, stale once connected
        await drain()
        await rig.engine.selectAudioDevice("speakerphone")
        #expect(pipecat.calls.last == "prefer speaker")

        pipecat.setState(state: .disconnected) // Daily left the call: a drop
        await waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.wakeAll() // attempt 1's backoff
        await waitUntil { rig.requests.count == 2 && pipecat.calls.last?.hasPrefix("connect") == true }

        #expect(pipecat.calls.last == "connect preferring speakerphone")
        #expect(routeRequests(pipecat) == ["prefer earpiece", "prefer speaker"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aHoldAndResumeChangeNoRoute() async throws {
        let rig = earpieceRig()
        let id = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)
        await connect(rig, pipecat)
        rig.outputPort = .builtInSpeaker

        await rig.system.setHeldFromSystem(id, onHold: true)
        await rig.system.setHeldFromSystem(id, onHold: false)
        await rig.system.awaitPendingWork()

        #expect(pipecat.calls.contains("agent audio unsubscribed"))
        #expect(routeRequests(pipecat) == ["prefer earpiece"])
    }

    /// A ring's join leaves audio alone until the answer: the route goes to Daily at
    /// CallKit's activation, before the agent is subscribed and told the user is on
    /// the line.
    @Test(.timeLimit(.minutes(1)))
    func aRingsJoinGetsTheRouteOnlyAtTheAnswersActivation() async throws {
        let rig = earpieceRig(minimumOutgoingConnecting: .seconds(3))
        rig.ringPreparation = .media
        rig.refreshTarget()
        _ = rig.ring()
        await waitUntil { rig.pipecat?.calls.contains("connect") == true }
        let pipecat = try #require(rig.pipecat)
        pipecat.botJoins()
        await waitUntil { rig.engine.ringPreparationPhase == .ready }
        #expect(pipecat.calls == ["agent audio unsubscribed", "connect"])

        await rig.system.answerIncomingCall()
        await rig.system.activateAudioSession()
        await waitUntil { pipecat.calls.contains("send client-message") }
        await rig.system.awaitPendingWork()

        #expect(pipecat.calls == [
            "agent audio unsubscribed", "connect", "prefer earpiece", "agent audio subscribed", "send client-message",
        ])
    }
}
