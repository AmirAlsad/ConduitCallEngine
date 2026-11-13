//
//  DailyInterruptionRecoveryTests.swift
//  ConduitCallEngineDailyTests
//
//  The experimental recoveries after a phone call (`DailyInterruptionRecovery`),
//  under the real engine: what each asks of Daily, in order, after the attach that
//  follows the interruption and before `call-resumed`. Whether any of them brings
//  the audio back is for a device to show.
//

import AVFoundation
import Foundation
import Testing
import ConduitCallEngine
import ConduitCallEngineTesting
@_spi(InterruptionRecoveryExperiment) @testable import ConduitCallEngineDaily

@MainActor
struct DailyInterruptionRecoveryTests {

    /// A connected call, its agent ready, with `recovery` chosen.
    private func connectedCall(_ recovery: DailyInterruptionRecovery) async throws -> (DailyEngineRig, UUID, FakePipecatTransport) {
        let rig = DailyEngineRig()
        rig.recordsMic = true
        rig.interruptionRecovery = recovery
        rig.outputPort = .builtInReceiver
        let id = try await rig.placeActivatedCall()
        let pipecat = try #require(rig.pipecat)
        pipecat.botJoins()
        await waitUntil { rig.engine.state.isConnected }
        rig.sleeper.wakeAll() // the first connect's bound, stale once connected
        await drain()
        return (rig, id, pipecat)
    }

    /// iOS holds the call for a phone call, the interruption begins and CallKit
    /// deactivates the session; the phone call ends, the engine resumes the call
    /// and CallKit activates the session again.
    private func phoneCall(_ rig: DailyEngineRig, _ id: UUID) async {
        await rig.system.setHeldFromSystem(id, onHold: true)
        rig.system.beginAudioInterruption()
        rig.system.deactivateAudioSession()
        await drain()
        await rig.system.setHeldFromSystem(id, onHold: false)
        await rig.system.activateAudioSession()
        await drain()
    }

    private func signals(_ pipecat: FakePipecatTransport) -> [String] {
        pipecat.sentMessages.compactMap {
            let message = try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            return (message?["data"] as? [String: Any])?["t"] as? String
        }
    }

    /// The calls Daily got from `start` on.
    private func callsSinceResume(_ pipecat: FakePipecatTransport, from start: Int) -> [String] {
        Array(pipecat.calls[start...])
    }

