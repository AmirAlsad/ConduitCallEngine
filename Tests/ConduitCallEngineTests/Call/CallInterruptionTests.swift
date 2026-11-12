//
//  CallInterruptionTests.swift
//  ConduitCallEngineTests
//
//  Audio-interruption handling: a transient takeover (Siri, navigation, a phone
//  call) pauses the mic while interrupted and re-applies the correct mic state on
//  resume — respecting mute and push-to-talk. Driven through the fake observer at
//  simulator speed; the live audio behavior is device-only.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct CallInterruptionTests {

    /// Place + connect + activate so the mic is live before the interruption.
    private func connectedCall(pushToTalk: Bool = false) async -> CallEngineHarness {
        let h = CallEngineHarness(pushToTalk: pushToTalk)
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.activate(FakeAudioSession())
        return h
    }

    @Test func observingStartsOnPlaceCallAndStopsOnEnd() async throws {
        let h = CallEngineHarness()
        #expect(!h.interruption.isObserving)

        await h.placeCall()
        #expect(h.interruption.isObserving)

        await h.engine.endCall()
        #expect(!h.interruption.isObserving)
    }

    @Test func interruptionBeganPausesMic() async throws {
        let h = await connectedCall()
        #expect(h.transport.isMicEnabled)

        h.interruption.simulateBegan()

        #expect(h.engine.isInterrupted)
        await waitUntil { !h.transport.isMicEnabled }
        #expect(!h.transport.isMicEnabled)
    }

    @Test func interruptionEndedWithResumeReenablesMic() async throws {
        let h = await connectedCall()
        h.interruption.simulateBegan()
        await waitUntil { !h.transport.isMicEnabled }

        h.interruption.simulateEnded(shouldResume: true)

        #expect(!h.engine.isInterrupted)
        await waitUntil { h.transport.isMicEnabled }
        #expect(h.transport.isMicEnabled)
    }

    @Test func interruptionEndedWithoutResumeStaysPaused() async throws {
        let h = await connectedCall()
        h.interruption.simulateBegan()
        await waitUntil { !h.transport.isMicEnabled }

        h.interruption.simulateEnded(shouldResume: false)
        await h.engine.awaitPendingMediaWork()

        #expect(h.engine.isInterrupted) // until CallKit activates the session again
        #expect(!h.transport.isMicEnabled) // not auto-resumed
    }

    @Test func resumeRespectsMute() async throws {
        let h = await connectedCall()
        await h.engine.setMuted(true)
        #expect(!h.transport.isMicEnabled)

        h.interruption.simulateBegan()
        h.interruption.simulateEnded(shouldResume: true)

        // Yield for the async re-apply, then confirm mute survived the interruption.
        await waitUntil { !h.engine.isInterrupted }
        #expect(h.engine.isMuted)
        #expect(!h.transport.isMicEnabled)
    }

    @Test func resumeKeepsMicOffInPushToTalk() async throws {
        let h = await connectedCall(pushToTalk: true)
        #expect(!h.transport.isMicEnabled) // PTT holds the mic closed

        h.interruption.simulateBegan()
        h.interruption.simulateEnded(shouldResume: true)

        await waitUntil { !h.engine.isInterrupted }
        #expect(!h.transport.isMicEnabled)
    }

    // MARK: - The user's mic controls are gated too

    enum Unmute: String, CaseIterable, Sendable {
        case inApp, fromTheSystem
    }

    private func unmute(_ h: CallEngineHarness, _ how: Unmute) async {
        switch how {
        case .inApp:
            await h.engine.setMuted(true)
            await h.engine.setMuted(false)
        case .fromTheSystem:
            h.engine.providerPerformSetMuted(h.callID, muted: true)
            h.engine.providerPerformSetMuted(h.callID, muted: false)
            let calls = h.transport.setMicEnabledCallCount
            await waitUntil { h.transport.setMicEnabledCallCount >= calls + 2 }
        }
    }

    @Test(arguments: Unmute.allCases)
    func unmuteBeforeActivationKeepsTheMicClosed(how: Unmute) async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        await unmute(h, how)

        #expect(!h.engine.isMuted)
        #expect(!h.transport.isMicEnabled)

        await h.engine.activate(FakeAudioSession())
        #expect(h.transport.isMicEnabled)
    }

    @Test(arguments: Unmute.allCases)
    func unmuteDuringAnInterruptionKeepsTheMicClosed(how: Unmute) async throws {
        let h = await connectedCall()
        h.interruption.simulateBegan()
        await waitUntil { !h.transport.isMicEnabled }

        await unmute(h, how)

        #expect(!h.engine.isMuted)
        #expect(!h.transport.isMicEnabled)

        h.interruption.simulateEnded(shouldResume: true)
        await waitUntil { h.transport.isMicEnabled }
        #expect(h.transport.isMicEnabled)
    }

    @Test func pushToTalkBeforeActivationKeepsTheMicClosed() async throws {
        let h = CallEngineHarness(pushToTalk: true)
        await h.placeCall()
        h.engine.handle(.connected)

        await h.engine.setPushToTalkActive(true)
        #expect(!h.transport.isMicEnabled)

        // Still held when CallKit activates the session: the user is talking.
        await h.engine.activate(FakeAudioSession())
        #expect(h.transport.isMicEnabled)

        await h.engine.setPushToTalkActive(false)
        #expect(!h.transport.isMicEnabled)
    }

    @Test func pushToTalkDuringAnInterruptionKeepsTheMicClosed() async throws {
        let h = await connectedCall(pushToTalk: true)
        h.interruption.simulateBegan()

        await h.engine.setPushToTalkActive(true)
        await waitUntil { h.transport.setMicEnabledCallCount > 0 && !h.transport.isMicEnabled }
        #expect(!h.transport.isMicEnabled)

        h.interruption.simulateEnded(shouldResume: true)
        await waitUntil { h.transport.isMicEnabled }
        #expect(h.transport.isMicEnabled) // still held

        await h.engine.setPushToTalkActive(false)
        #expect(!h.transport.isMicEnabled)
    }

    @Test func connectingDuringAnInterruptionKeepsTheMicClosed() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        await h.engine.activate(FakeAudioSession()) // CallKit activated before the join
        h.interruption.simulateBegan()
        await waitUntil { h.transport.setMicEnabledCallCount >= 2 }
        let calls = h.transport.setMicEnabledCallCount

        h.engine.handle(.connected)
        await waitUntil { h.transport.setMicEnabledCallCount > calls }

        #expect(h.transport.setMicEnabledCallCount > calls)
        #expect(!h.transport.isMicEnabled)
    }

    @Test func endedWithoutBeganIsIgnored() async throws {
        let h = await connectedCall()
        #expect(h.transport.isMicEnabled)

        h.interruption.simulateEnded(shouldResume: true) // no preceding interruption

        #expect(!h.engine.isInterrupted)
        #expect(h.transport.isMicEnabled)
    }
}
