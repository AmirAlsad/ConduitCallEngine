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

    // MARK: - Joining while ringing

    /// A rig whose target lets a ring join during the ring, rung with `media`; returns
    /// once the device has joined the ring's room. The answered call must not wait
    /// for the outgoing minimum, so every rig here sets one.
    private func ringJoined(botThere: Bool) async throws -> (DailyEngineRig, UUID, FakePipecatTransport) {
        let rig = DailyEngineRig(minimumOutgoingConnecting: .seconds(3))
        rig.ringPreparation = .media
        rig.refreshTarget()
        let id = rig.ring()
        await waitUntil { rig.pipecat?.calls.contains("connect") == true }
        let pipecat = try #require(rig.pipecat)
        #expect(pipecat.calls == ["agent audio unsubscribed", "connect"]) // unsubscribed before the join
        if botThere {
            pipecat.botJoins()
            await waitUntil { rig.engine.ringPreparationPhase == .ready }
        } else {
            await waitUntil { rig.sleeper.pendingCount == 1 } // the ring join's bound
            #expect(rig.engine.ringPreparationPhase == .connecting)
        }
        #expect(rig.engine.state == .incomingRinging)
        #expect(rig.host.cues.isEmpty)
        #expect(!pipecat.micHistory.contains(true))
        #expect(!pipecat.sentClientReady) // the agent is unheard, so it cannot be ready
        return (rig, id, pipecat)
    }

    /// The agent is in the room before the user answers: the answer connects the
    /// call at once, and CallKit's activation subscribes to the agent before the
    /// engine tells it the user is on the line (or the greeting would go unheard).
    @Test(.timeLimit(.minutes(1)))
    func aRingJoinedWhileRingingIsReadyAtTheAnswer() async throws {
        let (rig, _, pipecat) = try await ringJoined(botThere: true)
        try #require(rig.controls.last).suspensions = 20 // Daily takes a while to subscribe

        await rig.system.answerIncomingCall()
        #expect(rig.engine.state.isConnected)
        #expect(!rig.host.transitions.contains(.connecting))
        #expect(rig.engine.activeCall?.wasReadyAtAnswer == true)
        #expect(rig.host.cues.isEmpty) // CallKit has not activated the audio yet

        await rig.system.activateAudioSession()
        await waitUntil { pipecat.calls.contains("send client-message") }
        await rig.system.awaitPendingWork()

        #expect(pipecat.calls == [
            "agent audio unsubscribed", "connect", "agent audio subscribed", "send client-message",
        ])
        #expect(signals(pipecat) == ["call-connected"])
        #expect(pipecat.micHistory.last == true)
        #expect(pipecat.sentClientReady)
        #expect(rig.host.cues == [.moment(.connected)])
        #expect(rig.requests.map(\.purpose) == [.ringing(joinsBeforeAnswer: true)])
    }

    /// Answered before the agent is there: the call connects the moment the agent
    /// arrives, with no outgoing minimum.
    @Test(.timeLimit(.minutes(1)))
    func anAnswerBeforeTheAgentIsThereConnectsTheMomentItArrives() async throws {
        let (rig, _, pipecat) = try await ringJoined(botThere: false)

        await rig.system.answerIncomingCall()
        #expect(rig.engine.state == .connecting)
        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()
        #expect(pipecat.calls == ["agent audio unsubscribed", "connect", "agent audio subscribed"])
        #expect(signals(pipecat).isEmpty)

        pipecat.botJoins()
        await waitUntil { rig.engine.state.isConnected }
        await rig.system.awaitPendingWork()

        #expect(rig.engine.state.isConnected)
        #expect(!rig.engine.isTimerRunning(.minimumOutgoingConnecting))
        #expect(signals(pipecat) == ["call-connected"])
        #expect(pipecat.micHistory.last == true)
        #expect(rig.host.cues == [.start(.connecting), .stop, .moment(.connected)])
        #expect(rig.engine.activeCall?.wasReadyAtAnswer == false)
        #expect(rig.requests.count == 1)
    }

    /// The agent never comes: the ring's join bound runs out after the answer, the
    /// call connects once more as without pre-connect (a normal join, on a new
    /// client), and when that agent does not come either, the call fails.
    @Test(.timeLimit(.minutes(1)))
    func anAnsweredRingWhoseAgentNeverComesFailsAfterTheJoinBound() async throws {
        let (rig, _, first) = try await ringJoined(botThere: false)
        await rig.system.answerIncomingCall()
        await rig.system.activateAudioSession()

        rig.sleeper.wakeAll() // the ring join's 30 seconds
        await waitUntil { rig.pipecats.count == 2 && rig.sleeper.pendingCount == 1 }
        let second = try #require(rig.pipecats.last)
        #expect(rig.engine.state == .connecting)
        #expect(first.calls == ["agent audio unsubscribed", "connect", "agent audio subscribed", "disconnect", "release"]) // no end-call
        #expect(second.calls == ["agent audio subscribed", "connect"])

        rig.sleeper.wakeAll() // the fresh join's 30 seconds
        await waitUntil { rig.engine.state.isTerminal }

        #expect(rig.engine.state == .failed(.agentUnreachable))
        #expect(rig.requests.map(\.purpose) == [.ringing(joinsBeforeAnswer: true), .answered])
        #expect(rig.host.records.map(\.outcome) == [.failed])
    }

    /// Declined with the agent in the room: the device leaves, telling the agent,
    /// and nothing was ever audible or cued.
    @Test(.timeLimit(.minutes(1)))
    func aRingThatEndsUnansweredLeavesTheRoomUnheard() async throws {
        let (rig, id, pipecat) = try await ringJoined(botThere: true)

        rig.system.endCallFromSystem(id)
        await rig.system.awaitPendingWork()

        #expect(pipecat.calls == ["agent audio unsubscribed", "connect", "send client-message", "disconnect", "release"])
        #expect(signals(pipecat) == ["end-call"])
        #expect(!pipecat.micHistory.contains(true))
        #expect(rig.host.cues.isEmpty)
        #expect(rig.host.records.map(\.outcome) == [.declined])
    }

    /// A hold after a ring-time join silences the agent as on any call, and the
    /// resume brings it back.
    @Test(.timeLimit(.minutes(1)))
    func aHoldAfterARingJoinSilencesTheAgentUntilTheResume() async throws {
        let (rig, id, pipecat) = try await ringJoined(botThere: true)
        await rig.system.answerIncomingCall()
        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()

        await rig.system.setHeldFromSystem(id, onHold: true)
        await drain()
        #expect(pipecat.remoteAudio == .unsubscribed)
        #expect(pipecat.micHistory.last == false)

        await rig.system.setHeldFromSystem(id, onHold: false)
        await rig.system.awaitPendingWork()
        await drain()

        #expect(pipecat.remoteAudio == .subscribed)
        #expect(pipecat.micHistory.last == true)
        #expect(signals(pipecat) == ["call-connected", "call-held", "call-resumed"])
        #expect(Array(pipecat.calls.filter { $0.hasPrefix("agent audio") }) == [
            "agent audio unsubscribed", "agent audio subscribed", "agent audio unsubscribed", "agent audio subscribed",
        ])
    }

    /// A reconnect after a ring-time join is a normal join: the agent stays
    /// subscribed, and the agent being in the room is not enough; it must be ready.
    @Test(.timeLimit(.minutes(1)))
    func aReconnectAfterARingJoinIsANormalJoin() async throws {
        let (rig, _, pipecat) = try await ringJoined(botThere: true)
        await rig.system.answerIncomingCall()
        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()
        rig.sleeper.wakeAll() // the ring join's bound, over once the agent was there
        await drain()
        let callsBeforeTheDrop = pipecat.calls.count

        pipecat.setState(state: .disconnected) // Daily left the call: a drop
        await waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.wakeAll() // attempt 1's backoff
        await waitUntil { pipecat.calls.count == callsBeforeTheDrop + 2 }
        pipecat.botAnswersClientReady = false
        pipecat.botJoins()
        await drain()

        #expect(rig.engine.state == .reconnecting(attempt: 1))
        #expect(Array(pipecat.calls.dropFirst(callsBeforeTheDrop)) == ["agent audio subscribed", "connect"])

        pipecat.becomeReady()
        await waitUntil { rig.engine.state.isConnected }
        await rig.system.awaitPendingWork()

        #expect(rig.engine.state.isConnected)
        #expect(rig.requests.map(\.purpose) == [.ringing(joinsBeforeAnswer: true), .reconnect(attempt: 1)])
        #expect(signals(pipecat) == ["call-connected", "call-connected"])
    }

    /// An outgoing call joins before CallKit activates it (the credential fetch is
    /// quick): Daily's default subscriptions, untouched, and the call connects on
    /// bot-ready, not on the agent's presence, exactly as before.
    @Test(.timeLimit(.minutes(1)))
    func anOutgoingCallJoinedBeforeTheActivationKeepsDefaultSubscriptions() async throws {
        let rig = DailyEngineRig()
        await rig.engine.placeCall(rig.target)
        await drain()
        let pipecat = try #require(rig.pipecat)
        #expect(pipecat.calls == ["connect"])
        pipecat.botAnswersClientReady = false
        pipecat.botJoins()
        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()
        #expect(rig.engine.state == .connecting)

        pipecat.becomeReady()
        await waitUntil { rig.engine.state.isConnected }
        await rig.system.awaitPendingWork()

        #expect(rig.engine.state.isConnected)
        #expect(!pipecat.calls.contains { $0.hasPrefix("agent audio") })
        #expect(rig.engine.activeCall?.wasReadyAtAnswer == false)
    }

    /// The other order: CallKit activates the call while it dials, before the join.
    @Test(.timeLimit(.minutes(1)))
    func anOutgoingCallActivatedWhileDialingWaitsForBotReady() async throws {
        let rig = DailyEngineRig()
        rig.system.suspendsOutgoingStarts = true
        let placing = Task { await rig.engine.placeCall(rig.target) }
        await waitUntil { rig.system.pendingOutgoingStartCount == 1 }
        await rig.system.activateAudioSession()
        rig.system.releaseOutgoingStarts()
        await placing.value
        await drain()
        let pipecat = try #require(rig.pipecat)
        pipecat.botAnswersClientReady = false

        pipecat.botJoins()
        await drain()
        #expect(rig.engine.state == .connecting)

        pipecat.becomeReady()
        await waitUntil { rig.engine.state.isConnected }
        #expect(rig.engine.state.isConnected)
        #expect(!pipecat.calls.contains { $0.hasPrefix("agent audio") })
    }

    // MARK: - The agent hears that the user is on the line

    @Test(.timeLimit(.minutes(1)))
    func anOutgoingCallSendsCallConnectedOnceTheBotIsReady() async throws {
        let rig = DailyEngineRig()
        _ = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)
        await rig.system.awaitPendingWork()
        #expect(signals(pipecat).isEmpty) // connecting: nobody to tell yet

        pipecat.botJoins()
        await waitUntil { rig.engine.state.isConnected }
        await rig.system.awaitPendingWork()

        #expect(signals(pipecat) == ["call-connected"])
    }

    // MARK: - The mic opens once the call is connected

    /// CallKit activates while Daily is still joining and the bot is not ready: the
    /// mic stays closed (Daily took a pre-join enable as a no-op, so it never
    /// depended on that), and opens once the bot is ready.
    @Test(.timeLimit(.minutes(1)))
    func theMicOpensWhenTheBotIsReadyNotAtTheActivation() async throws {
        let rig = DailyEngineRig()
        _ = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)
        await rig.system.awaitPendingWork()
        #expect(!pipecat.micHistory.contains(true))

        pipecat.botJoins()
        await waitUntil { rig.engine.state.isConnected }
        await rig.system.awaitPendingWork()

        #expect(pipecat.micHistory.last == true)
        #expect(signals(pipecat) == ["call-connected"])
    }

    /// The other order: the bot is ready before CallKit activates.
    @Test(.timeLimit(.minutes(1)))
    func aCallReadyBeforeTheActivationOpensTheMicAtTheActivation() async throws {
        let rig = DailyEngineRig()
        await rig.engine.placeCall(rig.target)
        await drain()
        let pipecat = try #require(rig.pipecat)
        pipecat.botJoins()
        await waitUntil { rig.engine.state.isConnected }
        await rig.system.awaitPendingWork()
        #expect(!pipecat.micHistory.contains(true))

        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()

        #expect(pipecat.micHistory.last == true)
    }

    // MARK: - The minimum connecting time

    @Test(.timeLimit(.minutes(1)))
    func aBotReadyBeforeTheMinimumStaysConnectingUntilItHasPassed() async throws {
        let rig = DailyEngineRig(minimumOutgoingConnecting: .seconds(3))
        _ = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)
        pipecat.botJoins()
        await waitUntil { rig.engine.isTimerRunning(.minimumOutgoingConnecting) }
        await rig.system.awaitPendingWork()

        #expect(rig.engine.state == .connecting)
        #expect(!pipecat.micHistory.contains(true))
        #expect(signals(pipecat).isEmpty)

        #expect(rig.system.fireTimer(.minimumOutgoingConnectingDuration))
        await rig.system.awaitPendingWork()

        #expect(rig.engine.state.isConnected)
        #expect(pipecat.micHistory.last == true)
        #expect(signals(pipecat) == ["call-connected"])
    }

    /// Daily drops while the engine holds the connection: the call reconnects, as a
    /// connected call does, instead of failing as one that never connected.
    @Test(.timeLimit(.minutes(1)))
    func aDropDuringTheMinimumReconnectsTheCallItMade() async throws {
        let rig = DailyEngineRig(minimumOutgoingConnecting: .seconds(3))
        _ = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)
        pipecat.botJoins()
        await waitUntil { rig.engine.isTimerRunning(.minimumOutgoingConnecting) }

        pipecat.setState(state: .disconnected) // Daily left the call
        await waitUntil { rig.engine.state == .reconnecting(attempt: 1) }

        #expect(rig.engine.state == .reconnecting(attempt: 1))
        #expect(rig.host.records.isEmpty)
    }

    // MARK: - Signals that do not leave the device

    /// Daily refuses the app message carrying `call-resumed`: before, the agent that
    /// closed its audio on `call-held` stayed closed for the rest of the call.
    @Test(.timeLimit(.minutes(1)))
    func aResumeDailyCouldNotSendReachesTheAgentOnARetry() async throws {
        let rig = DailyEngineRig()
        let id = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)
        pipecat.botJoins()
        await waitUntil { rig.engine.state.isConnected }
        rig.sleeper.wakeAll() // the first connect's bound, stale once connected
        await drain()
        await rig.system.setHeldFromSystem(id, onHold: true)
        let control = try #require(rig.controls.last)
        control.appMessageError = FakeDailyCallControl.Refused()

        await rig.system.setHeldFromSystem(id, onHold: false)
        await waitUntil { rig.sleeper.pendingCount == 1 }
        control.appMessageError = nil
        rig.sleeper.wakeAll()
        await waitUntil { signals(pipecat).last == "call-resumed" }

        #expect(signals(pipecat) == ["call-connected", "call-held", "call-resumed"])
    }

    private func signals(_ pipecat: FakePipecatTransport) -> [String] {
        pipecat.sentMessages.compactMap {
            let message = try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            return (message?["data"] as? [String: Any])?["t"] as? String
        }
    }

    // MARK: - Reconnect attempts on the same transport

    /// A connected call whose Daily client dropped: the engine's first attempt has
    /// joined room 2 with the same client, and its join bound is sleeping.
    private func firstAttemptJoined(_ rig: DailyEngineRig) async throws -> FakePipecatTransport {
        _ = try await rig.placeActivatedCall()
        let first = try #require(rig.pipecat)
        first.botJoins()
        await waitUntil { rig.engine.state.isConnected }
        rig.sleeper.wakeAll() // the first connect's bound, stale once connected
        await drain()
        #expect(first.calls == ["connect", "send client-message"]) // call-connected

        first.setState(state: .disconnected) // Daily left the call: a drop
        await waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.wakeAll() // attempt 1's backoff
        await waitUntil { rig.requests.count == 2 && rig.sleeper.pendingCount == 1 }
        #expect(first.calls == ["connect", "send client-message", "connect"]) // the same client rejoined
        #expect(rig.engine.state == .reconnecting(attempt: 1))
        return first
    }

    /// Room 2's agent never gets ready, so the engine's join bound fails attempt 1 and
    /// attempt 2 connects the same transport with room 3. The client is still in room
    /// 2: the adapter must take the session over, not refuse every later attempt.
    @Test(.timeLimit(.minutes(1)))
    func anAttemptAfterAJoinBoundRanOutJoinsTheNextRoom() async throws {
        let rig = DailyEngineRig()
        let first = try await firstAttemptJoined(rig)

        rig.sleeper.wakeAll() // 30 seconds and room 2's agent never got ready
        await waitUntil { rig.engine.state == .reconnecting(attempt: 2) && rig.sleeper.pendingCount == 1 }
        rig.sleeper.wakeAll() // attempt 2's backoff
        await waitUntil { rig.pipecats.count == 2 }
        let second = try #require(rig.pipecats.last)
        second.botJoins()
        await waitUntil { rig.engine.state.isConnected }

        #expect(rig.engine.state.isConnected)
        #expect(rig.requests.map(\.purpose) == [.outgoing, .reconnect(attempt: 1), .reconnect(attempt: 2)])
        #expect(first.calls == ["connect", "send client-message", "connect", "disconnect", "release"]) // no end-call: the call goes on
        #expect(second.calls.prefix(1) == ["connect"])
        #expect(rig.host.records.isEmpty)
    }

    /// The hold paused attempt 1 while it waited for room 2's agent; the resume starts
    /// a new attempt at once, on a client that is still in room 2.
    @Test(.timeLimit(.minutes(1)))
    func theResumeAfterAHeldReconnectJoinsTheNextRoom() async throws {
        let rig = DailyEngineRig()
        _ = try await firstAttemptJoined(rig)
        let id = try #require(rig.system.startedCallIDs.first)

        await rig.system.setHeldFromSystem(id, onHold: true)
        #expect(rig.engine.state == .reconnecting(attempt: 0))
        await rig.system.setHeldFromSystem(id, onHold: false)
        await waitUntil { rig.pipecats.count == 2 }
        let second = try #require(rig.pipecats.last)
        second.botJoins()
        await waitUntil { rig.engine.state.isConnected }

        #expect(rig.engine.state.isConnected)
        #expect(rig.requests.count == 3)
    }

    /// The other side of the take-over: while Daily heals a connected call (the
    /// network path is down), the engine's attempts do not rejoin, and Daily's own
    /// recovery recovers the call.
    @Test(.timeLimit(.minutes(1)))
    func anAttemptWhileDailyHealsLeavesTheSessionAlone() async throws {
        let rig = DailyEngineRig()
        _ = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)
        pipecat.botJoins()
        await waitUntil { rig.engine.state.isConnected }
        rig.sleeper.wakeAll()
        await drain()
        let monitor = try #require(rig.pathMonitors.last)
        monitor.deliver(true) // the monitor's first delivery
        monitor.deliver(false)
        await waitUntil { rig.engine.state == .reconnecting(attempt: 0) && rig.sleeper.pendingCount == 1 }

        rig.sleeper.wakeAll() // 30 seconds of Daily healing
        await waitUntil { rig.engine.state == .reconnecting(attempt: 1) && rig.sleeper.pendingCount == 1 }
        rig.sleeper.wakeAll() // attempt 1's backoff: its connect is refused
        await waitUntil { rig.engine.state == .reconnecting(attempt: 2) }
        monitor.deliver(true) // Daily healed
        await waitUntil { rig.engine.state.isConnected }
        await rig.system.awaitPendingWork()

        #expect(rig.engine.state.isConnected)
        #expect(rig.pipecats.count == 1)
        // No second join; call-connected again for the healed connection.
        #expect(pipecat.calls == ["connect", "send client-message", "send client-message"])
    }
}
