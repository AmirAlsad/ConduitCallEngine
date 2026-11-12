//
//  SignalDeliveryTests.swift
//  ConduitCallEngineTests
//
//  The agent converges on the call's real state: a call-control signal the
//  transport could not send is sent again, as the current state, after a short and
//  growing wait, a bounded number of times, and on the next connection. The agent
//  counts as possibly held until a `resumed` is known to have left the device.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct SignalDeliveryTests {
    private let sleeper = ManualSleeper()

    private func harness() -> CallEngineHarness {
        let sleeper = sleeper
        return CallEngineHarness(sleep: { await sleeper.sleep($0) })
    }

    private func liveCall(_ h: CallEngineHarness) async {
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.activate(FakeAudioSession())
    }

    private func setHeld(_ h: CallEngineHarness, _ onHold: Bool) async {
        h.provider.simulateSetHeld(h.callID, onHold: onHold)
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()
        await settle()
    }

    @Test func aResumeThatFailsToSendIsSentAgain() async throws {
        let h = harness()
        await liveCall(h)
        await setHeld(h, true)
        h.transport.signalDeliveries = [.failed]

        await setHeld(h, false)
        #expect(h.transport.sentSignals == [.held, .resumed])
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested == [.seconds(1)])
        sleeper.wakeFirst()
        await waitUntil { h.transport.sentSignals.count == 3 }
        await settle()

        #expect(h.transport.sentSignals == [.held, .resumed, .resumed])
        #expect(sleeper.pendingCount == 0) // sent: nothing more to retry
    }

    @Test func aHoldThatFailsToSendIsSentAgainWhileHeld() async throws {
        let h = harness()
        await liveCall(h)
        h.transport.signalDeliveries = [.failed]

        await setHeld(h, true)
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.wakeFirst()
        await waitUntil { h.transport.sentSignals.count == 2 }

        #expect(h.transport.sentSignals == [.held, .held])
    }

    /// A retry sends the call's state when it runs, not the signal that failed.
    @Test func aRetryAfterTheStateChangedSendsTheCurrentState() async throws {
        let h = harness()
        await liveCall(h)
        h.transport.signalDeliveries = [.failed]
        await setHeld(h, true)
        await waitUntil { sleeper.pendingCount == 1 }

        await setHeld(h, false)
        sleeper.wakeFirst()
        await settle()

        #expect(h.transport.sentSignals == [.held, .resumed])
    }

    @Test func aSignalThatKeepsFailingIsRetriedAFewTimesThenOnTheNextConnection() async throws {
        let h = harness()
        await liveCall(h)
        await setHeld(h, true)
        h.transport.signalDeliveries = Array(repeating: .failed, count: 7)

        await setHeld(h, false)
        for _ in 0..<6 {
            await waitUntil { sleeper.pendingCount == 1 }
            sleeper.wakeFirst()
            await settle()
        }
        await settle()
        #expect(sleeper.requested == [1, 2, 4, 8, 16, 30].map { .seconds($0) })
        #expect(sleeper.pendingCount == 0) // gives up on this connection
        #expect(h.transport.sentSignals.filter { $0 == .resumed }.count == 7)

        h.engine.handle(.reconnecting)
        h.engine.handle(.connected) // a new connection: the agent may still think it is held
        await h.engine.awaitPendingSignals()

        #expect(h.transport.sentSignals.filter { $0 == .resumed }.count == 8)
    }

    /// Before, a resume was taken as heard the moment it was queued.
    @Test func aResumeThatFailedIsSentAgainAfterAReconnect() async throws {
        let h = harness()
        await liveCall(h)
        await setHeld(h, true)
        h.transport.signalDeliveries = [.failed]
        await setHeld(h, false)

        h.engine.handle(.reconnecting) // the connection goes before the retry runs
        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()

        #expect(h.transport.sentSignals == [.held, .resumed, .resumed])
    }

    @Test func anAnswerThatFailsToSendIsSentAgain() async throws {
        let h = harness()
        h.ring(preconnect: "media") // the host allows no preparation; the agent still waits
        await h.engine.answer()
        h.engine.handle(.connected)
        h.transport.signalDeliveries = [.failed]
        await h.engine.activate(FakeAudioSession())
        await h.engine.awaitPendingSignals()
        #expect(h.transport.sentSignals == [.answered])

        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.wakeFirst()
        await waitUntil { h.transport.sentSignals.count == 2 }

        #expect(h.transport.sentSignals == [.answered, .answered])
    }

    @Test func aTransportWithoutSignalsIsNeverAskedAgain() async throws {
        let h = harness()
        await liveCall(h)
        h.transport.signalDeliveries = [.unsupported, .unsupported]

        await setHeld(h, true)
        await setHeld(h, false)
        await settle()

        #expect(h.transport.sentSignals == [.held, .resumed])
        #expect(sleeper.requested.isEmpty)
    }

    @Test func aRetryPendingWhenTheCallEndsChangesNothing() async throws {
        let h = harness()
        await liveCall(h)
        h.transport.signalDeliveries = [.failed]
        await setHeld(h, true)
        await waitUntil { sleeper.pendingCount == 1 }

        await h.engine.endCall()
        sleeper.wakeAll()
        await settle()

        #expect(h.transport.sentSignals == [.held])
    }
}