    @Test(.timeLimit(.minutes(1)))
    func offAsksNothingMoreOfDaily() async throws {
        let (rig, id, pipecat) = try await connectedCall(.off)
        await rig.system.setHeldFromSystem(id, onHold: true)
        rig.system.beginAudioInterruption()
        rig.system.deactivateAudioSession()
        await drain()
        let start = pipecat.calls.count

        await rig.system.setHeldFromSystem(id, onHold: false)
        await rig.system.activateAudioSession()
        await waitUntil { signals(pipecat).last == "call-resumed" }

        #expect(callsSinceResume(pipecat, from: start) == ["mic off", "agent audio subscribed", "mic on", "send client-message"])
        #expect(rig.transportPauses.filter { $0 < .seconds(1) }.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func restartMediaStopsCaptureAndPlayoutThenStartsThem() async throws {
        let (rig, id, pipecat) = try await connectedCall(.restartMedia)
        await rig.system.setHeldFromSystem(id, onHold: true)
        rig.system.beginAudioInterruption()
        rig.system.deactivateAudioSession()
        await drain()
        let start = pipecat.calls.count

        await rig.system.setHeldFromSystem(id, onHold: false)
        await rig.system.activateAudioSession()
        await waitUntil { signals(pipecat).last == "call-resumed" }

        #expect(callsSinceResume(pipecat, from: start) == [
            "mic off", // the resume, before CallKit activates the session
            "agent audio subscribed", "mic on", // the attach and the engine's mic
            "mic off", "agent audio unsubscribed", "agent audio subscribed", "mic on", // A
            "send client-message", // call-resumed
        ])
        #expect(rig.transportPauses.first == .milliseconds(500))
        #expect(pipecat.remoteAudio == .subscribed)
        #expect(pipecat.micHistory.last == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func restartMediaLeavesAMutedMicOff() async throws {
        let (rig, id, pipecat) = try await connectedCall(.restartMedia)
        await rig.engine.setMuted(true)
        await drain()
        await rig.system.setHeldFromSystem(id, onHold: true)
        rig.system.beginAudioInterruption()
        rig.system.deactivateAudioSession()
        await drain()
        let start = pipecat.calls.count

        await rig.system.setHeldFromSystem(id, onHold: false)
        await rig.system.activateAudioSession()
        await waitUntil { signals(pipecat).last == "call-resumed" }

        #expect(callsSinceResume(pipecat, from: start) == [
            "mic off", "agent audio subscribed", "mic off",
            "mic off", "agent audio unsubscribed", "agent audio subscribed",
            "send client-message",
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func reassertAudioDeviceGoesByAnotherDeviceThenResubscribes() async throws {
        let (rig, id, pipecat) = try await connectedCall(.reassertAudioDevice)
        await rig.system.setHeldFromSystem(id, onHold: true)
        rig.system.beginAudioInterruption()
        rig.system.deactivateAudioSession()
        await drain()
        let start = pipecat.calls.count

        await rig.system.setHeldFromSystem(id, onHold: false)
        await rig.system.activateAudioSession()
        await waitUntil { signals(pipecat).last == "call-resumed" }

        #expect(callsSinceResume(pipecat, from: start) == [
            "mic off", "agent audio subscribed", "mic on",
            "prefer speaker", "prefer earpiece", "agent audio unsubscribed", "agent audio subscribed", // B
            "send client-message",
        ])
        #expect(rig.controls.last?.preferredAudioRoute == .earpiece)
        #expect(pipecat.remoteAudio == .subscribed)
    }

    /// The call on the loudspeaker goes by the earpiece instead.
    @Test(.timeLimit(.minutes(1)))
    func reassertAudioDeviceOnTheSpeakerGoesByTheEarpiece() async throws {
        let (rig, id, pipecat) = try await connectedCall(.reassertAudioDevice)
        await rig.engine.selectAudioDevice("speakerphone")
        await drain()
        let start = pipecat.calls.count

        await phoneCall(rig, id)
        await waitUntil { signals(pipecat).last == "call-resumed" }

        #expect(pipecat.calls[start...].filter { $0.hasPrefix("prefer") } == ["prefer earpiece", "prefer speaker"])
        #expect(rig.controls.last?.preferredAudioRoute == .speaker)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejoinLeavesWithoutEndCallAndJoinsTheSameRoomOnANewClient() async throws {
        let (rig, id, first) = try await connectedCall(.rejoin)
        let joined = rig.pipecats.count

        await phoneCall(rig, id)
        await waitUntil { rig.pipecats.count == joined + 1 }
        let second = try #require(rig.pipecats.last)
        await waitUntil { signals(second).last == "call-resumed" }

        #expect(Array(first.calls.suffix(2)) == ["disconnect", "release"])
        #expect(!signals(first).contains("end-call"))
        #expect(second.calls.contains("agent audio subscribed"))
        #expect(second.calls.contains { $0.hasPrefix("connect") })
        #expect(second.calls.contains("mic on"))
        #expect(rig.requests.count == 1) // the same credentials, no new request
        #expect(rig.engine.state == .reconnecting(attempt: 0))

        second.botJoins()
        await waitUntil { signals(second).last == "call-connected" }

        #expect(rig.engine.state.isConnected)
        #expect(signals(second) == ["call-resumed", "call-connected"])
        #expect(rig.host.records.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRejoinThatFailsIsReportedAsADrop() async throws {
        let (rig, id, _) = try await connectedCall(.rejoin)
        let joined = rig.pipecats.count
        rig.failsJoins = true

        await phoneCall(rig, id)
        await waitUntil { rig.pipecats.count == joined + 1 && rig.engine.state == .reconnecting(attempt: 1) }

        #expect(rig.engine.state == .reconnecting(attempt: 1))
        #expect(rig.host.records.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHoldWithNoInterruptionRunsNoRecovery() async throws {
        let (rig, id, pipecat) = try await connectedCall(.restartMedia)
        await rig.system.setHeldFromSystem(id, onHold: true)
        rig.system.deactivateAudioSession()
        await drain()
        let start = pipecat.calls.count

        await rig.system.setHeldFromSystem(id, onHold: false)
        await rig.system.activateAudioSession()
        await waitUntil { signals(pipecat).last == "call-resumed" }

        #expect(callsSinceResume(pipecat, from: start) == ["mic off", "agent audio subscribed", "mic on", "send client-message"])
        #expect(rig.pipecats.count == 1)
    }
}
