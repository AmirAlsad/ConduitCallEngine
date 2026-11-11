//
//  PushRegistrationTests.swift
//  ConduitCallEngineTests
//
//  The engine's PushKit plumbing, driven through `FakeVoIPPushRegistry`: starting
//  registration once, handing token updates to the host, exposing the current
//  token, and routing pushes straight into the push entry.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct PushRegistrationTests {

    @Test func startPushRegistrationIsIdempotent() {
        let h = CallEngineHarness()
        h.engine.startPushRegistration()
        h.engine.startPushRegistration()

        #expect(h.pushRegistry.startCount == 1)
    }

    @Test func tokenUpdatesReachTheDelegate() {
        let h = CallEngineHarness()
        #expect(h.engine.voipPushToken == nil) // none until PushKit issues one
        h.engine.startPushRegistration()

        let token = Data([0xAB, 0x01, 0xFF])
        h.pushRegistry.simulateTokenUpdate(token)

        #expect(h.delegate.events == [.pushToken(token)])
        #expect(h.engine.voipPushToken == token)
    }

    @Test func incomingPushesGoStraightToThePushEntry() {
        let h = CallEngineHarness()
        h.engine.startPushRegistration()
        var completions = 0

        h.pushRegistry.simulateIncomingPush(
            ["target_id": h.target.id.uuidString, "call_id": UUID().uuidString]
        ) { completions += 1 }

        // Reported and ringing before the PushKit callback returned.
        #expect(h.provider.reportedIncoming.count == 1)
        #expect(h.engine.state == .incomingRinging)
        #expect(completions == 1)
    }
}
