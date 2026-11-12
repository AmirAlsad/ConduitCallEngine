//
//  DailyRemoteAudioGateTests.swift
//  ConduitCallEngineDailyTests
//
//  When a Daily call's agent audio is unsubscribed and subscribed again: a detach
//  after an attach silences it, the next attach restores it, a call never detached is
//  left alone, a join while ringing holds it back until the first attach, and changes
//  are applied one at a time toward the latest wanted state.
//

import Testing
@testable import ConduitCallEngineDaily

struct DailyRemoteAudioGateTests {
    @Test func aCallThatIsNeverDetachedIsLeftAlone() {
        var gate = DailyRemoteAudioGate()
        gate.attach()
        gate.attach()

        let next = gate.beginApplying()
        #expect(gate.wanted == nil)
        #expect(next == nil)
    }

    /// The engine can detach before CallKit ever activated the session (a call torn
    /// down while dialing); nothing has played, so nothing changes.
    @Test func aDetachBeforeAnyAttachIsLeftAlone() {
        var gate = DailyRemoteAudioGate()
        gate.detach()

        #expect(gate.wanted == nil)
    }

    @Test func aDetachAfterAnAttachUnsubscribesAndTheNextAttachSubscribes() {
        var gate = DailyRemoteAudioGate()
        gate.attach()

        gate.detach()
        #expect(gate.wanted == .unsubscribed)

        gate.attach()
        #expect(gate.wanted == .subscribed)
    }

    @Test func aJoinWhileRingingHoldsTheAgentBackUntilTheFirstAttach() {
        var gate = DailyRemoteAudioGate()
        gate.holdAgentBackUntilFirstAttach()
        #expect(gate.wanted == .unsubscribed)
        #expect(gate.holdsAgentBack)

        gate.detach()
        #expect(gate.wanted == .unsubscribed)
        #expect(gate.holdsAgentBack)

        gate.attach()
        #expect(gate.wanted == .subscribed)
        #expect(!gate.holdsAgentBack)

        gate.detach()
        #expect(gate.wanted == .unsubscribed)
    }

    /// Once attached, the call is under way: a hold-back asked for later changes
    /// nothing, so the call keeps Daily's default subscription.
    @Test func aHoldBackAfterAnAttachChangesNothing() {
        var gate = DailyRemoteAudioGate()
        gate.attach()

        gate.holdAgentBackUntilFirstAttach()

        #expect(gate.wanted == nil)
        #expect(!gate.holdsAgentBack)
    }

    // `beginApplying()` mutates, which `#expect` and `#require` cannot evaluate, so
    // its result is taken first.

    @Test func oneChangeIsAppliedAtATime() throws {
        var gate = heldGate()
        let firstResult = gate.beginApplying()
        let first = try #require(firstResult)
        gate.attach()

        let whileApplying = gate.beginApplying()
        gate.applyDidSucceed(first)
        let afterwards = gate.beginApplying()

        #expect(whileApplying == nil)
        #expect(afterwards?.state == .subscribed)
    }

    @Test func anAppliedStateIsNotAppliedAgain() throws {
        var gate = heldGate()
        let applicationResult = gate.beginApplying()
        let application = try #require(applicationResult)

        gate.applyDidSucceed(application)
        let next = gate.beginApplying()

        #expect(gate.applied == .unsubscribed)
        #expect(next == nil)
    }

    @Test func aRefusedChangeWaitsForTheJoin() throws {
        var gate = heldGate()
        let applicationResult = gate.beginApplying()
        let application = try #require(applicationResult)

        gate.applyDidFail(application)
        let beforeTheJoin = gate.beginApplying()
        gate.joinDidComplete()
        let onceJoined = gate.beginApplying()

        #expect(beforeTheJoin == nil)
        #expect(onceJoined?.state == .unsubscribed)
    }

    @Test func aRefusedChangeIsTriedAgainAfterTheNextEdge() throws {
        var gate = heldGate()
        let applicationResult = gate.beginApplying()
        let application = try #require(applicationResult)
        gate.applyDidFail(application)

        gate.detach()
        let next = gate.beginApplying()

        #expect(next?.state == .unsubscribed)
    }

    /// A new session (a rejoin, or the client released) has none of the old one's
    /// subscription, and the old session's application completing changes nothing.
    @Test func aNewSessionAppliesAgainAndIgnoresTheOldSessionsResult() throws {
        var gate = heldGate()
        let oldResult = gate.beginApplying()
        let old = try #require(oldResult)

        gate.sessionDidReset()
        let currentResult = gate.beginApplying()
        let current = try #require(currentResult)
        gate.applyDidSucceed(old)

        #expect(current.state == .unsubscribed)
        #expect(gate.applied == nil)
        #expect(gate.isApplying)
        gate.applyDidSucceed(current)
        #expect(gate.applied == .unsubscribed)
    }

    /// A call attached and then detached, as by a hold.
    private func heldGate() -> DailyRemoteAudioGate {
        var gate = DailyRemoteAudioGate()
        gate.attach()
        gate.detach()
        return gate
    }
}
