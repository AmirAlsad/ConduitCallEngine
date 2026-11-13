//
//  DailyRouteUnderEngineTests.swift
//  ConduitCallEngineDailyTests
//
//  The route a Daily call asks Daily to prefer, with the real engine driving the
//  adapter (`DailyEngineRig`): CallKit's activation before and after the join, the
//  speaker default and the user's pick, a reconnect, a hold, and a ring's join.
//  The rig's session reports the earpiece, as a CallKit call with nothing connected,
//  until a test has Daily's join move it to the loudspeaker, as Daily's default does.
//

import Foundation
import Testing
import ConduitCallEngine
import ConduitCallEngineTesting
@testable import ConduitCallEngineDaily

@MainActor
struct DailyRouteUnderEngineTests {
    private func earpieceRig(
        supportsHolding: Bool = false,
        defaultsToSpeaker: Bool = false,
        minimumOutgoingConnecting: Duration = .zero
    ) -> DailyEngineRig {
        let rig = DailyEngineRig(
            supportsHolding: supportsHolding,
            minimumOutgoingConnecting: minimumOutgoingConnecting,
            defaultsToSpeaker: defaultsToSpeaker
        )
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

    /// Credentials before the activation: the join starts on a provisional
    /// earpiece, and the activation, reading the loudspeaker Daily's join left,
    /// keeps the earpiece.
    @Test(.timeLimit(.minutes(1)))
    func anOutgoingCallJoinedBeforeItsActivationStartsOnTheEarpiece() async throws {
        let rig = earpieceRig()
        rig.dailyDropsPreferenceAtJoin = true
        await rig.engine.placeCall(rig.target)
        let pipecat = try #require(rig.pipecat)
        await waitUntil { pipecat.calls.count == 3 }
        #expect(pipecat.calls == ["prefer earpiece for the join", "connect preferring earpiece", "prefer earpiece"])
        rig.outputPort = .builtInSpeaker

        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()
        await connect(rig, pipecat)

        #expect(routeRequests(pipecat) == ["prefer earpiece for the join", "prefer earpiece"])
    }

    /// With the speaker default on, the engine asks for the speaker once the call
    /// connects; that request wins over the earpiece kept until then.
    @Test(.timeLimit(.minutes(1)))
    func theSpeakerDefaultWinsWhenTheCallConnects() async throws {
        let rig = earpieceRig(defaultsToSpeaker: true)
        _ = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)

        await connect(rig, pipecat)

        #expect(routeRequests(pipecat) == ["prefer earpiece for the join", "prefer speaker"])
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
        #expect(routeRequests(pipecat) == ["prefer earpiece for the join", "prefer speaker"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aHoldAndResumeChangeNoRoute() async throws {
        let rig = earpieceRig(supportsHolding: true)
        let id = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)
        await connect(rig, pipecat)
        rig.outputPort = .builtInSpeaker

        await rig.system.setHeldFromSystem(id, onHold: true)
        await rig.system.setHeldFromSystem(id, onHold: false)
        await rig.system.awaitPendingWork()

