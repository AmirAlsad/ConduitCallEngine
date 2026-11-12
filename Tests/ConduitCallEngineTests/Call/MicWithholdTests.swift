//
//  MicWithholdTests.swift
//  ConduitCallEngineTests
//
//  The host's withhold of the mic (`setMicWithheld(_:)`): one more input to the
//  mic rule, which keeps the mic closed while the host plays its own sounds. It is
//  not mute and touches nothing but the mic, it ends with the call, and a bound
//  on the engine's injected sleep (a `ManualSleeper` here) releases one the host
//  forgets. Every order of it against the other inputs is in `MicRuleTests`.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct MicWithholdTests {
    private let sleeper = ManualSleeper()

    private func harness(micWithholdTimeout: Duration = .seconds(5), pushToTalk: Bool = false) -> CallEngineHarness {
        let sleeper = sleeper
        return CallEngineHarness(
            pushToTalk: pushToTalk,
            micWithholdTimeout: micWithholdTimeout,
            sleep: { await sleeper.sleep($0) }
        )
    }

    /// Placed, connected and activated: the mic is live.
    private func liveCall(_ h: CallEngineHarness) async {
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.activate(FakeAudioSession())
        await h.engine.awaitPendingMediaWork()
    }

    private func withhold(_ h: CallEngineHarness, _ withheld: Bool) async {
        h.engine.setMicWithheld(withheld)
        await h.engine.awaitPendingMediaWork()
    }

    // MARK: - Not mute

    @Test func aWithholdClosesTheMicAndChangesNothingElse() async throws {
        let h = harness()
        await liveCall(h)
        #expect(h.transport.isMicEnabled)
        let state = h.engine.state
        let cues = h.delegate.cues
        let transitions = h.delegate.transitions

        await withhold(h, true)

        #expect(h.engine.isMicWithheld)
        #expect(!h.transport.isMicEnabled)
        #expect(!h.engine.isMuted)
        #expect(h.provider.muteStates.isEmpty) // CallKit is never told of it
        #expect(h.transport.isAudioAttached) // the agent stays audible
        #expect(h.transport.sentSignals.isEmpty)
        #expect(h.engine.state == state)
        #expect(h.delegate.cues == cues)
        #expect(h.delegate.transitions == transitions)
        #expect(h.delegate.records.isEmpty)

        await withhold(h, false)

        #expect(!h.engine.isMicWithheld)
        #expect(h.transport.isMicEnabled)
        #expect(!h.engine.isMuted)
        #expect(h.provider.muteStates.isEmpty)
        #expect(h.transport.isAudioAttached)
        #expect(h.transport.sentSignals.isEmpty)
        #expect(h.delegate.cues == cues)
        #expect(h.delegate.transitions == transitions)
    }

    @Test func muteChangesWhileWithheldAreTheUsersAndApplyAtTheRelease() async throws {
        let h = harness()
        await liveCall(h)
        await withhold(h, true)

        await h.engine.setMuted(true)
        #expect(h.engine.isMuted)
        #expect(h.provider.muteStates[h.callID] == true)
        await withhold(h, false)
        #expect(!h.transport.isMicEnabled)

        h.provider.simulateSetMuted(h.callID, muted: false) // unmuted from the system UI
        await h.engine.awaitPendingMediaWork()
        #expect(h.transport.isMicEnabled)
        #expect(!h.engine.isMuted)
    }

    @Test func aWithholdOverridesAHeldTalkButton() async throws {
        let h = harness(pushToTalk: true)
        await liveCall(h)
        await h.engine.setPushToTalkActive(true)
        #expect(h.transport.isMicEnabled)

        await withhold(h, true)
        #expect(!h.transport.isMicEnabled)

        await withhold(h, false)
        #expect(h.transport.isMicEnabled)
    }

    // MARK: - Releasing re-derives the mic

    enum OtherReason: String, CaseIterable, Sendable {
        case muted, held, interrupted, deactivated
    }

    @Test(arguments: OtherReason.allCases)
    func aReleaseLeavesTheMicClosedWhileAnotherInputCloses(_ reason: OtherReason) async throws {
        let h = harness()
        await liveCall(h)
        await withhold(h, true)

        switch reason {
        case .muted: await h.engine.setMuted(true)
        case .held: h.provider.simulateSetHeld(h.callID, onHold: true)
        case .interrupted: h.interruption.simulateBegan()
        case .deactivated: h.provider.simulateDeactivate(FakeAudioSession())
        }
        await withhold(h, false)

        #expect(!h.engine.isMicWithheld)
        #expect(!h.transport.isMicEnabled)
    }

    // MARK: - Any time, in any order

    @Test func aWithholdBeforeThereIsACallAppliesToTheCall() async throws {
        let h = harness()
        h.engine.setMicWithheld(true)
        #expect(h.engine.isMicWithheld)

        await liveCall(h)

        #expect(h.engine.isMicWithheld)
        #expect(!h.transport.micEnabledHistory.contains(true))
        await withhold(h, false)
        #expect(h.transport.isMicEnabled)
    }

    @Test func aWithholdAfterACallEndedAppliesToTheNextCall() async throws {
        let h = harness()
        await liveCall(h)
        await h.engine.endCall()
        #expect(h.engine.state.isTerminal)

        h.engine.setMicWithheld(true)
        await liveCall(h) // the terminal state is reset by the next call

        #expect(h.engine.isMicWithheld)
        #expect(!h.transport.micEnabledHistory.contains(true))
    }

    @Test func aWithholdAtTheConnectingCueKeepsTheMicClosedThroughTheConnect() async throws {
        let h = harness()
        h.delegate.onCue = { engine, cue in
            if cue == .start(.connecting) { engine.setMicWithheld(true) }
        }
        await h.placeCall()
        await h.engine.activate(FakeAudioSession()) // before the connect: the rule would open the mic
        h.engine.handle(.connected)
        await h.engine.awaitPendingMediaWork()

        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.connected)])
        #expect(h.transport.setMicEnabledCallCount > 0)
        #expect(!h.transport.micEnabledHistory.contains(true))
    }

    enum ConnectedCue: String, CaseIterable, Sendable {
        /// An outgoing call that connects before CallKit activates its audio: the
        /// cue comes at the activation.
        case atTheActivation
        /// A pre-connected ring answered with its agent there: no connecting cue.
        case atAPreconnectedAnswer
    }

    /// A withhold made inside the cue is in place before the engine's own mic
    /// command for the change that delivered it.
    @Test(arguments: ConnectedCue.allCases)
    func aWithholdAtTheConnectedCueClosesTheMicBeforeItOpens(_ path: ConnectedCue) async throws {
        let h = harness()
        h.delegate.onCue = { engine, cue in
            if cue == .moment(.connected) { engine.setMicWithheld(true) }
        }
        switch path {
        case .atTheActivation:
            await h.placeCall()
            h.engine.handle(.connected)
        case .atAPreconnectedAnswer:
            h.allowRingPreparation(.media)
            h.transport.canConnectWhileRinging = true
            h.ring(preconnect: "media")
            await settle()
            h.engine.handle(.connected)
            #expect(h.engine.ringPreparationPhase == .ready)
            await h.engine.answer()
        }
        #expect(!h.engine.isMicWithheld)

        await h.engine.activate(FakeAudioSession())
        await h.engine.awaitPendingMediaWork()

        #expect(h.delegate.cues.last == .moment(.connected))
        #expect(h.engine.isMicWithheld)
        #expect(h.transport.isAudioAttached)
        #expect(!h.transport.micEnabledHistory.contains(true))
    }

    // MARK: - The end of the call

    enum Ending: String, CaseIterable, Sendable {
        case byTheUser, fromTheSystem, byTheAgent, byAFailure, byAProviderReset
    }

    @Test(arguments: Ending.allCases)
    func aWithholdEndsWithTheCall(_ ending: Ending) async throws {
        let h = harness()
        await liveCall(h)
        await withhold(h, true)
        #expect(h.engine.isTimerRunning(.micWithholdTimeout))

        switch ending {
        case .byTheUser: await h.engine.endCall()
        case .fromTheSystem: h.provider.simulateEndCall(h.callID)
        case .byTheAgent: h.engine.handle(.disconnected(reason: .botLeft))
        case .byAFailure: h.engine.handle(.disconnected(reason: .authFailed))
        case .byAProviderReset: h.provider.simulateReset()
        }

        #expect(h.engine.state.isTerminal)
        #expect(!h.engine.isMicWithheld)
        #expect(!h.engine.isTimerRunning(.micWithholdTimeout))

        let next = h.target.makeTransportCount
        await liveCall(h)
        #expect(h.target.makeTransportCount == next + 1)
        #expect(h.transport.isMicEnabled)
    }

    @Test func aWithholdEndsWithARingThatIsNeverAnswered() async throws {
        let h = harness()
        let callID = UUID()
        h.ring(callID: callID)
        h.engine.setMicWithheld(true)

        h.provider.simulateEndCall(callID) // declined

        #expect(h.engine.state == .ended(.declined))
        #expect(!h.engine.isMicWithheld)
    }

    @Test func aWithholdOutlivesAReconnect() async throws {
        let h = harness()
        await liveCall(h)
        await withhold(h, true)

        h.engine.handle(.reconnecting)
        h.engine.handle(.connected)
        await h.engine.awaitPendingMediaWork()

        #expect(h.engine.isMicWithheld)
        #expect(!h.transport.isMicEnabled)
        #expect(h.engine.isTimerRunning(.micWithholdTimeout))
        #expect(sleeper.requested.filter { $0 == .seconds(5) }.count == 1) // not started again
    }

    // MARK: - The bound

    @Test func theDefaultBoundIsFiveSeconds() {
        #expect(CallEngineConfiguration().micWithholdTimeout == .seconds(5))
    }

    enum Order: String, CaseIterable, Sendable {
        case activationFirst, connectFirst
    }

    @Test(arguments: Order.allCases)
    func theBoundStartsOnceTheCallIsConnectedWithItsAudioActivated(_ order: Order) async throws {
        let h = harness(micWithholdTimeout: .seconds(3))
        h.engine.setMicWithheld(true)
        await h.placeCall()
        #expect(!h.engine.isTimerRunning(.micWithholdTimeout))

        switch order {
        case .activationFirst:
            await h.engine.activate(FakeAudioSession())
            #expect(!h.engine.isTimerRunning(.micWithholdTimeout))
            h.engine.handle(.connected)
        case .connectFirst:
            h.engine.handle(.connected)
            #expect(!h.engine.isTimerRunning(.micWithholdTimeout))
            await h.engine.activate(FakeAudioSession())
        }

        #expect(h.engine.isTimerRunning(.micWithholdTimeout))
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested == [.seconds(3)])
    }

    @Test func theBoundReleasesAWithholdTheHostForgets() async throws {
        let h = harness()
        await liveCall(h)
        await withhold(h, true)
        await waitUntil { sleeper.pendingCount == 1 }
        let cues = h.delegate.cues

        sleeper.wakeFirst()
        await waitUntil { !h.engine.isMicWithheld }
        await h.engine.awaitPendingMediaWork()

        #expect(!h.engine.isMicWithheld)
        #expect(h.transport.isMicEnabled)
        #expect(!h.engine.isMuted)
        #expect(h.provider.muteStates.isEmpty)
        #expect(h.delegate.cues == cues)
        #expect(!h.engine.isTimerRunning(.micWithholdTimeout))
    }

    @Test func theBoundReleasesIntoTheRestOfTheRule() async throws {
        let h = harness()
        await liveCall(h)
        await withhold(h, true)
        await h.engine.setMuted(true)

        #expect(h.engine.fireTimer(.micWithholdTimeout))
        await h.engine.awaitPendingMediaWork()

        #expect(!h.engine.isMicWithheld)
        #expect(!h.transport.isMicEnabled)
    }

    @Test func aReleaseStopsTheBound() async throws {
        let h = harness()
        await liveCall(h)
        await withhold(h, true)
        await waitUntil { sleeper.pendingCount == 1 }

        await withhold(h, false)
        #expect(!h.engine.isTimerRunning(.micWithholdTimeout))
        await h.engine.setMuted(true)
        sleeper.wakeAll() // the cancelled bound wakes, and changes nothing
        await settle()

        #expect(h.engine.isMuted)
        #expect(!h.transport.isMicEnabled)

        await withhold(h, true) // a new withhold gets a bound of its own
        #expect(h.engine.isTimerRunning(.micWithholdTimeout))
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested == [.seconds(5), .seconds(5)])
    }

    @Test func aSecondWithholdDoesNotRestartTheBound() async throws {
        let h = harness()
        await liveCall(h)
        await withhold(h, true)
        let commands = h.transport.setMicEnabledCallCount

        await withhold(h, true)

        #expect(sleeper.requested == [.seconds(5)])
        #expect(h.transport.setMicEnabledCallCount == commands)
    }

    // MARK: - ConduitCallEngineTesting

    @Test func aHostTestFiresTheBoundThroughTheSimulatedSystem() async throws {
        let system = SimulatedCallSystem()
        let engine = CallEngine.simulated(system: system)
        let transport = FakeTransport()
        let target = CallTarget(
            id: UUID(),
            displayName: "Assistant",
            makeTransport: { transport },
            connect: { _ in CallConnection(url: URL(string: "https://example.invalid/room")!, token: "t") }
        )
        engine.setMicWithheld(true)
        await engine.placeCall(target)
        #expect(!system.fireTimer(.micWithholdTimeout)) // not before the call is connected

        system.deliverTransportEvent(.connected)
        await system.activateAudioSession()
        await system.awaitPendingWork()
        #expect(engine.isMicWithheld)
        #expect(!transport.isMicEnabled)

        #expect(system.fireTimer(.micWithholdTimeout))
        await system.awaitPendingWork()

        #expect(!engine.isMicWithheld)
        #expect(transport.isMicEnabled)
        #expect(!system.fireTimer(.micWithholdTimeout))
        await engine.endCall()
    }
}
