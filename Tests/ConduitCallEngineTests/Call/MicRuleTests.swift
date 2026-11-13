//
//  MicRuleTests.swift
//  ConduitCallEngineTests
//
//  The one mic rule: the transport's mic is on only once the call has been
//  reported connected and while CallKit has activated the session, the call is
//  not on hold, no interruption holds it, the host is not withholding it, and the
//  user wants it on (unmuted, or in push-to-talk mode the button held). Every
//  input re-derives the mic from that rule, so the order the inputs arrive in
//  never matters; the permutation tests drive every order against a reference
//  model of the rule, including orders whose interruption never reports its end,
//  and end each order by checking the call has a way out.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct MicRuleTests {

    /// Placed, connected and activated: the mic is live.
    private func liveCall(supportsHolding: Bool = false) async -> CallEngineHarness {
        let h = CallEngineHarness(supportsHolding: supportsHolding)
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.activate(FakeAudioSession())
        return h
    }

    private func activate(_ h: CallEngineHarness) async {
        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()
    }

    // MARK: - An interruption that ends without permission to resume

    @Test func activationBeforeAnUnresumableEndReopensTheMic() async throws {
        let h = await liveCall()
        h.interruption.simulateBegan()
        await activate(h) // CallKit hands the session back before the end is reported
        await h.engine.awaitPendingMediaWork()
        #expect(!h.engine.isInterrupted)
        #expect(h.transport.isMicEnabled)

        h.interruption.simulateEnded(shouldResume: false)
        await h.engine.awaitPendingMediaWork()

        #expect(!h.engine.isInterrupted)
        #expect(!h.engine.isMuted)
        #expect(h.transport.isMicEnabled)
    }

    // MARK: - CallKit handing the audio back ends an interruption

    /// iOS does not always report an interruption's end (it did not after a phone
    /// call on iOS 27): CallKit activating the audio of a call that is not held is
    /// the system giving the audio back.
    @Test func anActivationOfACallThatIsNotHeldEndsTheInterruptionWithoutItsEnd() async throws {
        let h = await liveCall()
        h.interruption.simulateBegan()
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingMediaWork()
        #expect(h.engine.isInterrupted)
        #expect(!h.transport.isMicEnabled)

        await activate(h)

        #expect(!h.engine.isInterrupted)
        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
    }

    @Test func anActivationWhileHeldEndsTheInterruptionAtTheResume() async throws {
        let h = await liveCall(supportsHolding: true)
        h.interruption.simulateBegan()
        h.provider.simulateSetHeld(h.callID, onHold: true)
        h.provider.simulateDeactivate(FakeAudioSession())
        await activate(h) // CallKit gives the held call its session back
        #expect(h.engine.isInterrupted)
        #expect(!h.transport.isMicEnabled)

        h.provider.simulateSetHeld(h.callID, onHold: false)
        await h.engine.awaitPendingMediaWork()

        #expect(!h.engine.isInterrupted)
        #expect(h.transport.isMicEnabled)
    }

    @Test func aResumeWithoutAnActivationSinceTheInterruptionKeepsItGoing() async throws {
        let h = await liveCall()
        h.provider.simulateSetHeld(h.callID, onHold: true)
        h.interruption.simulateBegan()

        h.provider.simulateSetHeld(h.callID, onHold: false)
        await h.engine.awaitPendingMediaWork()

        #expect(h.engine.isInterrupted)
        #expect(!h.transport.isMicEnabled)
    }

    /// The documented case stays: an end without permission to resume does not
    /// reopen the mic by itself, an activation after it does.
    @Test func anUnresumableEndStillWaitsForTheActivationAfterADeactivation() async throws {
        let h = await liveCall()
        h.interruption.simulateBegan()
        h.provider.simulateDeactivate(FakeAudioSession())
        h.interruption.simulateEnded(shouldResume: false)
        await h.engine.awaitPendingMediaWork()
        #expect(h.engine.isInterrupted)
        #expect(!h.transport.isMicEnabled)

        await activate(h)

        #expect(!h.engine.isInterrupted)
        #expect(h.transport.isMicEnabled)
    }

    @Test func anUnresumableEndKeepsTheMicPausedUntilCallKitActivatesAgain() async throws {
        let h = await liveCall()
        h.interruption.simulateBegan()
        h.interruption.simulateEnded(shouldResume: false)
        await h.engine.awaitPendingMediaWork()

        #expect(h.engine.isInterrupted) // the UI shows why the mic is closed
        #expect(!h.transport.isMicEnabled)

        await activate(h)

        #expect(!h.engine.isInterrupted)
        #expect(h.transport.isMicEnabled)
    }

    @Test func unmutingAfterAnUnresumableEndReopensTheMic() async throws {
        let h = await liveCall()
        await h.engine.setMuted(true)
        h.interruption.simulateBegan()
        h.interruption.simulateEnded(shouldResume: false)

        await h.engine.setMuted(false)

        #expect(!h.engine.isInterrupted)
        #expect(h.transport.isMicEnabled)
    }

    @Test func pushToTalkAfterAnUnresumableEndOpensTheMic() async throws {
        let h = CallEngineHarness(pushToTalk: true)
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.activate(FakeAudioSession())
        h.interruption.simulateBegan()
        h.interruption.simulateEnded(shouldResume: false)

        await h.engine.setPushToTalkActive(true)

        #expect(!h.engine.isInterrupted)
        #expect(h.transport.isMicEnabled)
    }

    @Test func unmutingDuringAnInterruptionDoesNotEndIt() async throws {
        let h = await liveCall()
        await h.engine.setMuted(true)
        h.interruption.simulateBegan()

        await h.engine.setMuted(false)

        #expect(h.engine.isInterrupted)
        #expect(!h.transport.isMicEnabled)
    }

    // MARK: - Before the call is connected

    /// CallKit activates an outgoing call's audio long before its agent is there
    /// (the credential fetch and the join come after). The mic stays closed until
    /// the call is connected, whatever the host does, and opens then.
    @Test func anActivationBeforeTheCallConnectsKeepsTheMicClosedUntilItConnects() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        await activate(h)
        await h.engine.setMuted(false)
        await h.engine.awaitPendingMediaWork()
        #expect(!h.transport.isMicEnabled)
        #expect(h.transport.isAudioAttached) // the agent can be heard as soon as it speaks

        h.engine.handle(.connected)
        await h.engine.awaitPendingMediaWork()

        #expect(h.transport.isMicEnabled)
        #expect(h.transport.micEnabledHistory.last == true)
        #expect(h.transport.micEnabledHistory.dropLast().allSatisfy { !$0 })
    }

    @Test func anAnsweredRingKeepsTheMicClosedUntilItConnects() async throws {
        let h = CallEngineHarness()
        h.ring()
        await h.engine.answer()
        await activate(h)
        await h.engine.awaitPendingMediaWork()
        #expect(h.engine.state.isConnecting)
        #expect(!h.transport.isMicEnabled)

        h.engine.handle(.connected)
        await h.engine.awaitPendingMediaWork()

        #expect(h.transport.isMicEnabled)
    }

    /// Once connected, the call keeps its mic through an outage: closing it during
    /// a transport's own recovery would only add a change for the SDK to apply.
    @Test func aReconnectingCallKeepsItsMicOpen() async throws {
        let h = await liveCall()
        await h.engine.awaitPendingMediaWork()
        let opened = h.transport.micEnabledHistory.count

        h.engine.handle(.reconnecting)
        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()
        h.engine.handle(.connected)
        await h.engine.awaitPendingMediaWork()

        #expect(h.transport.isMicEnabled)
        #expect(h.transport.micEnabledHistory.dropFirst(opened).allSatisfy { $0 })
    }

    // MARK: - Deactivation

    @Test func deactivationClosesTheMicAndDetaches() async throws {
        let h = await liveCall()
        #expect(h.transport.isMicEnabled)

        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingMediaWork()

        #expect(!h.transport.isMicEnabled)
        #expect(!h.transport.isAudioAttached)
    }

    @Test func reactivationReattachesThenReopensTheMic() async throws {
        let h = await liveCall()
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingMediaWork()

        await activate(h)

        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
    }

    // MARK: - Every order

    /// 360 orders per argument: the connection and CallKit's activation in either
    /// order, woven through a deactivation, an interruption and an unmute, from a
    /// call that has not connected yet.
    @Test(arguments: [true, false])
    func everyOrderOfTheConnectionAndTheActivationLeavesTheMicWhereTheRuleSays(shouldResume: Bool) async throws {
        let events: [MicEvent] = [.connect, .activate, .deactivate, .interrupt, .endInterruption, .unmute]
        try await MicRuleScenario.runEveryOrder(of: events, shouldResume: shouldResume)
    }

    @Test(arguments: [true, false])
    func everyOrderOfTheInputsLeavesTheMicWhereTheRuleSays(shouldResume: Bool) async throws {
        let events: [MicEvent] = [.activate, .deactivate, .interrupt, .endInterruption, .unmute]
        try await MicRuleScenario.runEveryOrder(of: events, shouldResume: shouldResume)
    }

    /// 1,260 orders per argument: hold and its release woven through activation,
    /// deactivation, an interruption and an unmute.
    @Test(arguments: [true, false])
    func everyOrderWithAHoldLeavesTheMicAndMediaWhereTheRuleSays(shouldResume: Bool) async throws {
        let events: [MicEvent] = [.activate, .deactivate, .hold, .unhold, .interrupt, .endInterruption, .unmute]
        try await MicRuleScenario.runEveryOrder(of: events, shouldResume: shouldResume)
    }

    /// 2,520 orders per argument: the host's withhold and its release, in either
    /// order, woven through activation, deactivation, an interruption and an unmute.
    @Test(arguments: [true, false])
    func everyOrderWithAWithholdLeavesTheMicWhereTheRuleSays(shouldResume: Bool) async throws {
        let events: [MicEvent] = [.activate, .deactivate, .interrupt, .endInterruption, .unmute, .withhold, .release]
        try await MicRuleScenario.runEveryOrder(of: events, shouldResume: shouldResume)
    }

    /// 2,520 orders: the withhold and its release woven through the connection,
    /// activation, a hold and an unmute, from a call that has not connected yet, so
    /// the withhold also comes before the connect and the activation.
    @Test func everyOrderOfAWithholdAroundTheConnectAndAHoldLeavesTheMicWhereTheRuleSays() async throws {
        let events: [MicEvent] = [.connect, .activate, .hold, .unhold, .unmute, .withhold, .release]
        try await MicRuleScenario.runEveryOrder(of: events, shouldResume: true)
    }

    /// 360 orders: the interruption's end never arrives (as after a phone call on
    /// iOS 27), woven through activation, deactivation, a hold and an unmute. The
    /// way-out check every run ends with shows none of them leaves the call stuck.
    @Test func everyOrderWhoseInterruptionNeverEndsLeavesAWayOut() async throws {
        let events: [MicEvent] = [.activate, .deactivate, .hold, .unhold, .interrupt, .unmute]
        try await MicRuleScenario.runEveryOrder(of: events, shouldResume: false)
    }

    /// 60 orders: the edges of the device sequence (a system hold, an interruption
    /// whose end never comes, a deactivation, the resume, an activation), in every
    /// order with the hold before its release, on an unmuted call.
    @Test func everyOrderOfAHeldCallsInterruptionWithoutAnEndLeavesAWayOut() async throws {
        let events: [MicEvent] = [.hold, .interrupt, .deactivate, .unhold, .activate]
        try await MicRuleScenario.runEveryOrder(of: events, shouldResume: false, unmuted: true)
    }
}

