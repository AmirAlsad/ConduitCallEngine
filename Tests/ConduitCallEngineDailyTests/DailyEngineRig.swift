//
//  DailyEngineRig.swift
//  ConduitCallEngineDailyTests
//
//  The real `PipecatDailyTransport`, over a real `PipecatClient` whose Daily
//  transport and call client are fakes, driven by a real `CallEngine` over a
//  `SimulatedCallSystem`. Tests here cross the seam: what the engine asks of the
//  adapter, in the order and the situations it asks it, against what the adapter
//  and the Pipecat client then do.
//

import AVFoundation
import Foundation
import ConduitCallEngine
import ConduitCallEngineTesting
@testable import ConduitCallEngineDaily

/// A sleep the test ends by hand, recording how long each sleeper asked for.
@MainActor
final class HandSleeper {
    private(set) var requested: [Duration] = []
    private var pending: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int { pending.count }

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { pending.append($0) }
    }

    /// End the oldest pending sleep.
    func wakeFirst() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
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
final class DailyEngineRig {
    let system = SimulatedCallSystem()
    let sleeper = HandSleeper()
    let host = RecordingHost()
    let engine: CallEngine
    let targetID = UUID()

    /// Every Pipecat transport made (one per adapter session), in order.
    private(set) var pipecats: [FakePipecatTransport] = []
    private(set) var controls: [FakeDailyCallControl] = []
    private(set) var pathMonitors: [FakePathMonitor] = []
    private(set) var transports: [PipecatDailyTransport] = []
    /// Every credential request, in order; request n is answered with room n.
    private(set) var requests: [ConnectRequest] = []
    /// What the target allows a ring to prepare.
    var ringPreparation: RingPreparation = .none
    /// The output port the session reports, as iOS's route; nil reports none.
    var outputPort: AVAudioSession.Port?
    /// The session's available inputs, as iOS reports them.
    var availableInputs: [AVAudioSession.Port] = []
    /// When set, each Daily session drops its preferred device at the join.
    var dailyDropsPreferenceAtJoin = false
    /// The audio devices each new Daily session lists.
    var mics: [String] = []
    /// While true, the target's credential fetch waits for `releaseCredentials()`.
    var holdsCredentials = false
    private var pendingCredentials: CheckedContinuation<Void, Never>?

    init(
        joinTimeout: Duration? = .seconds(30),
        minimumOutgoingConnecting: Duration = .zero,
        defaultsToSpeaker: Bool = false
    ) {
        let sleeper = sleeper
        engine = CallEngine.simulated(
            configuration: CallEngineConfiguration(
                ringTimeout: nil,
                joinTimeout: joinTimeout,
                minimumOutgoingConnectingDuration: minimumOutgoingConnecting,
                defaultsToSpeaker: defaultsToSpeaker
            ),
            system: system,
            sleep: { await sleeper.sleep($0) }
        )
        engine.delegate = host
        host.target = target
    }

    var target: CallTarget {
        CallTarget(
            id: targetID,
            displayName: "Agent",
            handle: nil,
            ringPreparation: ringPreparation,
            makeTransport: { [unowned self] in makeTransport() },
            connect: { [unowned self] request in
                requests.append(request)
                if holdsCredentials { await withCheckedContinuation { pendingCredentials = $0 } }
                return Self.room(requests.count)
            }
        )
    }

    static func room(_ number: Int) -> CallConnection {
        CallConnection(url: URL(string: "https://example.daily.co/room-\(number)")!, token: "token-\(number)")
    }

    private func makeTransport() -> PipecatDailyTransport {
        let transport = PipecatDailyTransport(
            makePipecatTransport: { [unowned self] in
                let fake = FakePipecatTransport()
                fake.mics = mics
                pipecats.append(fake)
                return fake
            },
            makePathMonitor: { [unowned self] in
                let monitor = FakePathMonitor()
                pathMonitors.append(monitor)
                return monitor
            },
            makeCallControl: { [unowned self] transport in
                let fake = transport as! FakePipecatTransport
                let control = FakeDailyCallControl(transport: fake)
                if dailyDropsPreferenceAtJoin { fake.onJoin = { control.preferredAudioRoute = nil } }
                controls.append(control)
                return control
            },
            readOutputPort: { [unowned self] in outputPort },
            readAvailableInputs: { [unowned self] in availableInputs }
        )
        transports.append(transport)
        return transport
    }

    /// Lets a held credential fetch return.
    func releaseCredentials() {
        holdsCredentials = false
        pendingCredentials?.resume()
        pendingCredentials = nil
    }

    /// Whether a credential fetch is waiting for `releaseCredentials()`.
    var isHoldingCredentials: Bool { pendingCredentials != nil }

    /// The Pipecat transport of the adapter's current session.
    var pipecat: FakePipecatTransport? { pipecats.last }

    /// Hand the host the target as configured now (after changing `ringPreparation`).
    func refreshTarget() {
        host.target = target
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

    /// Place a call and let CallKit activate it, so the transport has joined and the
    /// engine is waiting for the agent.
    func placeActivatedCall() async throws -> UUID {
        await engine.placeCall(target)
        await system.activateAudioSession()
        await drain()
        guard let id = system.startedCallIDs.first else { throw RigError.noCall }
        return id
    }

    enum RigError: Error { case noCall }
}

/// Lets the main-actor hops queued by SDK callbacks, media commands and the
/// adapter's own tasks run.
@MainActor
func drain(_ ticks: Int = 200) async {
    for _ in 0..<ticks { await Task.yield() }
}

/// Yield until `condition` holds or the tick budget runs out.
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
