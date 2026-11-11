//
//  CallCredentialResolutionTests.swift
//  ConduitCallEngineTests
//
//  The credential step between creating the transport and joining the room
//  (`CallTarget.connect`): once per attempt, and the races where CallKit
//  activation or the user's End lands while credentials are in flight. What an
//  agent's target resolves to is in AgentCallTargetTests / AgentCallHostTests.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct CallCredentialResolutionTests {

    // MARK: - Ordering against CallKit activation

    @Test func activationDuringSuspendedResolveAttachesTheTransport() async throws {
        let h = CallEngineHarness()
        h.target.suspend = true

        let place = Task { await h.placeCall() }
        await waitUntil { h.target.connectCount == 1 }
        #expect(h.target.connectCount == 1)
        #expect(h.target.makeTransportCount == 1) // created before the fetch
        #expect(h.transport.connectCount == 0)

        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()
        #expect(h.transport.isAudioAttached)

        h.target.release()
        await place.value

        #expect(h.transport.connectCount == 1)
        #expect(h.transport.lastConnection == h.target.connection)
        #expect(h.transport.isAudioAttached)
    }

    // MARK: - Ending while credentials are in flight

    @Test func endDuringSuspendedFirstResolveNeverJoinsTheRoom() async throws {
        let h = CallEngineHarness()
        h.target.suspend = true

        let place = Task { await h.placeCall() }
        await waitUntil { h.target.connectCount == 1 }
        #expect(h.target.connectCount == 1)
        await h.engine.endCall()
        #expect(h.engine.state.endedOutcome == .canceled)

        h.target.release()
        await place.value

        #expect(h.transport.connectCount == 0)
        #expect(h.engine.state.endedOutcome == .canceled)
        #expect(h.delegate.records.map(\.outcome) == [.canceled])
    }

    @Test(arguments: [false, true])
    func endDuringSuspendedRetryKeepsTheCallTerminal(retryFails: Bool) async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.target.suspend = true
        h.engine.handle(.disconnected(reason: .networkDropped))
        #expect(h.engine.state.reconnectingAttempt == 1)
        await waitUntil { h.target.connectCount == 2 }
        #expect(h.target.connectCount == 2)
        let retry = try #require(h.engine.reconnectTask)

        await h.engine.endCall()
        #expect(h.engine.state.endedOutcome == .completed)

        if retryFails { h.target.error = TransportError.connectionFailed("pairing: server(503)") }
        h.target.release()
        await retry.value

        #expect(h.engine.state.endedOutcome == .completed)
        #expect(h.engine.reconnectTask == nil)
        #expect(h.transport.connectCount == 1) // the retry never joined
        #expect(h.delegate.transitions.filter { $0.contains("→reconnecting") } == ["connected→reconnecting(1)"])
        #expect(h.delegate.transitions.last == "reconnecting(1)→ended(completed)")
        #expect(h.delegate.records.count == 1)
    }

    // MARK: - Awaits that outlive the call (or come before its transport)

    @Test func cancelledPlaceCallTaskStillJoins() async throws {
        let h = CallEngineHarness()
        h.target.suspend = true

        let place = Task { await h.placeCall() }
        await waitUntil { h.target.connectCount == 1 }
        #expect(h.target.connectCount == 1)
        place.cancel() // e.g. a SwiftUI `.task` going away; the call is not over

        h.target.release()
        await place.value

        #expect(h.transport.connectCount == 1)
        #expect(h.engine.state.isConnecting)
    }

    @Test(arguments: [false, true])
    func endWhileDialingEndsTheStartedCallAndNeverJoins(resetBeforeStartReturns: Bool) async throws {
        let h = CallEngineHarness()
        h.provider.suspendStart = true

        let place = Task { await h.placeCall() }
        await waitUntil { h.provider.pendingStartCount == 1 }
        #expect(h.provider.pendingStartCount == 1)
        await h.engine.endCall()
        #expect(h.engine.state.endedOutcome == .canceled)
        #expect(h.provider.endRequests.isEmpty) // CallKit had no call id yet
        if resetBeforeStartReturns { h.engine.reset() } // the UI dismisses a user end

        h.provider.releaseStart()
        await place.value

        #expect(h.provider.endRequests == [h.callID]) // the started call is not left behind
        #expect(h.provider.reportedConnecting.isEmpty)
        #expect(h.target.makeTransportCount == 0)
        #expect(h.target.connectCount == 0)
        #expect(h.engine.state == (resetBeforeStartReturns ? .idle : .ended(.canceled)))
        #expect(h.delegate.records.map(\.outcome) == [.canceled])

        h.provider.simulateEndCall(h.callID) // CallKit's round trip for that end is inert
        #expect(h.delegate.records.count == 1)
        #expect(h.delegate.transitions.contains("dialing→connecting") == false)
    }

    @Test func activationWhileDialingAttachesTheTransportWhenItIsCreated() async throws {
        let h = CallEngineHarness()
        h.provider.suspendStart = true

        let place = Task { await h.placeCall() }
        await waitUntil { h.provider.pendingStartCount == 1 }
        #expect(h.provider.pendingStartCount == 1)
        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()
        #expect(h.engine.isAudioActivated)
        #expect(h.target.makeTransportCount == 0) // nothing to attach yet

        h.provider.releaseStart()
        await place.value

        #expect(h.transport.isAudioAttached)
        #expect(h.transport.connectCount == 1)
    }

    @Test func activationBeforeAnswerAttachesTheTransportWhenItIsCreated() async throws {
        let h = CallEngineHarness()
        h.ring()
        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()
        #expect(h.engine.isAudioActivated)
        #expect(h.target.makeTransportCount == 0)

        await h.engine.answer()

        #expect(h.transport.isAudioAttached)
        #expect(h.transport.connectCount == 1)
    }

    @Test func endDuringTheActivationReplayNeverFetchesCredentials() async throws {
        let h = CallEngineHarness()
        h.provider.suspendStart = true
        h.transport.suspendAttach = true // the transport this call will get

        let place = Task { await h.placeCall() }
        await waitUntil { h.provider.pendingStartCount == 1 }
        #expect(h.provider.pendingStartCount == 1)
        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()

        h.provider.releaseStart()
        await waitUntil { h.transport.pendingAttachCount == 1 }
        #expect(h.transport.pendingAttachCount == 1) // replaying the activation
        await h.engine.endCall()

        h.transport.releaseAttach()
        await place.value

        #expect(h.target.connectCount == 0)
        #expect(h.transport.connectCount == 0)
        #expect(h.engine.state.endedOutcome == .canceled)
    }

    @Test func retryResolvingAfterTheTransportRecoveredDoesNotRejoin() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        h.target.suspend = true
        h.engine.handle(.disconnected(reason: .networkDropped))
        await waitUntil { h.target.connectCount == 2 }
        #expect(h.target.connectCount == 2)
        let retry = try #require(h.engine.reconnectTask)

        h.engine.handle(.connected) // the same transport came back on its own
        #expect(h.engine.state.isConnected)

        h.target.release()
        await retry.value

        #expect(h.transport.connectCount == 1) // the superseded attempt stays inert
        #expect(h.engine.state.isConnected)
        #expect(h.delegate.transitions.last == "reconnecting(1)→connected")
    }

    @Test(arguments: [false, true])
    func staleFirstResolveLeavesTheNextCallAlone(staleAttemptFails: Bool) async throws {
        let h = CallEngineHarness()
        h.target.suspend = true
        let first = Task { await h.placeCall() }
        await waitUntil { h.target.connectCount == 1 }
        #expect(h.target.connectCount == 1)
        await h.engine.endCall()
        h.engine.reset()

        h.target.suspend = false
        await h.placeCall() // a new call, on its own transport
        #expect(h.transports.made.count == 2)
        #expect(h.transports.made[1].connectCount == 1)

        if staleAttemptFails { h.target.error = TransportError.authenticationFailed }
        h.target.release() // the first call's fetch resolves late
        await first.value

        #expect(h.transports.made[0].connectCount == 0)
        #expect(h.transports.made[1].connectCount == 1)
        #expect(h.engine.state.isConnecting) // not failed, not re-joined
        #expect(h.delegate.records.map(\.outcome) == [.canceled])
    }

    @Test(arguments: [false, true])
    func staleRetryLeavesTheNextCallAlone(staleAttemptFails: Bool) async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        h.target.suspend = true
        h.engine.handle(.disconnected(reason: .networkDropped))
        await waitUntil { h.target.connectCount == 2 }
        #expect(h.target.connectCount == 2)
        let staleRetry = try #require(h.engine.reconnectTask)
        await h.engine.endCall()
        h.engine.reset()

        h.target.suspend = false
        await h.placeCall()
        h.engine.handle(.connected)
        let transitionsBefore = h.delegate.transitions

        if staleAttemptFails { h.target.error = TransportError.connectionFailed("stale") }
        h.target.release() // the first call's retry resolves late
        await staleRetry.value

        #expect(h.engine.state.isConnected)
        #expect(h.transports.made.map(\.connectCount) == [1, 1])
        #expect(h.delegate.transitions == transitionsBefore) // no reconnecting, no failure
        #expect(h.engine.reconnectTask == nil)
    }

    // MARK: - Once per attempt

    @Test func resolverRunsOncePerReconnectAttempt() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        #expect(h.target.connectCount == 1)

        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()
        #expect(h.target.connectCount == 2)
        #expect(h.transport.connectCount == 2)

        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()
        #expect(h.target.connectCount == 3)
        #expect(h.transport.connectCount == 3)

        #expect(h.transport.lastConnection == h.target.connection)
        #expect(h.target.makeTransportCount == 1) // one transport, reused by every attempt
    }
}
