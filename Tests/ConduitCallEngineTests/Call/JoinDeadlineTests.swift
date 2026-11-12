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

    // MARK: - The first connect

    enum Direction: String, CaseIterable, Sendable {
        case outgoing, incoming
    }

    /// A call whose transport joined, waiting for the agent: the bound is sleeping.
    private func firstConnectWaitingForTheAgent(_ h: CallEngineHarness, _ direction: Direction) async {
        switch direction {
        case .outgoing:
            await h.placeCall()
        case .incoming:
            h.ring()
            await h.engine.answer()
        }
        await waitUntil { sleeper.pendingCount == 1 }
    }

    @Test(arguments: Direction.allCases)
    func aCallWhoseAgentNeverJoinsFailsAsAgentUnreachable(direction: Direction) async throws {
        let h = harness()
        await firstConnectWaitingForTheAgent(h, direction)
        #expect(sleeper.requested == [.seconds(30)])
        #expect(h.engine.state == .connecting)

        sleeper.wakeFirst()

        await waitUntil { h.engine.state.isTerminal }
        #expect(h.engine.state == .failed(.agentUnreachable))
        let record = try #require(h.delegate.records.first)
        #expect(h.delegate.records.count == 1)
        #expect(record.outcome == .failed)
        #expect(record.failureReason == .agentUnreachable)
        #expect(h.provider.reportedEnded.map(\.reason) == [.failed])
        await waitUntil { h.transport.disconnectCount == 1 }
        #expect(h.transport.disconnectCount == 1) // the end-call signal, for an agent that turns up late
        #expect(h.delegate.cues == [.start(.connecting), .stop])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test(arguments: Direction.allCases)
    func anAgentThatJoinsInTimeConnectsTheCall(direction: Direction) async throws {
        let h = harness()
        await firstConnectWaitingForTheAgent(h, direction)

        h.engine.handle(.connected)
        sleeper.wakeAll()
        await settle()

        #expect(h.engine.state.isConnected)
        #expect(h.delegate.records.isEmpty)
    }

    @Test func endingTheCallWhileWaitingForTheAgentStopsTheBound() async throws {
        let h = harness()
        await firstConnectWaitingForTheAgent(h, .outgoing)

        await h.engine.endCall()
        sleeper.wakeAll()
        await settle()

        #expect(h.engine.state == .ended(.canceled))
        #expect(h.delegate.records.map(\.outcome) == [.canceled])
    }

    @Test func aConnectThatReportsConnectedBeforeItReturnsStartsNoBound() async throws {
        let h = harness()
        h.transport.suspendConnect = true
        let place = Task { await h.placeCall() }
        await waitUntil { h.transport.connectCount == 1 }
        h.engine.handle(.connected)
        h.transport.releaseConnect()
        await place.value
        await settle()

        #expect(h.engine.state.isConnected)
        #expect(sleeper.requested.isEmpty)
    }

    @Test func aFirstConnectThatThrowsFailsAsBeforeWithoutABound() async throws {
        let h = harness()
        h.transport.connectError = .connectionFailed("refused")

        await h.placeCall()
        await settle()

        #expect(h.engine.state == .failed(.transportError))
        #expect(sleeper.requested.isEmpty)
    }

    /// The call id CallKit knows the first connect's call by.
    private func callID(_ h: CallEngineHarness, _ direction: Direction) throws -> UUID {
        switch direction {
        case .outgoing: h.callID
        case .incoming: try #require(h.provider.reportedIncoming.first?.id)
        }
    }

    /// The user is on another call: the agent may not get ready meanwhile (on Daily
    /// it cannot, since a held call's agent audio is unsubscribed), and the user is
    /// not waiting for it. The bound runs again, in full, from the resume.
    @Test(arguments: Direction.allCases)
    func aHoldWhileWaitingForTheAgentStopsTheBoundUntilTheResume(direction: Direction) async throws {
        let h = harness()
        await firstConnectWaitingForTheAgent(h, direction)
        let id = try callID(h, direction)

        #expect(h.engine.providerPerformSetHeld(id, onHold: true))
        sleeper.wakeAll() // the bound that was running when the call was held
        await settle()
        #expect(h.engine.state == .connecting)
        #expect(h.delegate.records.isEmpty)

        #expect(h.engine.providerPerformSetHeld(id, onHold: false))
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested == [.seconds(30), .seconds(30)])
        h.engine.handle(.connected)

        #expect(h.engine.state.isConnected)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func aJoinThatReturnsWhileHeldStartsItsBoundAtTheResume() async throws {
        let h = harness()
        h.transport.suspendConnect = true
        let place = Task { await h.placeCall() }
        await waitUntil { h.transport.connectCount == 1 }
        #expect(h.engine.providerPerformSetHeld(h.callID, onHold: true))
        h.transport.releaseConnect()
        await place.value
        await settle()
        #expect(sleeper.requested.isEmpty)

        #expect(h.engine.providerPerformSetHeld(h.callID, onHold: false))
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested == [.seconds(30)])
        sleeper.wakeFirst()
        await waitUntil { h.engine.state.isTerminal }

        #expect(h.engine.state == .failed(.agentUnreachable))
    }

    @Test func noBoundConfiguredLeavesTheCallConnecting() async throws {
        let h = harness(joinTimeout: nil)
        await h.placeCall()
        await settle()

        #expect(h.engine.state == .connecting)
        #expect(sleeper.requested.isEmpty)
    }

    // MARK: - Reconnect attempts

    /// A placed call that connected in time. The first connect's bound is cancelled
    /// but still asleep in the `ManualSleeper`; it is woken, and stays inert.
    private func connectedCall(_ h: CallEngineHarness) async {
        await h.placeCall()
        if h.engine.state == .connecting, sleeper.pendingCount == 0 {
            await waitUntil { sleeper.pendingCount == 1 }
        }
        h.engine.handle(.connected)
        sleeper.wakeAll()
        await settle()
    }

    /// A connected call that dropped, with the engine's first attempt joined and
    /// waiting for the agent: the backoff has run and the bound is sleeping.
    private func attemptWaitingForTheAgent(_ h: CallEngineHarness) async {
        await connectedCall(h)
        h.engine.handle(.disconnected(reason: .networkDropped))
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.wakeFirst() // the backoff before attempt 1
        await waitUntil { h.transport.connectCount == 2 && sleeper.pendingCount == 1 }
    }

    @Test func anAttemptThatJoinsButNeverReportsCountsAsFailed() async throws {
        let h = harness()
        await attemptWaitingForTheAgent(h)
        #expect(sleeper.requested == [.seconds(30), .seconds(1), .seconds(30)])
        #expect(h.engine.state == .reconnecting(attempt: 1))

        sleeper.wakeFirst() // 30 seconds with no `.connected`

        await waitUntil { h.engine.state == .reconnecting(attempt: 2) }
        #expect(h.engine.state == .reconnecting(attempt: 2))
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested == [.seconds(30), .seconds(1), .seconds(30), .seconds(2)]) // the next backoff
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
        await connectedCall(h)
        h.transport.connectError = .connectionFailed("refused")
        h.engine.handle(.disconnected(reason: .networkDropped))
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.wakeFirst()

        await waitUntil { h.engine.state == .reconnecting(attempt: 2) }
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested == [.seconds(30), .seconds(1), .seconds(2)]) // the first connect's bound, then backoffs only
    }

    @Test func noBoundConfiguredWaitsForTheTransport() async throws {
        let h = harness(joinTimeout: nil)
        await connectedCall(h)
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
