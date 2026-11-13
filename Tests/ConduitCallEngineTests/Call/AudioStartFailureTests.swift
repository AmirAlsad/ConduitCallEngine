//
//  AudioStartFailureTests.swift
//  ConduitCallEngineTests
//
//  A transport whose audio did not start at an attach (`audioStartFailure()`):
//  the engine attaches it again a few times while the call stays activated and not
//  held, and tells the agent the user is back only once the audio started or the
//  attempts are spent.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct AudioStartFailureTests {

    private func liveCall(_ h: CallEngineHarness) async {
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.activate(FakeAudioSession())
        await h.engine.awaitPendingWork()
    }

    /// Held, deactivated and activated again while held: the resume attaches.
    private func heldWithTheAudioHandedBack(_ h: CallEngineHarness) async {
        _ = h.provider.simulateSetHeld(h.callID, onHold: true)
        h.provider.simulateDeactivate(FakeAudioSession())
        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingWork()
    }

    private func resume(_ h: CallEngineHarness) {
        _ = h.provider.simulateSetHeld(h.callID, onHold: false)
    }

    @Test(.timeLimit(.minutes(1))) func aStartThatFailsIsAttachedAgainBeforeTheResumeIsSent() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(supportsHolding: true, sleep: { await sleeper.sleep($0) })
        await liveCall(h)
        await heldWithTheAudioHandedBack(h)
        h.transport.failingAttaches = 1

        resume(h)
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requested.last == CallEngine.audioStartRetryDelays[0])
        #expect(h.transport.sentSignals == [.connected, .held])

        sleeper.wakeAll()
        await h.engine.awaitPendingWork()

        #expect(Array(h.transport.commands.suffix(4)) == [.attach, .mic(true), .attach, .send(.resumed)])
        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
    }

    @Test(.timeLimit(.minutes(1))) func theAgentIsToldOnceTheAttemptsAreSpent() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(supportsHolding: true, sleep: { await sleeper.sleep($0) })
        await liveCall(h)
        await heldWithTheAudioHandedBack(h)
        h.transport.failingAttaches = 100
        let attaches = h.transport.commands.filter { $0 == .attach }.count

        resume(h)
        for _ in CallEngine.audioStartRetryDelays {
            await waitUntil { sleeper.pendingCount == 1 }
            #expect(h.transport.sentSignals == [.connected, .held])
            sleeper.wakeAll()
        }
        await h.engine.awaitPendingWork()

        #expect(sleeper.requested.suffix(3) == CallEngine.audioStartRetryDelays[...])
        #expect(h.transport.commands.filter { $0 == .attach }.count == attaches + 1 + CallEngine.audioStartRetryDelays.count)
        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
    }

    @Test(.timeLimit(.minutes(1))) func aHoldDuringTheWaitEndsTheAttempts() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(supportsHolding: true, sleep: { await sleeper.sleep($0) })
        await liveCall(h)
        await heldWithTheAudioHandedBack(h)
        h.transport.failingAttaches = 100
        resume(h)
        await waitUntil { sleeper.pendingCount == 1 }
        let attaches = h.transport.commands.filter { $0 == .attach }.count

        _ = h.provider.simulateSetHeld(h.callID, onHold: true)
        sleeper.wakeAll()
        await h.engine.awaitPendingWork()

        #expect(h.transport.commands.filter { $0 == .attach }.count == attaches)
        #expect(h.transport.commands.last { $0 == .attach || $0 == .detach } == .detach)
        #expect(sleeper.pendingCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func theFirstAttachOfACallIsConfirmedToo() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(sleep: { await sleeper.sleep($0) })
        h.transport.failingAttaches = 1
        await h.placeCall()
        h.engine.handle(.connected)

        let activation = Task { await h.engine.activate(FakeAudioSession()) }
        await waitUntil { sleeper.pendingCount == 1 }
        #expect(!h.transport.sentSignals.contains(.connected))
        sleeper.wakeAll()
        await activation.value
        await h.engine.awaitPendingWork()

        #expect(h.transport.commands.filter { $0 == .attach }.count == 2)
        #expect(h.transport.sentSignals == [.connected])
    }

    @Test(.timeLimit(.minutes(1))) func anAttachThatStartsAsksForNoRetry() async throws {
        let sleeper = ManualSleeper()
        let h = CallEngineHarness(supportsHolding: true, sleep: { await sleeper.sleep($0) })
        await liveCall(h)
        await heldWithTheAudioHandedBack(h)

        resume(h)
        await h.engine.awaitPendingWork()

        #expect(sleeper.requested.isEmpty)
        #expect(h.transport.sentSignals == [.connected, .held, .resumed])
    }
}
