//
//  LiveKitEndCallSignalTests.swift
//  ConduitCallEngineLiveKitTests
//
//  How LiveKitTransport sends its RTVI client messages (the end-call signal and the
//  call-control signals): whenever the room is not already leaving, including while
//  it is still connecting or reconnecting, in the envelope a Pipecat bot parses.
//

import Foundation
import Testing
import ConduitCallEngine
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

    /// The bytes the reference bot's `_livekit_client_signal` parses: label, type and `data.t`.
    @Test(arguments: ["end-call"] + CallSignal.allCases.map(\.rawValue))
    func thePayloadIsTheRTVIClientMessageEnvelope(type: String) throws {
        let payload = try #require(LiveKitEndCallSignal.payload(type: type, id: "abcd1234"))

        let message = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(message["id"] as? String == "abcd1234")
        #expect(message["label"] as? String == "rtvi-ai")
        #expect(message["type"] as? String == "client-message")
        #expect(message["data"] as? [String: String] == ["t": type])
    }

    @Test func eachPayloadGetsAFreshEightCharacterID() throws {
        let first = try #require(LiveKitEndCallSignal.payload(type: "call-held"))
        let second = try #require(LiveKitEndCallSignal.payload(type: "call-held"))

        let ids = try [first, second].map {
            try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any])["id"] as? String
        }
        #expect(ids.allSatisfy { $0?.count == 8 })
        #expect(ids[0] != ids[1])
    }
}

struct LiveKitEndCallSignalDeadlineTests {
    @Test func aSendThatFinishesInTimeIsAwaited() async {
        let sent = SentFlag()

        let finished = await LiveKitEndCallSignal.run(within: .seconds(10)) { await sent.set() }

        #expect(await sent.value)
        #expect(finished)
    }

    /// A send held by LiveKit (a reconnecting room, a channel that never opens) must
    /// not hold up the hangup past the deadline, even if it ignores cancellation.
    @Test(.timeLimit(.minutes(1)))
    func aSendThatNeverFinishesIsAbandonedAtTheDeadline() async {
        let clock = ContinuousClock()
        let start = clock.now
        let gate = Gate()

        let finished = await LiveKitEndCallSignal.run(within: .milliseconds(100)) {
            await gate.wait()
        }

        #expect(clock.now - start < .seconds(3))
        #expect(finished == false)
        await gate.open()
    }

    /// Suspends its waiters, ignoring cancellation, until `open()`.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private actor SentFlag {
        private(set) var value = false
        func set() { value = true }
    }
}
