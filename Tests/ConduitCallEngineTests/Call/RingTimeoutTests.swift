//
//  RingTimeoutTests.swift
//  ConduitCallEngineTests
//
//  The ring timer: an incoming call nobody answers is ended as unanswered after
//  the configured timeout, which a push may shorten but never lengthen. Time is
//  the engine's injected sleep (a `ManualSleeper`), so each test decides when the
//  timeout elapses relative to answers, declines and resets.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct RingTimeoutTests {
    private let statusEndpoint = URL(string: "https://engine.example.com/inbound/status/live")!
    private let sleeper = ManualSleeper()

    private func harness(ringTimeout: Duration? = .seconds(60)) -> CallEngineHarness {
        let sleeper = sleeper
        return CallEngineHarness(ringTimeout: ringTimeout, sleep: { await sleeper.sleep($0) })
    }

    /// Ring and wait until the ring timer is sleeping.
    private func ringing(_ h: CallEngineHarness, callID: UUID = UUID(), ringTimeout: String? = nil) async {
        h.ring(callID: callID, statusURL: statusEndpoint, ringTimeout: ringTimeout)
        await waitUntil { sleeper.pendingCount == 1 }
    }

    @Test func theDefaultTimeoutIsSixtySeconds() {
        #expect(CallEngineConfiguration().ringTimeout == .seconds(60))
    }

    // MARK: - The timer fires

    @Test func anUnansweredRingEndsAsUnansweredAndIsMissed() async throws {
        let h = harness()
        let callID = UUID()
        await ringing(h, callID: callID)
        #expect(sleeper.requested == [.seconds(60)])

        sleeper.wakeAll()
        await waitUntil { h.engine.state == .idle }

        #expect(h.engine.state == .idle)
        #expect(h.engine.activeCall == nil)
        #expect(h.delegate.transitions == ["idle→incomingRinging", "incomingRinging→idle"])
        #expect(h.provider.reportedEnded.map(\.id) == [callID])
        #expect(h.provider.reportedEnded.first?.reason == .unanswered)
        let record = try #require(h.delegate.records.first)
        #expect(h.delegate.records.count == 1)
        #expect(record.targetID == h.target.id)
        #expect(record.direction == .incoming)
        #expect(record.outcome == .noAnswer)
        #expect(record.duration == 0)
        #expect(record.failureReason == nil)
        #expect(record.missedReason == .ringTimedOut)
        #expect(h.ringStatusReporter.reports == [
            .init(status: .unanswered, callID: callID, endpoint: statusEndpoint, apiKey: ""),
        ])
        #expect(h.delegate.cues.isEmpty)
        #expect(!h.interruption.isObserving)
        #expect(h.pushCompletions == 1)
        #expect(h.target.makeTransportCount == 0)
    }

    @Test func theNextRingAfterATimeoutRingsWithItsOwnTimer() async throws {
        let h = harness()
        await ringing(h)
        sleeper.wakeAll()
        await waitUntil { h.engine.state == .idle }

        h.ring()
        await waitUntil { sleeper.pendingCount == 1 }

        #expect(h.engine.state == .incomingRinging)
        #expect(sleeper.requested == [.seconds(60), .seconds(60)])
    }

    @Test func noTimeoutConfiguredMeansNoTimer() async throws {
        let h = harness(ringTimeout: nil)
        h.ring()
        await settle()

        #expect(sleeper.requested.isEmpty)
        #expect(h.engine.state == .incomingRinging)
    }

    // MARK: - Anything that ends the ring first wins

    enum FirstEnding: String, CaseIterable, Sendable {
        case answered, declined, providerReset, canceled, unknownTargetEnded
    }

    @Test(arguments: FirstEnding.allCases)
    func aTimerThatFiresAfterTheRingEndedChangesNothing(first: FirstEnding) async throws {
        let h = harness()
        let callID = UUID()
        h.ring(targetID: first == .unknownTargetEnded ? UUID() : nil, callID: callID, statusURL: statusEndpoint)
        await waitUntil { sleeper.pendingCount == 1 }
        switch first {
        case .answered: await h.engine.answer()
        case .declined: h.provider.simulateEndCall(callID)
        case .providerReset: h.provider.simulateReset()
        case .canceled: h.cancel(callID: callID)
        case .unknownTargetEnded: break // ended as soon as CallKit accepted it
        }
        let state = h.engine.state
        let events = h.delegate.events
        let ended = h.provider.reportedEnded.map(\.id)
        let receipts = h.ringStatusReporter.reports

        sleeper.wakeAll()
        await settle()

        #expect(h.engine.state == state)
        #expect(h.delegate.events == events)
        #expect(h.provider.reportedEnded.map(\.id) == ended)
        #expect(h.ringStatusReporter.reports == receipts)
        #expect(!h.delegate.records.contains { $0.missedReason == .ringTimedOut })
    }

    /// CallKit delivered the answer action, but `answer()` has not run yet when the
    /// timer fires: the answer must win.
    @Test func anAnswerActionAlreadyDeliveredBeatsTheTimer() async throws {
        let h = harness()
        let callID = UUID()
        await ringing(h, callID: callID)

        sleeper.wakeAll() // the timer resumes first...
        h.provider.simulateAnswerCall(callID) // ...then the answer action arrives
        await waitUntil { h.engine.state.isConnecting }

        #expect(h.engine.state.isConnecting)
        #expect(h.provider.reportedEnded.isEmpty)
        #expect(h.delegate.records.isEmpty)
        #expect(h.ringStatusReporter.reports.map(\.status) == [.answered])
    }

    @Test func anEarlierRingsTimerDoesNotEndTheNextRing() async throws {
        let h = harness()
        let first = UUID()
        await ringing(h, callID: first)
        h.provider.simulateEndCall(first) // declined; its timer still sleeps
        h.engine.reset()
        let second = UUID()
        h.ring(callID: second)
        await waitUntil { sleeper.pendingCount == 2 }

        sleeper.wakeFirst() // only the first ring's timeout elapses
        await settle()

        #expect(h.engine.state == .incomingRinging)
        #expect(!h.provider.reportedEnded.map(\.id).contains(second))
    }

    @Test func aBusyRingStartsNoTimerOfItsOwn() async throws {
        let h = harness()
        await ringing(h)

        h.ring() // busy
        await settle()

        #expect(sleeper.requested == [.seconds(60)])
        #expect(h.engine.state == .incomingRinging)
    }

    // MARK: - The push's ring_timeout

    struct PushedTimeout: Sendable, CustomTestStringConvertible {
        let pushed: String?
        let configured: Duration?
        let expected: Duration?
        var testDescription: String {
            "pushed \(pushed ?? "nil"), configured \(configured.map { "\($0)" } ?? "nil")"
        }
    }

    @Test(arguments: [
        PushedTimeout(pushed: "30", configured: .seconds(60), expected: .seconds(30)),
        PushedTimeout(pushed: "90", configured: .seconds(60), expected: .seconds(60)),
        PushedTimeout(pushed: "5", configured: .seconds(60), expected: .seconds(10)),
        PushedTimeout(pushed: "10", configured: .seconds(60), expected: .seconds(10)),
        PushedTimeout(pushed: "30", configured: .seconds(5), expected: .seconds(5)),
        PushedTimeout(pushed: "30", configured: nil, expected: .seconds(30)),
        PushedTimeout(pushed: "3", configured: nil, expected: .seconds(10)),
        PushedTimeout(pushed: nil, configured: .seconds(45), expected: .seconds(45)),
        PushedTimeout(pushed: "0", configured: .seconds(60), expected: .seconds(60)),
        PushedTimeout(pushed: "-20", configured: .seconds(60), expected: .seconds(60)),
        PushedTimeout(pushed: "20.5", configured: .seconds(60), expected: .seconds(60)),
        PushedTimeout(pushed: "soon", configured: .seconds(60), expected: .seconds(60)),
        PushedTimeout(pushed: nil, configured: nil, expected: nil),
    ])
    func aPushMayShortenTheRingButNeverLengthenIt(_ example: PushedTimeout) async throws {
        let h = harness(ringTimeout: example.configured)
        h.ring(ringTimeout: example.pushed)
        if example.expected == nil {
            await settle()
        } else {
            await waitUntil { sleeper.pendingCount == 1 }
        }

        #expect(sleeper.requested == [example.expected].compactMap { $0 })
    }

    @Test func aRingTimeoutThatIsNotAStringIsIgnored() async throws {
        let h = harness()
        h.deliverPush([
            "target_id": h.target.id.uuidString, "call_id": UUID().uuidString, "ring_timeout": 20,
        ])
        await waitUntil { sleeper.pendingCount == 1 }

        #expect(sleeper.requested == [.seconds(60)])
    }

    // MARK: - Missed-call semantics

    @Test(arguments: [
        (MissedCallReason.busy, false), (.filteredByFocus, false), (.ringTimedOut, true), (.canceledByCaller, true),
    ])
    func reachedUserTellsARingTheUserSawFromOneTheyDidNot(reason: MissedCallReason, reachedUser: Bool) {
        #expect(reason.reachedUser == reachedUser)
    }

    @Test func missedReasonsHaveStableRawValues() throws {
        #expect(MissedCallReason.allRawValues == ["busy", "filteredByFocus", "ringTimedOut", "canceledByCaller"])
        let encoded = try JSONEncoder().encode([MissedCallReason.ringTimedOut])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["ringTimedOut"]"#)
    }
}

private extension MissedCallReason {
    static var allRawValues: [String] {
        [MissedCallReason.busy, .filteredByFocus, .ringTimedOut, .canceledByCaller].map(\.rawValue)
    }
}
