//
//  LiveKitEngineRig.swift
//  ConduitCallEngineLiveKitTests
//
//  The real `LiveKitTransport`, over a `FakeLiveKitRoom` that sequences its work as
//  LiveKit's `Room` does, driven by a real `CallEngine` over a `SimulatedCallSystem`.
//

import Foundation
import ConduitCallEngine
import ConduitCallEngineTesting
@testable import ConduitCallEngineLiveKit

@MainActor
final class HandSleeper {
    private(set) var requested: [Duration] = []
    private var pending: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int { pending.count }

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { pending.append($0) }
    }

    func wakeAll() {
        let waiting = pending
        pending = []
        waiting.forEach { $0.resume() }
    }
}

@MainActor
final class RecordingHost: CallEngineDelegate {
    private(set) var transitions: [CallState] = []
    private(set) var records: [CallRecord] = []
    private(set) var cues: [CallCue] = []
    var target: CallTarget?

    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? { target }
    func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState) { transitions.append(new) }
    func callEngine(_ engine: CallEngine, didFinish record: CallRecord) { records.append(record) }
    func callEngine(_ engine: CallEngine, cue: CallCue) { cues.append(cue) }
}

@MainActor
final class LiveKitEngineRig {
    let system = SimulatedCallSystem()
    let sleeper = HandSleeper()
    let host = RecordingHost()
    let engine: CallEngine
    let targetID = UUID()
    /// Configures each room as the transport creates it.
    var prepareRoom: (FakeLiveKitRoom) -> Void = { _ in }
    var ringPreparation: RingPreparation = .none

    private(set) var rooms: [FakeLiveKitRoom] = []
    private(set) var audioEngines: [FakeLiveKitAudioEngine] = []
    private(set) var requests: [ConnectRequest] = []

    init(joinTimeout: Duration? = .seconds(30), ringTimeout: Duration? = nil, minimumConnecting: Duration = .zero) {
        let sleeper = sleeper
        engine = CallEngine.simulated(
            configuration: CallEngineConfiguration(
                ringTimeout: ringTimeout,
                joinTimeout: joinTimeout,
                minimumConnectingDuration: minimumConnecting
            ),
            system: system,
            sleep: { await sleeper.sleep($0) }
        )
        engine.delegate = host
        refreshTarget()
    }

    /// Hand the host the target as configured now (after changing `ringPreparation`).
    func refreshTarget() {
        host.target = target
    }

    var target: CallTarget {
        CallTarget(
            id: targetID,
            displayName: "Agent",
            handle: nil,
            ringPreparation: ringPreparation,
            makeTransport: { [unowned self] in
                LiveKitTransport(
                    makeRoom: { [unowned self] mapper in
                        let room = FakeLiveKitRoom()
                        room.events = mapper
                        self.prepareRoom(room)
                        self.rooms.append(room)
                        return room
                    },
                    audioEngine: makeAudioEngine()
                )
            },
            connect: { [unowned self] request in
                requests.append(request)
                return CallConnection(url: URL(string: "wss://example.livekit.cloud/room-\(requests.count)")!, token: "t")
            }
        )
    }

    var room: FakeLiveKitRoom? { rooms.last }

    private func makeAudioEngine() -> FakeLiveKitAudioEngine {
        let engine = FakeLiveKitAudioEngine()
        audioEngines.append(engine)
        return engine
    }

    /// Ring with `preconnect` and return the ring's call id.
    func ring(preconnect: String? = "media") -> UUID {
        engine.startPushRegistration()
        let id = UUID()
        var push: [AnyHashable: Any] = ["target_id": targetID.uuidString, "call_id": id.uuidString]
        push["preconnect"] = preconnect
        system.deliverPush(push) {}
        return id
    }
}

@MainActor
func drain(_ ticks: Int = 200) async {
    for _ in 0..<ticks { await Task.yield() }
}

@MainActor
func waitUntil(ticks: Int = 1000, _ condition: () -> Bool) async {
    for _ in 0..<ticks {
        if condition() { return }
        await Task.yield()
    }
}

extension CallState {
    var isConnected: Bool { if case .connected = self { true } else { false } }
}
