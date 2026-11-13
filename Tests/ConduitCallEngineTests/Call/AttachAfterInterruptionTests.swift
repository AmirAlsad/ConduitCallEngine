//
//  AttachAfterInterruptionTests.swift
//  ConduitCallEngineTests
//
//  The attach that follows a real audio interruption during which the call's
//  media was detached (CallKit's deactivation, or a hold) logs the audio session
//  CallKit activated, once per such attach, and never otherwise. The engine reads
//  the session only to log it, so the fake session's reads show the log.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct AttachAfterInterruptionTests {

    private func liveCall(_ h: CallEngineHarness) async {
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.activate(FakeAudioSession())
        await h.engine.awaitPendingWork()
    }

    private func activate(_ h: CallEngineHarness, _ session: FakeAudioSession) async {
        h.provider.simulateActivate(session)
        await h.engine.awaitPendingWork()
    }

    @Test func theAttachAfterADeactivationDuringAnInterruptionLogsTheSession() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        h.interruption.simulateBegan()
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingWork()
        let session = FakeAudioSession()

        await activate(h, session)

        #expect(session.diagnosticReadCount >= 1)
        #expect(h.transport.isAudioAttached)
    }

    @Test func itLogsOncePerInterruption() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        h.interruption.simulateBegan()
        h.provider.simulateDeactivate(FakeAudioSession())
        await activate(h, FakeAudioSession())

        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingWork()
        let next = FakeAudioSession()
        await activate(h, next)

        #expect(next.diagnosticReadCount == 0)
    }

    @Test func aDeactivationWithNoInterruptionLogsNothing() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingWork()
        let session = FakeAudioSession()

        await activate(h, session)

        #expect(session.diagnosticReadCount == 0)
    }

    @Test func anInterruptionWhileAttachedLogsNothing() async throws {
        let h = CallEngineHarness()
        let session = FakeAudioSession()
        await h.placeCall()
        h.engine.handle(.connected)
        await activate(h, session)

        h.interruption.simulateBegan()
        h.interruption.simulateEnded(shouldResume: true)
        await h.engine.awaitPendingWork()

        #expect(session.diagnosticReadCount == 0)
    }

    /// With the experimental hold: the interruption began during the hold, and the
    /// resume's attach logs the session CallKit activated.
    @Test func theResumeAfterAPhoneCallLogsTheSession() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await liveCall(h)
        _ = h.provider.simulateSetHeld(h.callID, onHold: true)
        h.interruption.simulateBegan()
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingWork()
        _ = h.provider.simulateSetHeld(h.callID, onHold: false)
        let session = FakeAudioSession()

        await activate(h, session)

        #expect(session.diagnosticReadCount >= 1)
        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
    }
}
