//
//  CallHoldTests.swift
//  ConduitCallEngineTests
//
//  Call hold: CallKit's hold action (iOS holding the call for a phone call, or
//  the host through `setOnHold`) closes the mic, stops media, tells the agent and
//  marks the moment, without changing the call's state. Reconnection waits for
//  the resume, and the record counts the held time. Driven through the fake
//  provider; how iOS sequences hold with audio activation is device-only.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct CallHoldTests {

    /// Placed, connected and activated: the mic is live and media attached.
    private func liveCall(_ h: CallEngineHarness) async {
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.activate(FakeAudioSession())
    }

    private func activate(_ h: CallEngineHarness) async {
        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()
    }

    @discardableResult
    private func setHeld(_ h: CallEngineHarness, _ onHold: Bool, id: UUID? = nil) async -> Bool {
        let performed = h.provider.simulateSetHeld(id ?? h.callID, onHold: onHold)
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()
        return performed
    }

    // MARK: - Reporting

    @Test(arguments: [true, false])
    func callsAreReportedHoldableAsConfigured(supportsHolding: Bool) async throws {
        let h = CallEngineHarness(supportsHolding: supportsHolding)
        await h.placeCall()
        let ringID = UUID()
        h.ring(callID: ringID) // busy: reported and ended

        #expect(h.provider.holdableCalls[h.callID] == supportsHolding)
        #expect(h.provider.holdableCalls[ringID] == supportsHolding)
    }

    @Test func aCorrectedRingStaysHoldable() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        let id = UUID()
        h.ring(callID: id, displayName: "Someone else") // corrected to the target's name

        #expect(h.provider.updatedCalls.map(\.id) == [id])
        #expect(h.provider.holdableCalls[id] == true)
    }

    // MARK: - Holding and resuming

    @Test func holdClosesTheMicStopsMediaAndTellsTheAgent() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        let state = h.engine.state
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.isAudioAttached)

        let performed = await setHeld(h, true)

        #expect(performed)
        #expect(h.engine.isOnHold)
        #expect(h.engine.state == state) // hold is not a state
        #expect(!h.transport.isMicEnabled)
        #expect(!h.transport.isAudioAttached)
        #expect(h.transport.sentSignals == [.connected, .held])
        #expect(h.delegate.cues.last == .moment(.held))
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func resumeRestartsMediaReopensTheMicAndTellsTheAgent() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        await setHeld(h, true)

        let performed = await setHeld(h, false)

        #expect(performed)
        #expect(!h.engine.isOnHold)
        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
        #expect(Array(h.delegate.cues.suffix(2)) == [.moment(.held), .moment(.resumed)])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func resumeBeforeCallKitReactivatesWaitsForTheActivation() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        await setHeld(h, true)
        h.provider.simulateDeactivate(FakeAudioSession())

        await setHeld(h, false)

        #expect(!h.transport.isAudioAttached)
        #expect(!h.transport.isMicEnabled)

        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()

        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
    }

    @Test func anActivationWhileHeldWaitsForTheResume() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        await setHeld(h, true)
        h.provider.simulateDeactivate(FakeAudioSession())

        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()

        #expect(h.engine.isAudioActivated)
        #expect(!h.transport.isAudioAttached)
        #expect(!h.transport.isMicEnabled)

        await setHeld(h, false)

        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
    }

    @Test func anInterruptionEndingWhileHeldKeepsTheMicClosed() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        h.interruption.simulateBegan()
        await setHeld(h, true)

        h.interruption.simulateEnded(shouldResume: true)
        await h.engine.awaitPendingMediaWork()

        #expect(!h.engine.isInterrupted)
        #expect(!h.transport.isMicEnabled)

        await setHeld(h, false)
        #expect(h.transport.isMicEnabled)
    }

    enum UserMicControl: String, CaseIterable, Sendable {
        case unmuteInApp, unmuteFromTheSystem, pushToTalk
    }

    @Test(arguments: UserMicControl.allCases)
    func theUsersMicControlsWhileHeldTakeEffectOnResume(control: UserMicControl) async throws {
        let h = CallEngineHarness(supportsHolding: true, pushToTalk: control == .pushToTalk)
        await liveCall(h)
        if control != .pushToTalk { await h.engine.setMuted(true) }
        await setHeld(h, true)

        switch control {
        case .unmuteInApp: await h.engine.setMuted(false)
        case .unmuteFromTheSystem: h.provider.simulateSetMuted(h.callID, muted: false)
        case .pushToTalk: await h.engine.setPushToTalkActive(true)
        }
        await h.engine.awaitPendingMediaWork()

        #expect(!h.transport.isMicEnabled)
        #expect(!h.engine.isMuted)

        await setHeld(h, false)
        #expect(h.transport.isMicEnabled)
    }

    @Test func aRepeatedHoldOrResumeChangesNothing() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        #expect(await setHeld(h, false)) // not held: nothing to resume

        await setHeld(h, true)
        #expect(await setHeld(h, true))
        await setHeld(h, false)
        #expect(await setHeld(h, false))

        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
        #expect(h.delegate.cues.filter { $0 == .moment(.held) }.count == 1)
        #expect(h.delegate.cues.filter { $0 == .moment(.resumed) }.count == 1)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    // MARK: - Audio after a resume

    /// A harness whose timers wait until a test fires them.
    private func timedHarness() -> CallEngineHarness {
        CallEngineHarness(supportsHolding: true, sleep: parkedSleep)
    }

    /// Held by the system, CallKit deactivated the audio, and the resume came with
    /// no activation: the call is not held and has no audio.
    private func resumedWithoutAudio(_ h: CallEngineHarness) async {
        await liveCall(h)
        await setHeld(h, true)
        h.provider.simulateDeactivate(FakeAudioSession())
        await setHeld(h, false)
    }

    @Test func aResumeCallKitDoesNotFollowWithAnActivationIsAskedForAgain() async throws {
        let h = timedHarness()
        await resumedWithoutAudio(h)
        #expect(h.engine.isTimerRunning(.activationRecovery))
        let signals = h.transport.sentSignals
        let cues = h.delegate.cues

        #expect(h.engine.fireTimer(.activationRecovery))
        await h.engine.awaitPendingWork()

        // The hold and resume that brought the audio back by hand, silently.
        #expect(h.provider.heldRequests.map(\.onHold) == [true, false])
        #expect(h.provider.heldRequests.allSatisfy { $0.id == h.callID })
        #expect(!h.engine.isOnHold)
        #expect(h.transport.sentSignals == signals)
        #expect(h.delegate.cues == cues)
        #expect(h.engine.isTimerRunning(.activationRecovery)) // the next attempt waits

        await activate(h)

        #expect(!h.engine.isTimerRunning(.activationRecovery))
        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func theRequestIsRepeatedAFewTimesAtMost() async throws {
        let h = timedHarness()
        await resumedWithoutAudio(h)

        var fired = 0
        while h.engine.fireTimer(.activationRecovery) {
            fired += 1
            await h.engine.awaitPendingWork()
            try #require(fired <= 10)
        }

        #expect(fired == CallEngine.activationRecoveryAttemptLimit)
        #expect(h.provider.heldRequests.count == 2 * CallEngine.activationRecoveryAttemptLimit)
        #expect(!h.engine.isOnHold)

        // A new resume from the user starts a new budget.
        await h.engine.setOnHold(true)
        await h.engine.setOnHold(false)
        #expect(h.engine.isTimerRunning(.activationRecovery))
    }

    @Test func theWaitIsTheEnginesSleep() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(supportsHolding: true, sleep: { await sleeper.sleep($0) })
        await resumedWithoutAudio(h)
        await waitUntil { sleeper.pendingCount == 1 }

        #expect(sleeper.requested == [CallEngine.activationRecoveryDelay])
        sleeper.wakeFirst()
        await waitUntil { h.provider.heldRequests.count == 2 }
        #expect(h.provider.heldRequests.map(\.onHold) == [true, false])
    }

    @Test func aResumeWithTheAudioActivatedAsksForNothing() async throws {
        let h = timedHarness()
        await liveCall(h)
        await setHeld(h, true)
        await setHeld(h, false) // CallKit kept the session active

        #expect(!h.engine.isTimerRunning(.activationRecovery))
    }

    @Test func anActivationBeforeTheWaitEndsAsksForNothing() async throws {
        let h = timedHarness()
        await resumedWithoutAudio(h)

        await activate(h)

        #expect(!h.engine.isTimerRunning(.activationRecovery))
        #expect(!h.engine.fireTimer(.activationRecovery))
        #expect(h.provider.heldRequests.isEmpty)
    }

    @Test func aHoldBeforeTheWaitEndsAsksForNothing() async throws {
        let h = timedHarness()
        await resumedWithoutAudio(h)

        await setHeld(h, true)

        #expect(h.engine.isOnHold)
        #expect(!h.engine.isTimerRunning(.activationRecovery))
        #expect(h.provider.heldRequests.isEmpty)
    }

    @Test func theCallEndingStopsTheWait() async throws {
        let h = timedHarness()
        await resumedWithoutAudio(h)

        await h.engine.endCall()

        #expect(!h.engine.isTimerRunning(.activationRecovery))
    }

    /// A hold that lands between the request's own hold and its resume stands: the
    /// request's resume is refused, so CallKit keeps the call held.
    @Test func aHoldDuringTheRequestStands() async throws {
        let h = timedHarness()
        await resumedWithoutAudio(h)
        var injected = false
        h.provider.onEvent = { [h] event in
            guard event == "held-request(false)", !injected else { return }
            injected = true
            h.provider.simulateSetHeld(h.callID, onHold: true) // e.g. the user holds
        }

        #expect(h.engine.fireTimer(.activationRecovery))
        await h.engine.awaitPendingWork()

        #expect(injected)
        #expect(h.engine.isOnHold)
        #expect(!h.engine.isTimerRunning(.activationRecovery))
        #expect(h.delegate.cues.last == .moment(.held))

        // The user's own resume afterwards is performed.
        await h.engine.setOnHold(false)
        #expect(!h.engine.isOnHold)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func aRefusedHoldIsAskedForAgainLater() async throws {
        let h = timedHarness()
        await resumedWithoutAudio(h)
        h.provider.refusesHeldRequests = true

        #expect(h.engine.fireTimer(.activationRecovery))
        await h.engine.awaitPendingWork()

        #expect(!h.engine.isOnHold)
        #expect(h.engine.isTimerRunning(.activationRecovery))
    }

    @Test func noAttemptIsMadeWhileAnotherCallIsActive() async throws {
        let h = timedHarness()
        await resumedWithoutAudio(h)
        h.provider.simulateOtherCallStarted() // e.g. the user resumed during a phone call

        #expect(h.engine.fireTimer(.activationRecovery))
        await h.engine.awaitPendingWork()

        #expect(h.provider.heldRequests.isEmpty)
        #expect(h.engine.isTimerRunning(.activationRecovery)) // it checks again later
    }

    /// A phone call can still be listed a moment after it is hung up. Its end asks
    /// CallKit again at once, rather than waiting for the next check.
    @Test func theOtherCallEndingAsksAtOnce() async throws {
        let h = timedHarness()
        await resumedWithoutAudio(h)
        let other = h.provider.simulateOtherCallStarted()
        #expect(h.engine.fireTimer(.activationRecovery))
        await h.engine.awaitPendingWork()
        #expect(h.provider.heldRequests.isEmpty)

        h.provider.simulateOtherCallEnded(other)
        await h.engine.awaitPendingWork()

        #expect(h.provider.heldRequests.map(\.onHold) == [true, false])
        #expect(!h.engine.isOnHold)
    }

    /// Waiting for another call spends none of the attempts.
    @Test func waitingForAnotherCallSpendsNoAttempt() async throws {
        let h = timedHarness()
        await resumedWithoutAudio(h)
        let other = h.provider.simulateOtherCallStarted()
        for _ in 0..<CallEngine.activationRecoveryAttemptLimit + 2 {
            #expect(h.engine.fireTimer(.activationRecovery))
            await h.engine.awaitPendingWork()
        }
        #expect(h.provider.heldRequests.isEmpty)
        h.provider.simulateOtherCallEnded(other)
        await h.engine.awaitPendingWork()

        var fired = 0
        while h.engine.fireTimer(.activationRecovery) {
            fired += 1
            await h.engine.awaitPendingWork()
        }

        #expect(h.provider.heldRequests.count == 2 * CallEngine.activationRecoveryAttemptLimit)
        #expect(fired == CallEngine.activationRecoveryAttemptLimit - 1) // the end asked once itself
    }

    /// While another call stays active, the engine stops checking after a while.
    @Test func anotherCallThatStaysActiveIsCheckedForABoundedTime() async throws {
        let h = timedHarness()
        await resumedWithoutAudio(h)
        h.provider.simulateOtherCallStarted()

        var fired = 0
        while h.engine.fireTimer(.activationRecovery) {
            fired += 1
            await h.engine.awaitPendingWork()
        }

        #expect(fired == CallEngine.activationRecoveryWaitLimit + 1)
        #expect(h.provider.heldRequests.isEmpty)
    }

    // MARK: - Resuming once the other call ends

    /// iOS holds the call when the user accepts a phone call during it.
    private func heldForAnotherCall(_ h: CallEngineHarness) async -> UUID {
        await liveCall(h)
        let other = h.provider.simulateOtherCallStarted()
        await setHeld(h, true)
        return other
    }

    @Test func aCallTheSystemHeldIsResumedWhenTheOtherCallEnds() async throws {
        let h = timedHarness()
        let other = await heldForAnotherCall(h)
        h.provider.simulateDeactivate(FakeAudioSession())
        #expect(h.engine.isOnHold)

        h.provider.simulateOtherCallEnded(other)
        await h.engine.awaitPendingWork()

        #expect(h.provider.heldRequests.map(\.onHold) == [false])
        #expect(h.provider.heldRequests.allSatisfy { $0.id == h.callID })
        #expect(!h.engine.isOnHold)
        #expect(h.transport.sentSignals == [.connected, .held]) // the user cannot hear yet
        #expect(Array(h.delegate.cues.suffix(2)) == [.moment(.held), .moment(.resumed)])
        #expect(h.engine.isTimerRunning(.activationRecovery)) // the audio is still to come

        await activate(h)
        await h.engine.awaitPendingSignals()
        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func aHoldTheHostAskedForIsNeverResumedByTheEngine() async throws {
        let h = timedHarness()
        await liveCall(h)
        let other = h.provider.simulateOtherCallStarted()
        await h.engine.setOnHold(true)

        h.provider.simulateOtherCallEnded(other)
        await h.engine.awaitPendingWork()

        #expect(h.engine.isOnHold)
        #expect(h.provider.heldRequests.map(\.onHold) == [true])
    }

    @Test func theHostKeepingASystemHoldStopsTheEngineResumingIt() async throws {
        let h = timedHarness()
        let other = await heldForAnotherCall(h)

        await h.engine.setOnHold(true)
        h.provider.simulateOtherCallEnded(other)
        await h.engine.awaitPendingWork()

        #expect(h.engine.isOnHold)
        #expect(h.provider.heldRequests.map(\.onHold) == [true])
    }

    @Test func aThirdCallStillUpKeepsTheCallHeldUntilItEnds() async throws {
        let h = timedHarness()
        let first = await heldForAnotherCall(h)
        let second = h.provider.simulateOtherCallStarted() // call waiting

        h.provider.simulateOtherCallEnded(first)
        await h.engine.awaitPendingWork()
        #expect(h.engine.isOnHold)
        #expect(h.provider.heldRequests.isEmpty)

        h.provider.simulateOtherCallEnded(second)
        await h.engine.awaitPendingWork()
        #expect(!h.engine.isOnHold)
        #expect(h.provider.heldRequests.map(\.onHold) == [false])
    }

    @Test func anOtherCallOnHoldStillKeepsTheCallHeld() async throws {
        let h = timedHarness()
        let first = await heldForAnotherCall(h)
        let second = h.provider.simulateOtherCallStarted()
        h.provider.simulateOtherCallHeld(first, onHold: true)

        h.provider.simulateOtherCallEnded(second)
        await h.engine.awaitPendingWork()

        #expect(h.engine.isOnHold)
        #expect(h.provider.heldRequests.isEmpty)
    }

    @Test func theEnginesOwnCallsAndUnseenCallsChangeNothing() async throws {
        let h = timedHarness()
        _ = await heldForAnotherCall(h)

        h.provider.simulateObservedCallChange(ObservedCall(id: h.callID, hasEnded: true, isOnHold: false))
        h.provider.simulateObservedCallChange(ObservedCall(id: UUID(), hasEnded: true, isOnHold: false))
        await h.engine.awaitPendingWork()

        #expect(h.engine.isOnHold)
        #expect(h.provider.heldRequests.isEmpty)
    }

    @Test func aSystemHoldWithNoOtherCallSeenStaysHeld() async throws {
        let h = timedHarness()
        await liveCall(h)
        let earlier = h.provider.simulateOtherCallStarted()
        h.provider.simulateOtherCallEnded(earlier) // before the hold
        await setHeld(h, true) // the user held from the system call screen

        h.provider.simulateOtherCallEnded(earlier)
        await h.engine.awaitPendingWork()

        #expect(h.engine.isOnHold)
        #expect(h.provider.heldRequests.isEmpty)
    }

    @Test func aCallThatStartsDuringTheHoldCounts() async throws {
        let h = timedHarness()
        await liveCall(h)
        await setHeld(h, true)
        let other = h.provider.simulateOtherCallStarted()

        h.provider.simulateOtherCallEnded(other)
        await h.engine.awaitPendingWork()

        #expect(!h.engine.isOnHold)
    }

    @Test func turnedOffTheCallStaysHeld() async throws {
        let h = CallEngineHarness(supportsHolding: true, resumesAfterSystemHold: false, sleep: parkedSleep)
        let other = await heldForAnotherCall(h)

        h.provider.simulateOtherCallEnded(other)
        await h.engine.awaitPendingWork()

        #expect(h.engine.isOnHold)
        #expect(h.provider.heldRequests.isEmpty)
    }

    @Test func anOtherCallDeclinedWithoutAHoldChangesNothing() async throws {
        let h = timedHarness()
        await liveCall(h)
        let other = h.provider.simulateOtherCallStarted()

        h.provider.simulateOtherCallEnded(other)
        await h.engine.awaitPendingWork()

        #expect(!h.engine.isOnHold)
        #expect(h.provider.heldRequests.isEmpty)
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected])
    }

    @Test func aResumeAlreadyMadeByTheUserIsNotRequestedAgain() async throws {
        let h = timedHarness()
        let other = await heldForAnotherCall(h)
        await setHeld(h, false) // the user resumed from the system call screen

        h.provider.simulateOtherCallEnded(other)
        await h.engine.awaitPendingWork()

        #expect(h.provider.heldRequests.isEmpty)
        #expect(!h.engine.isOnHold)
    }

    @Test func aCallThatEndedIsNotResumed() async throws {
        let h = timedHarness()
        let other = await heldForAnotherCall(h)
        h.provider.simulateEndCall(h.callID)

        h.provider.simulateOtherCallEnded(other)
        await h.engine.awaitPendingWork()

        #expect(h.provider.heldRequests.isEmpty)
        #expect(h.delegate.records.count == 1)
    }

    // MARK: - Refusals (the action names the call; the call must be holdable)

    @Test func holdForAnotherCallIsRefused() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)

        let performed = await setHeld(h, true, id: UUID()) // e.g. a busy ring's id

        #expect(!performed)
        #expect(!h.engine.isOnHold)
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected])
    }

    @Test func holdIsRefusedWhenHoldingIsTurnedOff() async throws {
        let h = CallEngineHarness(supportsHolding: false)
        await liveCall(h)

        #expect(!(await setHeld(h, true)))
        await h.engine.setOnHold(true)

        #expect(h.provider.heldRequests.isEmpty)
        #expect(!h.engine.isOnHold)
        #expect(h.transport.isMicEnabled)
    }

    @Test func aRingingCallCannotBeHeld() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        let id = UUID()
        h.ring(callID: id)

        #expect(!(await setHeld(h, true, id: id)))
        #expect(!h.engine.isOnHold)
        #expect(h.engine.state == .incomingRinging)
    }

    @Test func anEndedCallCannotBeResumed() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        await setHeld(h, true)
        await h.engine.endCall()

        #expect(!h.engine.isOnHold)
        #expect(!(await setHeld(h, false)))
    }

    // MARK: - The host's hold

    @Test func setOnHoldAsksCallKitWhichPerformsIt() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)

        await h.engine.setOnHold(true)

        #expect(h.provider.heldRequests.map(\.id) == [h.callID])
        #expect(h.provider.heldRequests.map(\.onHold) == [true])
        #expect(h.engine.isOnHold)
        #expect(!h.transport.isMicEnabled)

        await h.engine.setOnHold(false)

        #expect(h.provider.heldRequests.map(\.onHold) == [true, false])
        #expect(!h.engine.isOnHold)
        #expect(h.transport.isMicEnabled)
    }

    @Test func setOnHoldWithNoCallAsksNothing() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await h.engine.setOnHold(true)

        h.ring()
        await h.engine.setOnHold(true)

        #expect(h.provider.heldRequests.isEmpty)
        #expect(!h.engine.isOnHold)
    }

    // MARK: - Reconnection waits for the resume

    @Test func aDropWhileHeldWaitsForTheResumeThenRetriesAtOnce() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(supportsHolding: true, sleep: { await sleeper.sleep($0) })
        await liveCall(h)
        await setHeld(h, true)

        h.engine.handle(.disconnected(reason: .networkDropped))
        await settle()

        #expect(h.engine.state == .reconnecting(attempt: 0))
        #expect(sleeper.requested.isEmpty)
        #expect(h.target.connectCount == 1)

        await setHeld(h, false)
        await waitUntil { h.target.connectCount == 2 }

        #expect(h.engine.state == .reconnecting(attempt: 1))
        #expect(h.target.connectCount == 2)
        #expect(sleeper.requested.isEmpty) // attempt 1 runs at once

        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func holdPausesAPendingRetryAndResumeRestartsAtAttemptOne() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(supportsHolding: true, sleep: { await sleeper.sleep($0) })
        await liveCall(h)
        h.engine.handle(.disconnected(reason: .networkDropped))
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.wakeFirst()
        await h.engine.awaitPendingReconnect() // attempt 1 ran
        h.engine.handle(.disconnected(reason: .networkDropped))
        await waitUntil { sleeper.pendingCount == 1 } // attempt 2's backoff
        #expect(h.engine.state == .reconnecting(attempt: 2))
        let connects = h.target.connectCount

        await setHeld(h, true)
        #expect(h.engine.state == .reconnecting(attempt: 0))
        sleeper.wakeAll() // the paused retries' backoffs end
        await settle()
        #expect(h.target.connectCount == connects)

        await setHeld(h, false)
        await waitUntil { h.target.connectCount == connects + 1 }

        #expect(h.engine.state == .reconnecting(attempt: 1))
        #expect(h.target.connectCount == connects + 1)
    }

    @Test func aSelfHealThatOutlastsItsDeadlineWhileHeldWaitsForTheResume() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(supportsHolding: true, sleep: { await sleeper.sleep($0) })
        await liveCall(h)
        await setHeld(h, true)

        h.engine.handle(.reconnecting)
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.wakeFirst() // the self-heal deadline passes
        await settle()

        #expect(h.engine.state == .reconnecting(attempt: 0))
        #expect(sleeper.requested.count == 1) // no backoff was started
        #expect(h.target.connectCount == 1)

        await setHeld(h, false)
        await waitUntil { h.target.connectCount == 2 }
        #expect(h.engine.state == .reconnecting(attempt: 1))
    }

    @Test func aTransportThatRecoversWhileHeldNeedsNoRetry() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(supportsHolding: true, sleep: { await sleeper.sleep($0) })
        await liveCall(h)
        await setHeld(h, true)
        h.engine.handle(.disconnected(reason: .networkDropped))

        h.engine.handle(.connected)
        await setHeld(h, false)
        await settle()

        #expect(h.engine.state.isConnected)
        #expect(h.target.connectCount == 1)
        #expect(sleeper.requested.isEmpty)
    }

    // MARK: - Telling the agent

    /// `call-resumed` tells the agent the user can hear it again, so it follows the
    /// attach the resume issued (Daily subscribes to the agent's audio there).
    @Test func aResumeReachesTheAgentAfterTheAttach() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        await setHeld(h, true)
        h.transport.suspendAttach = true

        h.provider.simulateSetHeld(h.callID, onHold: false)
        await waitUntil { h.transport.pendingAttachCount == 1 }
        await settle()
        #expect(h.transport.sentSignals == [.connected, .held])

        h.transport.releaseAttach()
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()
        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
    }

    /// `call-resumed` says the user can hear and speak again, which is true only
    /// once CallKit has activated the resumed call's audio.
    @Test func aResumeBeforeTheActivationTellsTheAgentAtTheActivation() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        await setHeld(h, true)
        h.provider.simulateDeactivate(FakeAudioSession())

        await setHeld(h, false)
        #expect(h.transport.sentSignals == [.connected, .held])

        await activate(h)
        await h.engine.awaitPendingSignals()
        #expect(h.transport.isAudioAttached)
        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
    }

    /// Asking CallKit again for the audio tells the agent nothing; the activation
    /// it brings does.
    @Test func aResumeWhoseActivationIsAskedForAgainTellsTheAgentAtTheActivation() async throws {
        let h = timedHarness()
        await liveCall(h)
        await setHeld(h, true)
        h.provider.simulateDeactivate(FakeAudioSession())
        await setHeld(h, false)
        #expect(h.engine.fireTimer(.activationRecovery))
        await h.engine.awaitPendingWork()
        #expect(h.transport.sentSignals == [.connected, .held])

        await activate(h)
        await h.engine.awaitPendingSignals()
        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
    }

    /// A call held again before the activation came never says it was back.
    @Test func aResumeHeldAgainBeforeTheActivationTellsTheAgentNothing() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        await setHeld(h, true)
        h.provider.simulateDeactivate(FakeAudioSession())
        await setHeld(h, false)
        await setHeld(h, true)
        await activate(h)
        await h.engine.awaitPendingSignals()

        #expect(h.transport.sentSignals == [.connected, .held])
    }

    @Test func aHeldCallTellsTheAgentAgainAfterEveryReconnect() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        await setHeld(h, true)
        h.engine.handle(.disconnected(reason: .networkDropped))

        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()
        await h.engine.awaitPendingMediaWork()

        #expect(h.transport.sentSignals == [.connected, .held, .held])
        #expect(!h.transport.isMicEnabled)
    }

    @Test func aResumeWhileDisconnectedReachesTheAgentOnReconnect() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        await setHeld(h, true)
        h.engine.handle(.disconnected(reason: .networkDropped))

        await setHeld(h, false)
        #expect(h.transport.sentSignals == [.connected, .held]) // nobody to tell yet

        await h.engine.awaitPendingReconnect()
        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()

        #expect(h.transport.sentSignals == [.connected, .held, .resumed, .connected])
    }

    /// The device is in the room once its connect returns, and an agent there may
    /// already be counting down to a greeting: a hold while the call still shows
    /// connecting reaches it at once, and the call showing connected later tells it
    /// nothing twice.
    @Test func aHoldWhileConnectingReachesTheAgentAtOnce() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await h.placeCall()
        await h.engine.activate(FakeAudioSession())

        await setHeld(h, true)
        #expect(h.engine.state.isConnecting)
        #expect(h.transport.sentSignals == [.held])
        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.held)])

        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()
        await h.engine.awaitPendingMediaWork()

        #expect(h.engine.state.isConnected)
        #expect(h.transport.sentSignals == [.held])
        #expect(!h.transport.isMicEnabled)
        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.held)]) // quiet while held

        await setHeld(h, false)
        #expect(h.transport.sentSignals == [.held, .resumed, .connected])
        #expect(h.transport.isMicEnabled)
        #expect(Array(h.delegate.cues.suffix(2)) == [.moment(.resumed), .moment(.connected)])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    /// A placed call whose agent is ready shows connecting for the rest of the
    /// minimum; a hold then reaches the agent, which is in the room, at once.
    @Test func aHoldDuringTheOutgoingMinimumReachesTheAgentAtOnce() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(supportsHolding: true, 
            minimumOutgoingConnectingDuration: .seconds(3), sleep: { await sleeper.sleep($0) }
        )
        await h.placeCall()
        await h.engine.activate(FakeAudioSession())
        h.engine.handle(.connected)
        #expect(h.engine.isTimerRunning(.minimumOutgoingConnecting))

        await setHeld(h, true)
        #expect(h.engine.state.isConnecting)
        #expect(h.transport.sentSignals == [.held])

        await setHeld(h, false)
        #expect(h.transport.sentSignals == [.held, .resumed])
        #expect(h.engine.state.isConnecting) // the minimum runs again from the resume

        #expect(h.engine.fireTimer(.minimumOutgoingConnecting))
        await h.engine.awaitPendingWork()
        #expect(h.engine.state.isConnected)
        #expect(h.transport.sentSignals == [.held, .resumed, .connected])
    }

    /// Before the join there is nothing to tell the agent over; the join tells it.
    @Test func aHoldBeforeTheJoinReachesTheAgentAtTheJoin() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        h.target.suspend = true
        let placing = Task { await h.placeCall() }
        await waitUntil { h.target.pendingCount == 1 }
        await h.engine.activate(FakeAudioSession())

        await setHeld(h, true)
        #expect(h.transport.sentSignals.isEmpty)

        h.target.release()
        await placing.value
        await h.engine.awaitPendingSignals()
        #expect(h.engine.state.isConnecting)
        #expect(h.transport.sentSignals == [.held])
    }

    /// An answered ring still connecting: the agent the ring started is told too.
    @Test func aHoldOfAnAnsweredCallStillConnectingReachesTheAgentAtOnce() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        h.ring(callID: h.callID)
        await h.engine.answer()
        await h.engine.activate(FakeAudioSession())

        await setHeld(h, true)
        #expect(h.engine.state.isConnecting)
        #expect(h.transport.sentSignals == [.held])

        h.engine.handle(.connected) // the agent became ready during the hold
        await h.engine.awaitPendingSignals()
        #expect(h.transport.sentSignals == [.held])

        await setHeld(h, false)
        #expect(h.transport.sentSignals == [.held, .resumed, .connected])
    }

    @Test func aHeldSignalStillQueuedWhenTheCallEndsDoesNotReachTheNextCall() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        let first = h.transport

        h.provider.simulateSetHeld(h.callID, onHold: true)
        h.provider.simulateEndCall(h.callID) // ends before the queued signal runs
        h.engine.reset()
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()

        #expect(h.transport !== first)
        #expect(first.sentSignals.isEmpty)
        #expect(h.transport.sentSignals.isEmpty)
        #expect(!h.engine.isOnHold)
    }

    // MARK: - Cues

    @Test func holdStopsTheRetryingLoopAndResumeRestartsIt() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        h.engine.handle(.reconnecting) // a self-heal: connectionLost, start(retrying)

        await setHeld(h, true)
        #expect(h.engine.repeatingCue == nil)
        await setHeld(h, false)
        h.engine.handle(.connected)

        #expect(Array(h.delegate.cues.dropFirst(3)) == [
            .moment(.connectionLost), .start(.retrying),
            .stop, .moment(.held),
            .moment(.resumed), .start(.retrying),
            .stop, .moment(.reconnected),
        ])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func anOutageThatStartsWhileHeldIsMarkedOnResume() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        await setHeld(h, true)
        h.engine.handle(.reconnecting)

        await setHeld(h, false)
        h.engine.handle(.connected)

        #expect(Array(h.delegate.cues.dropFirst(3)) == [
            .moment(.held),
            .moment(.resumed), .moment(.connectionLost), .start(.retrying),
            .stop, .moment(.reconnected),
        ])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func aCallThatConnectsWhileHeldIsMarkedConnectedOnce() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await h.placeCall()
        await h.engine.activate(FakeAudioSession())
        await setHeld(h, true)
        h.engine.handle(.connected)
        await setHeld(h, false)
        await setHeld(h, true)
        await setHeld(h, false)

        #expect(h.delegate.cues.filter { $0 == .moment(.connected) }.count == 1)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func anOutageThatHealsWhileHeldIsNotMarked() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        await setHeld(h, true)
        h.engine.handle(.reconnecting)
        h.engine.handle(.connected)

        await setHeld(h, false)

        #expect(Array(h.delegate.cues.dropFirst(3)) == [.moment(.held), .moment(.resumed)])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    // MARK: - Ending and the record

    @Test func endingWhileHeldRecordsOnceWithTheHeldTime() async throws {
        let clock = MutableClock()
        let h = CallEngineHarness(supportsHolding: true, now: { clock.now() })
        await liveCall(h)
        clock.advance(10)
        await setHeld(h, true)
        clock.advance(100)

        h.provider.simulateEndCall(h.callID)
        h.provider.simulateEndCall(h.callID) // CallKit's own round-trip

        #expect(h.delegate.records.count == 1)
        #expect(h.delegate.records.first?.duration == 110)
        #expect(h.delegate.records.first?.outcome == .completed)
        #expect(!h.engine.isOnHold)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func aProviderResetWhileHeldFailsTheCallOnce() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        await setHeld(h, true)

        h.provider.simulateReset()

        #expect(h.engine.state == .failed(.unknown))
        #expect(h.delegate.records.count == 1)
        #expect(!h.engine.isOnHold)
        #expect(h.delegate.cueViolations.isEmpty)
    }
}
