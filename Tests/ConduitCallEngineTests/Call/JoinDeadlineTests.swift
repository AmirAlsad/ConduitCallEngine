//
//  JoinDeadlineTests.swift
//  ConduitCallEngineTests
//
//  The bound on waiting for `.connected` once a transport's `connect` has
//  returned. A transport can join and then never report the agent ready; without
//  a bound the call would wait forever. Time is the engine's injected sleep (a
//  `ManualSleeper`), so each test decides when the bound runs out.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct JoinDeadlineTests {
    private let sleeper = ManualSleeper()

    private func harness(
        joinTimeout: Duration? = .seconds(30),
        policy: ReconnectionPolicy = .default
    ) -> CallEngineHarness {
        let sleeper = sleeper
        return CallEngineHarness(policy: policy, joinTimeout: joinTimeout, sleep: { await sleeper.sleep($0) })
    }

    @Test func theDefaultBoundIsThirtySeconds() {
        #expect(CallEngineConfiguration().joinTimeout == .seconds(30))
    }

    // MARK: - Reconnect attempts

    /// A connected call that dropped, with the engine's first attempt joined and
    /// waiting for the agent: the backoff has run and the bound is sleeping.
    private func attemptWaitingForTheAgent(_ h: CallEngineHarness) async {
        await h.placeCall()
        h.engine.handle(.connected)
        h.engine.handle(.disconnected(reason: .networkDropped))
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.wakeFirst() // the backoff before attempt 1
        await waitUntil { h.transport.connectCount == 2 && sleeper.pendingCount == 1 }
    }

    @Test func anAttemptThatJoinsButNeverReportsCountsAsFailed() async throws {
        let h = harness()
        await attemptWaitingForTheAgent(h)
        #expect(sleeper.requested == [.seconds(1), .seconds(30)])
        #expect(h.engine.state == .reconnecting(attempt: 1))

        sleeper.wakeFirst() // 30 seconds with no `.connected`

        await waitUntil { h.engine.state == .reconnecting(attempt: 2) }
        #expect(h.engine.state == .reconnecting(attempt: 2))
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested == [.seconds(1), .seconds(30), .seconds(2)]) // the next backoff
        sleeper.wakeFirst()
        await waitUntil { h.transport.connectCount == 3 }
        #expect(h.target.connectCount == 3) // fresh credentials for the next attempt
        #expect(h.transport.connectCount == 3)
        #expect(h.transport.disconnectCount == 0)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func theLastAttemptRunningOutEndsTheCall() async throws {
        let h = harness(policy: ReconnectionPolicy(maxAttempts: 1, baseDelaySeconds: 1, maxDelaySeconds: 1))
        await attemptWaitingForTheAgent(h)

        sleeper.wakeFirst()

        await waitUntil { h.engine.state.isTerminal }
        #expect(h.engine.state == .failed(.lostConnection))
        #expect(h.delegate.records.map(\.failureReason) == [.lostConnection])
        #expect(h.provider.reportedEnded.map(\.reason) == [.failed])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func anAgentThatArrivesInTimeStopsTheBound() async throws {
        let h = harness()
        await attemptWaitingForTheAgent(h)

        h.engine.handle(.connected)
        sleeper.wakeAll()
        await settle()

        #expect(h.engine.state.isConnected)
        #expect(h.transport.connectCount == 2)
        #expect(sleeper.pendingCount == 0)
    }

    @Test func aDropWhileWaitingReplacesTheBound() async throws {
        let h = harness()
        await attemptWaitingForTheAgent(h)

        h.engine.handle(.disconnected(reason: .networkDropped)) // the attempt failed after all
        #expect(h.engine.state == .reconnecting(attempt: 2))
        await waitUntil { sleeper.pendingCount == 2 }
        sleeper.wakeFirst() // the first attempt's bound: stale
        await settle()

        #expect(h.engine.state == .reconnecting(attempt: 2))
        #expect(h.transport.connectCount == 2)
    }

    @Test func endingTheCallWhileWaitingStopsTheBound() async throws {
        let h = harness()
        await attemptWaitingForTheAgent(h)

        await h.engine.endCall()
        sleeper.wakeAll()
        await settle()

        #expect(h.engine.state == .ended(.completed))
        #expect(h.delegate.records.count == 1)
        #expect(h.transport.connectCount == 2)
    }

    @Test func anAttemptThatThrowsStartsNoBound() async throws {
        let h = harness()
        await h.placeCall()
        h.engine.handle(.connected)
        h.transport.connectError = .connectionFailed("refused")
        h.engine.handle(.disconnected(reason: .networkDropped))
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.wakeFirst()

        await waitUntil { h.engine.state == .reconnecting(attempt: 2) }
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested == [.seconds(1), .seconds(2)]) // backoffs only
    }

    @Test func noBoundConfiguredWaitsForTheTransport() async throws {
        let h = harness(joinTimeout: nil)
        await h.placeCall()
        h.engine.handle(.connected)
        h.engine.handle(.disconnected(reason: .networkDropped))
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.wakeFirst()
        await waitUntil { h.transport.connectCount == 2 }
        await settle()

        #expect(sleeper.requested == [.seconds(1)])
        #expect(h.engine.state == .reconnecting(attempt: 1))
    }

    @Test func aHoldWhileWaitingPausesTheReconnect() async throws {
        let h = harness()
        await attemptWaitingForTheAgent(h)

        #expect(h.engine.providerPerformSetHeld(h.callID, onHold: true))
        #expect(h.engine.state == .reconnecting(attempt: 0))
        sleeper.wakeAll() // the bound of the attempt the hold paused
        await settle()

        #expect(h.engine.state == .reconnecting(attempt: 0))
        #expect(h.transport.connectCount == 2)
    }
}
