//
//  LiveKitEngineRig.swift
//  ConduitCallEngineLiveKitTests
//
//  The real `LiveKitTransport`, over a `FakeLiveKitRoom` that sequences its work as
//  LiveKit's `Room` does, driven by a real `CallEngine` over a `SimulatedCallSystem`.
//

import Foundation
import Synchronization
import Testing
import ConduitCallEngine
import ConduitCallEngineTesting
@testable import ConduitCallEngineLiveKit

@MainActor
final class HandSleeper {
    private(set) var requested: [Duration] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int { pending.count }

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        let waiters = sleepWaiters
        sleepWaiters = []
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { pending.append($0) }
    }

    /// Returns once a sleep is pending, however long the sleeper takes to get here.
    func untilSleeping() async {
        guard pending.isEmpty else { return }
        await withCheckedContinuation { sleepWaiters.append($0) }
    }

    func wakeAll() {
        let waiting = pending
        pending = []
        waiting.forEach { $0.resume() }
    }
}

/// The moment the rig's engine is built at: its clock stands still, so no wait it
/// measures by `now` (the outgoing minimum connecting time) passes with the machine's time.
let testEpoch = Date(timeIntervalSince1970: 1_000_000)

/// A sleep that never runs out by itself: it ends, throwing `CancellationError`, only
/// when its task is cancelled. For the adapter's deadline, which must wait for what
/// it bounds however long the machine takes.
@Sendable
func parkedSleep(_ duration: Duration) async throws {
    let park = Park()
    await withTaskCancellationHandler {
        await park.wait()
    } onCancel: {
        park.open()
    }
    throw CancellationError()
}

/// Suspends `wait()` until `open()`; a `wait()` after `open()` returns at once.
private final class Park: Sendable {
    private let state = Mutex<(isOpen: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen { state.waiter = continuation }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    func open() {
        let waiter = state.withLock { state in
            state.isOpen = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

/// A LiveKit transport whose waits do not run on the machine's time: the wait for a
/// connecting room yields instead of sleeping, and the client messages' deadline
/// never runs out by itself.
@MainActor
func makeLiveKitTransport(
    makeRoom: (RoomEventMapper) -> LiveKitRoomControlling,
    audioEngine: LiveKitAudioEngineControlling
) -> LiveKitTransport {
    LiveKitTransport(
        makeRoom: makeRoom,
        audioEngine: audioEngine,
        sleep: { _ in await Task.yield() },
        deadlineSleep: parkedSleep
    )
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

    /// `supportsHolding` is off by default, as the package's is.
    init(
        supportsHolding: Bool = false,
        joinTimeout: Duration? = .seconds(30),
        ringTimeout: Duration? = nil,
        minimumOutgoingConnecting: Duration = .zero
    ) {
        let sleeper = sleeper
        engine = CallEngine.simulated(
            configuration: CallEngineConfiguration(
                ringTimeout: ringTimeout,
                joinTimeout: joinTimeout,
                minimumOutgoingConnectingDuration: minimumOutgoingConnecting,
                supportsHolding: supportsHolding
            ),
            system: system,
            now: { testEpoch },
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
                makeLiveKitTransport(
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

/// Yield the main actor until `condition` holds. A budget that runs out records an
/// issue at the caller, so the test fails where it waited rather than at an
/// expectation that only looks wrong. Work that runs off the main actor may need
/// more than yields: prefer `SimulatedCallSystem.awaitPendingWork()` where it covers it.
@MainActor
func waitUntil(
    ticks: Int = 1000,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    for _ in 0..<ticks {
        if condition() { return }
        await Task.yield()
    }
    if condition() { return }
    Issue.record("waitUntil gave up after \(ticks) yields", sourceLocation: sourceLocation)
}

extension CallState {
    var isConnected: Bool { if case .connected = self { true } else { false } }
}
