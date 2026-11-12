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
        let h = CallEngineHarness()
        let id = UUID()
        h.ring(callID: id, displayName: "Someone else") // corrected to the target's name

        #expect(h.provider.updatedCalls.map(\.id) == [id])
        #expect(h.provider.holdableCalls[id] == true)
    }

    // MARK: - Holding and resuming

    @Test func holdClosesTheMicStopsMediaAndTellsTheAgent() async throws {
        let h = CallEngineHarness()
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
        #expect(h.transport.sentSignals == [.held])
        #expect(h.delegate.cues.last == .moment(.held))
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func resumeRestartsMediaReopensTheMicAndTellsTheAgent() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        await setHeld(h, true)

        let performed = await setHeld(h, false)

        #expect(performed)
        #expect(!h.engine.isOnHold)
        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.held, .resumed])
        #expect(Array(h.delegate.cues.suffix(2)) == [.moment(.held), .moment(.resumed)])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func resumeBeforeCallKitReactivatesWaitsForTheActivation() async throws {
        let h = CallEngineHarness()
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
        let h = CallEngineHarness()
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
        let h = CallEngineHarness()
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
        let h = CallEngineHarness(pushToTalk: control == .pushToTalk)
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
        let h = CallEngineHarness()
        await liveCall(h)
        #expect(await setHeld(h, false)) // not held: nothing to resume

        await setHeld(h, true)
        #expect(await setHeld(h, true))
        await setHeld(h, false)
        #expect(await setHeld(h, false))

        #expect(h.transport.sentSignals == [.held, .resumed])
        #expect(h.delegate.cues.filter { $0 == .moment(.held) }.count == 1)
        #expect(h.delegate.cues.filter { $0 == .moment(.resumed) }.count == 1)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    // MARK: - Refusals (the action names the call; the call must be holdable)

    @Test func holdForAnotherCallIsRefused() async throws {
        let h = CallEngineHarness()
        await liveCall(h)

        let performed = await setHeld(h, true, id: UUID()) // e.g. a busy ring's id

        #expect(!performed)
        #expect(!h.engine.isOnHold)
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals.isEmpty)
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
        let h = CallEngineHarness()
        let id = UUID()
        h.ring(callID: id)

        #expect(!(await setHeld(h, true, id: id)))
        #expect(!h.engine.isOnHold)
        #expect(h.engine.state == .incomingRinging)
    }

    @Test func anEndedCallCannotBeResumed() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        await setHeld(h, true)
        await h.engine.endCall()

        #expect(!h.engine.isOnHold)
        #expect(!(await setHeld(h, false)))
    }

    // MARK: - The host's hold

    @Test func setOnHoldAsksCallKitWhichPerformsIt() async throws {
        let h = CallEngineHarness()
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
        let h = CallEngineHarness()
        await h.engine.setOnHold(true)

        h.ring()
        await h.engine.setOnHold(true)

        #expect(h.provider.heldRequests.isEmpty)
        #expect(!h.engine.isOnHold)
    }

    // MARK: - Reconnection waits for the resume

    @Test func aDropWhileHeldWaitsForTheResumeThenRetriesAtOnce() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(sleep: { await sleeper.sleep($0) })
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
        let h = CallEngineHarness(sleep: { await sleeper.sleep($0) })
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
        let h = CallEngineHarness(sleep: { await sleeper.sleep($0) })
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
        let h = CallEngineHarness(sleep: { await sleeper.sleep($0) })
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
        let h = CallEngineHarness()
        await liveCall(h)
        await setHeld(h, true)
        h.transport.suspendAttach = true

        h.provider.simulateSetHeld(h.callID, onHold: false)
        await waitUntil { h.transport.pendingAttachCount == 1 }
        await settle()
        #expect(h.transport.sentSignals == [.held])

        h.transport.releaseAttach()
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()
        #expect(h.transport.sentSignals == [.held, .resumed])
    }

    @Test func aHeldCallTellsTheAgentAgainAfterEveryReconnect() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        await setHeld(h, true)
        h.engine.handle(.disconnected(reason: .networkDropped))

        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()
        await h.engine.awaitPendingMediaWork()

        #expect(h.transport.sentSignals == [.held, .held])
        #expect(!h.transport.isMicEnabled)
    }

    @Test func aResumeWhileDisconnectedReachesTheAgentOnReconnect() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        await setHeld(h, true)
        h.engine.handle(.disconnected(reason: .networkDropped))

        await setHeld(h, false)
        #expect(h.transport.sentSignals == [.held]) // nobody to tell yet

        await h.engine.awaitPendingReconnect()
        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()

        #expect(h.transport.sentSignals == [.held, .resumed])
    }

    @Test func aHoldBeforeConnectingReachesTheAgentOnceConnected() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        await h.engine.activate(FakeAudioSession())

        await setHeld(h, true)
        #expect(h.transport.sentSignals.isEmpty)
        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.held)])

        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()
        await h.engine.awaitPendingMediaWork()

        #expect(h.engine.state.isConnected)
        #expect(h.transport.sentSignals == [.held])
        #expect(!h.transport.isMicEnabled)
        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.held)]) // quiet while held

        await setHeld(h, false)
        #expect(h.transport.sentSignals == [.held, .resumed])
        #expect(h.transport.isMicEnabled)
        #expect(Array(h.delegate.cues.suffix(2)) == [.moment(.resumed), .moment(.connected)])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func aHeldSignalStillQueuedWhenTheCallEndsDoesNotReachTheNextCall() async throws {
        let h = CallEngineHarness()
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
        let h = CallEngineHarness()
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
        let h = CallEngineHarness()
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
        let h = CallEngineHarness()
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
        let h = CallEngineHarness()
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
        let h = CallEngineHarness(now: { clock.now() })
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
        let h = CallEngineHarness()
        await liveCall(h)
        await setHeld(h, true)

        h.provider.simulateReset()

        #expect(h.engine.state == .failed(.unknown))
        #expect(h.delegate.records.count == 1)
        #expect(!h.engine.isOnHold)
        #expect(h.delegate.cueViolations.isEmpty)
    }
}
