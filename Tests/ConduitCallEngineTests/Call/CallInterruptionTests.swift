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
        await h.engine.activate(FakeAudioSession(hasExternalAudioRoute: false))
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

        #expect(!h.engine.isInterrupted)
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

    @Test func endedWithoutBeganIsIgnored() async throws {
        let h = await connectedCall()
        #expect(h.transport.isMicEnabled)

        h.interruption.simulateEnded(shouldResume: true) // no preceding interruption

        #expect(!h.engine.isInterrupted)
        #expect(h.transport.isMicEnabled)
    }
}
