//
//  MicRuleTests.swift
//  ConduitCallEngineTests
//
//  The one mic rule: the transport's mic is on only while CallKit has activated
//  the session, the call is not on hold, no interruption holds it, and the user
//  wants it on (unmuted, or in push-to-talk mode the button held). Every input re-derives the mic from
//  that rule, so the order the inputs arrive in never matters; the permutation
//  test drives every order against a reference model of the rule.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct MicRuleTests {

    /// Placed, connected and activated: the mic is live.
    private func liveCall() async -> CallEngineHarness {
        let h = CallEngineHarness()
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
        await activate(h) // CallKit hands the session back while still interrupted
        await h.engine.awaitPendingMediaWork()
        #expect(!h.transport.isMicEnabled)

        h.interruption.simulateEnded(shouldResume: false)
        await h.engine.awaitPendingMediaWork()

        #expect(!h.engine.isInterrupted)
        #expect(!h.engine.isMuted)
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
}

/// An input to the mic rule, as the system or the user delivers it.
enum MicEvent: String, CustomStringConvertible, Sendable {
    case activate, deactivate, interrupt, endInterruption, unmute, hold, unhold

    var description: String { rawValue }
}

/// The documented rule, as a reference the engine is checked against.
struct MicRuleModel {
    enum Interruption: Equatable { case none, interrupted(reactivated: Bool), awaitingActivation }

    let shouldResume: Bool
    var isActivated = false
    var isMuted = true
    var isHeld = false
    var interruption = Interruption.none

    var isInterrupted: Bool { interruption != .none }
    /// Media runs on a session CallKit activated, and not while held.
    var isAttached: Bool { isActivated && !isHeld }
    var micIsOn: Bool { isActivated && !isHeld && !isInterrupted && !isMuted }

    mutating func apply(_ event: MicEvent) {
        switch event {
        case .activate:
            isActivated = true
            switch interruption {
            case .interrupted: interruption = .interrupted(reactivated: true)
            case .awaitingActivation: interruption = .none
            case .none: break
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
        }
    }
}

@MainActor
enum MicRuleScenario {
    /// Drive one connected, muted call through `order` and compare the mic with
    /// the model after every step. Returns a description of the first mismatch.
    static func run(_ order: [MicEvent], shouldResume: Bool) async -> String? {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.setMuted(true)
        var model = MicRuleModel(shouldResume: shouldResume)

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
            }
            await h.engine.awaitPendingMediaWork()
            model.apply(event)

            let mic = h.transport.isMicEnabled
            let where_ = "\(order) step \(step) (\(event))"
            if mic && !h.engine.isAudioActivated { return "\(where_): mic on before activation" }
            if mic && h.engine.isOnHold { return "\(where_): mic on while held" }
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

    static func runEveryOrder(of events: [MicEvent], shouldResume: Bool) async throws {
        let orders = orders(of: events)
        try #require(!orders.isEmpty)
        var failures: [String] = []
        for order in orders {
            if let failure = await run(order, shouldResume: shouldResume) { failures.append(failure) }
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
