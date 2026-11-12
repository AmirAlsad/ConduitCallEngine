//
//  PreconnectTests.swift
//  ConduitCallEngineTests
//
//  Pre-connect: an incoming call prepared while it rings. The tier is the lowest
//  of what the push asks for (`preconnect`), what the host's target allows and,
//  for media, what the transport can do; anything missing is today's ring. Audio
//  waits for CallKit throughout: nothing attaches, opens the mic or touches the
//  route before CallKit activates the session after the answer.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct PreconnectTests {
    private let statusEndpoint = URL(string: "https://engine.example.com/inbound/status/live")!

    /// A harness whose host allows `tier` and whose next transport declares `capable`.
    /// Its host asks for the speaker default, whose selection shows when the route
    /// work ran (only after CallKit's activation).
    private func harness(
        allows tier: RingPreparation = .media,
        capable: Bool = true,
        joinTimeout: Duration? = nil,
        sleep: ((Duration) async -> Void)? = nil
    ) -> CallEngineHarness {
        let h = sleep.map { sleep in
            CallEngineHarness(joinTimeout: joinTimeout, defaultsToSpeaker: true, sleep: { await sleep($0) })
        } ?? CallEngineHarness(joinTimeout: joinTimeout, defaultsToSpeaker: true)
        h.allowRingPreparation(tier)
        h.transport.canConnectWhileRinging = capable
        return h
    }

    /// Ring with `preconnect` and let the preparation run as far as it can.
    private func ring(_ h: CallEngineHarness, preconnect: String? = "media", callID: UUID = UUID()) async {
        h.ring(callID: callID, statusURL: statusEndpoint, preconnect: preconnect)
        await settle()
    }

    private func activate(_ h: CallEngineHarness) async {
        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()
        await settle()
    }

    /// Nothing that needs CallKit's activation has reached `transport`.
    private func expectNoAudioWork(on transport: FakeTransport, _ comment: Comment? = nil) {
        #expect(transport.isAudioAttached == false, comment)
        #expect(transport.isMicEnabled == false, comment)
        #expect(transport.audioDeviceSelections.isEmpty, comment)
        #expect(transport.audioDeviceReadCount == 0, comment)
        #expect(transport.sentSignals.isEmpty, comment)
    }

    // MARK: - Opting in

    @Test func theEngineAdvertisesPreconnect() {
        #expect(CallEngine.supportedPushFeatures.contains("preconnect"))
    }

    @Test func theTiersAreOrdered() {
        #expect(RingPreparation.none < .credentials)
        #expect(RingPreparation.credentials < .media)
        #expect(min(RingPreparation.media, .credentials) == .credentials)
    }

    /// Everything a ring and its answered call do that the host, CallKit, the
    /// receipt server and the transport can see, in order.
    private struct Trace: Equatable {
        var log: [String] = []
        var requests: [ConnectRequest] = []
        var transportsMade: [Int] = []
        var connects: [Int] = []
        var signals: [[CallSignal]] = []
        var phases: [RingPreparationPhase] = []

        @MainActor mutating func record(_ h: CallEngineHarness) {
            transportsMade.append(h.transports.made.count)
            connects.append(h.transports.made.map(\.connectCount).reduce(0, +))
            phases.append(h.engine.ringPreparationPhase)
        }
    }

    /// Ring, answer, connect, activate and hang up, recording what is seen.
    private func trace(_ h: CallEngineHarness, preconnect: String?, callID: UUID) async -> Trace {
        var trace = Trace()
        await ring(h, preconnect: preconnect, callID: callID)
        trace.record(h)
        await h.engine.answer()
        await settle()
        trace.record(h)
        h.engine.handle(.connected)
        await activate(h)
        trace.record(h)
        h.provider.simulateEndCall(callID)
        await settle()
        trace.record(h)
        trace.log = h.log.entries
        trace.requests = h.target.requests
        trace.signals = h.transports.made.map(\.sentSignals)
        return trace
    }

    /// The regression guard: a host and a transport that both opt in change nothing
    /// unless the push asks for pre-connect with a value the engine knows.
    @Test(arguments: [nil, "", "soon", "MEDIA", "none"])
    func withoutTheSendersOptInARingIsTodays(preconnect: String?) async throws {
        let callID = UUID()
        let today = await trace(harness(allows: .none, capable: false), preconnect: nil, callID: callID)
        let h = harness(allows: .media, capable: true)

        let traced = await trace(h, preconnect: preconnect, callID: callID)

        #expect(traced == today)
        #expect(traced.transportsMade.first == 0) // nothing made while ringing
        #expect(traced.requests == [ConnectRequest(purpose: .answered, callID: callID)])
        #expect(traced.signals == [[.connected]]) // as on every call
        #expect(h.delegate.resolved.first?.requestedPreparation == RingPreparation.none)
    }

    /// The host decides: without its opt-in the ring and the call are today's,
    /// `call-connected` included.
    @Test(arguments: ["credentials", "media"])
    func withoutTheHostsOptInARingIsTodaysAndTheAgentHearsOfTheAnswer(preconnect: String) async throws {
        let callID = UUID()
        let today = await trace(harness(allows: .none, capable: false), preconnect: nil, callID: callID)
        let h = harness(allows: .none, capable: true)

        var traced = await trace(h, preconnect: preconnect, callID: callID)

        #expect(traced.signals == [[.connected]])
        traced.signals = today.signals
        #expect(traced == today)
        #expect(h.delegate.resolved.first?.requestedPreparation == (preconnect == "media" ? .media : .credentials))
    }

    struct TierCase: CustomTestStringConvertible, Sendable {
        let push: String
        let host: RingPreparation
        let capable: Bool
        let expected: RingPreparation
        var testDescription: String { "push \(push), host \(host), capable \(capable) -> \(expected)" }
    }

    @Test(arguments: [
        TierCase(push: "media", host: .media, capable: true, expected: .media),
        TierCase(push: "media", host: .media, capable: false, expected: .credentials),
        TierCase(push: "media", host: .credentials, capable: true, expected: .credentials),
        TierCase(push: "credentials", host: .media, capable: true, expected: .credentials),
        TierCase(push: "credentials", host: .credentials, capable: false, expected: .credentials),
        TierCase(push: "media", host: .none, capable: true, expected: .none),
        TierCase(push: "credentials", host: .none, capable: true, expected: .none),
    ])
    func theTierIsTheLowestOfTheThree(tier: TierCase) async throws {
        let h = harness(allows: tier.host, capable: tier.capable)
        let callID = UUID()

        await ring(h, preconnect: tier.push, callID: callID)

        switch tier.expected {
        case .none:
            #expect(h.engine.ringPreparationPhase == .idle)
            #expect(h.target.requests.isEmpty)
            #expect(h.target.makeTransportCount == 0)
        case .credentials:
            #expect(h.engine.ringPreparationPhase == .credentialsReady)
            #expect(h.target.requests == [ConnectRequest(purpose: .ringing(joinsBeforeAnswer: false), callID: callID)])
            #expect(h.transport.connectCount == 0)
            // Reading whether a transport can join while ringing takes one, so the
            // answer uses the transport made for that.
            #expect(h.target.makeTransportCount == (tier.host == .media && tier.push == "media" ? 1 : 0))
        case .media:
            #expect(h.engine.ringPreparationPhase == .connecting)
            #expect(h.target.requests == [ConnectRequest(purpose: .ringing(joinsBeforeAnswer: true), callID: callID)])
            #expect(h.transport.connectCount == 1)
        }
        #expect(h.engine.state == .incomingRinging)
    }

    @Test func aRingForAnUnknownTargetPreparesNothing() async throws {
        let h = harness()
        h.ring(targetID: UUID(), preconnect: "media")
        await settle()

        #expect(h.target.requests.isEmpty)
        #expect(h.target.makeTransportCount == 0)
        #expect(h.engine.state == .idle)
    }

    @Test func aRingFocusFiltersPreparesNothing() async throws {
        let h = harness()
        h.provider.reportIncomingError = .filteredByFocus
        await ring(h)

        #expect(h.target.requests.isEmpty)
        #expect(h.target.makeTransportCount == 0)
        #expect(h.engine.ringPreparationPhase == .idle)
    }

    /// Preparation starts once CallKit accepts the report; an answer that comes
    /// before that connects as it would without pre-connect.
    @Test func preparationWaitsForCallKitToAcceptTheRing() async throws {
        let h = harness()
        h.provider.completesIncomingReportsLater = true
        let callID = UUID()
        await ring(h, callID: callID)
        #expect(h.target.requests.isEmpty)
        #expect(h.engine.ringPreparationPhase == .idle)

        h.provider.completeIncomingReports()
        await settle()

        #expect(h.engine.ringPreparationPhase == .connecting)
        #expect(h.pushCompletions == 1)
    }

    @Test func anAnswerBeforeCallKitAcceptsTheRingConnectsAsToday() async throws {
        let h = harness()
        h.provider.completesIncomingReportsLater = true
        let callID = UUID()
        await ring(h, callID: callID)

        await h.engine.answer()
        h.provider.completeIncomingReports()
        await settle()

        #expect(h.target.requests == [ConnectRequest(purpose: .answered, callID: callID)])
        #expect(h.target.makeTransportCount == 1)
        #expect(h.engine.state == .connecting)
    }

    // MARK: - The media tier while ringing

    @Test func aMediaRingJoinsWithNoAudioAndNoCallChange() async throws {
        let h = harness()
        let callID = UUID()
        await ring(h, callID: callID)
        let transport = h.transport

        #expect(transport.connectCount == 1)
        #expect(transport.lastConnection == h.target.connection)
        #expect(transport.setMicEnabledCallCount == 0)
        expectNoAudioWork(on: transport)

        h.engine.handle(.connected)
        h.engine.handle(.audioDevicesChanged)
        h.engine.handle(.botStartedSpeaking)
        await settle()

        #expect(h.engine.ringPreparationPhase == .ready)
        #expect(h.engine.state == .incomingRinging)
        #expect(h.engine.isBotSpeaking == false)
        #expect(h.delegate.transitions == ["idle→incomingRinging"])
        #expect(h.delegate.cues.isEmpty)
        #expect(h.provider.reportedConnected.isEmpty)
        #expect(h.provider.reportedEnded.isEmpty)
        #expect(transport.setMicEnabledCallCount == 0)
        expectNoAudioWork(on: transport)
    }

    // MARK: - Which join is made while ringing

    /// A transport can tell its join during the ring from every other: only the
    /// `.media` ring's own join is `connectWhileRinging(_:)`. The connect after the
    /// preparation failed following the answer, and a reconnect, are `connect(_:)`.
    @Test func onlyTheRingsOwnJoinIsAJoinWhileRinging() async throws {
        let sleeper = ManualSleeper()
        let h = harness(joinTimeout: .seconds(30), sleep: { await sleeper.sleep($0) })
        await ring(h)
        #expect(h.transport.ringingConnectCount == 1)
        #expect(h.transport.connectCount == 1)

        await h.engine.answer()
        #expect(h.engine.fireTimer(.joinTimeout)) // the agent never came: connect afresh
        await h.engine.awaitPendingWork()
        #expect(h.transport.connectCount == 2)
        h.engine.handle(.connected)
        h.engine.handle(.disconnected(reason: .networkDropped))
        #expect(h.engine.fireTimer(.reconnectBackoff))
        await h.engine.awaitPendingReconnect()
        #expect(h.transport.connectCount == 3)

        #expect(h.transport.ringingConnectCount == 1)
        #expect(h.target.requests.map(\.purpose) == [
            .ringing(joinsBeforeAnswer: true), .answered, .reconnect(attempt: 1),
        ])
    }

    enum NoRingJoin: String, CaseIterable, Sendable {
        case credentialsRing, mediaRingOnATransportThatCannotJoinWhileRinging, plainRing, outgoingCall
    }

    @Test(arguments: NoRingJoin.allCases)
    func noOtherCallJoinsWhileRinging(_ call: NoRingJoin) async throws {
        let h = harness(allows: call == .credentialsRing ? .credentials : .media, capable: call != .mediaRingOnATransportThatCannotJoinWhileRinging)
        switch call {
        case .credentialsRing: await ring(h, preconnect: "credentials")
        case .mediaRingOnATransportThatCannotJoinWhileRinging: await ring(h)
        case .plainRing: await ring(h, preconnect: nil)
        case .outgoingCall: await h.placeCall()
        }
        if call != .outgoingCall { await h.engine.answer() }

        #expect(h.transport.connectCount == 1)
        #expect(h.transport.ringingConnectCount == 0)
    }

    @Test func theUsersControlsDuringAMediaRingDoNotReachTheTransport() async throws {
        let h = harness()
        let callID = UUID()
        await ring(h, callID: callID)
        let transport = h.transport

        await h.engine.setMuted(true)
        h.engine.providerPerformSetMuted(callID, muted: false)
        await h.engine.selectAudioDevice("receiver")
        await h.engine.setOnHold(true)
        await settle()

        #expect(transport.setMicEnabledCallCount == 0)
        expectNoAudioWork(on: transport)
        #expect(h.provider.heldRequests.isEmpty)
    }

    /// An activation CallKit delivers late for an earlier call never reaches the
    /// ring's transport, during the ring or once it is answered.
    @Test func aStaleActivationNeverAttachesTheRingsTransport() async throws {
        let h = harness()
        await ring(h)
        h.engine.handle(.connected)
        let transport = h.transport

        await activate(h)
        expectNoAudioWork(on: transport)

        await h.engine.answer()
        await h.engine.awaitPendingMediaWork()
        await settle()

        #expect(transport.isAudioAttached == false)
        #expect(transport.isMicEnabled == false)
        #expect(transport.sentSignals.isEmpty)
    }

    // MARK: - Answering a ring whose agent is ready

    private func readyRing(_ h: CallEngineHarness, callID: UUID = UUID()) async {
        await ring(h, callID: callID)
        h.engine.handle(.connected)
        #expect(h.engine.ringPreparationPhase == .ready)
    }

    @Test func answeringAReadyRingConnectsAtOnceWithoutARingback() async throws {
        let clock = MutableClock()
        let h = CallEngineHarness(now: { clock.now() })
        h.allowRingPreparation(.media)
        h.transport.canConnectWhileRinging = true
        let callID = UUID()
        await readyRing(h, callID: callID)
        clock.advance(20)
        let answeredAt = clock.now()
        let before = h.log.entries.count

        await h.engine.answer()

        #expect(h.engine.state == .connected(since: answeredAt))
        #expect(h.engine.ringPreparationPhase == .idle)
        #expect(h.delegate.transitions == ["idle→incomingRinging", "incomingRinging→connected"])
        #expect(h.delegate.cues.isEmpty) // CallKit has not activated the call's audio yet
        #expect(Array(h.log.entries.dropFirst(before)) == [
            "bearer", "receipt(answered)", "T(incomingRinging→connected)",
        ])
        await activate(h)
        #expect(h.delegate.cues == [.moment(.connected)])
        #expect(h.log.entries.last == "cue(connected)")
        #expect(h.provider.reportedConnected.isEmpty) // CallKit's answer action marks it connected
        #expect(h.target.makeTransportCount == 1)
        #expect(h.transport.connectCount == 1)
        #expect(h.target.requests.count == 1)

        clock.advance(30)
        h.provider.simulateEndCall(callID)
        let record = try #require(h.delegate.records.first)
        #expect(record.outcome == .completed)
        #expect(record.duration == 30) // from the answer, not the ring
    }

    @Test func aReadyAnswerLeavesAudioAndRouteToCallKitsActivation() async throws {
        let h = harness()
        await readyRing(h)
        let transport = h.transport

        await h.engine.answer()
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()
        await settle()

        #expect(transport.isAudioAttached == false)
        #expect(transport.isMicEnabled == false)
        #expect(transport.audioDeviceSelections.isEmpty)
        #expect(transport.audioDeviceReadCount == 0)
        #expect(transport.sentSignals.isEmpty)

        h.engine.handle(.audioDevicesChanged) // a route change before activation waits too
        await settle()
        #expect(transport.audioDeviceReadCount == 0)

        await activate(h)

        #expect(transport.isAudioAttached)
        #expect(transport.isMicEnabled)
        #expect(transport.audioDeviceSelections == ["speaker"]) // the hands-free default
        #expect(transport.sentSignals == [.connected])
        #expect(h.engine.audioDevices.isEmpty == false)
    }

    /// CallKit can activate the session between delivering the answer action and the
    /// engine's hop to `answer()`.
    @Test func anActivationBeforeTheAnswerHopRunsStillComesFirst() async throws {
        let h = harness()
        let callID = UUID()
        await readyRing(h, callID: callID)
        let transport = h.transport

        h.provider.simulateAnswerCall(callID)
        await h.engine.activate(FakeAudioSession())
        #expect(h.engine.state == .incomingRinging)
        expectNoAudioWork(on: transport)

        await waitUntil { h.engine.state.isConnected }
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()
        await settle()

        #expect(h.engine.state.isConnected)
        #expect(transport.isAudioAttached)
        #expect(transport.isMicEnabled)
        #expect(transport.sentSignals == [.connected])
        #expect(transport.audioDeviceSelections == ["speaker"])
    }

    @Test func theAgentIsToldOfTheAnswerAgainAfterEveryReconnect() async throws {
        let h = harness()
        await readyRing(h)
        await h.engine.answer()
        await activate(h)

        h.engine.handle(.reconnecting)
        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()
        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()
        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()

        #expect(h.transport.sentSignals == [.connected, .connected, .connected])
    }

    @Test func aHeldCallIsToldOfTheAnswerOnlyOnTheResume() async throws {
        let h = harness()
        let callID = UUID()
        await readyRing(h, callID: callID)
        await h.engine.answer()
        #expect(h.engine.providerPerformSetHeld(callID, onHold: true))

        await activate(h)
        #expect(h.transport.sentSignals == [.held])

        #expect(h.engine.providerPerformSetHeld(callID, onHold: false))
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()

        #expect(h.transport.sentSignals == [.held, .resumed, .connected])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func aRingWhosePushAskedForNothingIsToldAsEveryCallIs() async throws {
        let h = harness(allows: .media)
        await ring(h, preconnect: nil)
        await h.engine.answer()
        h.engine.handle(.connected)
        await activate(h)

        #expect(h.transport.sentSignals == [.connected])
    }

    @Test func anOutgoingCallIsToldAsEveryCallIs() async throws {
        let h = harness()
        await h.placeCall()
        h.engine.handle(.connected)
        await activate(h)

        #expect(h.transport.sentSignals == [.connected])
    }

    // MARK: - Answering a ring that is still being prepared

    @Test func answeringWhileTheTransportJoinsWaitsForTheAgent() async throws {
        let h = harness()
        await ring(h)
        #expect(h.engine.ringPreparationPhase == .connecting)

        await h.engine.answer()
        await h.engine.activate(FakeAudioSession())

        #expect(h.engine.state == .connecting)
        #expect(h.delegate.cues == [.start(.connecting)])
        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected)
        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.connected)])
        #expect(h.target.makeTransportCount == 1)
        #expect(h.transport.connectCount == 1)
        #expect(h.target.requests.count == 1)
    }

    // MARK: - A pre-connection never makes the answered call worse

    /// The ring's transport joined, and the agent never came. Without a bound the
    /// preparation would wait for the whole ring and hand the answer a room with no
    /// agent in it.
    @Test func aRingWhoseAgentNeverArrivesDropsItsPreparationAfterTheJoinBound() async throws {
        let sleeper = ManualSleeper()
        let h = harness(joinTimeout: .seconds(30), sleep: { await sleeper.sleep($0) })
        let callID = UUID()
        await ring(h, callID: callID)
        let ringTransport = h.transport
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested == [.seconds(30)]) // bounded from the join's return, during the ring

        sleeper.wakeAll()
        await settle()

        #expect(h.engine.ringPreparationPhase == .failed)
        #expect(h.engine.state == .incomingRinging)
        #expect(ringTransport.disconnectCount == 1)
        #expect(h.delegate.cues.isEmpty)

        await h.engine.answer()
        #expect(h.target.requests.last == ConnectRequest(purpose: .answered, callID: callID))
        #expect(h.transports.made.count == 2)
    }

    @Test func aRingWhoseAgentArrivesInTimeIsNotBounded() async throws {
        let sleeper = ManualSleeper()
        let h = harness(joinTimeout: .seconds(30), sleep: { await sleeper.sleep($0) })
        await ring(h)
        await waitUntil { sleeper.pendingCount == 1 }

        h.engine.handle(.connected)
        sleeper.wakeAll()
        await settle()

        #expect(h.engine.ringPreparationPhase == .ready)
    }

    /// Answered while the joined transport still waits for its agent: the bound keeps
    /// counting from the join, and when it runs out the call connects as it would have
    /// without pre-connect (fresh credentials, `.answered`), on the same transport, so
    /// the agent of the abandoned join is not sent the end-call signal (the fresh
    /// credentials may name the same room).
    @Test func anAnsweredRingWhoseAgentNeverArrivesConnectsAfresh() async throws {
        let sleeper = ManualSleeper()
        let h = harness(joinTimeout: .seconds(30), sleep: { await sleeper.sleep($0) })
        let callID = UUID()
        await ring(h, callID: callID)
        await waitUntil { sleeper.pendingCount == 1 }

        await h.engine.answer()
        #expect(sleeper.requested == [.seconds(30)]) // not restarted at the answer
        sleeper.wakeAll()
        await waitUntil { h.transport.connectCount == 2 }

        #expect(h.engine.state == .connecting)
        #expect(h.delegate.records.isEmpty)
        #expect(h.target.requests.map(\.purpose) == [.ringing(joinsBeforeAnswer: true), .answered])
        #expect(h.target.requests.last?.callID == callID)
        #expect(h.transports.made.count == 1)
        #expect(h.transport.disconnectCount == 0)

        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected)
        await h.engine.activate(FakeAudioSession())
        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.connected)])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    enum PreparedFailure: String, CaseIterable, Sendable {
        case joinThrows, credentialsFail, rejectedCredentials, networkDropped, errorWhileJoining, botLeftBeforeReady, authFailed
    }

    /// Whatever the ring prepared failing after the answer, before the agent was
    /// there, sends the call down the path it would have taken without pre-connect.
    @Test(arguments: PreparedFailure.allCases)
    func aPreparationThatFailsAfterTheAnswerConnectsAfresh(failure: PreparedFailure) async throws {
        let h = harness(allows: failure == .credentialsFail || failure == .rejectedCredentials ? .credentials : .media)
        let callID = UUID()
        switch failure {
        case .joinThrows: h.transport.suspendConnect = true
        case .credentialsFail, .rejectedCredentials: h.target.suspend = true
        default: break
        }
        await ring(h, callID: callID)
        let answer = Task { await h.engine.answer() }
        await settle()
        #expect(h.engine.state == .connecting)

        switch failure {
        case .joinThrows:
            h.transport.connectError = .connectionFailed("refused")
            h.transport.releaseConnect()
            await waitUntil { h.transport.connectCount == 2 } // the fresh connect, held too
            h.transport.connectError = nil
            h.transport.releaseConnect()
        case .credentialsFail, .rejectedCredentials:
            h.target.error = failure == .rejectedCredentials ? TransportError.authenticationFailed : TransportError.connectionFailed("down")
            h.target.release()
            await waitUntil { h.target.pendingCount == 1 } // the fresh fetch, held too
            h.target.error = nil
            h.target.release()
        case .networkDropped: h.engine.handle(.disconnected(reason: .networkDropped))
        case .errorWhileJoining: h.engine.handle(.error(.connectionFailed("timed out")))
        case .botLeftBeforeReady: h.engine.handle(.disconnected(reason: .botLeft))
        case .authFailed: h.engine.handle(.disconnected(reason: .authFailed))
        }
        await answer.value
        await waitUntil { h.target.requests.last?.purpose == .answered && h.transport.connectCount >= 1 }
        await settle()

        #expect(h.engine.state == .connecting)
        #expect(h.delegate.records.isEmpty)
        #expect(h.target.requests.last == ConnectRequest(purpose: .answered, callID: callID))
        #expect(h.transports.made.count == 1)
        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    /// Only once: the fresh connect is an ordinary first connect, whose failure fails
    /// the call as it would without pre-connect.
    @Test func aFreshConnectThatFailsTooFailsTheCall() async throws {
        let h = harness()
        h.transport.suspendConnect = true
        await ring(h)
        await h.engine.answer()
        h.transport.connectError = .connectionFailed("refused")
        h.transport.releaseConnect()
        await waitUntil { h.transport.connectCount == 2 }
        h.transport.releaseConnect()
        await waitUntil { h.engine.state.isTerminal }

        #expect(h.engine.state == .failed(.transportError))
        #expect(h.delegate.records.map(\.failureReason) == [.transportError])
        #expect(h.target.requests.map(\.purpose) == [.ringing(joinsBeforeAnswer: true), .answered])
        #expect(h.transport.connectCount == 2)
    }

    /// A drop of the abandoned join while the fresh credentials are being fetched does
    /// not fail the call: the fresh connect decides.
    @Test func aDropWhileConnectingAfreshIsLeftToTheFreshConnect() async throws {
        let h = harness()
        await ring(h)
        await h.engine.answer()
        h.target.suspend = true
        h.engine.handle(.error(.connectionFailed("timed out"))) // the prepared join failed
        await waitUntil { h.target.pendingCount == 1 }

        h.engine.handle(.disconnected(reason: .networkDropped))
        h.target.release()
        await waitUntil { h.transport.connectCount == 2 }

        #expect(h.engine.state == .connecting)
        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected)
    }

    @Test(arguments: [false, true])
    func aJoinStillUnderWayAtTheAnswerIsTheCallsFirstConnect(fails: Bool) async throws {
        let sleeper = ManualSleeper()
        let h = harness(joinTimeout: .seconds(30), sleep: { await sleeper.sleep($0) })
        h.transport.suspendConnect = true
        await ring(h)
        #expect(h.transport.connectCount == 1)

        await h.engine.answer()
        #expect(h.engine.state == .connecting)
        if fails { h.transport.connectError = .connectionFailed("refused") }
        h.transport.releaseConnect()
        if fails {
            await waitUntil { h.transport.connectCount == 2 }
            h.transport.releaseConnect()
        }
        await settle()

        if fails {
            // Connected afresh; that connect failed the same way.
            #expect(h.engine.state == .failed(.transportError))
            #expect(h.delegate.records.map(\.failureReason) == [.transportError])
            #expect(h.target.requests.last?.purpose == .answered)
        } else {
            #expect(h.engine.state == .connecting)
            #expect(sleeper.requested == [.seconds(30)]) // the join bound, from the join's return
        }
    }

    @Test(arguments: [RingPreparation.credentials, .media])
    func answeringWhileCredentialsAreInFlightWaitsForThem(tier: RingPreparation) async throws {
        let h = harness(allows: tier)
        h.target.suspend = true
        let callID = UUID()
        await ring(h, callID: callID)
        #expect(h.engine.ringPreparationPhase == .fetchingCredentials)

        let answer = Task { await h.engine.answer() }
        await settle()
        #expect(h.engine.state == .connecting)
        #expect(h.target.connectCount == 1) // no second fetch
        h.target.release()
        await answer.value

        #expect(h.target.requests == [
            ConnectRequest(purpose: .ringing(joinsBeforeAnswer: tier == .media), callID: callID),
        ])
        #expect(h.target.makeTransportCount == 1)
        #expect(h.transport.connectCount == 1)
        #expect(h.transport.lastConnection == h.target.connection)
        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected)
    }

    /// The ring's credentials failing after the answer send the call to an `.answered`
    /// fetch; rejected there too, the call fails as it would without pre-connect.
    @Test func credentialsThatFailAfterTheAnswerAndAgainFailTheCall() async throws {
        let h = harness(allows: .credentials)
        h.target.suspend = true
        await ring(h)

        let answer = Task { await h.engine.answer() }
        await settle()
        h.target.error = TransportError.authenticationFailed
        h.target.release()
        await answer.value
        await waitUntil { h.target.pendingCount == 1 }
        h.target.release()
        await waitUntil { h.engine.state.isTerminal }

        #expect(h.engine.state == .failed(.badToken))
        #expect(h.target.requests.map(\.purpose) == [.ringing(joinsBeforeAnswer: false), .answered])
    }

    @Test(arguments: [false, true])
    func answeringAPreparedCredentialsRingJoinsWithThem(capable: Bool) async throws {
        let h = harness(allows: capable ? .credentials : .media, capable: capable)
        let callID = UUID()
        await ring(h, callID: callID)
        #expect(h.engine.ringPreparationPhase == .credentialsReady)
        #expect(h.transport.connectCount == 0)

        await h.engine.answer()

        #expect(h.engine.state == .connecting)
        #expect(h.target.requests == [ConnectRequest(purpose: .ringing(joinsBeforeAnswer: false), callID: callID)])
        #expect(h.target.makeTransportCount == 1)
        #expect(h.transport.connectCount == 1)
        #expect(h.transport.lastConnection == h.target.connection)
    }

    @Test func aCredentialsRingAnsweredLeavesTheRouteToCallKitsActivation() async throws {
        let h = harness(allows: .credentials)
        await ring(h)
        await h.engine.answer()
        h.engine.handle(.connected)
        await settle()
        #expect(h.transport.audioDeviceSelections.isEmpty)
        #expect(h.transport.audioDeviceReadCount == 0)

        await activate(h)

        #expect(h.transport.audioDeviceSelections == ["speaker"])
        #expect(h.transport.sentSignals == [.connected])
    }

    // MARK: - A preparation that fails keeps the ring

    enum PreparationFailure: String, CaseIterable, Sendable {
        case credentialsThrow, rejectedCredentials, connectThrows
        case networkDropped, unknownDrop, authFailed, errorWhileJoining, botLeftWhileJoining
    }

    private func failPreparation(_ h: CallEngineHarness, _ failure: PreparationFailure) async {
        switch failure {
        case .credentialsThrow: h.target.error = TransportError.connectionFailed("backend down")
        case .rejectedCredentials: h.target.error = TransportError.authenticationFailed
        case .connectThrows: h.transport.connectError = .connectionFailed("refused")
        default: break
        }
        await ring(h)
        switch failure {
        case .networkDropped: h.engine.handle(.connected); h.engine.handle(.disconnected(reason: .networkDropped))
        case .unknownDrop: h.engine.handle(.connected); h.engine.handle(.disconnected(reason: .unknown))
        case .authFailed: h.engine.handle(.disconnected(reason: .authFailed))
        case .errorWhileJoining: h.engine.handle(.error(.connectionFailed("timed out")))
        case .botLeftWhileJoining: h.engine.handle(.disconnected(reason: .botLeft))
        default: break
        }
        await settle()
    }

    @Test(arguments: PreparationFailure.allCases)
    func aFailedPreparationKeepsTheRing(failure: PreparationFailure) async throws {
        let h = harness()
        await failPreparation(h, failure)
        let ringTransport = h.transport

        #expect(h.engine.ringPreparationPhase == .failed)
        #expect(h.engine.state == .incomingRinging)
        #expect(h.delegate.transitions == ["idle→incomingRinging"])
        #expect(h.delegate.records.isEmpty)
        #expect(h.provider.reportedEnded.isEmpty)
        #expect(h.ringStatusReporter.reports.isEmpty)
        #expect(h.delegate.cues.isEmpty)
        if failure != .credentialsThrow, failure != .rejectedCredentials {
            #expect(ringTransport.disconnectCount == 1) // torn down, sending the end-call signal if up
        }
        expectNoAudioWork(on: ringTransport)
    }

    @Test(arguments: PreparationFailure.allCases)
    func answeringAfterAFailedPreparationConnectsAsToday(failure: PreparationFailure) async throws {
        let h = harness()
        await failPreparation(h, failure)
        h.target.error = nil
        h.transport.connectError = nil
        let callID = try #require(h.provider.reportedIncoming.first?.id)

        await h.engine.answer()

        #expect(h.engine.state == .connecting)
        #expect(h.target.requests.last == ConnectRequest(purpose: .answered, callID: callID))
        #expect(h.target.connectCount == 2)
        let made = h.transports.made
        #expect(made.count == 2) // a fresh transport, not the failed one
        #expect(made.last?.connectCount == 1)
        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected)
    }

    @Test func anErrorOnceTheAgentIsThereIsOnlyLogged() async throws {
        let h = harness()
        await readyRing(h)

        h.engine.handle(.error(.connectionFailed("timed out")))

        #expect(h.engine.ringPreparationPhase == .ready)
        #expect(h.transport.disconnectCount == 0)
    }

    @Test func aHealDuringTheRingWaitsForTheAgentAgain() async throws {
        let h = harness()
        await readyRing(h)

        h.engine.handle(.reconnecting)
        #expect(h.engine.ringPreparationPhase == .connecting)
        h.engine.handle(.connected)
        #expect(h.engine.ringPreparationPhase == .ready)
        #expect(h.delegate.transitions == ["idle→incomingRinging"])
    }

    // MARK: - The agent leaving a ready ring is the caller cancelling it

    @Test(arguments: [false, true])
    func theAgentLeavingAReadyRingCancelsIt(callKitCompletesLater: Bool) async throws {
        let h = harness()
        h.provider.completesIncomingReportsLater = callKitCompletesLater
        let callID = UUID()
        h.ring(callID: callID, statusURL: statusEndpoint, preconnect: "media")
        if callKitCompletesLater { h.provider.completeIncomingReports() }
        await settle()
        h.engine.handle(.connected)
        let ringTransport = h.transport

        h.engine.handle(.disconnected(reason: .botLeft))

        #expect(h.engine.state == .idle)
        #expect(h.engine.ringPreparationPhase == .idle)
        #expect(h.delegate.transitions == ["idle→incomingRinging", "incomingRinging→idle"])
        #expect(h.provider.reportedEnded.map(\.id) == [callID])
        #expect(h.provider.reportedEnded.map(\.reason) == [.remoteEnded])
        let record = try #require(h.delegate.records.first)
        #expect(h.delegate.records.count == 1)
        #expect(record.outcome == .noAnswer)
        #expect(record.missedReason == .canceledByCaller)
        #expect(h.ringStatusReporter.reports.map(\.status) == [.canceled])
        #expect(h.delegate.cues.isEmpty)
        await waitUntil { ringTransport.disconnectCount == 1 }
        #expect(ringTransport.disconnectCount == 1)
        #expect(h.pushCompletions == 1)
    }

    /// Once CallKit has delivered the answer, the ring is the user's: the agent
    /// leaving then is a lost pre-connection, and the answer connects afresh.
    @Test func theAgentLeavingAfterTheAnswerActionIsNotACancel() async throws {
        let h = harness()
        let callID = UUID()
        await readyRing(h, callID: callID)

        h.provider.simulateAnswerCall(callID)
        h.engine.handle(.disconnected(reason: .botLeft))
        await waitUntil { h.engine.state != .incomingRinging }

        #expect(h.engine.state == .connecting)
        #expect(h.delegate.records.isEmpty)
        #expect(h.provider.reportedEnded.isEmpty)
        #expect(h.target.requests.last == ConnectRequest(purpose: .answered, callID: callID))
        #expect(h.transports.made.count == 2)
    }

    // MARK: - A prepared ring that ends without an answer

    enum Stage: String, CaseIterable, Sendable {
        case fetching, joining, ready
    }

    enum Ending: String, CaseIterable, Sendable {
        case declined, timedOut, canceled, providerReset
    }

    struct EndingCase: CustomTestStringConvertible, Sendable {
        let stage: Stage
        let ending: Ending
        let callKitCompletesLater: Bool
        var testDescription: String { "\(stage), \(ending), CallKit completes \(callKitCompletesLater ? "later" : "at once")" }

        static let all: [EndingCase] = Stage.allCases.flatMap { stage in
            Ending.allCases.flatMap { ending in
                [false, true].map { EndingCase(stage: stage, ending: ending, callKitCompletesLater: $0) }
            }
        }
    }

    @Test(arguments: EndingCase.all)
    func aPreparedRingThatEndsTearsThePreparationDown(endingCase: EndingCase) async throws {
        let (stage, ending) = (endingCase.stage, endingCase.ending)
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(ringTimeout: .seconds(60), sleep: { await sleeper.sleep($0) })
        h.allowRingPreparation(.media)
        h.transport.canConnectWhileRinging = true
        h.provider.completesIncomingReportsLater = endingCase.callKitCompletesLater
        if stage == .fetching { h.target.suspend = true }
        let callID = UUID()
        await ring(h, callID: callID)
        h.provider.completeIncomingReports()
        await settle()
        if stage == .ready { h.engine.handle(.connected) }
        let ringTransport = h.transport
        let expectedPhase: RingPreparationPhase = switch stage {
        case .fetching: .fetchingCredentials
        case .joining: .connecting
        case .ready: .ready
        }
        #expect(h.engine.ringPreparationPhase == expectedPhase)

        switch ending {
        case .declined: h.provider.simulateEndCall(callID)
        case .timedOut: sleeper.wakeAll()
        case .canceled: h.cancel(callID: callID)
        case .providerReset: h.provider.simulateReset()
        }
        await waitUntil { h.engine.state != .incomingRinging }
        h.provider.completeIncomingReports() // a held verdict for the cancel push
        h.target.release() // a fetch that was in flight returns late
        await settle()

        #expect(h.engine.ringPreparationPhase == .idle)
        #expect(h.delegate.records.count == 1)
        #expect(h.delegate.cues.isEmpty)
        #expect(h.pushCompletions == (ending == .canceled ? 2 : 1))
        #expect(ringTransport.disconnectCount == 1)
        #expect(ringTransport.connectCount == (stage == .fetching ? 0 : 1)) // a late fetch never joins
        expectNoAudioWork(on: ringTransport)
        let receipts = h.ringStatusReporter.reports.map(\.status)
        switch ending {
        case .declined: #expect(receipts == [.declined])
        case .timedOut: #expect(receipts == [.unanswered])
        case .canceled: #expect(receipts == [.canceled])
        case .providerReset: #expect(receipts.isEmpty)
        }
    }

    @Test func aLateFetchFromAnEarlierRingLeavesTheNextRingAlone() async throws {
        let h = harness(allows: .credentials)
        h.target.suspend = true
        let first = UUID()
        await ring(h, callID: first)
        h.provider.simulateEndCall(first) // declined while its credentials are in flight
        h.engine.reset()
        let second = UUID()
        await ring(h, callID: second)
        #expect(h.target.pendingCount == 2)

        h.target.release() // both fetches return
        await settle()

        #expect(h.engine.ringPreparationPhase == .credentialsReady)
        await h.engine.answer()
        #expect(h.target.requests.map(\.callID) == [first, second])
        #expect(h.transport.connectCount == 1)
        #expect(h.engine.activeCall != nil)
        #expect(h.engine.state == .connecting)
    }

    @Test(arguments: [false, true])
    func anotherPushDuringAPreparedRingLeavesItAlone(sameCallID: Bool) async throws {
        let h = harness()
        let callID = UUID()
        await readyRing(h, callID: callID)
        let ringTransport = h.transport
        let requests = h.target.requests

        h.ring(callID: sameCallID ? callID : UUID(), statusURL: statusEndpoint, preconnect: "media")
        await settle()

        #expect(h.engine.state == .incomingRinging)
        #expect(h.engine.ringPreparationPhase == .ready)
        #expect(ringTransport.disconnectCount == 0)
        #expect(h.target.requests == requests)
        #expect(h.target.makeTransportCount == 1)
        #expect(h.pushCompletions == 2)

        await h.engine.answer()
        #expect(h.engine.state.isConnected)
    }

    // MARK: - Every order of the answer, the activation, the agent and the credentials

    enum OrderEvent: String, CaseIterable, Sendable, CustomStringConvertible {
        case credentials, agent, answer, activation
        var description: String { rawValue }
    }

    private static func permutations(_ items: [OrderEvent]) -> [[OrderEvent]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[OrderEvent]] in
            var rest = items
            let first = rest.remove(at: index)
            return permutations(rest).map { [first] + $0 }
        }
    }

    /// The orders that can happen: the agent arrives only once the transport has
    /// credentials to join with, and, at the credentials tier, once the answer has
    /// let it join. An activation before the answer is a stale one, from an earlier call.
    private static func orders(for tier: RingPreparation) -> [[OrderEvent]] {
        permutations(OrderEvent.allCases).filter { order in
            let position = { (event: OrderEvent) in order.firstIndex(of: event)! }
            guard position(.credentials) < position(.agent) else { return false }
            return tier == .media || position(.answer) < position(.agent)
        }
    }

    @Test(arguments: [RingPreparation.credentials, .media])
    func everyOrderEndsConnectedWithAudioOnlyAfterTheActivation(tier: RingPreparation) async throws {
        let orders = Self.orders(for: tier)
        #expect(orders.count == (tier == .media ? 12 : 8))
        for order in orders {
            await run(order, tier: tier)
        }
    }

    private func run(_ order: [OrderEvent], tier: RingPreparation) async {
        let h = harness(allows: tier)
        h.target.suspend = true
        let callID = UUID()
        await ring(h, callID: callID)
        let label = Comment(rawValue: order.map(\.rawValue).joined(separator: " → "))
        var answerTask: Task<Void, Never>?
        var activated = false
        for event in order {
            switch event {
            case .credentials:
                h.target.release()
            case .agent:
                h.engine.handle(.connected)
            case .answer:
                answerTask = Task { await h.engine.answer() }
            case .activation:
                h.provider.simulateActivate(FakeAudioSession())
                await h.engine.awaitPendingActivation()
                activated = answerTask != nil
            }
            await settle()
            await h.engine.awaitPendingMediaWork()
            await h.engine.awaitPendingSignals()
            if !activated, let transport = h.transports.made.first {
                expectNoAudioWork(on: transport, label)
            }
        }
        await answerTask?.value
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()
        await settle()

        #expect(h.engine.state.isConnected, label)
        #expect(h.target.makeTransportCount == 1, label)
        #expect(h.target.connectCount == 1, label)
        #expect(h.transport.connectCount == 1, label)
        #expect(h.delegate.cueViolations.isEmpty, label)
        let agentFirst = order.firstIndex(of: .agent)! < order.firstIndex(of: .answer)!
        // The connected moment waits for CallKit's activation of the answered call.
        let connected: [CallCue] = activated ? [.moment(.connected)] : []
        #expect(h.delegate.cues == (agentFirst ? connected : [.start(.connecting), .stop] + connected), label)
        if activated {
            #expect(h.transport.isAudioAttached, label)
            #expect(h.transport.isMicEnabled, label)
            #expect(h.transport.sentSignals == [.connected], label)
            #expect(h.transport.audioDeviceSelections == ["speaker"], label)
        } else {
            expectNoAudioWork(on: h.transport, label)
        }
    }
}
