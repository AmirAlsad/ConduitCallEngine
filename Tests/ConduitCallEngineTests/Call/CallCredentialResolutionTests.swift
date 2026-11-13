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

    /// CallKit activates the session once the answer action is fulfilled, which can
    /// be before the engine's hop to `answer()` has created the transport.
    @Test func activationBeforeAnswerAttachesTheTransportWhenItIsCreated() async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        h.ring(callID: callID)
        h.provider.simulateAnswerCall(callID)
        await h.engine.activate(FakeAudioSession())
        #expect(h.engine.isAudioActivated)
        #expect(h.target.makeTransportCount == 0)

        await waitUntil { h.transport.connectCount == 1 }

        #expect(h.transport.isAudioAttached)
        #expect(h.transport.connectCount == 1)
    }

    /// CallKit never activates a ringing call's session before it is answered, so
    /// an activation then belongs to an earlier call, delivered late.
    @Test func anActivationDuringARingNobodyAnsweredIsIgnored() async throws {
        let h = CallEngineHarness()
        h.ring()
        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()
        #expect(h.engine.isAudioActivated == false)

        await h.engine.answer()
        await h.engine.awaitPendingMediaWork()

        #expect(h.transport.connectCount == 1)
        #expect(h.transport.isAudioAttached == false)
        #expect(h.transport.isMicEnabled == false)

        h.provider.simulateActivate(FakeAudioSession()) // the answered call's own activation
        await h.engine.awaitPendingActivation()
        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled == false) // connecting: the mic waits for the agent

        h.engine.handle(.connected)
        await h.engine.awaitPendingMediaWork()
        #expect(h.transport.isMicEnabled)
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

    @Test(arguments: [nil, TransportError.connectionFailed("stale"), .authenticationFailed])
    func staleRetryLeavesTheNextCallAlone(staleAttemptError: TransportError?) async throws {
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

        h.target.error = staleAttemptError
        h.target.release() // the first call's retry resolves late
        await staleRetry.value

        #expect(h.engine.state.isConnected)
        #expect(h.transports.made.map(\.connectCount) == [1, 1])
        #expect(h.delegate.transitions == transitionsBefore) // no reconnecting, no failure
        #expect(h.engine.reconnectTask == nil)
    }

    // MARK: - Rejected credentials while reconnecting

    enum Rejection: String, CaseIterable, Sendable {
        case byTheTarget, byTheTransport
    }

    /// Rejected credentials will not get better with another attempt: the call
    /// fails as `.badToken` at once, not as `.lostConnection` once the budget is spent.
    @Test(arguments: Rejection.allCases)
    func rejectedCredentialsDuringAReconnectFailAsBadToken(rejection: Rejection) async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        switch rejection {
        case .byTheTarget: h.target.error = TransportError.authenticationFailed
        case .byTheTransport: h.transport.connectError = .authenticationFailed
        }

        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()

        #expect(h.engine.state == .failed(.badToken))
        #expect(h.delegate.records.map(\.failureReason) == [.badToken])
        #expect(h.target.connectCount == 2) // no further attempt
        #expect(h.engine.reconnectTask == nil)
        #expect(h.delegate.transitions.last == "reconnecting(1)→failed(badToken)")
    }

    @Test(arguments: [0, 1])
    func authErrorEventWhileReconnectingFailsAsBadToken(attempt: Int) async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        if attempt == 0 {
            h.engine.handle(.reconnecting)
        } else {
            h.engine.handle(.disconnected(reason: .networkDropped))
        }
        #expect(h.engine.state == .reconnecting(attempt: attempt))

        h.engine.handle(.error(.authenticationFailed))

        #expect(h.engine.state == .failed(.badToken))
    }

    @Test func otherErrorEventWhileReconnectingChangesNothing() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        h.engine.handle(.disconnected(reason: .networkDropped))
        let transitions = h.delegate.transitions

        h.engine.handle(.error(.connectionFailed("timed out")))

        #expect(h.engine.state == .reconnecting(attempt: 1))
        #expect(h.delegate.transitions == transitions)
        #expect(h.delegate.records.isEmpty)
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

    // MARK: - What the target is told

    @Test func anOutgoingCallsRequestsSayWhatTheyAreFor() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()
        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()

        #expect(h.target.requests == [
            ConnectRequest(purpose: .outgoing, callID: h.callID),
            ConnectRequest(purpose: .reconnect(attempt: 1), callID: h.callID),
            ConnectRequest(purpose: .reconnect(attempt: 2), callID: h.callID),
        ])
    }

    /// A server tells the calls apart by the id: each placed call has its own.
    @Test func eachOutgoingCallHasAnIDOfItsOwn() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.endCall()
        await h.placeCall()

        let ids = h.target.requests.map(\.callID)
        #expect(h.target.requests.map(\.purpose) == [.outgoing, .outgoing])
        #expect(ids.first == h.callID)
        #expect(ids.allSatisfy { $0 != nil })
        #expect(Set(ids).count == 2)
    }

    @Test func anIncomingCallsRequestsCarryTheRingsID() async throws {
        let h = CallEngineHarness()
        let callID = UUID()
        h.ring(callID: callID)
        await h.engine.answer()
        h.engine.handle(.connected)
        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()

        #expect(h.target.requests == [
            ConnectRequest(purpose: .answered, callID: callID),
            ConnectRequest(purpose: .reconnect(attempt: 1), callID: callID),
        ])
    }
}
