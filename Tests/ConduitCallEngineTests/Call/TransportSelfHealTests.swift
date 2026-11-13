//
//  TransportSelfHealTests.swift
//  ConduitCallEngineTests
//
//  A transport that heals itself reports `.reconnecting` and then `.connected`
//  or `.disconnected`. These pin how the engine composes those with its own
//  reconnect loop and with the call ending, in every order a transport (LiveKit's
//  SDK, or the Daily adapter's network-path inference) can produce.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct TransportSelfHealTests {
    private let clock = MutableClock()
    private let h: CallEngineHarness

    init() {
        // Holding is on for the one test that holds; nothing else here holds.
        h = CallEngineHarness(supportsHolding: true, now: { [clock] in clock.now() })
    }

    private func selfHealingCall() async {
        await h.placeCall()
        h.engine.handle(.connected)
        clock.advance(30)
        h.engine.handle(.reconnecting)
    }

    @Test func recoveryReturnsToConnectedWithoutSpendingARetry() async {
        let connectedAt = clock.now()
        await selfHealingCall()
        #expect(h.engine.state == .reconnecting(attempt: 0))

        h.engine.handle(.connected)

        #expect(h.engine.state == .connected(since: connectedAt))
        #expect(h.engine.reconnectTask == nil)
        #expect(h.transport.connectCount == 1)
        #expect(Array(h.delegate.transitions.suffix(2)) == [
            "connected→reconnecting(0)", "reconnecting(0)→connected",
        ])
    }

    @Test func aDropWhileHealingStartsTheEnginesReconnect() async {
        await selfHealingCall()

        h.engine.handle(.disconnected(reason: .networkDropped))

        #expect(h.engine.state == .reconnecting(attempt: 1))
        await h.engine.awaitPendingReconnect()
        #expect(h.transport.connectCount == 2)

        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected)
        #expect(Array(h.delegate.transitions.suffix(3)) == [
            "connected→reconnecting(0)", "reconnecting(0)→reconnecting(1)", "reconnecting(1)→connected",
        ])
    }

    @Test func aDropAfterAnnouncedRecoveryStartsTheEnginesReconnect() async {
        await selfHealingCall()
        h.engine.handle(.connected)

        h.engine.handle(.disconnected(reason: .networkDropped))

        #expect(h.engine.state == .reconnecting(attempt: 1))
        await h.engine.awaitPendingReconnect()
        #expect(h.transport.connectCount == 2)
    }

    @Test func endingTheCallWhileHealingEndsItAsCompleted() async {
        await selfHealingCall()

        await h.engine.endCall()
        h.engine.handle(.connected) // a recovery that arrives after the end

        #expect(h.engine.state == .ended(.completed))
        #expect(h.delegate.records.map(\.outcome) == [.completed])
        await waitUntil { h.transport.disconnectCount == 1 }
        #expect(h.transport.disconnectCount == 1)
    }

    // MARK: - The bound on waiting for a transport to heal itself

    private func boundedHealingCall() async -> (CallEngineHarness, ManualSleeper) {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(sleep: { [sleeper] in await sleeper.sleep($0) })
        await h.placeCall()
        h.engine.handle(.connected)
        h.engine.handle(.reconnecting)
        await waitUntil { sleeper.pendingCount == 1 }
        return (h, sleeper)
    }

    @Test func healingThatOutlastsTheBoundStartsTheEnginesReconnect() async throws {
        let (h, sleeper) = await boundedHealingCall()
        #expect(sleeper.requested == [.seconds(30)])
        #expect(h.engine.state == .reconnecting(attempt: 0))

        sleeper.wakeAll() // 30 seconds pass with no word from the transport

        await waitUntil { h.engine.state == .reconnecting(attempt: 1) }
        #expect(h.engine.state == .reconnecting(attempt: 1))
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested == [.seconds(30), .seconds(1)]) // then the policy's backoff
        sleeper.wakeAll()
        await h.engine.awaitPendingReconnect()

        #expect(h.target.connectCount == 2) // fresh credentials
        #expect(h.transport.connectCount == 2) // on the same transport
        #expect(h.transport.disconnectCount == 0) // no end-call signal
        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected)
        #expect(Array(h.delegate.transitions.suffix(3)) == [
            "connected→reconnecting(0)", "reconnecting(0)→reconnecting(1)", "reconnecting(1)→connected",
        ])
    }

    @Test func recoveryWithinTheBoundStopsIt() async throws {
        let (h, sleeper) = await boundedHealingCall()

        h.engine.handle(.connected)
        sleeper.wakeAll()
        await settle(ticks: 50) // the bound, had it not stopped, would start a reconnect

        #expect(h.engine.state.isConnected)
        #expect(h.engine.reconnectTask == nil)
        #expect(h.target.connectCount == 1)
    }

    @Test func endingWhileHealingStopsTheBound() async throws {
        let (h, sleeper) = await boundedHealingCall()

        await h.engine.endCall()
        sleeper.wakeAll()
        await settle(ticks: 50) // the bound, had it not stopped, would start a reconnect

        #expect(h.engine.state == .ended(.completed))
        #expect(h.target.connectCount == 1)
        #expect(h.delegate.records.count == 1)
    }

    @Test func aDropWhileHealingReplacesTheBound() async throws {
        let (h, sleeper) = await boundedHealingCall()

        h.engine.handle(.disconnected(reason: .networkDropped))
        #expect(h.engine.state == .reconnecting(attempt: 1))
        sleeper.wakeAll() // the bound, and the first backoff
        await waitUntil { sleeper.pendingCount > 0 || h.target.connectCount == 2 }
        sleeper.wakeAll()
        await h.engine.awaitPendingReconnect()

        #expect(h.target.connectCount == 2) // one attempt, not two
        #expect(h.engine.state == .reconnecting(attempt: 1))
    }

    @Test func theBoundOfAnEarlierHealDoesNotCutAShorterLaterOne() async throws {
        let (h, sleeper) = await boundedHealingCall()
        h.engine.handle(.connected)
        h.engine.handle(.reconnecting) // a second interruption, with its own bound
        await waitUntil { sleeper.pendingCount == 2 }
        #expect(sleeper.pendingCount == 2)

        sleeper.wakeFirst() // the first interruption's bound runs out
        await settle(ticks: 50) // the bound, had it not stopped, would start a reconnect
        #expect(h.engine.state == .reconnecting(attempt: 0))
        #expect(h.engine.reconnectTask == nil)

        sleeper.wakeFirst() // the second one's does
        await waitUntil { h.engine.state == .reconnecting(attempt: 1) }
        #expect(h.engine.state == .reconnecting(attempt: 1))
    }

    // MARK: - A recovery while the engine's attempt is joining

    /// The engine's attempt is inside `transport.connect` when `.connected` arrives
    /// (the join itself reported it, or the heal finished). A transport may be taking
    /// its session over there; cancelling that join could abort the session the call
    /// now counts as connected.
    private func attemptJoining() async throws -> Task<Void, Never> {
        await h.placeCall()
        h.engine.handle(.connected)
        h.transport.suspendConnect = true
        h.engine.handle(.disconnected(reason: .networkDropped))
        await waitUntil { h.transport.connectCount == 2 }
        #expect(h.transport.connectCount == 2)
        return try #require(h.engine.reconnectTask)
    }

    @Test func aRecoveryDuringTheJoinLeavesTheJoinRunning() async throws {
        let attempt = try await attemptJoining()

        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected)
        h.transport.releaseConnect()
        await attempt.value

        #expect(h.transport.canceledConnectCount == 0)
        #expect(h.engine.state.isConnected)
        #expect(h.engine.reconnectTask == nil)
    }

    @Test func aJoinThatFailsAfterTheCallRecoveredChangesNothing() async throws {
        let attempt = try await attemptJoining()
        h.engine.handle(.connected)
        let transitions = h.delegate.transitions

        h.transport.connectError = .connectionFailed("superseded")
        h.transport.releaseConnect()
        await attempt.value
        await settle()

        #expect(h.engine.state.isConnected)
        #expect(h.delegate.transitions == transitions)
        #expect(h.transport.connectCount == 2) // no further attempt
    }

    @Test func aRecoveryWhileFetchingCredentialsStillCancelsTheAttempt() async throws {
        await h.placeCall()
        h.engine.handle(.connected)
        h.target.suspend = true
        h.engine.handle(.disconnected(reason: .networkDropped))
        await waitUntil { h.target.connectCount == 2 }
        let attempt = try #require(h.engine.reconnectTask)

        h.engine.handle(.connected)
        h.target.release()
        await attempt.value

        #expect(h.transport.connectCount == 1) // never joined: the call had recovered
    }

    @Test func aHoldDuringTheJoinLeavesItRunning() async throws {
        let attempt = try await attemptJoining()

        #expect(h.engine.providerPerformSetHeld(h.callID, onHold: true))
        #expect(h.engine.state == .reconnecting(attempt: 0))
        h.transport.releaseConnect()
        await attempt.value
        h.engine.handle(.connected) // the join the hold did not cancel succeeded

        #expect(h.transport.canceledConnectCount == 0)
        #expect(h.engine.state.isConnected)
        #expect(h.engine.isOnHold)
    }

    @Test func theRemoteLeavingWhileHealingEndsTheCall() async {
        await selfHealingCall()

        h.engine.handle(.disconnected(reason: .botLeft))
        h.engine.handle(.connected)

        #expect(h.engine.state == .ended(.completed))
        #expect(h.provider.reportedEnded.map(\.reason) == [.remoteEnded])
        #expect(h.delegate.records.map(\.outcome) == [.completed])
    }
}