        #expect(pipecat.calls.contains("agent audio unsubscribed"))
        #expect(routeRequests(pipecat) == ["prefer earpiece for the join"])
    }

    // MARK: - A ring's join

    /// Rings with `preconnect: media` and lets the bot join during the ring.
    private func ringJoined(_ rig: DailyEngineRig) async throws -> FakePipecatTransport {
        rig.ringPreparation = .media
        rig.refreshTarget()
        _ = rig.ring()
        await waitUntil { rig.pipecat?.calls.contains { $0.hasPrefix("connect") } == true }
        let pipecat = try #require(rig.pipecat)
        pipecat.botJoins()
        await waitUntil { rig.engine.ringPreparationPhase == .ready }
        return pipecat
    }

    private func answer(_ rig: DailyEngineRig, _ pipecat: FakePipecatTransport) async {
        await rig.system.answerIncomingCall()
        await rig.system.activateAudioSession()
        await waitUntil { pipecat.calls.contains("send client-message") }
        await rig.system.awaitPendingWork()
    }

    /// The device case: a ring joined before the answer with nothing connected.
    /// Daily gets the earpiece before the join, and nothing else during the ring;
    /// Daily's join drops it and leaves the session on the loudspeaker, so the
    /// answer's activation asks for the earpiece again. The loudspeaker is never
    /// asked for.
    @Test(.timeLimit(.minutes(1)))
    func aRingAnsweredWithNothingConnectedEndsOnTheEarpiece() async throws {
        let rig = earpieceRig(minimumOutgoingConnecting: .seconds(3))
        rig.dailyDropsPreferenceAtJoin = true
        let pipecat = try await ringJoined(rig)
        #expect(pipecat.calls == ["agent audio unsubscribed", "prefer earpiece for the join", "connect preferring earpiece"])
        rig.outputPort = .builtInSpeaker

        await answer(rig, pipecat)

        #expect(pipecat.calls == [
            "agent audio unsubscribed", "prefer earpiece for the join", "connect preferring earpiece",
            "prefer earpiece", "agent audio subscribed", "send client-message",
        ])
        #expect(!pipecat.calls.contains { $0.contains("speaker") })
        #expect(rig.controls.last?.preferredAudioRoute == .earpiece)
    }

    /// Daily keeps what it was given before the join: the answer asks nothing more.
    @Test(.timeLimit(.minutes(1)))
    func aRingWhoseJoinKeptTheEarpieceAsksNothingAtTheAnswer() async throws {
        let rig = earpieceRig(minimumOutgoingConnecting: .seconds(3))
        let pipecat = try await ringJoined(rig)

        await answer(rig, pipecat)

        #expect(pipecat.calls == [
            "agent audio unsubscribed", "prefer earpiece for the join", "connect preferring earpiece",
            "agent audio subscribed", "send client-message",
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func aRingJoinedWithABluetoothHeadsetConnectedStaysOnIt() async throws {
        let rig = earpieceRig(minimumOutgoingConnecting: .seconds(3))
        rig.mics = ["earpiece", "speakerphone", "bluetooth"]
        rig.availableInputs = [.builtInMic, .bluetoothHFP]
        let pipecat = try await ringJoined(rig)
        #expect(pipecat.calls == ["agent audio unsubscribed", "prefer bluetooth for the join", "connect preferring bluetooth"])
        rig.outputPort = .bluetoothHFP

        await answer(rig, pipecat)

        #expect(routeRequests(pipecat) == ["prefer bluetooth for the join"])
    }

    /// The host asked for the loudspeaker: it wins, from the answer's activation.
    @Test(.timeLimit(.minutes(1)))
    func aRingWithTheSpeakerDefaultMovesToTheSpeakerOnlyAfterTheAnswer() async throws {
        let rig = earpieceRig(defaultsToSpeaker: true, minimumOutgoingConnecting: .seconds(3))
        let pipecat = try await ringJoined(rig)
        await rig.system.awaitPendingWork()
        #expect(routeRequests(pipecat) == ["prefer earpiece for the join"])

        await answer(rig, pipecat)
        await waitUntil { pipecat.calls.contains("prefer speaker") }

        #expect(routeRequests(pipecat) == ["prefer earpiece for the join", "prefer speaker"])
    }

    @Test(.timeLimit(.minutes(1)))
    func theUsersPickAfterARingsAnswerWins() async throws {
        let rig = earpieceRig(minimumOutgoingConnecting: .seconds(3))
        let pipecat = try await ringJoined(rig)
        await answer(rig, pipecat)

        await rig.engine.selectAudioDevice("speakerphone")

        #expect(routeRequests(pipecat) == ["prefer earpiece for the join", "prefer speaker"])
    }

    /// A drop after the answer: the rejoin names the earpiece the call started on.
    @Test(.timeLimit(.minutes(1)))
    func aReconnectAfterARingsAnswerKeepsTheEarpiece() async throws {
        let rig = earpieceRig(minimumOutgoingConnecting: .seconds(3))
        rig.dailyDropsPreferenceAtJoin = true
        let pipecat = try await ringJoined(rig)
        rig.outputPort = .builtInSpeaker
        await answer(rig, pipecat)
        await waitUntil { rig.engine.state.isConnected }
        rig.sleeper.wakeAll()
        await drain()
        let joins = pipecat.calls.filter { $0.hasPrefix("connect") }.count

        pipecat.setState(state: .disconnected) // Daily left the call: a drop
        await waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.wakeAll() // attempt 1's backoff
        await waitUntil { pipecat.calls.filter { $0.hasPrefix("connect") }.count == joins + 1 }
        await rig.system.awaitPendingWork()

        let rejoins = pipecat.calls.filter { $0.hasPrefix("connect") }
        #expect(rejoins.count == joins + 1)
        #expect(rejoins.last == "connect preferring earpiece")
        #expect(!pipecat.calls.contains { $0.contains("speaker") })
    }
}