/// An input to the mic rule, as the system or the user delivers it.
enum MicEvent: String, CustomStringConvertible, Sendable {
    case activate, deactivate, interrupt, endInterruption, unmute, hold, unhold
    /// The transport reports `.connected`. An order without it starts connected.
    case connect
    /// The host's `setMicWithheld(true)` and `setMicWithheld(false)`.
    case withhold, release

    var description: String { rawValue }
}

/// The documented rule, as a reference the engine is checked against.
struct MicRuleModel {
    enum Interruption: Equatable { case none, interrupted(reactivated: Bool), awaitingActivation }

    let shouldResume: Bool
    var isConnected = true
    var isActivated = false
    var isMuted = true
    var isHeld = false
    var isWithheld = false
    /// The withhold's bound runs once the call is connected with its audio
    /// activated while withheld, and stops only at the release.
    var isWithholdBoundRunning = false
    var interruption = Interruption.none

    var isInterrupted: Bool { interruption != .none }
    /// Media runs on a session CallKit activated, and not while held.
    var isAttached: Bool { isActivated && !isHeld }
    var micIsOn: Bool { isConnected && isActivated && !isHeld && !isInterrupted && !isWithheld && !isMuted }

    mutating func apply(_ event: MicEvent) {
        switch event {
        case .activate:
            isActivated = true
            // The audio of a call that is not held, handed back: the interruption is over.
            switch interruption {
            case .none: break
            case _ where !isHeld: interruption = .none
            case .interrupted: interruption = .interrupted(reactivated: true)
            case .awaitingActivation: interruption = .none
            }
        case .deactivate:
            isActivated = false
        case .interrupt:
            interruption = .interrupted(reactivated: false)
        case .endInterruption:
            switch interruption {
            case .none: break
            case .interrupted(reactivated: true): interruption = .none
            case .interrupted, .awaitingActivation: interruption = shouldResume ? .none : .awaitingActivation
            }
        case .unmute:
            isMuted = false
            if interruption == .awaitingActivation { interruption = .none }
        case .hold:
            isHeld = true
        case .unhold:
            isHeld = false
            if isActivated, interruption == .interrupted(reactivated: true) { interruption = .none }
        case .connect:
            isConnected = true
        case .withhold:
            isWithheld = true
        case .release:
            isWithheld = false
            isWithholdBoundRunning = false
        }
        if isWithheld, isConnected, isActivated { isWithholdBoundRunning = true }
    }
}

