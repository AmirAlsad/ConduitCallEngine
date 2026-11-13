//
//  MinimumConnectingTests.swift
//  ConduitCallEngineTests
//
//  `CallEngineConfiguration.minimumOutgoingConnectingDuration`: a call the user
//  placed whose transport is ready sooner stays `.connecting` until the connecting
//  loop has run that long, so state, CallKit's connected report, the connecting
//  cue, the mic, the agent's `call-connected` and the record agree. An incoming call
//  is never delayed: answered, it connects as soon as its transport is ready, and a
//  pre-connected ring answered with its agent there goes straight to connected.
//  While the engine holds a ready connection, the
//  transport's own news about it is applied to the call it made (the connection is
//  reported first), so the call ends up where it would have without the minimum;
//  the user's and the system's actions apply to the call as it stands, connecting.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct MinimumConnectingTests {
    private let minimum: Duration = .milliseconds(2600)
    private let clock = MutableClock()
    private let sleeper = ManualSleeper()

    /// Timers wait on a sleeper the test ends by hand; the clock moves by hand.
    private func harness(
        supportsHolding: Bool = false,
        minimum: Duration? = nil,
        joinTimeout: Duration? = nil,
        micWithholdTimeout: Duration = .seconds(5)
    ) -> CallEngineHarness {
        let sleeper = sleeper
        return CallEngineHarness(
            supportsHolding: supportsHolding,
            joinTimeout: joinTimeout,
            minimumOutgoingConnectingDuration: minimum ?? self.minimum,
            micWithholdTimeout: micWithholdTimeout,
            now: clock.now,
            sleep: { await sleeper.sleep($0) }
        )
    }

    private func activate(_ h: CallEngineHarness) async {
        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()
        await h.engine.awaitPendingWork()
    }

    private func setHeld(_ h: CallEngineHarness, _ onHold: Bool) async {
        h.provider.simulateSetHeld(h.callID, onHold: onHold)
        await h.engine.awaitPendingWork()
    }

    // MARK: - The minimum

    @Test func theDefaultIsNoMinimum() {
        #expect(CallEngineConfiguration().minimumOutgoingConnectingDuration == .zero)
    }

    @Test func aCallReadySoonerStaysConnectingForTheRestOfTheMinimum() async throws {
        let h = harness()
        await h.placeCall()
        await activate(h)
        clock.advance(1)

        h.engine.handle(.connected)
        await h.engine.awaitPendingWork()

        #expect(h.engine.state.isConnecting)
        #expect(h.engine.repeatingCue == .connecting)
        #expect(h.provider.reportedConnected.isEmpty)
        #expect(!h.delegate.cues.contains(.moment(.connected)))
        #expect(!h.transport.isMicEnabled)
        #expect(h.transport.sentSignals.isEmpty)
        #expect(h.engine.isTimerRunning(.minimumOutgoingConnecting))
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested.last == .milliseconds(1600))

        clock.advance(1.6)
        #expect(h.engine.fireTimer(.minimumOutgoingConnecting))
        await h.engine.awaitPendingWork()

        #expect(h.engine.state == .connected(since: clock.now()))
        #expect(h.provider.reportedConnected == [h.callID])
        #expect(Array(h.delegate.cues.suffix(2)) == [.stop, .moment(.connected)])
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected])
        #expect(h.delegate.cueViolations.isEmpty)

        clock.advance(10)
        await h.engine.endCall()
        let record = try #require(h.delegate.records.first)
        #expect(record.outcome == .completed)
        #expect(record.duration == 10) // from the reported connection, as CallKit counts it
    }

    @Test func theMicOpensWithTheReportedConnection() async throws {
        let h = harness()
        await h.placeCall()
        await activate(h)
        await h.engine.setMuted(false)
        h.engine.handle(.connected)
        await h.engine.awaitPendingWork()
        #expect(h.transport.micEnabledHistory.allSatisfy { !$0 })

        #expect(h.engine.fireTimer(.minimumOutgoingConnecting))
        await h.engine.awaitPendingWork()

        #expect(h.transport.isMicEnabled)
    }

    @Test func aCallReadyAfterTheMinimumConnectsAtOnce() async throws {
        let h = harness()
        await h.placeCall()
        clock.advance(3)

        h.engine.handle(.connected)

        #expect(h.engine.state.isConnected)
        #expect(!h.engine.isTimerRunning(.minimumOutgoingConnecting))
        #expect(h.provider.reportedConnected == [h.callID])
    }

    @Test func theMinimumCountsFromTheConnectingCueNotTheDial() async throws {
        let h = harness()
        h.provider.suspendStart = true
        let place = Task { await h.placeCall() }
        await waitUntil { h.provider.pendingStartCount == 1 }
        clock.advance(5) // CallKit takes its time; the ringback has not started
        h.provider.releaseStart()
        await place.value
        #expect(h.delegate.cues == [.start(.connecting)])

        h.engine.handle(.connected)

        #expect(h.engine.state.isConnecting)
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested.last == minimum)
    }

    // MARK: - Rings

    @Test func aPreconnectedRingAnsweredWithItsAgentThereIsNotDelayed() async throws {
        let h = harness()
        h.allowRingPreparation(.media)
        h.transport.canConnectWhileRinging = true
        let id = UUID()
        h.ring(callID: id, preconnect: "media")
        _ = await h.engine.awaitPendingRingPreparation()
        h.engine.handle(.connected)
        #expect(h.engine.ringPreparationPhase == .ready)

        await h.engine.answer()

        #expect(h.engine.state.isConnected)
        #expect(!h.engine.isTimerRunning(.minimumOutgoingConnecting))
        #expect(!h.delegate.cues.contains(.start(.connecting)))
    }

    /// The minimum is for a call the user placed, so its ringback can finish. A ring
    /// answered while its pre-connected agent is still on its way connects the
    /// moment the agent is there.
    @Test func aRingStillJoiningAtTheAnswerConnectsAsSoonAsItsAgentIsThere() async throws {
        let h = harness()
        h.allowRingPreparation(.media)
        h.transport.canConnectWhileRinging = true
        h.ring(preconnect: "media")
        _ = await h.engine.awaitPendingRingPreparation()
        #expect(h.engine.ringPreparationPhase == .connecting)
        clock.advance(20) // ringing

        await h.engine.answer()
        #expect(h.engine.state.isConnecting)
        clock.advance(0.5)
        h.engine.handle(.connected)

        #expect(h.engine.state == .connected(since: clock.now()))
        #expect(!h.engine.isTimerRunning(.minimumOutgoingConnecting))
        #expect(h.provider.reportedConnected.isEmpty) // CallKit's answer marks an incoming call
    }

    @Test(arguments: ["none", "credentials"])
    func anAnsweredRingConnectsAsSoonAsItsTransportIsReady(preconnect: String) async throws {
        let h = harness()
        h.allowRingPreparation(.credentials)
        h.ring(preconnect: preconnect)
        _ = await h.engine.awaitPendingRingPreparation()
        await h.engine.answer()
        await activate(h)
        #expect(h.engine.state.isConnecting)
        #expect(h.delegate.cues == [.start(.connecting)])

        h.engine.handle(.connected)
        await h.engine.awaitPendingWork()

        #expect(h.engine.state == .connected(since: clock.now()))
        #expect(!h.engine.isTimerRunning(.minimumOutgoingConnecting))
        #expect(h.delegate.cues == [.start(.connecting), .stop, .moment(.connected)])
        #expect(h.transport.sentSignals == [.connected])
        #expect(h.delegate.cueViolations.isEmpty)
    }

    /// The resume of an answered call held while connecting starts the connecting
    /// loop again, but no minimum: a transport ready during the hold connects at the
    /// resume.
    @Test func anAnsweredCallReadyWhileHeldConnectsAtTheResume() async throws {
        let h = harness(supportsHolding: true)
        h.ring(callID: h.callID)
        await h.engine.answer()
        await activate(h)
        await setHeld(h, true)
        h.engine.handle(.connected)
        #expect(h.engine.state.isConnected) // as with no minimum: connected while held
        #expect(!h.delegate.cues.contains(.moment(.connected)))

        await setHeld(h, false)

        #expect(!h.engine.isTimerRunning(.minimumOutgoingConnecting))
        #expect(h.delegate.cues.last == .moment(.connected))
        #expect(h.delegate.cueViolations.isEmpty)
    }

    // MARK: - The join deadline counts the readiness

    @Test func theReadinessEndsTheJoinDeadline() async throws {
        let h = harness(joinTimeout: .seconds(30))
        await h.placeCall()
        #expect(h.engine.isTimerRunning(.joinTimeout))

        h.engine.handle(.connected)

        #expect(!h.engine.isTimerRunning(.joinTimeout))
        #expect(h.engine.state.isConnecting)
    }

    /// The transport reports `.connected` before its `connect` returns: the return
    /// must not start a wait for an agent that is already there.
    @Test func aConnectReturningAfterTheReadinessStartsNoJoinDeadline() async throws {
        let h = harness(joinTimeout: .seconds(30))
        h.transport.suspendConnect = true
        let place = Task { await h.placeCall() }
        await waitUntil { h.transport.connectCount == 1 }
        h.engine.handle(.connected)

        h.transport.releaseConnect()
        await place.value

        #expect(!h.engine.isTimerRunning(.joinTimeout))
        #expect(h.engine.fireTimer(.minimumOutgoingConnecting))
        #expect(h.engine.state.isConnected)
    }

    // MARK: - The transport's news during the wait: as without the minimum

    enum TransportNews: String, CaseIterable, CustomTestStringConvertible {
        case drop, unknownDrop, selfHeal, agentLeft, credentialsRejected, error, connectThrows
        var testDescription: String { rawValue }
    }

    /// What a call shows the host, CallKit and the agent.
    private struct Trace: Equatable {
        var transitions: [String]
        var cues: [CallCue]
        var records: [String]
        var reportedConnected: Int
        var reportedEnded: [CallEndReason]
        var signals: [CallSignal]
    }

    private func trace(of news: TransportNews, minimum: Duration) async -> Trace {
        let h = harness(minimum: minimum)
        if news == .connectThrows { h.transport.suspendConnect = true }
        let place = Task { await h.placeCall() }
        await waitUntil { h.transport.connectCount == 1 }
        await activate(h)
        h.engine.handle(.connected)
        await h.engine.awaitPendingWork()
        switch news {
        case .drop: h.engine.handle(.disconnected(reason: .networkDropped))
        case .unknownDrop: h.engine.handle(.disconnected(reason: .unknown))
        case .selfHeal: h.engine.handle(.reconnecting)
        case .agentLeft: h.engine.handle(.disconnected(reason: .botLeft))
        case .credentialsRejected: h.engine.handle(.disconnected(reason: .authFailed))
        case .error: h.engine.handle(.error(.connectionFailed("transport error")))
        case .connectThrows:
            h.transport.connectError = .connectionFailed("late failure")
            h.transport.releaseConnect()
        }
        await place.value
        // News that changes nothing for a connected call leaves the wait running:
        // let it run out, so both calls are compared where they end up.
        _ = h.engine.fireTimer(.minimumOutgoingConnecting)
        await h.engine.awaitPendingWork()
        let trace = Trace(
            transitions: h.delegate.transitions,
            cues: h.delegate.cues,
            records: h.delegate.records.map { "\($0.outcome.rawValue) \($0.failureReason?.rawValue ?? "-")" },
            reportedConnected: h.provider.reportedConnected.count,
            reportedEnded: h.provider.reportedEnded.map(\.reason),
            signals: h.transport.sentSignals
        )
        await h.engine.endCall()
        return trace
    }

    @Test(arguments: TransportNews.allCases)
    func theTransportsNewsDuringTheWaitEndsWhereItWouldWithoutTheMinimum(_ news: TransportNews) async throws {
        let without = await trace(of: news, minimum: .zero)
        var with = await trace(of: news, minimum: .seconds(3600))

        if with.records.isEmpty {
            #expect(with == without)
        } else {
            // A call that ends the moment it is reported connected never had the
            // user on the line, so its agent is not told so.
            #expect(with.signals.isEmpty)
            with.signals = without.signals
            #expect(with == without)
        }
    }

    @Test func aDropDuringTheWaitReconnectsRatherThanFailing() async throws {
        let h = harness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.handle(.disconnected(reason: .networkDropped))

        #expect(h.engine.state == .reconnecting(attempt: 1))
        #expect(h.delegate.records.isEmpty)
        #expect(!h.engine.isTimerRunning(.minimumOutgoingConnecting))
    }

    // MARK: - The user's and the system's actions during the wait

    @Test func hangingUpDuringTheWaitEndsACallThatNeverConnected() async throws {
        let h = harness()
        await h.placeCall()
        await activate(h)
        h.engine.handle(.connected)

        await h.engine.endCall()

        #expect(h.engine.state == .ended(.canceled))
        #expect(h.provider.reportedConnected.isEmpty)
        #expect(!h.delegate.cues.contains(.moment(.connected)))
        #expect(h.delegate.records.map(\.outcome) == [.canceled])
        #expect(h.delegate.records.first?.duration == 0)
        #expect(!h.engine.isTimerRunning(.minimumOutgoingConnecting))
        #expect(h.transport.sentSignals.isEmpty)
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func anEndFromTheSystemUIDuringTheWaitIsOneRecord() async throws {
        let h = harness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.provider.simulateEndCall(h.callID)
        #expect(!h.engine.fireTimer(.minimumOutgoingConnecting))

        #expect(h.engine.state == .ended(.canceled))
        #expect(h.delegate.records.count == 1)
        #expect(h.provider.reportedConnected.isEmpty)
    }

    @Test func aProviderResetDuringTheWaitFailsTheCall() async throws {
        let h = harness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.provider.simulateReset()

        #expect(h.engine.state == .failed(.unknown))
        #expect(h.delegate.records.map(\.outcome) == [.failed])
        #expect(h.provider.reportedConnected.isEmpty)
        #expect(!h.engine.isTimerRunning(.minimumOutgoingConnecting))
    }

    /// A hold stops the ringback, so the wait stops too; the resume starts the
    /// ringback again and the full minimum with it.
    @Test func aHoldDuringTheWaitRestartsItInFullAtTheResume() async throws {
        let h = harness(supportsHolding: true, joinTimeout: .seconds(30))
        await h.placeCall()
        await activate(h)
        h.engine.handle(.connected)
        #expect(h.engine.isTimerRunning(.minimumOutgoingConnecting))

        await setHeld(h, true)
        #expect(!h.engine.isTimerRunning(.minimumOutgoingConnecting))
        #expect(!h.engine.isTimerRunning(.joinTimeout))
        #expect(h.engine.state.isConnecting)
        clock.advance(60)
        await waitUntil { sleeper.requested.count == 2 } // the join bound and the first wait
        let waits = sleeper.requested.count

        await setHeld(h, false)
        #expect(h.delegate.cues.last == .start(.connecting))
        #expect(h.engine.isTimerRunning(.minimumOutgoingConnecting))
        #expect(!h.engine.isTimerRunning(.joinTimeout)) // the agent is there
        await waitUntil { sleeper.requested.count == waits + 1 }
        #expect(sleeper.requested.count == waits + 1)
        #expect(sleeper.requested.last == minimum)
        #expect(h.engine.state.isConnecting)

        #expect(h.engine.fireTimer(.minimumOutgoingConnecting))
        await h.engine.awaitPendingWork()
        #expect(h.engine.state.isConnected)
        #expect(Array(h.delegate.cues.suffix(2)) == [.stop, .moment(.connected)])
        #expect(h.transport.sentSignals == [.held, .resumed, .connected]) // the agent in the room heard of the hold
        #expect(h.delegate.cueViolations.isEmpty)
    }

    @Test func aTransportReadyWhileHeldWaitsForTheResumeAndTheMinimum() async throws {
        let h = harness(supportsHolding: true)
        await h.placeCall()
        await activate(h)
        await setHeld(h, true)
        clock.advance(10)

        h.engine.handle(.connected)
        #expect(h.engine.state.isConnecting)
        #expect(!h.engine.isTimerRunning(.minimumOutgoingConnecting))

        await setHeld(h, false)
        #expect(h.engine.isTimerRunning(.minimumOutgoingConnecting))
        #expect(h.engine.fireTimer(.minimumOutgoingConnecting))
        #expect(h.engine.state.isConnected)
    }

    @Test func aZeroMinimumConnectsWhileHeldAsBefore() async throws {
        let h = harness(supportsHolding: true, minimum: .zero)
        await h.placeCall()
        await setHeld(h, true)

        h.engine.handle(.connected)

        #expect(h.engine.state.isConnected)
        #expect(h.engine.isOnHold)
    }

    @Test func aDeactivationDuringTheWaitDoesNotChangeIt() async throws {
        let h = harness()
        await h.placeCall()
        await activate(h)
        h.engine.handle(.connected)
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingWork()

        #expect(h.engine.fireTimer(.minimumOutgoingConnecting))
        #expect(h.engine.state.isConnected)
        #expect(!h.delegate.cues.contains(.moment(.connected))) // waits for the activation

        await activate(h)
        #expect(h.delegate.cues.last == .moment(.connected))
    }

    @Test func anInterruptionDuringTheWaitDoesNotChangeIt() async throws {
        let h = harness()
        await h.placeCall()
        await activate(h)
        h.engine.handle(.connected)
        h.interruption.simulateBegan()

        #expect(h.engine.fireTimer(.minimumOutgoingConnecting))
        await h.engine.awaitPendingWork()
        #expect(h.engine.state.isConnected)
        #expect(!h.transport.isMicEnabled)

        h.interruption.simulateEnded(shouldResume: true)
        await h.engine.awaitPendingWork()
        #expect(h.transport.isMicEnabled)
    }

    // MARK: - Every order

    /// 360 orders: the transport's readiness, the minimum passing, CallKit's
    /// activation, a hold and its resume, and an unmute. The call is reported
    /// connected exactly when the transport is ready and the minimum has passed
    /// since the connecting loop last started (a hold stops it; the resume starts
    /// it again), and never before; the mic opens only then.
    @Test func everyOrderReportsTheConnectionOnlyOnceItIsDue() async throws {
        let events: [WaitEvent] = [.ready, .elapse, .activate, .hold, .unhold, .unmute]
        let orders = WaitEvent.permutations(of: events).filter {
            $0.firstIndex(of: .hold)! < $0.firstIndex(of: .unhold)!
        }
        try #require(orders.count == 360)
        var failures: [String] = []
        for order in orders {
            if let failure = await run(order) { failures.append(failure) }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(orders.count) orders failed; first: \(failures.prefix(3))")
    }

    private func run(_ order: [WaitEvent]) async -> String? {
        let clock = MutableClock()
        let h = CallEngineHarness(
            supportsHolding: order.contains(.hold),
            minimumOutgoingConnectingDuration: minimum,
            now: clock.now,
            sleep: { _ in try await Task.sleep(for: .seconds(24 * 60 * 60)) }
        )
        await h.placeCall()
        await h.engine.setMuted(true)
        let failure = await drive(h, clock: clock, through: order)
        await h.engine.endCall()
        return failure
    }

    private func drive(_ h: CallEngineHarness, clock: MutableClock, through order: [WaitEvent]) async -> String? {
        var ready = false, elapsed = false, held = false, activated = false, muted = true, reported = false
        for (step, event) in order.enumerated() {
            switch event {
            case .ready:
                h.engine.handle(.connected)
                ready = true
            case .elapse:
                clock.advance(minimum / .seconds(1))
                _ = h.engine.fireTimer(.minimumOutgoingConnecting)
                if !held { elapsed = true }
            case .activate:
                h.provider.simulateActivate(FakeAudioSession())
                await h.engine.awaitPendingActivation()
                activated = true
            case .hold:
                h.provider.simulateSetHeld(h.callID, onHold: true)
                held = true
                elapsed = false
            case .unhold:
                h.provider.simulateSetHeld(h.callID, onHold: false)
                held = false
                elapsed = false
            case .unmute:
                await h.engine.setMuted(false)
                muted = false
            }
            if ready && elapsed && !held { reported = true }
            await h.engine.awaitPendingWork()
            let where_ = "\(order) step \(step) (\(event))"
            if h.engine.state.isConnected != reported {
                return "\(where_): connected \(h.engine.state.isConnected), expected \(reported)"
            }
            if h.provider.reportedConnected.count != (reported ? 1 : 0) {
                return "\(where_): CallKit told connected \(h.provider.reportedConnected.count) times"
            }
            let mic = reported && activated && !held && !muted
            if h.transport.isMicEnabled != mic { return "\(where_): mic \(h.transport.isMicEnabled), expected \(mic)" }
            if !reported, h.delegate.cues.contains(.moment(.connected)) { return "\(where_): connected cue before the connection" }
            if !h.delegate.cueViolations.isEmpty { return "\(where_): \(h.delegate.cueViolations)" }
        }
        return nil
    }
}

enum WaitEvent: String, CustomStringConvertible, Sendable {
    /// The transport reports `.connected`.
    case ready
    /// The minimum passes (the clock moves on by it, and its timer is run out if it runs).
    case elapse
    case activate, hold, unhold, unmute

    var description: String { rawValue }

    static func permutations(of items: [WaitEvent]) -> [[WaitEvent]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[WaitEvent]] in
            var rest = items
            let first = rest.remove(at: index)
            return permutations(of: rest).map { [first] + $0 }
        }
    }
}
