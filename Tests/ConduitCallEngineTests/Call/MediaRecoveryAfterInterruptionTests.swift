//
//  MediaRecoveryAfterInterruptionTests.swift
//  ConduitCallEngineTests
//
//  The attach that follows a real audio interruption: when an interruption was in
//  progress while the call's media was detached (a hold, CallKit's deactivation),
//  the engine asks the transport to recover its media once, after that attach and
//  its mic command and before the signal that tells the agent the user is back, and
//  runs the experimental session recovery, if one is chosen, before that attach.
//  Whether any recovery brings real audio back is device-only.
//

import Foundation
import Testing
@_spi(InterruptionRecoveryExperiment) @testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct MediaRecoveryAfterInterruptionTests {

    /// Placed, connected and activated: the mic is live and media attached.
    private func liveCall(_ h: CallEngineHarness) async {
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.activate(FakeAudioSession())
        await h.engine.awaitPendingWork()
    }

    @discardableResult
    private func setHeld(_ h: CallEngineHarness, _ onHold: Bool) async -> Bool {
        let performed = h.provider.simulateSetHeld(h.callID, onHold: onHold)
        await h.engine.awaitPendingWork()
        return performed
    }

    private func activate(_ h: CallEngineHarness, _ session: FakeAudioSession? = nil) async {
        h.provider.simulateActivate(session ?? FakeAudioSession())
        await h.engine.awaitPendingWork()
    }

    /// The sequence a phone call brought on one device: iOS holds the call, the
    /// interruption begins, CallKit deactivates the session; the phone call ends,
    /// the call is resumed, and CallKit activates the session again.
    private func phoneCallDuringTheCall(_ h: CallEngineHarness, session: FakeAudioSession? = nil) async {
        await setHeld(h, true)
        h.interruption.simulateBegan()
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingWork()
        await setHeld(h, false)
        await activate(h, session)
    }

    @Test func theAttachAfterAPhoneCallAsksTheTransportToRecoverBeforeTheResumeIsSent() async throws {
        let h = CallEngineHarness()
        await liveCall(h)

        await phoneCallDuringTheCall(h)

        #expect(h.transport.mediaRecoveryCount == 1)
        #expect(Array(h.transport.commands.suffix(4)) == [.attach, .mic(true), .recoverMediaAfterInterruption, .send(.resumed)])
        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
    }

    @Test func anInterruptionThatBeganBeforeTheHoldCountsToo() async throws {
        let h = CallEngineHarness()
        await liveCall(h)

        h.interruption.simulateBegan()
        await setHeld(h, true)
        await setHeld(h, false)

        // The interruption's end never came, so the mic stays closed.
        #expect(h.transport.mediaRecoveryCount == 1)
        #expect(Array(h.transport.commands.suffix(4)) == [.attach, .mic(false), .recoverMediaAfterInterruption, .send(.resumed)])
    }

    @Test func anActivationDuringTheHoldRecoversAtTheResume() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        await setHeld(h, true)
        h.interruption.simulateBegan()
        h.provider.simulateDeactivate(FakeAudioSession())
        await activate(h)
        #expect(h.transport.mediaRecoveryCount == 0) // still held: nothing attached

        await setHeld(h, false)

        #expect(h.transport.mediaRecoveryCount == 1)
        #expect(Array(h.transport.commands.suffix(4)) == [.attach, .mic(true), .recoverMediaAfterInterruption, .send(.resumed)])
    }

    @Test func aHoldWithNoInterruptionAsksForNothing() async throws {
        let h = CallEngineHarness()
        await liveCall(h)

        await setHeld(h, true)
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingWork()
        await setHeld(h, false)
        await activate(h)

        #expect(h.transport.mediaRecoveryCount == 0)
        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
    }

    @Test func anInterruptionWhileAttachedAsksForNothing() async throws {
        let h = CallEngineHarness()
        await liveCall(h)

        h.interruption.simulateBegan()
        h.interruption.simulateEnded(shouldResume: true)
        await h.engine.awaitPendingWork()
        await setHeld(h, true)
        await setHeld(h, false)

        #expect(h.transport.mediaRecoveryCount == 0)
    }

    @Test func itIsAskedOnceForOneInterruption() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        await phoneCallDuringTheCall(h)

        await setHeld(h, true)
        await setHeld(h, false)

        #expect(h.transport.mediaRecoveryCount == 1)
    }

    @Test func aCallHeldAgainBeforeItsAttachRecoversAtTheAttachThatComes() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        await setHeld(h, true)
        h.interruption.simulateBegan()
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingWork()
        await setHeld(h, false)
        await setHeld(h, true)
        await activate(h)
        #expect(h.transport.mediaRecoveryCount == 0)

        await setHeld(h, false)

        #expect(h.transport.mediaRecoveryCount == 1)
    }

    @Test func aCallThatEndsInterruptedLeavesTheNextCallAlone() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        await setHeld(h, true)
        h.interruption.simulateBegan()
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.endCall()
        await h.engine.awaitPendingWork()
        let first = h.transport
        h.engine.reset()

        await liveCall(h)
        let second = h.transport
        #expect(second !== first)
        await setHeld(h, true)
        await setHeld(h, false)

        #expect(first.mediaRecoveryCount == 0)
        #expect(second.mediaRecoveryCount == 0)
    }

    // MARK: - The experimental session recovery

    @Test(arguments: [
        (SessionInterruptionRecovery.off, 0, 0),
        (.reapplyCategory, 1, 0),
        (.reapplyCategoryAndActivate, 1, 1),
    ])
    func theSessionRecoveryChosenRunsOnTheActivatedSession(
        recovery: SessionInterruptionRecovery,
        reapplies: Int,
        activations: Int
    ) async throws {
        let h = CallEngineHarness()
        h.engine.sessionInterruptionRecovery = { recovery }
        await liveCall(h)
        let session = FakeAudioSession()

        await phoneCallDuringTheCall(h, session: session)

        #expect(session.reapplyCount == reapplies)
        #expect(session.activateCount == activations)
        #expect(h.transport.mediaRecoveryCount == 1)
    }

    @Test func theSessionRecoveryRunsBeforeTheAttach() async throws {
        let h = CallEngineHarness()
        h.engine.sessionInterruptionRecovery = { .reapplyCategoryAndActivate }
        await liveCall(h)
        await setHeld(h, true)
        h.interruption.simulateBegan()
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingWork()
        await setHeld(h, false)
        h.transport.suspendAttach = true
        let session = FakeAudioSession()

        h.provider.simulateActivate(session)
        await waitUntil { h.transport.pendingAttachCount == 1 }

        #expect(session.reapplyCount == 1)
        #expect(session.activateCount == 1)
        h.transport.releaseAttach()
        await h.engine.awaitPendingWork()
        #expect(h.transport.mediaRecoveryCount == 1)
    }

    @Test(arguments: [SessionInterruptionRecovery.reapplyCategory, .reapplyCategoryAndActivate])
    func noSessionRecoveryWithoutAnInterruption(recovery: SessionInterruptionRecovery) async throws {
        let h = CallEngineHarness()
        h.engine.sessionInterruptionRecovery = { recovery }
        await liveCall(h)
        let session = FakeAudioSession()

        await setHeld(h, true)
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingWork()
        await setHeld(h, false)
        await activate(h, session)

        #expect(session.reapplyCount == 0)
        #expect(session.activateCount == 0)
    }
}
