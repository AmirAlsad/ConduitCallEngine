//
//  CallCueTests.swift
//  ConduitCallEngineTests
//
//  The cue channel: the moments a host marks with its own sound. Each guarantee
//  `CallCue` documents is pinned here, and every test also checks the sequence
//  is well formed (a start is always stopped before the next start, before a
//  connected moment, and by the time the call is over) and that `repeatingCue`
//  matched the last start or stop when each cue was delivered.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct CallCueTests {

    private let statusEndpoint = URL(string: "https://engine.example.com/inbound/status/live")!

    /// Placed, activated by CallKit (as it does right after the start), connected.
    private func connectedCall(_ h: CallEngineHarness) async {
        await h.placeCall()
        await h.engine.activate(FakeAudioSession())
        h.engine.handle(.connected)
    }

    // MARK: - Connecting

    @Test func outgoingCallLoopsWhileConnectingThenMarksConnected() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        #expect(h.delegate.cues == [.start(.connecting)])
        #expect(h.engine.repeatingCue == .connecting)
        await h.engine.activate(FakeAudioSession())

        h.engine.handle(.connected)

        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.connected)])
        #expect(h.engine.repeatingCue == nil)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func cuesFollowTheTransitionTheyBelongTo() async throws {
        let h = CallEngineHarness()
        await connectedCall(h)

        #expect(h.log.entries.filter { $0.hasPrefix("T(") || $0.hasPrefix("cue(") } == [
            "T(idle→dialing)",
            "T(dialing→connecting)", "cue(start(connecting))",
            "T(connecting→connected)", "cue(stop)", "cue(connected)",
        ])
    }

    @Test func answeringRingsBackOnlyAfterTheAnsweredReceipt() async throws {
        let h = CallEngineHarness()
        h.ring(statusURL: statusEndpoint)
        #expect(h.delegate.cues.isEmpty) // CallKit owns the ring
        let before = h.log.entries.count

        await h.engine.answer()

        #expect(Array(h.log.entries.dropFirst(before).prefix(4)) == [
            "bearer", "receipt(answered)", "T(incomingRinging→connecting)", "cue(start(connecting))",
        ])
        await h.engine.activate(FakeAudioSession())
        h.engine.handle(.connected)
        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.connected)])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    // MARK: - The connected moment waits for CallKit's audio

    /// A host plays its "connected" sound on `.moment(.connected)`; before CallKit
    /// has activated the session that sound plays into a session that is not live.
    @Test(arguments: [false, true])
    func aCallConnectedBeforeCallKitActivatedIsMarkedConnectedAtTheActivation(answered: Bool) async throws {
        let h = CallEngineHarness()
        if answered {
            h.ring()
            await h.engine.answer()
        } else {
            await h.placeCall()
        }
        h.engine.handle(.connected)
        #expect(h.delegate.cues == [.start(.connecting), .stop]) // the ringback stops with the state

        await h.engine.activate(FakeAudioSession())

        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.connected)])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func aCallHeldBeforeCallKitActivatedIsMarkedConnectedOnceResumedAndActive() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        #expect(h.engine.providerPerformSetHeld(h.callID, onHold: true))
        await h.engine.activate(FakeAudioSession())
        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.held)])

        #expect(h.engine.providerPerformSetHeld(h.callID, onHold: false))

        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.held), .moment(.resumed), .moment(.connected)])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    /// The user never heard it connect: when it is back, it is marked connected, once.
    @Test func aCallThatDroppedBeforeCallKitActivatedIsMarkedConnectedWhenItIsBack() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        h.engine.handle(.reconnecting)
        await h.engine.activate(FakeAudioSession())

        h.engine.handle(.connected)

        #expect(h.delegate.cues == [
            .start(.connecting), .stop,
            .moment(.connectionLost), .start(.retrying),
            .stop, .moment(.connected),
        ])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    // MARK: - Outages

    @Test func aDropMarksTheLossOnceThenLoopsUntilReconnected() async throws {
        let h = CallEngineHarness()
        await connectedCall(h)

        h.engine.handle(.disconnected(reason: .networkDropped))
        #expect(Array(h.delegate.cues.suffix(2)) == [.moment(.connectionLost), .start(.retrying)])
        #expect(h.engine.repeatingCue == .retrying)
        await h.engine.awaitPendingReconnect()
        h.engine.handle(.connected)

        #expect(Array(h.delegate.cues.dropFirst(3)) == [
            .moment(.connectionLost), .start(.retrying), .stop, .moment(.reconnected),
        ])
        #expect(h.engine.repeatingCue == nil)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func aSelfHealThatEscalatesMarksTheLossOnce() async throws {
        let h = CallEngineHarness()
        await connectedCall(h)

        h.engine.handle(.reconnecting) // reconnecting(0)
        h.engine.handle(.disconnected(reason: .networkDropped)) // reconnecting(1)
        await h.engine.awaitPendingReconnect()
        h.engine.handle(.disconnected(reason: .networkDropped)) // reconnecting(2)
        await h.engine.awaitPendingReconnect()
        h.engine.handle(.connected)

        #expect(Array(h.delegate.transitions.suffix(4)) == [
            "connected→reconnecting(0)", "reconnecting(0)→reconnecting(1)",
            "reconnecting(1)→reconnecting(2)", "reconnecting(2)→connected",
        ])
        #expect(Array(h.delegate.cues.dropFirst(3)) == [
            .moment(.connectionLost), .start(.retrying), .stop, .moment(.reconnected),
        ])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func eachOutageIsMarkedOnce() async throws {
        let h = CallEngineHarness()
        await connectedCall(h)

        for _ in 0..<2 {
            h.engine.handle(.reconnecting)
            h.engine.handle(.connected)
        }

        #expect(h.delegate.cues.filter { $0 == .moment(.connectionLost) }.count == 2)
        #expect(h.delegate.cues.filter { $0 == .moment(.reconnected) }.count == 2)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func anExhaustedBudgetStopsTheLoop() async throws {
        let policy = ReconnectionPolicy(maxAttempts: 1, baseDelaySeconds: 0, maxDelaySeconds: 0)
        let h = CallEngineHarness(policy: policy)
        await connectedCall(h)

        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()
        h.engine.handle(.disconnected(reason: .networkDropped))

        #expect(h.engine.state == .failed(.lostConnection))
        #expect(h.delegate.cues.last == .stop)
        #expect(h.engine.repeatingCue == nil)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    // MARK: - Every ending stops a running loop

    enum Ending: String, CaseIterable, Sendable {
        case userEnded, endedFromSystem, agentLeft, authFailed, providerReset
    }

    @Test(arguments: Ending.allCases, [false, true])
    func anEndingStopsTheLoop(ending: Ending, whileReconnecting: Bool) async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        if whileReconnecting {
            h.engine.handle(.connected)
            h.engine.handle(.reconnecting)
        }
        #expect(h.engine.repeatingCue != nil)

        switch ending {
        case .userEnded: await h.engine.endCall()
        case .endedFromSystem: h.provider.simulateEndCall(h.callID)
        case .agentLeft: h.engine.handle(.disconnected(reason: .botLeft))
        case .authFailed: h.engine.handle(.disconnected(reason: .authFailed))
        case .providerReset: h.provider.simulateReset()
        }

        #expect(h.engine.state.isTerminal)
        #expect(h.delegate.cues.last == .stop)
        #expect(h.engine.repeatingCue == nil)
        // The stop comes with the terminal transition, before the record.
        let stop = try #require(h.log.entries.lastIndex(of: "cue(stop)"))
        let finish = try #require(h.log.entries.firstIndex { $0.hasPrefix("finish(") })
        #expect(stop < finish)

        h.engine.reset()
        #expect(h.delegate.cues.last == .stop) // returning to idle adds nothing
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func aCallEndedWhileDialingProducesNoCues() async throws {
        let h = CallEngineHarness()
        h.provider.suspendStart = true
        let place = Task { await h.placeCall() }
        await waitUntil { h.provider.pendingStartCount == 1 }

        await h.engine.endCall()
        h.provider.releaseStart()
        await place.value

        #expect(h.delegate.cues.isEmpty)
    }

    // MARK: - Rings nobody answered

    enum UnansweredRing: String, CaseIterable, Sendable {
        case declined, unknownTarget, filteredByFocus, reportFailed, providerReset, busy
    }

    @Test(arguments: UnansweredRing.allCases)
    func aRingThatIsNeverAnsweredProducesNoCues(ring: UnansweredRing) async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        switch ring {
        case .declined:
            h.ring(callID: callID, statusURL: statusEndpoint)
            h.provider.simulateEndCall(callID)
        case .unknownTarget:
            h.ring(targetID: UUID(), callID: callID)
        case .filteredByFocus:
            h.provider.reportIncomingError = .filteredByFocus
            h.ring(callID: callID)
        case .reportFailed:
            h.provider.reportIncomingError = .failed("refused")
            h.ring(callID: callID)
        case .providerReset:
            h.ring(callID: callID)
            h.provider.simulateReset()
        case .busy:
            h.ring(callID: UUID())
            h.ring(callID: callID)
        }

        #expect(h.delegate.cues.isEmpty)
        #expect(h.engine.repeatingCue == nil)
    }

    // MARK: - Observed state

    @Test func repeatingCueIsReadableWithoutTheDelegate() async throws {
        let h = CallEngineHarness()
        h.engine.delegate = nil
        await h.placeCall()
        #expect(h.engine.repeatingCue == .connecting)

        h.engine.handle(.connected)
        #expect(h.engine.repeatingCue == nil)

        h.engine.handle(.disconnected(reason: .networkDropped))
        #expect(h.engine.repeatingCue == .retrying)

        await h.engine.endCall()
        #expect(h.engine.repeatingCue == nil)
    }

    @Test func aSecondCallCuesFromAFreshStart() async throws {
        let h = CallEngineHarness()
        await connectedCall(h)
        h.engine.handle(.disconnected(reason: .botLeft))

        await connectedCall(h)

        #expect(h.delegate.cues == [
            .start(.connecting), .stop, .moment(.connected),
            .start(.connecting), .stop, .moment(.connected),
        ])
        #expect(h.delegate.cueViolations.isEmpty)
    }
}
