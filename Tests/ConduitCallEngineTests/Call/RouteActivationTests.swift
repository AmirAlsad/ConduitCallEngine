//
//  RouteActivationTests.swift
//  ConduitCallEngineTests
//
//  Route work (reading the routes, the hands-free default, the user's choice)
//  waits for CallKit's activation on every call, as attach and the mic do: an
//  output-port override on a session that is not active yet is lost or misapplied,
//  and the default would count as applied.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct RouteActivationTests {
    enum Direction: String, CaseIterable, Sendable {
        case outgoing, answered
    }

    private func connectedBeforeActivation(_ h: CallEngineHarness, _ direction: Direction) async {
        switch direction {
        case .outgoing: await h.placeCall()
        case .answered:
            h.ring()
            await h.engine.answer()
        }
        h.engine.handle(.connected)
        h.engine.handle(.audioDevicesChanged)
        await settle()
    }

    @Test(arguments: Direction.allCases)
    func aCallConnectedBeforeActivationLeavesTheRouteAlone(direction: Direction) async throws {
        let h = CallEngineHarness()
        await connectedBeforeActivation(h, direction)

        #expect(h.transport.audioDeviceReadCount == 0)
        #expect(h.transport.audioDeviceSelections.isEmpty)
        #expect(h.engine.audioDevices.isEmpty)

        await h.engine.activate(FakeAudioSession())
        await settle()

        #expect(h.transport.audioDeviceSelections == ["speaker"]) // the hands-free default, applied now
        #expect(h.engine.audioDevices.isEmpty == false)
        #expect(h.engine.selectedAudioDeviceID == "speaker")
    }

    @Test func aRouteChoiceBeforeActivationIsIgnored() async throws {
        let h = CallEngineHarness()
        await h.placeCall()

        await h.engine.selectAudioDevice("receiver")

        #expect(h.transport.audioDeviceSelections.isEmpty)
        #expect(h.transport.audioDeviceReadCount == 0)
    }

    @Test func routeChangesWhileDeactivatedWaitForTheNextActivation() async throws {
        let h = CallEngineHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.activate(FakeAudioSession())
        await settle()
        h.engine.providerDidDeactivate(FakeAudioSession())
        let reads = h.transport.audioDeviceReadCount

        h.engine.handle(.audioDevicesChanged)
        await settle()
        #expect(h.transport.audioDeviceReadCount == reads)

        await h.engine.activate(FakeAudioSession())
        await settle()
        #expect(h.transport.audioDeviceReadCount > reads)
    }
}
