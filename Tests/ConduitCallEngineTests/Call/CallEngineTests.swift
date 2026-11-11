//
//  CallEngineTests.swift
//  ConduitCallEngineTests
//
//  The call state machine — the heart of the app and the most-tested unit. Every
//  row of the transition table is asserted here against fakes, at simulator speed.
//  What the engine reports to its host is asserted on the recording delegate; what
//  the host does with it (history, cues, donation) is in AgentCallHostTests.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct CallEngineTests {

    // MARK: - Placing a call

    @Test func placeCallReportsToCallKitAndConnectsTransport() async throws {
        let h = CallEngineHarness()
        await h.placeCall()

        #expect(h.engine.state.isConnecting)
        #expect(h.provider.startedCalls == [h.callID])
        #expect(h.provider.startedHandles == [CallHandle(value: h.target.handle)])
        #expect(h.provider.reportedConnecting == [h.callID])
        #expect(h.transport.connectCount == 1)
        #expect(h.transport.lastConnection?.token == "valid-token")
        #expect(h.target.makeTransportCount == 1)
        #expect(h.engine.activeCall == ActiveCall(
            targetID: h.target.id, displayName: h.target.displayName, direction: .outgoing
        ))
        // The host starts the connecting cue and donates on dialing → connecting.
        #expect(h.delegate.transitions == ["idle→dialing", "dialing→connecting"])
    }

    @Test func placeCallIgnoredWhenNotIdle() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        await h.placeCall()

        #expect(h.transport.connectCount == 1)
        #expect(h.provider.startedCalls == [h.callID])
    }

    @Test func connectedIsReportedToCallKitBeforeTheHostHearsIt() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        // CallKit's timer starts before the host's "Connected" cue.
        #expect(Array(h.log.entries.suffix(2)) == ["reported-connected", "T(connecting→connected)"])
    }

    @Test func connectedTransitionsAndReportsConnected() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        #expect(h.engine.state.isConnected)
        #expect(h.provider.reportedConnected == [h.callID])
        #expect(h.delegate.transitions.last == "connecting→connected")
    }

    // MARK: - Failures

    @Test func missingTokenFailsWithBadToken() async throws {
        let h = CallEngineHarness()
        h.target.error = TransportError.authenticationFailed // the host's missing-token throw
        await h.placeCall()

        #expect(h.engine.state.failureReason == .badToken)
        #expect(h.transport.connectCount == 0)
        #expect(h.provider.reportedEnded.map(\.id) == [h.callID])
        #expect(h.provider.reportedEnded.first?.reason == .failed)
        #expect(h.delegate.records.count == 1)
        #expect(h.delegate.records.first?.outcome == .failed)
        #expect(h.delegate.records.first?.failureReason == .badToken)
        #expect(h.delegate.records.first?.targetID == h.target.id)
    }

    @Test func connectThrowingFailsWithTransportError() async throws {
        let h = CallEngineHarness()
        h.transport.connectError = .connectionFailed("boom")
        await h.placeCall()

        #expect(h.engine.state.failureReason == .transportError)
        #expect(h.provider.reportedEnded.first?.reason == .failed)
        #expect(h.delegate.records.first?.outcome == .failed)
        #expect(h.delegate.records.first?.failureReason == .transportError)
    }

    @Test func startOutgoingCallThrowingFailsWithUnknown() async throws {
        let h = CallEngineHarness()
        h.provider.startError = TransportError.connectionFailed("callkit refused")
        await h.placeCall()

        #expect(h.engine.state.failureReason == .unknown)
        #expect(h.transport.connectCount == 0)
    }

    @Test func authFailureWhileConnectingFailsWithBadToken() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.disconnected(reason: .authFailed))

        #expect(h.engine.state.failureReason == .badToken)
    }

    @Test func transportAuthErrorWhileConnectingFailsWithBadToken() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.error(.authenticationFailed))

        #expect(h.engine.state.failureReason == .badToken)
    }

    // MARK: - Reconnection

    @Test func networkDropSchedulesReconnectAndRecovers() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.handle(.disconnected(reason: .networkDropped))
        #expect(h.engine.state.reconnectingAttempt == 1)
        #expect(h.delegate.transitions.last == "connected→reconnecting(1)")

        await h.engine.awaitPendingReconnect()
        #expect(h.transport.connectCount == 2) // initial + one retry

        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected)
        #expect(h.delegate.transitions == [
            "idle→dialing", "dialing→connecting", "connecting→connected",
            "connected→reconnecting(1)", "reconnecting(1)→connected",
        ])
    }

    @Test func reconnectionBudgetExhaustionFailsWithLostConnection() async throws {
        let policy = ReconnectionPolicy(maxAttempts: 2, baseDelaySeconds: 0, maxDelaySeconds: 0)
        let h = CallEngineHarness(policy: policy)
        await h.placeCall()
        h.engine.handle(.connected)

        // Two drops are absorbed as retries; the third exhausts the budget.
        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()
        #expect(h.engine.state.reconnectingAttempt == 1)

        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()
        #expect(h.engine.state.reconnectingAttempt == 2)

        h.engine.handle(.disconnected(reason: .networkDropped))
        #expect(h.engine.state.failureReason == .lostConnection)
        #expect(h.provider.reportedEnded.first?.reason == .failed)
        #expect(h.transport.connectCount == 3) // initial + two retries
    }

    // MARK: - Audio-session handshake (the ownership invariant)

    @Test func activationAttachesMediaAndEnablesMic() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        let session = FakeAudioSession(hasExternalAudioRoute: false)
        await h.engine.activate(session)

        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
    }

    @Test func handsFreeDefaultRoutesToSpeakerWithoutExternalRoute() async throws {
        let h = CallEngineHarness() // FakeTransport routes: speaker + receiver (no external)
        await h.transport.setAudioDevice("receiver") // start on the earpiece
        await h.placeCall()
        h.engine.handle(.connected)

        await waitUntil { h.transport.selectedAudioDeviceID == "speaker" }
        #expect(h.transport.selectedAudioDeviceID == "speaker")
    }

    @Test func handsFreeDefaultLeavesExternalRouteAlone() async throws {
        let h = CallEngineHarness()
        h.transport.fakeAudioDevices = [
            AudioDeviceInfo(id: "bluetooth", name: "Bluetooth Speaker & Mic"),
            AudioDeviceInfo(id: "speaker", name: "Built-in Speaker & Mic"),
            AudioDeviceInfo(id: "earpiece", name: "Built-in Earpiece & Mic"),
        ]
        await h.transport.setAudioDevice("bluetooth") // on AirPods
        await h.placeCall()
        h.engine.handle(.connected)

        await waitUntil { h.engine.audioDevices.contains { $0.id == "bluetooth" } }
        #expect(h.transport.selectedAudioDeviceID == "bluetooth") // didn't yank to speaker
    }

    @Test func pushToTalkKeepsMicOffOnActivation() async throws {
        let h = CallEngineHarness(pushToTalk: true)
        await h.placeCall()

        let session = FakeAudioSession(hasExternalAudioRoute: false)
        await h.engine.activate(session)

        #expect(h.transport.isAudioAttached)
        #expect(!h.transport.isMicEnabled)
    }

    // MARK: - Mute

    @Test func inAppMuteReflectsToTransportAndProvider() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        await h.engine.setMuted(true)

        #expect(h.engine.isMuted)
        #expect(!h.transport.isMicEnabled)
        #expect(h.provider.muteStates[h.callID] == true)
    }

    @Test func systemMuteDoesNotCallBackIntoProvider() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.providerPerformSetMuted(h.callID, muted: true)

        #expect(h.engine.isMuted)
        #expect(h.provider.muteStates[h.callID] == nil)
    }

    // MARK: - Ending

    @Test func inAppEndDisconnectsRequestsEndAndLogsCompleted() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        await h.engine.endCall()

        #expect(h.engine.state.endedOutcome == .completed)
        #expect(h.provider.endRequests == [h.callID])
        #expect(h.provider.reportedEnded.isEmpty) // requested via endCall; not double-reported
        #expect(h.delegate.records.count == 1)
        #expect(h.delegate.records.first?.outcome == .completed)
    }

    @Test func systemEndLogsAndDoesNotRequestEndAgain() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.providerPerformEndCall(h.callID)

        #expect(h.engine.state.endedOutcome == .completed)
        #expect(h.provider.endRequests.isEmpty)
        #expect(h.delegate.records.map(\.outcome) == [.completed])
    }

    @Test func endBeforeConnectLogsCanceled() async throws {
        let h = CallEngineHarness()
        await h.placeCall()

        await h.engine.endCall()

        #expect(h.engine.state.endedOutcome == .canceled)
        #expect(h.delegate.records.first?.outcome == .canceled)
    }

    @Test func botLeftEndsCallAsRemote() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.handle(.disconnected(reason: .botLeft))

        #expect(h.engine.state.endedOutcome == .completed)
        #expect(h.provider.reportedEnded.first?.reason == .remoteEnded)
    }

    @Test func callLogRecordsConnectedDuration() async throws {
        let clock = MutableClock()
        let h = CallEngineHarness(now: clock.now)
        await h.placeCall()
        h.engine.handle(.connected) // firstConnectedAt = t0
        clock.advance(60)
        await h.engine.endCall()

        #expect(h.delegate.records == [CallRecord(
            targetID: h.target.id,
            direction: .outgoing,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            duration: 60,
            outcome: .completed
        )])
    }

    // MARK: - Lifecycle

    @Test func providerResetReturnsToIdle() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.providerWasReset()

        #expect(h.engine.state == .idle)
        #expect(h.engine.activeCall == nil)
        #expect(h.delegate.records.isEmpty) // a reset is not a finished call
        #expect(h.delegate.transitions.last == "connected→idle")

        // Nor is a ringing call that the provider resets: no record, no receipt.
        h.ring(statusURL: URL(string: "https://engine.example.com/inbound/status/live")!)
        #expect(h.engine.state == .incomingRinging)
        h.engine.providerWasReset()

        #expect(h.engine.state == .idle)
        #expect(h.delegate.records.isEmpty)
        #expect(h.ringStatusReporter.reports.isEmpty)
        #expect(h.delegate.bearerRequests.isEmpty)
    }

    @Test func resetReturnsToIdleAfterTerminalState() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.endCall()

        h.engine.reset()

        #expect(h.engine.state == .idle)
        #expect(h.engine.activeCall == nil)
    }

    @Test func lateConnectFailureAfterResetDoesNotReFail() async throws {
        let h = CallEngineHarness()
        h.transport.suspendConnect = true
        h.transport.connectError = .authenticationFailed

        // placeCall → connectTransport → connect() is entered and suspends.
        let place = Task { await h.placeCall() }
        await waitUntil { h.transport.connectCount == 1 }

        // An event fails the call (as the real transport would), then the user closes it.
        h.engine.handle(.disconnected(reason: .authFailed))
        #expect(h.engine.state.failureReason == .badToken)
        h.engine.reset()
        #expect(h.engine.state == .idle)

        // connect() now resolves LATE and throws. The stale failure must be ignored —
        // re-failing would re-present the call screen after it was dismissed.
        h.transport.releaseConnect()
        await place.value

        #expect(h.engine.state == .idle)
    }

    // MARK: - Speaking indicators

    @Test func botSpeakingEventsTrackState() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.handle(.botStartedSpeaking)
        #expect(h.engine.isBotSpeaking)

        h.engine.handle(.botStoppedSpeaking)
        #expect(!h.engine.isBotSpeaking)
    }

    @Test func remoteAudioLevelUpdates() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.remoteAudioLevel(0.7))

        #expect(h.engine.remoteAudioLevel == 0.7)
    }

    // MARK: - Real delegate / stream paths (the fire-and-forget seams)

    @Test func activationViaSystemDelegateAttachesMedia() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        let session = FakeAudioSession(hasExternalAudioRoute: false)
        h.provider.simulateActivate(session) // the real CallKit delegate path
        await h.engine.awaitPendingActivation()

        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
    }

    @Test func micReappliedOnConnectWhenActivationCameFirst() async throws {
        let h = CallEngineHarness()
        await h.placeCall()

        // CallKit activates the session BEFORE the transport reports connected —
        // the race a slow pairing fetch exposes. The one-shot enable in activate()
        // can't turn on a not-yet-joined mic, so the engine must re-apply it
        // once connected. (The fake doesn't model the no-op, so we assert the
        // re-apply happens, not the device-only end state.)
        let session = FakeAudioSession(hasExternalAudioRoute: false)
        h.provider.simulateActivate(session)
        await h.engine.awaitPendingActivation()
        #expect(h.engine.isAudioActivated)
        let callsBeforeConnect = h.transport.setMicEnabledCallCount

        h.transport.emit(.connected)
        await waitUntil { h.transport.setMicEnabledCallCount > callsBeforeConnect }
        #expect(h.transport.setMicEnabledCallCount > callsBeforeConnect)
        #expect(h.transport.isMicEnabled)
    }

    @Test func transportEventsReachCoordinatorViaStream() async throws {
        let h = CallEngineHarness()
        await h.placeCall()

        h.transport.emit(.connected) // delivered through the AsyncStream, not handle()
        await waitUntil { h.engine.state.isConnected }

        #expect(h.engine.state.isConnected)
        #expect(h.provider.reportedConnected == [h.callID])
    }

    // MARK: - Additional transition-table coverage

    @Test func transportSelfHealReconnectingIsDisplayOnly() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.handle(.reconnecting)
        #expect(h.engine.state.reconnectingAttempt == 0) // no app attempt counted
        #expect(h.delegate.transitions.last == "connected→reconnecting(0)")

        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected)
    }

    @Test func errorWhileConnectedIsNonTerminal() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.handle(.error(.timedOut))
        #expect(h.engine.state.isConnected)
    }

    @Test func unknownDisconnectWhileConnectedReconnects() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.handle(.disconnected(reason: .unknown))
        #expect(h.engine.state.reconnectingAttempt == 1)
        await h.engine.awaitPendingReconnect()
        #expect(h.transport.connectCount == 2)
    }

    @Test func disconnectBeforeEverConnectingFails() async throws {
        let h = CallEngineHarness()
        await h.placeCall() // connecting, never connected

        h.engine.handle(.disconnected(reason: .networkDropped))
        #expect(h.engine.state.failureReason == .transportError)
    }

    @Test func requestedByUserDisconnectIsNoOp() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.handle(.disconnected(reason: .requestedByUser))
        #expect(h.engine.state.isConnected)
    }

    @Test func endWhileReconnectingCancelsReconnect() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()
        #expect(h.engine.state.reconnectingAttempt == 1)

        await h.engine.endCall()

        #expect(h.engine.state.endedOutcome == .completed)
        #expect(h.engine.reconnectTask == nil)
    }

    @Test func duplicateConnectedIsIgnored() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        h.engine.handle(.connected) // stray duplicate

        #expect(h.provider.reportedConnected == [h.callID])
        #expect(h.delegate.transitions.filter { $0.hasSuffix("→connected") }.count == 1)
    }

    @Test func callCanBeReplacedAfterReset() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.endCall()
        h.engine.reset()
        #expect(h.engine.state == .idle)

        await h.placeCall()
        h.engine.handle(.connected)

        #expect(h.engine.state.isConnected)
        #expect(!h.engine.isMuted)
        // Each call gets its own transport; the first was torn down.
        #expect(h.transports.made.map(\.connectCount) == [1, 1])
        await waitUntil { h.transports.made.first?.disconnectCount == 1 }
        #expect(h.transports.made.first?.disconnectCount == 1)
    }
}
