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
@_spi(RingJoinExperiment) @testable import ConduitCallEngineDaily

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

    // MARK: - Experimental ring joins

    /// The engine sends `call-answered` after the attach it issued on CallKit's
    /// activation; with the agent's audio held back until that attach, the attach
    /// must not return before Daily has subscribed, or the agent starts its greeting
    /// before the user can hear it.
    @Test(.timeLimit(.minutes(1)))
    func aRingJoinedWithTheAgentHeldBackIsAudibleBeforeTheAgentHearsOfTheAnswer() async throws {
        let rig = DailyEngineRig(strategy: .agentAudioUnsubscribedUntilAnswer)
        rig.ringPreparation = .media
        rig.refreshTarget()
        _ = rig.ring()
        await waitUntil { rig.pipecat?.calls.contains("connect") == true }
        let pipecat = try #require(rig.pipecat)
        pipecat.botJoins() // present; its audio is unsubscribed, so it is not ready
        await waitUntil { rig.engine.ringPreparationPhase == .ready } // connected on presence
        try #require(rig.controls.last).suspensions = 20 // Daily takes a while to subscribe

        await rig.system.answerIncomingCall()
        await rig.system.activateAudioSession()
        await waitUntil { pipecat.calls.contains("send client-message") }
        await drain()

        let subscribed = try #require(pipecat.calls.firstIndex(of: "agent audio subscribed"))
        let answered = try #require(pipecat.calls.firstIndex(of: "send client-message"))
        #expect(subscribed < answered)
    }

    /// An outgoing call on a transport made with a ring-join strategy: CallKit
    /// activates it while it dials, so it is attached before it joins, the agent's
    /// audio is subscribed, and presence must not count as ready (the mic would open
    /// before the bot can hear the user).
    @Test(.timeLimit(.minutes(1)))
    func anOutgoingCallOnARingJoinTransportWaitsForBotReady() async throws {
        let rig = DailyEngineRig(strategy: .agentAudioUnsubscribedUntilAnswer)
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

        #expect(signals(pipecat) == ["call-held", "call-resumed"])
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

        first.setState(state: .disconnected) // Daily left the call: a drop
        await waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.wakeAll() // attempt 1's backoff
        await waitUntil { rig.requests.count == 2 && rig.sleeper.pendingCount == 1 }
        #expect(first.calls == ["connect", "connect"]) // the same client rejoined
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
        #expect(first.calls == ["connect", "connect", "disconnect", "release"]) // no end-call: the call goes on
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

        #expect(rig.engine.state.isConnected)
        #expect(rig.pipecats.count == 1)
        #expect(pipecat.calls == ["connect"])
    }
}
