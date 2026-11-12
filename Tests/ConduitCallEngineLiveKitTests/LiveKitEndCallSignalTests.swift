//
//  LiveKitEndCallSignalTests.swift
//  ConduitCallEngineLiveKitTests
//
//  When LiveKitTransport's disconnect sends the end-call signal: whenever the room
//  is not already leaving, including while it is still connecting or reconnecting.
//

import Testing
@testable import ConduitCallEngineLiveKit

struct LiveKitEndCallSignalTests {
    /// A host that disconnects while its connect is still in flight, or during an SDK
    /// reconnect, has a remote side that may already see it; skipping the signal
    /// there leaves the agent waiting out its grace window.
    @Test(arguments: [LiveKitEndCallSignal.RoomPhase.connecting, .reconnecting, .connected])
    func theSignalIsSentWhileTheRoomIsUpOrComingUp(phase: LiveKitEndCallSignal.RoomPhase) {
        #expect(LiveKitEndCallSignal.shouldSend(in: phase))
    }

    @Test(arguments: [LiveKitEndCallSignal.RoomPhase.disconnecting, .disconnected])
    func theSignalIsNotSentOnceTheRoomIsLeaving(phase: LiveKitEndCallSignal.RoomPhase) {
        #expect(LiveKitEndCallSignal.shouldSend(in: phase) == false)
    }
}

struct LiveKitEndCallSignalDeadlineTests {
    @Test func aSendThatFinishesInTimeIsAwaited() async {
        let sent = SentFlag()

        await LiveKitEndCallSignal.run(within: .seconds(10)) { await sent.set() }

        #expect(await sent.value)
    }

    /// A send held by LiveKit (a reconnecting room, a channel that never opens) must
    /// not hold up the hangup past the deadline, even if it ignores cancellation.
    @Test(.timeLimit(.minutes(1)))
    func aSendThatNeverFinishesIsAbandonedAtTheDeadline() async {
        let clock = ContinuousClock()
        let start = clock.now

        await LiveKitEndCallSignal.run(within: .milliseconds(100)) {
            let end = clock.now + .seconds(5)
            while clock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
        }

        #expect(clock.now - start < .seconds(3))
    }

    private actor SentFlag {
        private(set) var value = false
        func set() { value = true }
    }
}
