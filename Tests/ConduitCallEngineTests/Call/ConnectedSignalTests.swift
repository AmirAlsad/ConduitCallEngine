//
//  ConnectedSignalTests.swift
//  ConduitCallEngineTests
//
//  `CallSignal.connected` (`call-connected`): the agent is told the user is on the
//  line, on every call, once the call is connected, CallKit has activated its
//  audio, it is not held and the host is not withholding the mic, whichever comes
//  last; again on every new connection. Mute and push-to-talk do not delay it. The
//  every-order test drives each order of those inputs against that condition.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct ConnectedSignalTests {
    /// A harness whose timers wait until the call ends, so the withhold's bound
    /// never runs out by itself (the default sleep would release it at once).
    private func patientHarness(supportsHolding: Bool = false) -> CallEngineHarness {
        CallEngineHarness(supportsHolding: supportsHolding, sleep: SimulatedCallSystem.sleepUntilCancelled)
    }

    private func activate(_ h: CallEngineHarness) async {
        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()
        await h.engine.awaitPendingSignals()
    }

    private func setHeld(_ h: CallEngineHarness, _ onHold: Bool) async {
        h.provider.simulateSetHeld(h.callID, onHold: onHold)
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()
    }

    private func withhold(_ h: CallEngineHarness, _ withheld: Bool) async {
        h.engine.setMicWithheld(withheld)
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()
    }

    // MARK: - Every call

    @Test func anOutgoingCallIsToldOnceConnectedAndActivated() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        await activate(h)
        #expect(h.transport.sentSignals.isEmpty) // not connected yet

        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()

        #expect(h.transport.sentSignals == [.connected])
    }

    @Test func anOutgoingCallThatConnectsBeforeTheActivationIsToldAtTheActivation() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()
        #expect(h.transport.sentSignals.isEmpty) // the user cannot hear yet

        await activate(h)

        #expect(h.transport.sentSignals == [.connected])
    }

    @Test(arguments: [nil, "credentials", "media"])
    func anAnsweredRingIsToldWhateverItsPushAskedFor(preconnect: String?) async throws {
        let h = CallEngineHarness() // the host allows no preparation
        h.ring(preconnect: preconnect)
        await h.engine.answer()
        h.engine.handle(.connected)
        await activate(h)

        #expect(h.transport.sentSignals == [.connected])
    }

    @Test func itFollowsTheAttachAndMicCommandsBeforeIt() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        h.transport.suspendAttach = true

        h.provider.simulateActivate(FakeAudioSession())
        await waitUntil { h.transport.pendingAttachCount == 1 }
        await settle()
        #expect(h.transport.sentSignals.isEmpty) // waits for the attach

        h.transport.releaseAttach()
        await h.engine.awaitPendingActivation()
        await h.engine.awaitPendingSignals()

        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected])
    }

    // MARK: - What delays it, and what does not

    @Test func aMutedUserIsStillOnTheLine() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        await h.engine.setMuted(true)
        h.engine.handle(.connected)
        await activate(h)

        #expect(!h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected])
    }

    @Test func pushToTalkWithTheButtonUpIsStillOnTheLine() async throws {
        let h = CallEngineHarness(pushToTalk: true)
        await h.placeCall()
        h.engine.handle(.connected)
        await activate(h)

        #expect(!h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected])
    }

    @Test func theHostsWithholdDelaysItUntilTheRelease() async throws {
        let h = patientHarness()
        await h.placeCall()
        h.engine.setMicWithheld(true)
        h.engine.handle(.connected)
        await activate(h)
        #expect(h.transport.sentSignals.isEmpty)

        await withhold(h, false)

        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected])
    }

    @Test func aWithholdMadeInTheConnectedCueDelaysIt() async throws {
        let h = patientHarness()
        h.delegate.onCue = { engine, cue in
            if cue == .moment(.connected) { engine.setMicWithheld(true) }
        }
        await h.placeCall()
        await activate(h)
        h.engine.handle(.connected)
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()
        #expect(h.transport.sentSignals.isEmpty)
        #expect(h.transport.micEnabledHistory.allSatisfy { !$0 }) // never opened

        await withhold(h, false)

        #expect(h.transport.sentSignals == [.connected])
    }

    @Test func theWithholdsBoundSendsItWhenTheHostNeverReleases() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(sleep: { await sleeper.sleep($0) })
        await h.placeCall()
        h.engine.setMicWithheld(true)
        h.engine.handle(.connected)
        await activate(h)
        #expect(h.transport.sentSignals.isEmpty)

        #expect(h.engine.fireTimer(.micWithholdTimeout))
        await h.engine.awaitPendingWork()

        #expect(!h.engine.isMicWithheld)
        #expect(h.transport.sentSignals == [.connected])
    }

    @Test func aCallThatConnectsWhileHeldIsToldAfterTheResume() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await h.placeCall()
        await activate(h)
        await setHeld(h, true)
        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()
        #expect(h.transport.sentSignals == [.held])

        await setHeld(h, false)

        #expect(h.transport.sentSignals == [.held, .resumed, .connected])
    }

    @Test func aHoldAfterItWasSentDoesNotSendItAgainAtTheResume() async throws {
        let h = CallEngineHarness(supportsHolding: true)
        await h.placeCall()
        h.engine.handle(.connected)
        await activate(h)

        await setHeld(h, true)
        await setHeld(h, false)

        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
    }

    @Test func aDeactivationAndReactivationDoNotSendItAgain() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        await activate(h)

        h.provider.simulateDeactivate(FakeAudioSession())
        await activate(h)

        #expect(h.transport.sentSignals == [.connected])
    }

    // MARK: - New connections

    @Test func everyReconnectTellsTheAgentAgain() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        await activate(h)

        h.engine.handle(.reconnecting) // the transport heals itself
        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()
        h.engine.handle(.disconnected(reason: .networkDropped)) // the engine reconnects
        await h.engine.awaitPendingReconnect()
        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()

        #expect(h.transport.sentSignals == [.connected, .connected, .connected])
    }

    @Test func aReconnectWithheldForTheHostsSoundIsToldAtTheRelease() async throws {
        let h = patientHarness()
        h.delegate.onCue = { engine, cue in
            if cue == .moment(.reconnected) { engine.setMicWithheld(true) }
        }
        await h.placeCall()
        h.engine.handle(.connected)
        await activate(h)
        h.engine.handle(.disconnected(reason: .networkDropped))
        #expect(h.engine.fireTimer(.reconnectBackoff))
        await h.engine.awaitPendingReconnect()

        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()
        #expect(h.transport.sentSignals == [.connected])

        await withhold(h, false)

        #expect(h.transport.sentSignals == [.connected, .connected])
    }

    // MARK: - Every order

    /// 180 orders: the connection, CallKit's activation, a hold and its resume, and
    /// the host's withhold and its release. The agent is told exactly once, at the
    /// first moment all four conditions hold, and never before.
    @Test func everyOrderTellsTheAgentOnceAllConditionsHold() async throws {
        let events: [ConnectedSignalEvent] = [.connect, .activate, .hold, .unhold, .withhold, .release]
        let orders = ConnectedSignalEvent.permutations(of: events).filter { order in
            order.firstIndex(of: .hold)! < order.firstIndex(of: .unhold)!
                && order.firstIndex(of: .withhold)! < order.firstIndex(of: .release)!
        }
        try #require(orders.count == 180)
        var failures: [String] = []
        for order in orders {
            if let failure = await run(order) { failures.append(failure) }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(orders.count) orders failed; first: \(failures.prefix(3))")
    }

    /// The host withholds the mic from inside the `.moment(.connected)` cue, as
    /// Conduit and the guide's sample do, wherever that cue comes from: the
    /// connection, CallKit's activation or the resume. In every order of the
    /// connection, the activation, a hold and its resume, on a call placed or
    /// answered, the agent is told only after the host's release, and once.
    @Test(arguments: [CallDirection.outgoing, .incoming])
    func aWithholdMadeInTheConnectedCueHoldsTheSignalInEveryOrder(_ direction: CallDirection) async throws {
        let events: [ConnectedSignalEvent] = [.connect, .activate, .hold, .unhold]
        let orders = ConnectedSignalEvent.permutations(of: events).filter { order in
            order.firstIndex(of: .hold)! < order.firstIndex(of: .unhold)!
        }
        try #require(orders.count == 12)
        var failures: [String] = []
        for order in orders {
            if let failure = await runWithholdingInTheCue(order, direction) { failures.append(failure) }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(orders.count) orders failed; first: \(failures.prefix(3))")
    }

    private func runWithholdingInTheCue(_ order: [ConnectedSignalEvent], _ direction: CallDirection) async -> String? {
        let h = patientHarness()
        var cueCount = 0
        h.delegate.onCue = { engine, cue in
            guard cue == .moment(.connected) else { return }
            cueCount += 1
            engine.setMicWithheld(true)
        }
        switch direction {
        case .outgoing:
            await h.placeCall()
        case .incoming:
            h.ring(callID: h.callID)
            await h.engine.answer()
        }
        for (step, event) in order.enumerated() {
            switch event {
            case .connect: h.engine.handle(.connected)
            case .activate:
                h.provider.simulateActivate(FakeAudioSession())
                await h.engine.awaitPendingActivation()
            case .hold: h.provider.simulateSetHeld(h.callID, onHold: true)
            case .unhold: h.provider.simulateSetHeld(h.callID, onHold: false)
            default: break
            }
            await h.engine.awaitPendingMediaWork()
            await h.engine.awaitPendingSignals()
            if h.transport.sentSignals.contains(.connected) {
                await h.engine.endCall()
                return "\(direction) \(order) step \(step) (\(event)): told before the host's release"
            }
            if h.transport.micEnabledHistory.contains(true) {
                await h.engine.endCall()
                return "\(direction) \(order) step \(step) (\(event)): the mic opened during the host's sound"
            }
        }
        guard cueCount == 1, h.engine.isMicWithheld else {
            await h.engine.endCall()
            return "\(direction) \(order): connected cue \(cueCount) times, withheld \(h.engine.isMicWithheld)"
        }
        h.engine.setMicWithheld(false)
        await h.engine.awaitPendingMediaWork()
        await h.engine.awaitPendingSignals()
        let told = h.transport.sentSignals.filter { $0 == .connected }.count
        await h.engine.endCall()
        return told == 1 ? nil : "\(direction) \(order): told \(told) times after the release"
    }

    /// The reviewer's case: an answered ring still connecting is held, its agent
    /// gets ready during the hold, and CallKit's session is active at the resume.
    /// The connected cue comes at the resume; the agent must not be told before
    /// the host's "Connected" is done.
    @Test func anAnsweredCallThatConnectsDuringAHoldIsToldOnlyAfterTheConnectedSound() async throws {
        let h = patientHarness(supportsHolding: true)
        h.delegate.onCue = { engine, cue in
            if cue == .moment(.connected) { engine.setMicWithheld(true) }
        }
        h.ring(callID: h.callID)
        await h.engine.answer()
        await activate(h)
        await setHeld(h, true)
        h.engine.handle(.connected)
        await h.engine.awaitPendingSignals()
        #expect(h.transport.sentSignals == [.held])

        await setHeld(h, false)
        #expect(Array(h.delegate.cues.suffix(2)) == [.moment(.resumed), .moment(.connected)])
        #expect(h.engine.isMicWithheld)
        #expect(h.transport.sentSignals == [.held, .resumed])
        #expect(!h.transport.micEnabledHistory.contains(true))

        await withhold(h, false)
        #expect(h.transport.sentSignals == [.held, .resumed, .connected])
        #expect(h.transport.isMicEnabled)
    }

    private func run(_ order: [ConnectedSignalEvent]) async -> String? {
        let h = CallEngineHarness(supportsHolding: order.contains(.hold), sleep: SimulatedCallSystem.sleepUntilCancelled)
        await h.placeCall()
        var isConnected = false, isActivated = false, isHeld = false, isWithheld = false
        var isDue = false
        for (step, event) in order.enumerated() {
            switch event {
            case .connect: h.engine.handle(.connected); isConnected = true
            case .activate:
                h.provider.simulateActivate(FakeAudioSession())
                await h.engine.awaitPendingActivation()
                isActivated = true
            case .hold: h.provider.simulateSetHeld(h.callID, onHold: true); isHeld = true
            case .unhold: h.provider.simulateSetHeld(h.callID, onHold: false); isHeld = false
            case .withhold: h.engine.setMicWithheld(true); isWithheld = true
            case .release: h.engine.setMicWithheld(false); isWithheld = false
            }
            await h.engine.awaitPendingMediaWork()
            await h.engine.awaitPendingSignals()
            if isConnected && isActivated && !isHeld && !isWithheld { isDue = true }
            let told = h.transport.sentSignals.filter { $0 == .connected }.count
            if told != (isDue ? 1 : 0) {
                await h.engine.endCall()
                return "\(order) step \(step) (\(event)): told \(told) times, expected \(isDue ? 1 : 0)"
            }
        }
        await h.engine.endCall()
        return nil
    }
}

enum ConnectedSignalEvent: String, CustomStringConvertible, Sendable {
    case connect, activate, hold, unhold, withhold, release

    var description: String { rawValue }

    static func permutations(of items: [ConnectedSignalEvent]) -> [[ConnectedSignalEvent]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[ConnectedSignalEvent]] in
            var rest = items
            let first = rest.remove(at: index)
            return permutations(of: rest).map { [first] + $0 }
        }
    }
}
