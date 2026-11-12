//
//  DailyRemoteAudioGateTests.swift
//  ConduitCallEngineDailyTests
//
//  When a Daily call's agent audio is unsubscribed and subscribed again: a detach
//  after an attach silences it, the next attach restores it, a call never detached is
//  left alone, and changes are applied one at a time toward the latest wanted state.
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

    @Test(arguments: [DailyRemoteAudio.unsubscribed, .staged])
    func aHeldBackStartIsKeptUntilTheFirstAttach(until: DailyRemoteAudio) {
        var gate = DailyRemoteAudioGate(untilFirstAttach: until)
        #expect(gate.wanted == until)

        gate.detach()
        #expect(gate.wanted == until)

        gate.attach()
        #expect(gate.wanted == .subscribed)

        gate.detach()
        #expect(gate.wanted == .unsubscribed)
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
