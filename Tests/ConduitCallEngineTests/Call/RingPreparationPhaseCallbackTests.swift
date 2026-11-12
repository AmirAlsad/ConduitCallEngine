//
//  RingPreparationPhaseCallbackTests.swift
//  ConduitCallEngineTests
//
//  `callEngine(_:didChangeRingPreparationPhaseFrom:to:)`: one callback per real
//  change of `ringPreparationPhase`, made with the property already updated, the
//  phase leaving `.idle` only during a ring and returning to it before the answer's
//  transition, or after an unanswered ring's record.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct RingPreparationPhaseCallbackTests {
    private func harness(allows tier: RingPreparation, capable: Bool = true) -> CallEngineHarness {
        let h = CallEngineHarness()
        h.allowRingPreparation(tier)
        h.transport.canConnectWhileRinging = capable
        return h
    }

    /// The labels in `h.delegate.phaseTrace` from the ring's transition on, without
    /// PushKit's completions unless asked for.
    private func trace(_ h: CallEngineHarness, withPushCompletions: Bool = false) -> [String] {
        h.delegate.phaseTrace
            .drop { $0 != "T(idle→incomingRinging)" }
            .filter { withPushCompletions || $0 != "push-completed" }
    }

    @Test func aMediaRingReportsEachPhaseAndIdleBeforeTheAnswersTransition() async throws {
        let h = harness(allows: .media)
        h.ring(callID: h.callID, preconnect: "media")
        await h.engine.awaitPendingRingPreparation()
        h.engine.handle(.connected)

        await h.engine.answer()

        #expect(trace(h) == [
            "T(idle→incomingRinging)",
            "P(idle→fetchingCredentials)",
            "P(fetchingCredentials→connecting)",
            "P(connecting→ready)",
            "P(ready→idle)",
            "T(incomingRinging→connected)",
        ])
        #expect(h.delegate.phaseChanges.allSatisfy { $0.to == $0.observed })
    }

    @Test func aCredentialsRingReportsItsPhasesAndIdleBeforeConnecting() async throws {
        let h = harness(allows: .credentials)
        h.ring(callID: h.callID, preconnect: "credentials")
        await h.engine.awaitPendingRingPreparation()

        await h.engine.answer()

        #expect(Array(trace(h).prefix(5)) == [
            "T(idle→incomingRinging)",
            "P(idle→fetchingCredentials)",
            "P(fetchingCredentials→credentialsReady)",
            "P(credentialsReady→idle)",
            "T(incomingRinging→connecting)",
        ])
    }

    @Test func aFailedPreparationIsReportedAndClearedAtTheAnswer() async throws {
        let h = harness(allows: .credentials)
        h.target.error = TransportError.connectionFailed("backend down")
        h.ring(callID: h.callID, preconnect: "credentials")
        await h.engine.awaitPendingRingPreparation()
        #expect(h.engine.ringPreparationPhase == .failed)
        h.target.error = nil

        await h.engine.answer()

        #expect(Array(trace(h).prefix(5)) == [
            "T(idle→incomingRinging)",
            "P(idle→fetchingCredentials)",
            "P(fetchingCredentials→failed)",
            "P(failed→idle)",
            "T(incomingRinging→connecting)",
        ])
    }

    @Test func aRingWithNothingToPrepareReportsNoPhase() async throws {
        let h = harness(allows: .media)
        h.ring(callID: h.callID)
        await h.engine.awaitPendingRingPreparation()
        await h.engine.answer()
        h.engine.handle(.connected)
        await h.engine.endCall()

        #expect(h.delegate.phaseChanges.isEmpty)
    }

    /// Inside the push: with CallKit accepting the report at once, the preparation
    /// starts before PushKit's completion runs.
    @Test func thePreparationCanStartInsideThePushHandling() async throws {
        let h = harness(allows: .credentials)
        h.ring(callID: h.callID, preconnect: "credentials")

        #expect(Array(trace(h, withPushCompletions: true).prefix(3)) == [
            "T(idle→incomingRinging)",
            "P(idle→fetchingCredentials)",
            "push-completed",
        ])
    }

    enum Ending: CaseIterable { case declined, canceled, providerReset }

    @Test(arguments: Ending.allCases)
    func anUnansweredRingReturnsToIdleAfterItsRecord(_ ending: Ending) async throws {
        let h = harness(allows: .media)
        h.ring(callID: h.callID, preconnect: "media")
        await h.engine.awaitPendingRingPreparation()
        h.engine.handle(.connected)

        switch ending {
        case .declined: h.provider.simulateEndCall(h.callID)
        case .canceled: h.cancel(callID: h.callID)
        case .providerReset: h.provider.simulateReset()
        }

        let trace = trace(h)
        let finish = try #require(trace.firstIndex { $0.hasPrefix("finish(") })
        let idle = try #require(trace.firstIndex(of: "P(ready→idle)"))
        #expect(finish < idle)
        if let backToIdle = trace.firstIndex(of: "T(incomingRinging→idle)") {
            #expect(idle < backToIdle)
        }
        #expect(h.engine.ringPreparationPhase == .idle)
        #expect(trace.filter { $0.hasPrefix("P(") }.last == "P(ready→idle)")
    }
}