@MainActor
enum MicRuleScenario {
    /// Drive one connected, muted call through `order` and compare the mic with
    /// the model after every step. Returns a description of the first mismatch.
    static func run(_ order: [MicEvent], shouldResume: Bool, unmuted: Bool = false) async -> String? {
        // A sleep that lasts until the call's end cancels it, so the withhold's
        // bound never runs out by itself.
        let h = CallEngineHarness(supportsHolding: order.contains(.hold), sleep: SimulatedCallSystem.sleepUntilCancelled)
        await h.placeCall()
        if !order.contains(.connect) { h.engine.handle(.connected) }
        await h.engine.setMuted(!unmuted)
        var failure = await drive(h, through: order, shouldResume: shouldResume, startsMuted: !unmuted)
        if failure == nil { failure = await checkWayOut(h, after: order) }
        await h.engine.endCall()
        return failure
    }

    /// Whatever the order left, the call is never stuck: once it is not held and
    /// CallKit hands its audio back (as it does after a resume, which the user's
    /// hold control or the engine's own re-request provokes), the mic is open and
    /// nothing reports an interruption, whether or not the interruption's end ever
    /// arrived; only a withhold the order leaves in place keeps it closed. Every
    /// order unmutes and connects.
    private static func checkWayOut(_ h: CallEngineHarness, after order: [MicEvent]) async -> String? {
        if h.engine.isOnHold { h.provider.simulateSetHeld(h.callID, onHold: false) }
        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingActivation()
        await h.engine.awaitPendingMediaWork()
        if h.engine.isInterrupted { return "\(order) way out: still interrupted after CallKit handed the audio back" }
        if !h.transport.isAudioAttached { return "\(order) way out: media not attached" }
        if h.transport.isMicEnabled == h.engine.isMicWithheld {
            return "\(order) way out: mic \(h.transport.isMicEnabled) with the withhold \(h.engine.isMicWithheld)"
        }
        return nil
    }

