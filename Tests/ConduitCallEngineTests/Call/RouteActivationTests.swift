//
//  RouteActivationTests.swift
//  ConduitCallEngineTests
//
//  Route work (reading the routes, the speaker default when the host asks for it,
//  the user's choice) waits for CallKit's activation on every call, as attach and
//  the mic do: an output-port override on a session that is not active yet is lost
//  or misapplied, and the default would count as applied. With the speaker default
//  off (the default), the engine changes no route at all: the call starts where
//  iOS puts it (the earpiece), and only the user moves it.
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
        let h = CallEngineHarness(defaultsToSpeaker: true)
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

/// The speaker default off, as the package ships it: the engine selects no route of
/// its own on any path, and the user's choice works and stays as before.
@MainActor
struct NoSpeakerDefaultTests {
    /// A transport that starts on the earpiece, as a CallKit call with nothing
    /// connected does.
    private func earpieceHarness() async -> CallEngineHarness {
        let h = CallEngineHarness()
        await h.transport.setAudioDevice("receiver")
        return h
    }

    private func liveCall(_ h: CallEngineHarness) async {
        await h.placeCall()
        h.engine.handle(.connected)
        await h.engine.activate(FakeAudioSession())
        await h.engine.awaitPendingWork()
    }

    @Test func aCallStartsAndStaysOnTheEarpieceThroughConnectAndRouteChanges() async throws {
        let h = await earpieceHarness()
        await h.placeCall()
        await h.engine.activate(FakeAudioSession()) // connecting, ringback playing
        await h.engine.awaitPendingWork()
        h.engine.handle(.connected)
        h.engine.handle(.audioDevicesChanged)
        await h.engine.awaitPendingWork()

        #expect(h.transport.audioDeviceSelections == ["receiver"]) // only the test's own
        #expect(h.transport.selectedAudioDeviceID == "receiver")
        #expect(h.engine.selectedAudioDeviceID == "receiver")
        #expect(h.engine.audioDevices.map(\.id).contains("speaker")) // the picker still lists it
    }

    @Test func anAnsweredCallChangesNoRouteEither() async throws {
        let h = await earpieceHarness()
        h.ring()
        await h.engine.answer()
        await h.engine.activate(FakeAudioSession())
        h.engine.handle(.connected)
        await h.engine.awaitPendingWork()

        #expect(h.transport.audioDeviceSelections == ["receiver"])
    }

    @Test func reconnectsHoldsAndReactivationsChangeNoRoute() async throws {
        let h = await earpieceHarness()
        await liveCall(h)
        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()
        h.engine.handle(.connected)
        h.provider.simulateSetHeld(h.callID, onHold: true)
        h.provider.simulateDeactivate(FakeAudioSession())
        h.provider.simulateSetHeld(h.callID, onHold: false)
        await h.engine.activate(FakeAudioSession())
        await h.engine.awaitPendingWork()

        #expect(h.transport.audioDeviceSelections == ["receiver"])
    }

    /// Switching to the speaker mid-call sticks: nothing the engine does afterwards
    /// moves it back.
    @Test func theSpeakerTheUserPicksSticksThroughReconnectsAndHolds() async throws {
        let h = await earpieceHarness()
        await liveCall(h)

        await h.engine.selectAudioDevice("speaker")
        #expect(h.transport.selectedAudioDeviceID == "speaker")
        #expect(h.engine.selectedAudioDeviceID == "speaker")

        h.engine.handle(.reconnecting)
        h.engine.handle(.connected)
        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()
        h.engine.handle(.connected)
        h.provider.simulateSetHeld(h.callID, onHold: true)
        h.provider.simulateSetHeld(h.callID, onHold: false)
        h.engine.handle(.audioDevicesChanged)
        await h.engine.awaitPendingWork()

        #expect(h.transport.audioDeviceSelections == ["receiver", "speaker"])
        #expect(h.transport.selectedAudioDeviceID == "speaker")
    }

    @Test func anExternalRouteIsLeftAloneAsBefore() async throws {
        let h = CallEngineHarness()
        h.transport.fakeAudioDevices = [
            AudioDeviceInfo(id: "bluetooth", name: "AirPods"),
            AudioDeviceInfo(id: "speaker", name: "Speaker"),
            AudioDeviceInfo(id: "receiver", name: "Receiver"),
        ]
        await h.transport.setAudioDevice("bluetooth")
        await liveCall(h)

        #expect(h.transport.audioDeviceSelections == ["bluetooth"])
        #expect(h.engine.selectedAudioDeviceID == "bluetooth")
    }
}
