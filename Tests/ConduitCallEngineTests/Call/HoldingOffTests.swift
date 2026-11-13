//
//  HoldingOffTests.swift
//  ConduitCallEngineTests
//
//  Holding off (`CallEngineConfiguration.supportsHolding`, the default): as in 0.1,
//  calls are reported as not holdable, every hold action is refused and changes
//  nothing, other calls on the device are ignored, and a phone call the user
//  accepts ends the call: iOS ends it, and the engine tears down as for any end,
//  sends the end-call signal (the transport's disconnect) and records it once.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct HoldingOffTests {

    /// Placed, connected and activated: the mic is live and media attached.
    private func liveCall(_ h: CallEngineHarness) async {
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.activate(FakeAudioSession())
        await h.engine.awaitPendingWork()
    }

    @Test func holdingIsOffByDefault() {
        #expect(!CallEngineConfiguration().supportsHolding)
    }

    @Test func callsAreReportedAsNotHoldable() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        let ringID = UUID()
        h.ring(callID: ringID) // busy: reported and ended

        #expect(h.provider.supportsHolding == false)
        #expect(h.provider.holdableCalls[h.callID] == false)
        #expect(h.provider.holdableCalls[ringID] == false)
    }

    @Test(arguments: [true, false])
    func aSystemHoldActionIsRefusedAndChangesNothing(onHold: Bool) async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        let commands = h.transport.commands
        let cues = h.delegate.cues

        let performed = h.provider.simulateSetHeld(h.callID, onHold: onHold)
        await h.engine.awaitPendingWork()

        #expect(!performed)
        #expect(!h.engine.isOnHold)
        #expect(h.engine.state.isConnected)
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.isAudioAttached)
        #expect(h.transport.commands == commands)
        #expect(h.transport.sentSignals == [.connected])
        #expect(h.delegate.cues == cues)
        #expect(!h.engine.isTimerRunning(.activationRecovery))
    }

    @Test func theHostsHoldAsksCallKitNothing() async throws {
        let h = CallEngineHarness()
        await liveCall(h)

        await h.engine.setOnHold(true)
        await h.engine.setOnHold(false)

        #expect(h.provider.heldRequests.isEmpty)
        #expect(!h.engine.isOnHold)
        #expect(h.transport.isMicEnabled)
    }

    /// The sequence of a phone call the user accepts with End & Accept: it rings
    /// (the call observer sees it), the audio interruption begins, iOS ends the
    /// engine's call through CallKit and deactivates its session; later the phone
    /// call ends.
    @Test func aPhoneCallTheUserAcceptsEndsTheCallOnce() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        let transport = h.transport

        let phoneCall = h.provider.simulateOtherCallStarted()
        h.interruption.simulateBegan()
        #expect(!h.provider.simulateSetHeld(h.callID, onHold: true)) // refused, should iOS ask
        h.provider.simulateEndCall(h.callID)
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingWork()
        h.provider.simulateOtherCallEnded(phoneCall)
        await h.engine.awaitPendingWork()

        #expect(h.engine.state == .ended(.completed))
        #expect(transport.disconnectCount == 1)
        #expect(!transport.isAudioAttached)
        #expect(transport.sentSignals == [.connected])
        #expect(h.delegate.records.map(\.outcome) == [.completed])
        #expect(h.provider.heldRequests.isEmpty)
        #expect(!h.engine.isOnHold)
        #expect(!h.delegate.cues.contains(.moment(.held)))
        #expect(!h.engine.isTimerRunning(.activationRecovery))
        #expect(h.delegate.cueViolations.isEmpty)

        h.engine.reset()
        #expect(h.engine.state == .idle)
    }

    /// Other calls starting and ending during a call do nothing to it.
    @Test func otherCallsOnTheDeviceAreIgnored() async throws {
        let h = CallEngineHarness()
        await liveCall(h)
        let commands = h.transport.commands

        let other = h.provider.simulateOtherCallStarted()
        h.provider.simulateOtherCallHeld(other, onHold: true)
        h.provider.simulateOtherCallEnded(other)
        await h.engine.awaitPendingWork()

        #expect(h.provider.heldRequests.isEmpty)
        #expect(h.transport.commands == commands)
        #expect(h.engine.state.isConnected)
        #expect(!h.engine.isTimerRunning(.activationRecovery))
    }

    /// An interruption that CallKit answers with a deactivation and an activation,
    /// with no hold, pauses the mic and opens it again, as in 0.1.
    @Test func anInterruptionWithoutAHoldPausesAndResumesTheMic() async throws {
        let h = CallEngineHarness()
        await liveCall(h)

        h.interruption.simulateBegan()
        h.provider.simulateDeactivate(FakeAudioSession())
        await h.engine.awaitPendingWork()
        #expect(!h.transport.isMicEnabled)
        #expect(!h.transport.isAudioAttached)

        h.provider.simulateActivate(FakeAudioSession())
        await h.engine.awaitPendingWork()

        #expect(h.transport.isMicEnabled)
        #expect(h.transport.isAudioAttached)
        #expect(h.transport.sentSignals == [.connected])
        #expect(!h.engine.isOnHold)
        #expect(h.engine.state.isConnected)
    }
}
