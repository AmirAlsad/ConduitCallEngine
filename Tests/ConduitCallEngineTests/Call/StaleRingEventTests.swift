//
//  StaleRingEventTests.swift
//  ConduitCallEngineTests
//
//  A ring that ends without ever becoming a call (timed out, withdrawn, filtered,
//  refused) goes straight back to `.idle`. An event its prepared transport had
//  already sent can still reach the engine after that; it belongs to a call that
//  no longer exists and must change nothing.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct StaleRingEventTests {

    enum RingEnding: String, CaseIterable, Sendable {
        case canceledByTheCaller, timedOut, providerReset
    }

    /// The events that would end, fail or reconnect a live call.
    static let terminalEvents: [TransportEvent] = [
        .disconnected(reason: .botLeft),
        .disconnected(reason: .authFailed),
        .disconnected(reason: .networkDropped),
        .error(.authenticationFailed),
        .error(.connectionFailed("late")),
        .connected,
        .reconnecting,
    ]

    @Test(arguments: RingEnding.allCases)
    func anEventFromARingThatEndedToIdleChangesNothing(_ ending: RingEnding) async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(ringTimeout: .seconds(30), sleep: { await sleeper.sleep($0) })
        h.allowRingPreparation(.media)
        h.transport.canConnectWhileRinging = true
        let callID = UUID()
        h.ring(callID: callID, preconnect: "media")
        await settle()
        #expect(h.engine.ringPreparationPhase == .connecting)

        switch ending {
        case .canceledByTheCaller: h.cancel(callID: callID)
        case .timedOut: #expect(h.engine.fireTimer(.ringTimeout))
        case .providerReset: h.provider.simulateReset()
        }
        #expect(h.engine.state == .idle)
        let transitions = h.delegate.transitions
        let records = h.delegate.records.count
        let ended = h.provider.reportedEnded.count

        for event in Self.terminalEvents {
            h.engine.handle(event)
        }
        await h.engine.awaitPendingWork()

        #expect(h.engine.state == .idle)
        #expect(h.engine.activeCall == nil)
        #expect(h.delegate.transitions == transitions)
        #expect(h.delegate.records.count == records)
        #expect(h.provider.reportedEnded.count == ended)
    }
}
