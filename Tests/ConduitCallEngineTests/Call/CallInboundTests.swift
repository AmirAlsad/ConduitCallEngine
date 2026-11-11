//
//  CallInboundTests.swift
//  ConduitCallEngineTests
//
//  Agent-initiated inbound calls: a VoIP push rings via CallKit, the user answers,
//  and the transport connects with the resolved target's credentials. Decline and
//  unknown-target paths are asserted too. The push round-trip itself is
//  device-only; this drives the engine against fakes at simulator speed.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct CallInboundTests {

    private let statusEndpoint = URL(string: "https://engine.example.com/inbound/status/live")!

    @Test func receiveCallRingsAndResolvesAgent() async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        h.ring(callID: callID)

        #expect(h.engine.state == .incomingRinging)
        #expect(h.engine.activeCall?.targetID == h.target.id)
        #expect(h.engine.activeCall?.direction == .incoming)
        #expect(h.engine.activeCall?.displayName == h.target.displayName) // corrected
        #expect(h.provider.reportedIncoming.map(\.id) == [callID])
        // The push carried no name or handle: it rang under the fallbacks, then the
        // resolved target corrected it.
        let defaultHandle = CallHandle(value: CallTarget.defaultHandle(for: h.target.id))
        #expect(h.provider.reportedIncoming.first?.handle == defaultHandle)
        #expect(h.provider.reportedIncoming.first?.displayName == "Agent")
        #expect(h.provider.updatedCalls.map(\.id) == [callID])
        #expect(h.provider.updatedCalls.first?.handle == CallHandle(value: h.target.handle))
        #expect(h.provider.updatedCalls.first?.displayName == h.target.displayName)
        #expect(h.interruption.isObserving)
        #expect(h.delegate.resolved == [IncomingCall(
            callID: callID, targetID: h.target.id, displayName: "Agent",
            handle: CallTarget.defaultHandle(for: h.target.id), connection: nil
        )])
    }

    @Test func answerConnectsViaAgentDirectConfig() async throws {
        let h = CallEngineHarness()
        h.ring()
        await h.engine.answer()

        #expect(h.transport.connectCount == 1)
        #expect(h.target.connectCount == 1)
        #expect(h.transport.lastConnection == h.target.connection)
        #expect(h.engine.state.isConnecting)
        #expect(h.delegate.transitions == ["idle→incomingRinging", "incomingRinging→connecting"])
    }

    @Test func answerWithInlineCredentialsJoinsDirectly() async throws {
        let h = CallEngineHarness()
        let room = URL(string: "https://example.daily.co/inbound-room")!
        h.ring(roomURL: room, token: "push-token")

        // The inline room rides to the host, whose target joins it (AgentCallHostTests).
        #expect(h.delegate.resolved.first?.connection == CallConnection(url: room, token: "push-token"))
    }

    @Test func answeredCallConnectsAndLogsIncoming() async throws {
        let h = CallEngineHarness()
        h.ring()
        await h.engine.answer()
        h.engine.handle(.connected)

        #expect(h.engine.state.isConnected)
        #expect(h.provider.reportedConnected.isEmpty) // incoming connects via answer-action

        await h.engine.endCall()
        let record = try #require(h.delegate.records.first)
        #expect(record.direction == .incoming)
        #expect(record.outcome == .completed)
        #expect(record.failureReason == nil)
        #expect(record.missedReason == nil)
    }

    @Test func answerViaSystemDelegateConnects() async throws {
        let h = CallEngineHarness()
        h.ring()

        h.provider.simulateAnswerCall(UUID()) // the real CXAnswerCallAction path

        await waitUntil { h.transport.connectCount > 0 }
        #expect(h.transport.connectCount == 1)
    }

    @Test func declineWhileRingingLogsDeclined() async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        h.ring(callID: callID)

        h.engine.providerPerformEndCall(callID) // system decline

        #expect(h.engine.state.endedOutcome == .declined)
        let record = try #require(h.delegate.records.first)
        #expect(record.direction == .incoming)
        #expect(record.outcome == .declined)
        #expect(record.missedReason == nil)
        #expect(!h.interruption.isObserving)
    }

    @Test func unknownAgentReportsThenFails() async throws {
        let h = CallEngineHarness()
        let unknownID = UUID()
        h.ring(targetID: unknownID)

        #expect(h.provider.reportedIncoming.count == 1) // reported before failing
        #expect(h.provider.reportedIncoming.first?.handle == CallHandle(value: CallTarget.defaultHandle(for: unknownID)))
        #expect(h.provider.reportedIncoming.first?.displayName == "Agent")
        #expect(h.provider.updatedCalls.isEmpty) // nothing to correct it to
        #expect(h.provider.reportedEnded.first?.reason == .failed)
        #expect(h.engine.state.failureReason == .unknown)
        #expect(h.engine.activeCall?.targetID == unknownID) // the push's own identity
        #expect(h.pushCompletions == 1)
        // Recorded against the pushed id; the host finds no agent and writes no row.
        #expect(h.delegate.records.map(\.targetID) == [unknownID])
        #expect(h.delegate.records.first?.failureReason == .unknown)
    }

    @Test func receiveCallWhileBusyReportsAndImmediatelyEnds() async throws {
        // iOS terminates the app (killing the active call) if a VoIP push isn't
        // reported to CallKit — busy means report-then-end, never silent ignore.
        let h = CallEngineHarness()
        await h.placeCall() // already in a call
        let busyCallID = UUID()
        h.ring(callID: busyCallID)

        #expect(h.engine.state.isConnecting) // active call untouched
        #expect(h.engine.activeCall?.direction == .outgoing)
        #expect(h.provider.reportedIncoming.map(\.id) == [busyCallID])
        #expect(h.provider.reportedEnded.map(\.id) == [busyCallID])
        #expect(h.provider.reportedEnded.first?.reason == .unanswered)
        #expect(h.pushCompletions == 1)

        // The missed ring is recorded as an incoming no-answer the user never saw.
        #expect(h.delegate.records.count == 1)
        let record = try #require(h.delegate.records.first)
        #expect(record.targetID == h.target.id)
        #expect(record.direction == .incoming)
        #expect(record.outcome == .noAnswer)
        #expect(record.duration == 0)
        #expect(record.missedReason == .busy)
        #expect(h.delegate.transitions == ["idle→dialing", "dialing→connecting"]) // no T for the busy ring
    }

    @Test func focusFilteredRingLogsMissedAndReturnsToIdle() async throws {
        // Focus/DND makes reportNewIncomingCall fail with a filtered error: not a
        // failure — record a missed call and stay ready to ring again.
        let h = CallEngineHarness()
        h.provider.reportIncomingError = IncomingCallReportError.filteredByFocus
        h.ring()

        #expect(h.engine.state == .idle) // not stuck in .failed
        #expect(!h.interruption.isObserving)
        #expect(h.delegate.records.count == 1)
        let record = try #require(h.delegate.records.first)
        #expect(record.direction == .incoming)
        #expect(record.outcome == .noAnswer)
        #expect(record.missedReason == .filteredByFocus)
        #expect(h.delegate.transitions == ["idle→incomingRinging", "incomingRinging→idle"])

        // A later push (Focus off) rings normally.
        h.provider.reportIncomingError = nil
        h.ring()
        #expect(h.engine.state == .incomingRinging)
    }

    // MARK: - Ring-status receipts (push carried a status_url)

    @Test func answerReportsAnsweredReceiptWithBearer() async throws {
        let h = CallEngineHarness()
        h.delegate.bearers[h.target.id] = "agent-api-key"
        let callID = UUID()
        h.ring(callID: callID, statusURL: statusEndpoint)
        await h.engine.answer()

        #expect(h.ringStatusReporter.reports == [
            .init(status: .answered, callID: callID, endpoint: statusEndpoint, apiKey: "agent-api-key")
        ])
        #expect(h.delegate.bearerRequests == [h.target.id])
    }

    @Test func answeredReceiptIsSentBeforeTheRingback() async throws {
        let h = CallEngineHarness()
        h.ring(statusURL: statusEndpoint)
        let before = h.log.entries.count
        await h.engine.answer()

        #expect(Array(h.log.entries.dropFirst(before).prefix(3)) == [
            "bearer", "receipt(answered)", "T(incomingRinging→connecting)",
        ])
    }

    @Test func declineReportsDeclinedReceipt() async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        h.ring(callID: callID, statusURL: statusEndpoint)
        h.engine.providerPerformEndCall(callID)

        #expect(h.ringStatusReporter.reports.map(\.status) == [.declined])
        #expect(h.ringStatusReporter.reports.first?.callID == callID)
        #expect(h.ringStatusReporter.reports.first?.apiKey == "") // the host had no bearer
    }

    @Test func busyPushReportsBusyReceipt() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        let busyCallID = UUID()
        h.ring(callID: busyCallID, statusURL: statusEndpoint)

        #expect(h.ringStatusReporter.reports.map(\.status) == [.busy])
        #expect(h.ringStatusReporter.reports.first?.callID == busyCallID)
    }

    @Test func focusFilteredRingReportsSuppressedReceipt() async throws {
        let h = CallEngineHarness()
        h.provider.reportIncomingError = IncomingCallReportError.filteredByFocus
        let callID = UUID()
        h.ring(callID: callID, statusURL: statusEndpoint)

        #expect(h.ringStatusReporter.reports.map(\.status) == [.suppressedByFocus])
        #expect(h.ringStatusReporter.reports.first?.callID == callID)
    }

    @Test func completedCallReportsOnlyTheAnswerReceipt() async throws {
        // The receipt describes the RING's outcome; a normal hang-up after a
        // connected call must not produce a second (declined) report.
        let h = CallEngineHarness()
        h.ring(statusURL: statusEndpoint)
        await h.engine.answer()
        h.engine.handle(.connected)
        await h.engine.endCall()

        #expect(h.ringStatusReporter.reports.map(\.status) == [.answered])
    }

    @Test func noStatusURLReportsNothing() async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        h.ring(callID: callID)
        h.engine.providerPerformEndCall(callID)

        #expect(h.ringStatusReporter.reports.isEmpty)
        #expect(h.delegate.bearerRequests.isEmpty) // only asked when a receipt is sent
    }
}