    private static func drive(
        _ h: CallEngineHarness,
        through order: [MicEvent],
        shouldResume: Bool,
        startsMuted: Bool
    ) async -> String? {
        var model = MicRuleModel(shouldResume: shouldResume)
        model.isConnected = !order.contains(.connect)
        model.isMuted = startsMuted

        for (step, event) in order.enumerated() {
            switch event {
            case .activate:
                h.provider.simulateActivate(FakeAudioSession())
                await h.engine.awaitPendingActivation()
            case .deactivate:
                h.provider.simulateDeactivate(FakeAudioSession())
            case .interrupt:
                h.interruption.simulateBegan()
            case .endInterruption:
                h.interruption.simulateEnded(shouldResume: shouldResume)
            case .unmute:
                await h.engine.setMuted(false)
            case .hold:
                h.provider.simulateSetHeld(h.callID, onHold: true)
            case .unhold:
                h.provider.simulateSetHeld(h.callID, onHold: false)
            case .connect:
                h.engine.handle(.connected)
            case .withhold:
                h.engine.setMicWithheld(true)
            case .release:
                h.engine.setMicWithheld(false)
            }
            await h.engine.awaitPendingMediaWork()
            model.apply(event)

            let mic = h.transport.isMicEnabled
            let where_ = "\(order) step \(step) (\(event))"
            if mic && !h.engine.isAudioActivated { return "\(where_): mic on before activation" }
            if mic && h.engine.state.isConnecting { return "\(where_): mic on before the call connected" }
            if mic && h.engine.isOnHold { return "\(where_): mic on while held" }
            if mic && h.engine.isInterrupted { return "\(where_): mic on while interrupted" }
            if mic && h.engine.isMicWithheld { return "\(where_): mic on while withheld" }
            if h.transport.isAudioAttached != model.isAttached {
                return "\(where_): attached \(h.transport.isAudioAttached), rule says \(model.isAttached)"
            }
            if mic != model.micIsOn { return "\(where_): mic \(mic), rule says \(model.micIsOn)" }
            if h.engine.isInterrupted != model.isInterrupted {
                return "\(where_): isInterrupted \(h.engine.isInterrupted), rule says \(model.isInterrupted)"
            }
            if h.engine.isOnHold != model.isHeld {
                return "\(where_): isOnHold \(h.engine.isOnHold), rule says \(model.isHeld)"
            }
            if h.engine.isMicWithheld != model.isWithheld {
                return "\(where_): isMicWithheld \(h.engine.isMicWithheld), rule says \(model.isWithheld)"
            }
            if h.engine.isTimerRunning(.micWithholdTimeout) != model.isWithholdBoundRunning {
                return "\(where_): withhold bound running \(!model.isWithholdBoundRunning), rule says \(model.isWithholdBoundRunning)"
            }
            // A withhold is not mute, in the engine or in CallKit.
            if h.engine.isMuted != model.isMuted || h.provider.muteStates[h.callID] != model.isMuted {
                return "\(where_): muted \(h.engine.isMuted) / CallKit \(String(describing: h.provider.muteStates[h.callID])), rule says \(model.isMuted)"
            }
        }
        return nil
    }

    /// Every order of `events` in which an interruption ends after it begins and a
    /// hold is released after it is placed.
    static func orders(of events: [MicEvent]) -> [[MicEvent]] {
        permutations(of: events).filter { order in
            func isBefore(_ first: MicEvent, _ second: MicEvent) -> Bool {
                guard let a = order.firstIndex(of: first), let b = order.firstIndex(of: second) else { return true }
                return a < b
            }
            return isBefore(.interrupt, .endInterruption) && isBefore(.hold, .unhold)
        }
    }

    static func runEveryOrder(of events: [MicEvent], shouldResume: Bool, unmuted: Bool = false) async throws {
        let orders = orders(of: events)
        try #require(!orders.isEmpty)
        var failures: [String] = []
        for order in orders {
            if let failure = await run(order, shouldResume: shouldResume, unmuted: unmuted) { failures.append(failure) }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(orders.count) orders failed; first: \(failures.prefix(3))")
    }

    private static func permutations(of items: [MicEvent]) -> [[MicEvent]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[MicEvent]] in
            var rest = items
            let first = rest.remove(at: index)
            return permutations(of: rest).map { [first] + $0 }
        }
    }
}
