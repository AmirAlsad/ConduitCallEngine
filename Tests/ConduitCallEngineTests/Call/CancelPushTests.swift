//
//  CancelPushTests.swift
//  ConduitCallEngineTests
//
//  The sender withdrawing a ring: `{"action": "cancel", "call_id": ...}`, with no
//  `target_id`. Like every VoIP push it is reported to CallKit first, inside the
//  PushKit callback, and PushKit's completion runs once after CallKit's. What it
//  does next depends on what `call_id` names: the ringing call (ended, recorded,
//  `canceled` receipt), the call in progress (nothing more), or nothing the
//  engine knows (the report rings and is ended at once). A ring that arrives
//  after its own cancel is ended at once. The fake provider refuses a report
//  under an id it holds, as CallKit does (`callUUIDAlreadyExists`).
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct CancelPushTests {
    private let statusEndpoint = URL(string: "https://engine.example.com/inbound/status/live")!

    // MARK: - Cancelling the ringing call

    @Test(arguments: [false, true])
    func cancelEndsTheRingingCallAsAMissedCall(callKitCompletesLater: Bool) async throws {
        let h = CallEngineHarness()
        h.provider.completesIncomingReportsLater = callKitCompletesLater
        let callID = UUID()
        h.ring(callID: callID, statusURL: statusEndpoint)
        let before = h.log.entries.count

        h.cancel(callID: callID)
        h.provider.completeIncomingReports()

        #expect(h.engine.state == .idle)
        #expect(h.engine.activeCall == nil)
        #expect(h.delegate.transitions == ["idle→incomingRinging", "incomingRinging→idle"])
        // Reported under the ring's own id (CallKit refuses it as a duplicate), then
        // the ring is ended as the caller's hangup.
        #expect(h.provider.reportedIncoming.map(\.id) == [callID, callID])
        #expect(h.provider.reportedEnded.map(\.id) == [callID])
        #expect(h.provider.reportedEnded.first?.reason == .remoteEnded)
        #expect(Array(h.log.entries.dropFirst(before)).first == "report")
        let record = try #require(h.delegate.records.first)
        #expect(h.delegate.records.count == 1)
        #expect(record.outcome == .noAnswer)
        #expect(record.missedReason == .canceledByCaller)
        #expect(record.direction == .incoming)
        #expect(record.targetID == h.target.id)
        #expect(h.ringStatusReporter.reports == [
            .init(status: .canceled, callID: callID, endpoint: statusEndpoint, apiKey: ""),
        ])
        #expect(h.delegate.cues.isEmpty)
        #expect(!h.interruption.isObserving)
        #expect(h.pushCompletions == 2)
    }

    @Test func cancelIsReportedBeforeTheRingIsEnded() async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        h.ring(callID: callID, statusURL: statusEndpoint)
        let before = h.log.entries.count

        h.cancel(callID: callID)

        #expect(Array(h.log.entries.dropFirst(before)) == [
            "report", "report-completed", "ended(remoteEnded)", "finish(noAnswer)", "bearer", "receipt(canceled)",
            "T(incomingRinging→idle)", "push-completed",
        ])
    }

    @Test func cancelForARingOfAnUnresolvedTargetSendsNoReceipt() async throws {
        let h = CallEngineHarness()
        h.provider.completesIncomingReportsLater = true
        let callID = UUID()
        h.ring(targetID: UUID(), callID: callID, statusURL: statusEndpoint)

        h.cancel(callID: callID)
        h.provider.completeIncomingReports()

        #expect(h.engine.state == .idle)
        #expect(h.delegate.records.map(\.missedReason) == [.canceledByCaller])
        #expect(h.ringStatusReporter.reports.isEmpty)
        #expect(h.pushCompletions == 2)
    }

    /// The ring's report had not completed when the cancel came, and CallKit then
    /// accepted the cancel's report as a new call (it did not hold the id): that
    /// call is ended at once too.
    @Test func aCancelCallKitAcceptsAsANewCallIsEndedAtOnce() async throws {
        let h = CallEngineHarness()
        h.provider.completesIncomingReportsLater = true
        h.provider.reportIncomingError = .filteredByFocus // the ring itself never rang
        let callID = UUID()
        h.ring(callID: callID, statusURL: statusEndpoint)
        h.provider.reportIncomingError = nil

        h.cancel(callID: callID)
        h.provider.completeIncomingReports()

        #expect(h.provider.reportedEnded.map(\.id) == [callID, callID])
        #expect(h.provider.reportedEnded.allSatisfy { $0.reason == .remoteEnded })
        #expect(h.engine.state == .idle)
        #expect(h.delegate.records.map(\.missedReason) == [.canceledByCaller]) // the late Focus verdict adds nothing
        #expect(h.ringStatusReporter.reports.map(\.status) == [.canceled])
        #expect(h.pushCompletions == 2)
    }

    // MARK: - Cancelling the call in progress

    enum CallInProgress: String, CaseIterable, Sendable {
        case answerActionDelivered, connecting, connected
    }

    @Test(arguments: CallInProgress.allCases)
    func cancelForTheCallInProgressIsOnlyReported(call: CallInProgress) async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        h.ring(callID: callID, statusURL: statusEndpoint)
        switch call {
        case .answerActionDelivered:
            h.provider.simulateAnswerCall(callID) // answer() has not run yet
        case .connecting:
            await h.engine.answer()
        case .connected:
            await h.engine.answer()
            h.engine.handle(.connected)
        }
        let events = h.delegate.events
        let receipts = h.ringStatusReporter.reports

        h.cancel(callID: callID)

        #expect(h.provider.reportedIncoming.map(\.id) == [callID, callID])
        #expect(h.provider.reportedEnded.isEmpty)
        #expect(h.delegate.events == events)
        #expect(h.ringStatusReporter.reports == receipts)
        #expect(h.pushCompletions == 2)
        if call == .answerActionDelivered {
            await waitUntil { h.engine.state.isConnecting }
            #expect(h.engine.state.isConnecting) // the answer still connects
            #expect(h.delegate.records.isEmpty)
        }
    }

    // MARK: - Cancelling something the engine does not know

    @Test(arguments: [false, true])
    func cancelForAnUnknownCallIsReportedThenEndedAtOnce(callKitCompletesLater: Bool) async throws {
        let h = CallEngineHarness()
        h.provider.completesIncomingReportsLater = callKitCompletesLater
        let callID = UUID()

        h.cancel(callID: callID, displayName: "Assistant")
        if callKitCompletesLater {
            #expect(h.provider.reportedEnded.isEmpty) // only a call CallKit created can be ended
            h.provider.completeIncomingReports()
        }

        #expect(h.log.entries == ["report", "report-completed", "ended(remoteEnded)", "push-completed"])
        #expect(h.provider.reportedIncoming.first?.id == callID)
        #expect(h.provider.reportedIncoming.first?.displayName == "Assistant")
        #expect(h.engine.state == .idle)
        #expect(h.delegate.events.isEmpty)
        #expect(h.ringStatusReporter.reports.isEmpty)
        #expect(h.pushCompletions == 1)
    }

    @Test func cancelWithoutANameReportsUnderTheUnknownCallerName() async throws {
        let h = CallEngineHarness()
        h.cancel(callID: UUID())

        #expect(h.provider.reportedIncoming.first?.displayName == "Agent")
    }

    enum OtherCall: String, CaseIterable, Sendable {
        case ringing, connected
    }

    @Test(arguments: OtherCall.allCases)
    func cancelForAnotherCallLeavesTheCallInProgressAlone(other: OtherCall) async throws {
        let h = CallEngineHarness()
        if other == .ringing {
            h.ring(statusURL: statusEndpoint)
        } else {
            await h.placeCall()
            h.engine.handle(.connected)
        }
        let state = h.engine.state
        let events = h.delegate.events
        let canceledID = UUID()

        h.cancel(callID: canceledID)

        #expect(h.provider.reportedEnded.map(\.id) == [canceledID])
        #expect(h.engine.state == state)
        #expect(h.delegate.events == events) // no busy record
        #expect(h.ringStatusReporter.reports.isEmpty)
        #expect(h.pushCompletions == (other == .ringing ? 2 : 1))
    }

    @Test func cancelAfterTheRingWasDeclinedChangesNothing() async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        h.ring(callID: callID, statusURL: statusEndpoint)
        h.provider.simulateEndCall(callID)
        let events = h.delegate.events

        h.cancel(callID: callID)

        #expect(h.engine.state == .ended(.declined))
        #expect(h.delegate.events == events)
        #expect(h.ringStatusReporter.reports.map(\.status) == [.declined])
        #expect(h.provider.reportedEnded.map(\.id) == [callID]) // the flash the cancel caused
    }

    // MARK: - A ring that arrives after its cancel

    @Test(arguments: [false, true])
    func aRingAfterItsCancelIsEndedAtOnceWithoutTouchingTheEngine(callKitCompletesLater: Bool) async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        h.cancel(callID: callID) // APNs delivered the cancel first
        h.provider.completesIncomingReportsLater = callKitCompletesLater
        let before = h.log.entries.count

        h.ring(callID: callID, statusURL: statusEndpoint)
        h.provider.completeIncomingReports()

        #expect(Array(h.log.entries.dropFirst(before)) == [
            "report", "report-completed", "ended(remoteEnded)", "push-completed",
        ])
        #expect(h.engine.state == .idle)
        #expect(h.delegate.events.isEmpty) // not even resolved
        #expect(h.ringStatusReporter.reports.isEmpty)
        #expect(h.pushCompletions == 2)
    }

    @Test func aRingAfterItsCancelDuringAnotherCallIsNotBusy() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        let callID = UUID()
        h.cancel(callID: callID)
        let events = h.delegate.events

        h.ring(callID: callID, statusURL: statusEndpoint)

        #expect(h.delegate.events == events)
        #expect(h.ringStatusReporter.reports.isEmpty)
        #expect(h.engine.state.isConnecting)
    }

    @Test func aCanceledRingIsRedeliveredAndEndedAtOnce() async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        h.ring(callID: callID, statusURL: statusEndpoint)
        h.cancel(callID: callID)
        let events = h.delegate.events

        h.ring(callID: callID, statusURL: statusEndpoint) // a second delivery of the ring

        #expect(h.engine.state == .idle)
        #expect(h.delegate.events == events)
        #expect(h.ringStatusReporter.reports.map(\.status) == [.canceled])
    }

    @Test func aCancelIsRememberedForTenMinutes() async throws {
        let clock = MutableClock()
        let h = CallEngineHarness(now: { clock.now() })
        let remembered = UUID()
        let forgotten = UUID()
        h.cancel(callID: forgotten)
        clock.advance(5 * 60)
        h.cancel(callID: remembered)
        clock.advance(5 * 60 + 1)

        h.ring(callID: remembered)
        #expect(h.engine.state == .idle)

        h.ring(callID: forgotten)
        #expect(h.engine.state == .incomingRinging)
    }

    @Test func onlyTheLatestCancelsAreRemembered() async throws {
        let h = CallEngineHarness()
        let ids = (0...CallEngine.rememberedCancelLimit).map { _ in UUID() }
        ids.forEach { h.cancel(callID: $0) }

        h.ring(callID: ids[1])
        #expect(h.engine.state == .idle)

        h.ring(callID: ids[0]) // the oldest, pushed out by the newest
        #expect(h.engine.state == .incomingRinging)
    }

    // MARK: - Malformed cancels and unknown actions

    @Test(arguments: [
        ["action": "cancel"],
        ["action": "cancel", "call_id": "not-a-uuid"],
        ["action": "hang-up", "call_id": UUID().uuidString, "target_id": UUID().uuidString],
    ])
    func aMalformedRequestIsReportedThenEndedWithoutTouchingTheEngine(push: [String: String]) async throws {
        let h = CallEngineHarness()
        h.deliverPush(push)

        let reported = try #require(h.provider.reportedIncoming.first)
        #expect(reported.id.uuidString != push["call_id"]) // a fresh id
        #expect(h.log.entries == ["report", "report-completed", "ended(failed)", "push-completed"])
        #expect(h.engine.state == .idle)
        #expect(h.delegate.events.isEmpty)
    }

    @Test func aCancelThatAlsoNamesATargetIsStillACancel() async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        h.ring(callID: callID, statusURL: statusEndpoint)

        h.deliverPush(["action": "cancel", "call_id": callID.uuidString, "target_id": h.target.id.uuidString])

        #expect(h.engine.state == .idle)
        #expect(h.delegate.records.map(\.missedReason) == [.canceledByCaller])
    }

    @Test func anExplicitRingActionRings() async throws {
        let h = CallEngineHarness()
        h.deliverPush(["action": "ring", "target_id": h.target.id.uuidString, "call_id": UUID().uuidString])

        #expect(h.engine.state == .incomingRinging)
    }

    // MARK: - Capabilities

    @Test func theEngineAdvertisesCancelAndRingTimeout() {
        #expect(CallEngine.supportedPushFeatures == ["cancel", "ring_timeout"])
    }
}
