//
//  IncomingPushTests.swift
//  ConduitCallEngineTests
//
//  The PushKit entry (`handleIncomingPush`): iOS kills the app unless every VoIP
//  push reports a CallKit call before the callback returns, so the report comes
//  first on every path — before any state change or delegate call — and PushKit's
//  completion comes after CallKit's. Order is asserted on one log shared by the
//  fake provider, the recording delegate, and PushKit's completion. Real CallKit
//  completes later, so both delivery modes of the fake are covered.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct IncomingPushTests {

    private let statusEndpoint = URL(string: "https://engine.example.com/inbound/status/live")!

    // MARK: - Report first

    @Test func reportComesBeforeAnyStateChangeOrDelegateCall() async throws {
        let h = CallEngineHarness()
        h.ring() // the fake completes before returning: the inconvenient order

        #expect(h.log.entries == [
            "report", "report-completed", "resolve", "T(idle→incomingRinging)", "update", "push-completed",
        ])
    }

    @Test func reportComesFirstWhenCallKitCompletesLater() async throws {
        let h = CallEngineHarness()
        h.provider.completesIncomingReportsLater = true
        h.ring()

        // Resolved as soon as the report is issued, so an early answer can connect;
        // the correction waits for CallKit's verdict.
        #expect(h.log.entries == ["report", "resolve", "T(idle→incomingRinging)"])
        #expect(h.pushCompletions == 0)

        h.provider.completeIncomingReports()

        #expect(h.log.entries == [
            "report", "resolve", "T(idle→incomingRinging)", "report-completed", "update", "push-completed",
        ])
    }

    enum Path: String, CaseIterable, Sendable {
        case ring, busy, focus, reportError, unknownTarget, malformed
    }

    @Test(arguments: Path.allCases)
    func pushCompletionFollowsTheReportsCompletion(path: Path) async throws {
        let h = CallEngineHarness()
        if path == .busy { await h.placeCall() }
        let before = h.log.entries.count
        h.provider.completesIncomingReportsLater = true
        switch path {
        case .focus: h.provider.reportIncomingError = .filteredByFocus
        case .reportError: h.provider.reportIncomingError = .failed("boom")
        default: break
        }

        switch path {
        case .unknownTarget: h.ring(targetID: UUID())
        case .malformed: h.deliverPush(["call_id": UUID().uuidString])
        default: h.ring()
        }
        #expect(h.log.entries.dropFirst(before).first == "report")
        #expect(h.pushCompletions == 0) // held until CallKit's completion

        h.provider.completeIncomingReports()

        #expect(h.pushCompletions == 1)
        #expect(h.log.entries.last == "push-completed")
        let reportCompleted = try #require(h.log.entries.firstIndex(of: "report-completed"))
        let pushCompleted = try #require(h.log.entries.firstIndex(of: "push-completed"))
        #expect(reportCompleted < pushCompleted)
        #expect(h.provider.reportedIncoming.count == 1) // every push reports a call
    }

    @Test func answerBeforeCallKitCompletesTheReportConnects() async throws {
        let h = CallEngineHarness()
        h.provider.completesIncomingReportsLater = true
        let callID = UUID()
        h.ring(callID: callID)

        // CXAnswerCallAction can reach the engine before the report's completion.
        await h.engine.answer()
        #expect(h.engine.state.isConnecting)
        #expect(h.transport.connectCount == 1)
        #expect(h.provider.updatedCalls.isEmpty)

        h.provider.completeIncomingReports()

        #expect(h.provider.updatedCalls.map(\.id) == [callID]) // corrected exactly once
        #expect(h.engine.state.isConnecting) // the connecting call is undisturbed
        #expect(h.transport.connectCount == 1)
        #expect(h.delegate.records.isEmpty)
        #expect(h.pushCompletions == 1)
    }

    @Test(arguments: [IncomingCallReportError.filteredByFocus, .failed("late")])
    func lateVerdictForAnAnsweredCallLeavesItAlone(verdict: IncomingCallReportError) async throws {
        let h = CallEngineHarness()
        h.provider.completesIncomingReportsLater = true
        h.provider.reportIncomingError = verdict
        h.ring(statusURL: URL(string: "https://engine.example.com/inbound/status/live")!)
        await h.engine.answer()
        #expect(h.engine.state.isConnecting)
        let transitionsBefore = h.delegate.transitions

        h.provider.completeIncomingReports()

        #expect(h.engine.state.isConnecting)
        #expect(h.transport.connectCount == 1)
        #expect(h.delegate.transitions == transitionsBefore)
        #expect(h.delegate.records.isEmpty)
        #expect(h.provider.reportedEnded.isEmpty)
        #expect(h.ringStatusReporter.reports.map(\.status) == [.answered]) // no Focus receipt
        #expect(h.pushCompletions == 1)
    }

    @Test func answerForAnUnknownTargetDoesNothingAndTheVerdictFailsIt() async throws {
        let h = CallEngineHarness()
        h.provider.completesIncomingReportsLater = true
        h.ring(targetID: UUID())

        await h.engine.answer()
        #expect(h.engine.state == .incomingRinging)
        #expect(h.target.makeTransportCount == 0)

        h.provider.completeIncomingReports()
        #expect(h.engine.state.failureReason == .unknown)
        #expect(h.pushCompletions == 1)
    }

    enum StaleRing: String, CaseIterable, Sendable {
        case declined, providerReset, replacedByAnotherRing
    }

    @Test(arguments: StaleRing.allCases)
    func heldCompletionForAFinishedRingLeavesTheEngineAlone(stale: StaleRing) async throws {
        let h = CallEngineHarness()
        h.provider.completesIncomingReportsLater = true
        let first = UUID()
        h.ring(callID: first)

        let second = UUID()
        switch stale {
        case .declined:
            h.engine.providerPerformEndCall(first)
        case .providerReset:
            h.engine.providerWasReset()
        case .replacedByAnotherRing:
            h.engine.providerWasReset()
            h.ring(callID: second)
        }
        let stateBefore = h.engine.state
        let transitionsBefore = h.delegate.transitions
        let recordsBefore = h.delegate.records

        h.provider.completeIncomingReports() // the first ring's verdict arrives late

        #expect(!h.provider.updatedCalls.map(\.id).contains(first))
        #expect(!h.provider.reportedEnded.map(\.id).contains(first) || stale == .declined)
        if stale == .replacedByAnotherRing {
            // The second ring's own verdict still applies to it.
            #expect(h.provider.updatedCalls.map(\.id) == [second])
            #expect(h.engine.state == .incomingRinging)
            #expect(h.pushCompletions == 2)
        } else {
            #expect(h.engine.state == stateBefore)
            #expect(h.delegate.transitions == transitionsBefore)
            #expect(h.delegate.records == recordsBefore)
            #expect(h.pushCompletions == 1)
        }
    }

    // MARK: - Malformed pushes

    @Test(arguments: ["missing", "invalid"])
    func malformedPushIsReportedThenEndedWithoutTouchingTheEngine(targetID: String) async throws {
        let h = CallEngineHarness()
        var push: [AnyHashable: Any] = [
            "call_id": UUID().uuidString, "status_url": statusEndpoint.absoluteString,
        ]
        if targetID == "invalid" { push["target_id"] = "not-a-uuid" }
        h.deliverPush(push)

        let reported = try #require(h.provider.reportedIncoming.first)
        #expect(h.provider.reportedIncoming.count == 1)
        #expect(reported.displayName == "Agent")
        #expect(reported.handle == CallHandle(value: CallTarget.defaultHandle(for: reported.id)))
        #expect(h.provider.reportedEnded.map(\.id) == [reported.id])
        #expect(h.provider.reportedEnded.first?.reason == .failed)
        #expect(h.log.entries == ["report", "report-completed", "ended(failed)", "push-completed"])
        #expect(h.engine.state == .idle)
        #expect(h.delegate.events.isEmpty)
        #expect(h.ringStatusReporter.reports.isEmpty)
    }

    // MARK: - Payload keys and identity

    @Test func agentIDAliasRingsTheSameTarget() async throws {
        let h = CallEngineHarness()
        h.deliverPush(["agent_id": h.target.id.uuidString, "call_id": UUID().uuidString])

        #expect(h.delegate.resolved.map(\.targetID) == [h.target.id])
        #expect(h.engine.state == .incomingRinging)
    }

    @Test func targetIDWinsOverTheAgentIDAlias() async throws {
        let h = CallEngineHarness()
        h.deliverPush([
            "target_id": h.target.id.uuidString,
            "agent_id": UUID().uuidString,
            "call_id": UUID().uuidString,
        ])

        #expect(h.delegate.resolved.map(\.targetID) == [h.target.id])
        #expect(h.engine.state == .incomingRinging)
    }

    @Test func ringUsesThePushedNameAndHandle() async throws {
        let h = CallEngineHarness()
        h.ring(displayName: "Registered Name", handle: "registered@conduit.invalid")

        let reported = try #require(h.provider.reportedIncoming.first)
        #expect(reported.displayName == "Registered Name")
        #expect(reported.handle == CallHandle(value: "registered@conduit.invalid"))
        #expect(h.delegate.resolved.first?.displayName == "Registered Name")
        #expect(h.delegate.resolved.first?.handle == "registered@conduit.invalid")
        // Local truth wins: the resolved target differs, so the ring is corrected.
        #expect(h.provider.updatedCalls.first?.displayName == h.target.displayName)
        #expect(h.provider.updatedCalls.first?.handle == CallHandle(value: h.target.handle))
    }

    @Test func ringFallsBackToTheUnknownCallerNameAndDefaultHandle() async throws {
        let h = CallEngineHarness()
        h.ring()

        let reported = try #require(h.provider.reportedIncoming.first)
        #expect(reported.displayName == "Agent")
        #expect(reported.handle == CallHandle(value: CallTarget.defaultHandle(for: h.target.id)))
    }

    @Test func matchingIdentityIsNotCorrected() async throws {
        let h = CallEngineHarness()
        h.ring(displayName: h.target.displayName, handle: h.target.handle)

        #expect(h.provider.updatedCalls.isEmpty)
        #expect(h.log.entries == ["report", "report-completed", "resolve", "T(idle→incomingRinging)", "push-completed"])
    }

    @Test func busyRingIsCorrectedBeforeItEnds() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        let before = h.log.entries.count
        h.ring()

        #expect(Array(h.log.entries.dropFirst(before)) == [
            "report", "report-completed", "resolve", "update", "ended(unanswered)", "finish(noAnswer)", "push-completed",
        ])
        #expect(h.engine.state.isConnecting) // the live call is untouched
    }

    @Test func busyRingWhoseReportFailsIsNotEnded() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.provider.reportIncomingError = .failed("duplicate")
        // A duplicate delivery of the live call's own id: ending it would end the live call.
        h.ring(callID: h.callID, statusURL: URL(string: "https://engine.example.com/inbound/status/live")!)

        #expect(h.provider.reportedEnded.isEmpty)
        #expect(h.engine.state.isConnecting)
        #expect(h.delegate.records.map(\.missedReason) == [.busy]) // record and receipt as before
        #expect(h.ringStatusReporter.reports.map(\.status) == [.busy])
        #expect(h.pushCompletions == 1)
    }

    @Test func busyRingWithMatchingIdentityIsNotCorrected() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.ring(displayName: h.target.displayName, handle: h.target.handle)

        #expect(h.provider.updatedCalls.isEmpty)
        #expect(h.provider.reportedEnded.first?.reason == .unanswered)
    }

    // MARK: - Report results

    @Test func reportErrorFailsTheRingWithoutAReceipt() async throws {
        let h = CallEngineHarness()
        h.provider.reportIncomingError = .failed("boom")
        h.ring(statusURL: statusEndpoint)

        #expect(h.engine.state.failureReason == .unknown)
        #expect(h.provider.updatedCalls.isEmpty) // never accepted, so never corrected
        #expect(h.delegate.records.map(\.outcome) == [.failed])
        #expect(h.ringStatusReporter.reports.isEmpty)
        #expect(h.pushCompletions == 1)
    }

    @Test func unknownTargetSendsNoReceipt() async throws {
        let h = CallEngineHarness()
        h.ring(targetID: UUID(), statusURL: statusEndpoint)

        #expect(h.engine.state.failureReason == .unknown)
        #expect(h.ringStatusReporter.reports.isEmpty)
    }

    // MARK: - After a finished call (bug c)

    @Test(arguments: [false, true])
    func ringAfterAFinishedCallRings(endedInFailure: Bool) async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        if endedInFailure {
            h.engine.handle(.disconnected(reason: .authFailed))
        } else {
            h.engine.handle(.disconnected(reason: .botLeft))
        }
        #expect(h.engine.state.isTerminal)
        let terminal = h.engine.state.label

        let callID = UUID()
        h.ring(callID: callID)

        #expect(h.engine.state == .incomingRinging)
        #expect(Array(h.delegate.transitions.suffix(2)) == ["\(terminal)→idle", "idle→incomingRinging"])
        #expect(h.engine.activeCall?.direction == .incoming)
        #expect(!h.provider.reportedEnded.map(\.id).contains(callID)) // not treated as busy
    }

    @Test(arguments: [false, true])
    func placeCallAfterAFinishedCallDials(endedInFailure: Bool) async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        if endedInFailure {
            h.engine.handle(.disconnected(reason: .authFailed))
        } else {
            h.engine.handle(.disconnected(reason: .botLeft))
        }
        let terminal = h.engine.state.label

        await h.placeCall()

        #expect(h.engine.state.isConnecting)
        #expect(Array(h.delegate.transitions.suffix(3)) == ["\(terminal)→idle", "idle→dialing", "dialing→connecting"])
        #expect(h.transports.made.count == 2)
    }

    // MARK: - Stale placeCall continuations

    @Test(arguments: [false, true])
    func staleDialFromAReplacedCallEndsOnlyItsOwnCall(uiResetsFirst: Bool) async throws {
        let h = CallEngineHarness()
        let firstID = UUID()
        let secondID = UUID()
        h.provider.suspendStart = true

        h.provider.nextCallID = firstID
        let first = Task { await h.placeCall() }
        await waitUntil { h.provider.pendingStartCount == 1 }
        #expect(h.provider.pendingStartCount == 1)
        await h.engine.endCall()
        // RootTabView resets a user-ended call at once; otherwise placeCall does.
        if uiResetsFirst { h.engine.reset() }

        h.provider.nextCallID = secondID
        let second = Task { await h.placeCall() } // replaces the ended call
        await waitUntil { h.provider.pendingStartCount == 2 }
        #expect(h.provider.pendingStartCount == 2)
        #expect(h.engine.state == .dialing)

        h.provider.releaseStart()
        await first.value
        await second.value

        #expect(h.provider.endRequests == [firstID])
        #expect(h.provider.reportedConnecting == [secondID]) // B keeps its own CallKit id
        #expect(h.engine.activeCall?.direction == .outgoing)
        #expect(h.engine.state.isConnecting)
        #expect(h.transports.made.count == 1)
        #expect(h.transport.connectCount == 1)
        #expect(h.delegate.records.map(\.outcome) == [.canceled])
    }

    @Test func firstCallsStartFailingWhileASecondCallDialsLeavesTheSecondAlone() async throws {
        let h = CallEngineHarness()
        let secondID = UUID()
        h.provider.suspendStart = true

        let first = Task { await h.placeCall() }
        await waitUntil { h.provider.pendingStartCount == 1 }
        #expect(h.provider.pendingStartCount == 1)
        await h.engine.endCall()
        h.engine.reset()

        h.provider.nextCallID = secondID
        let second = Task { await h.placeCall() }
        await waitUntil { h.provider.pendingStartCount == 2 }
        #expect(h.provider.pendingStartCount == 2)

        h.provider.startError = TransportError.connectionFailed("callkit refused")
        h.provider.releaseFirstStart() // only the first call's start returns, and throws
        await first.value
        #expect(h.engine.state == .dialing) // the second call is not failed

        h.provider.startError = nil
        h.provider.releaseStart()
        await second.value
        #expect(h.engine.state.isConnecting)
        #expect(h.provider.reportedConnecting == [secondID])
        #expect(h.delegate.records.map(\.outcome) == [.canceled])
    }

    @Test func startFailingAfterAProviderResetDoesNotFail() async throws {
        let h = CallEngineHarness()
        h.provider.suspendStart = true
        let place = Task { await h.placeCall() }
        await waitUntil { h.provider.pendingStartCount == 1 }
        #expect(h.provider.pendingStartCount == 1)

        h.engine.providerWasReset()
        #expect(h.engine.state == .idle)
        h.provider.startError = TransportError.connectionFailed("callkit refused")
        h.provider.releaseStart()
        await place.value

        #expect(h.engine.state == .idle)
        #expect(h.delegate.transitions.last == "dialing→idle")
        #expect(h.delegate.records.isEmpty)
        #expect(h.provider.reportedEnded.isEmpty)
    }
}
