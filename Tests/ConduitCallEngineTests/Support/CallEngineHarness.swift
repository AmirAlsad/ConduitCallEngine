//
//  CallEngineHarness.swift
//  ConduitCallEngineTests
//
//  Shared fixtures for the engine-side CallEngine tests: the CallKit,
//  interruption, and receipt fakes, a scripted call target, a delegate that
//  records everything the engine reports, and a controllable clock. The
//  engine knows no agents, so nothing here needs SwiftData or the Keychain.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

/// A clock the tests advance by hand to make durations deterministic.
@MainActor
final class MutableClock {
    var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }
    func now() -> Date { current }
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

/// A sleep the test ends by hand, recording how long each sleeper asked for.
@MainActor
final class ManualSleeper {
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

/// Hands each call its own FakeTransport, so the engine's transport-identity
/// guards are exercised. `current` is the live call's transport — or, before the
/// next call, the one it will get — so a test can configure it ahead of time.
@MainActor
final class FakeTransportPool {
    private(set) var made: [FakeTransport] = []
    private var next = FakeTransport()

    var current: FakeTransport { made.last ?? next }

    func make() -> FakeTransport {
        let transport = next
        made.append(transport)
        next = FakeTransport()
        return transport
    }
}

/// A call target whose transport and credential step are scripted: it counts
/// `makeTransport` and `connect` calls, and `connect` can fail or be held open
/// until `release()` so a test can act while credentials are in flight.
@MainActor
final class FakeTarget {
    let id = UUID()
    let displayName = "Echo Bot"
    let handle = "echo-bot@conduit.invalid"
    var connection = CallConnection(url: URL(string: "https://example.daily.co/room")!, token: "valid-token")
    var error: (any Error)?
    var suspend = false
    /// What the target lets the engine prepare during a ring; see
    /// `CallEngineHarness.allowRingPreparation(_:)`.
    var ringPreparation: RingPreparation = .none

    /// Every request `connect` was called with, in order.
    private(set) var requests: [ConnectRequest] = []
    var connectCount: Int { requests.count }
    let transports: FakeTransportPool
    private var pending: [CheckedContinuation<Void, Never>] = []

    init(transports: FakeTransportPool) {
        self.transports = transports
    }

    var makeTransportCount: Int { transports.made.count }

    var callTarget: CallTarget {
        CallTarget(
            id: id,
            displayName: displayName,
            handle: handle,
            makeTransport: { [self] in transports.make() },
            connect: { [self] request in try await connect(request) },
            ringPreparation: ringPreparation
        )
    }

    private func connect(_ request: ConnectRequest) async throws -> CallConnection {
        requests.append(request)
        if suspend {
            await withCheckedContinuation { pending.append($0) }
        }
        if let error { throw error }
        return connection
    }

    var pendingCount: Int { pending.count }

    /// Resume every suspended `connect`; each then returns (or throws) as scripted.
    func release() {
        let waiting = pending
        pending = []
        waiting.forEach { $0.resume() }
    }
}

/// One ordered log shared by the fake provider, the recording delegate, and
/// PushKit's completion, so a test asserts the order across all three.
@MainActor
final class EventLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

/// Records every delegate call in order and answers from simple tables.
@MainActor
final class RecordingCallEngineDelegate: CallEngineDelegate {
    enum Event: Equatable {
        case transition(from: CallState, to: CallState)
        case finish(CallRecord)
        case resolve(IncomingCall)
        case bearer(UUID)
        case pushToken(Data)
        case cue(CallCue)
    }

    private(set) var events: [Event] = []
    /// `engine.repeatingCue` as the delegate read it at each cue, in cue order.
    private(set) var repeatingCueAtEachCue: [RepeatingCue?] = []
    var log: EventLog?
    var targets: [UUID: CallTarget] = [:]
    var bearers: [UUID: String] = [:]

    /// Transitions as `"old→new"` labels, in order.
    var transitions: [String] {
        events.compactMap {
            if case .transition(let old, let new) = $0 { return "\(old.label)→\(new.label)" }
            return nil
        }
    }

    var records: [CallRecord] {
        events.compactMap { if case .finish(let record) = $0 { return record } else { return nil } }
    }

    var resolved: [IncomingCall] {
        events.compactMap { if case .resolve(let call) = $0 { return call } else { return nil } }
    }

    var cues: [CallCue] {
        events.compactMap { if case .cue(let cue) = $0 { return cue } else { return nil } }
    }

    /// Every way the cues delivered so far break `CallCue`'s guarantees: a start
    /// while a loop runs, a stop with none running, a connected moment inside a
    /// loop, a connection loss not followed by the retrying loop, a hold with a
    /// loop running, any cue between a hold and its resume, a resume without a
    /// hold, or `repeatingCue` disagreeing with the last start or stop.
    var cueViolations: [String] {
        var violations: [String] = []
        var running: RepeatingCue?
        var isHeld = false
        let cues = cues
        for (index, cue) in cues.enumerated() {
            if isHeld, cue != .moment(.resumed) {
                violations.append("#\(index) \(cue.label) while held")
            }
            switch cue {
            case .start(let loop):
                if let running { violations.append("#\(index) start(\(loop)) while \(running) runs") }
                running = loop
            case .stop:
                if running == nil { violations.append("#\(index) stop with no loop running") }
                running = nil
            case .moment(let moment):
                if let running, moment == .connected || moment == .reconnected {
                    violations.append("#\(index) \(moment) while \(running) runs")
                }
                if moment == .connectionLost, index + 1 < cues.count, cues[index + 1] != .start(.retrying) {
                    violations.append("#\(index) connectionLost followed by \(cues[index + 1].label)")
                }
                if moment == .held {
                    if let running { violations.append("#\(index) held while \(running) runs") }
                    isHeld = true
                }
                if moment == .resumed {
                    if !isHeld { violations.append("#\(index) resumed without a hold") }
                    isHeld = false
                }
            }
            if repeatingCueAtEachCue[index] != running {
                violations.append("#\(index) repeatingCue was \(String(describing: repeatingCueAtEachCue[index]))")
            }
        }
        return violations
    }

    var bearerRequests: [UUID] {
        events.compactMap { if case .bearer(let id) = $0 { return id } else { return nil } }
    }

    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? {
        events.append(.resolve(call))
        log?.append("resolve")
        return targets[call.targetID]
    }

    func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState) {
        events.append(.transition(from: old, to: new))
        log?.append("T(\(old.label)→\(new.label))")
    }

    func callEngine(_ engine: CallEngine, cue: CallCue) {
        events.append(.cue(cue))
        repeatingCueAtEachCue.append(engine.repeatingCue)
        log?.append("cue(\(cue.label))")
    }

    func callEngine(_ engine: CallEngine, didFinish record: CallRecord) {
        events.append(.finish(record))
        log?.append("finish(\(record.outcome.rawValue))")
    }

    func callEngine(_ engine: CallEngine, ringStatusBearerForTarget id: UUID) -> String? {
        events.append(.bearer(id))
        log?.append("bearer")
        return bearers[id]
    }

    func callEngine(_ engine: CallEngine, didUpdateVoIPPushToken token: Data) {
        events.append(.pushToken(token))
        log?.append("push-token")
    }
}

@MainActor
final class CallEngineHarness {
    let provider = FakeCallProvider()
    let interruption = FakeAudioInterruptionObserver()
    let ringStatusReporter = FakeRingStatusReporter()
    let pushRegistry = FakeVoIPPushRegistry()
    let transports = FakeTransportPool()
    let target: FakeTarget
    let delegate = RecordingCallEngineDelegate()
    let log = EventLog()
    let engine: CallEngine
    let callID = UUID()
    /// How many times PushKit's completion has run, across every ring.
    private(set) var pushCompletions = 0

    /// `ringTimeout` and `joinTimeout` default to none, unlike the engine's,
    /// because the default `sleep` returns at once and would end every ring, and
    /// every attempt waiting for the agent, on the next yield. Tests of those
    /// timeouts pass one and a `ManualSleeper`.
    init(
        policy: ReconnectionPolicy = .default,
        pushToTalk: Bool = false,
        ringTimeout: Duration? = nil,
        joinTimeout: Duration? = nil,
        supportsHolding: Bool = true,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping (Duration) async throws -> Void = { _ in }
    ) {
        provider.nextCallID = callID
        target = FakeTarget(transports: transports)
        // The host knows this target, so an incoming push for it resolves.
        delegate.targets[target.id] = target.callTarget
        let log = self.log
        delegate.log = log
        provider.onEvent = { log.append($0) }
        ringStatusReporter.onEvent = { log.append($0) }

        engine = CallEngine(
            configuration: CallEngineConfiguration(
                unknownCallerName: "Agent",
                isPushToTalkEnabled: { pushToTalk },
                ringTimeout: ringTimeout,
                supportsHolding: supportsHolding,
                joinTimeout: joinTimeout
            ),
            callProvider: provider,
            interruptionObserver: interruption,
            ringStatusReporter: ringStatusReporter,
            pushRegistry: pushRegistry,
            policy: policy,
            now: now,
            sleep: sleep
        )
        engine.delegate = delegate
    }

    /// The live call's transport (or the next call's, before it is placed).
    var transport: FakeTransport { transports.current }

    /// Let the host's target prepare rings up to `tier` (pre-connect).
    func allowRingPreparation(_ tier: RingPreparation) {
        target.ringPreparation = tier
        delegate.targets[target.id] = target.callTarget
    }

    func placeCall() async {
        await engine.placeCall(target.callTarget)
    }

    /// Deliver a VoIP push for this harness's target (or `targetID`, e.g. an
    /// unknown one) through the engine's PushKit entry.
    func ring(
        targetID: UUID? = nil,
        callID: UUID = UUID(),
        displayName: String? = nil,
        handle: String? = nil,
        roomURL: URL? = nil,
        token: String? = nil,
        statusURL: URL? = nil,
        ringTimeout: String? = nil,
        preconnect: String? = nil
    ) {
        var push: [AnyHashable: Any] = [
            "target_id": (targetID ?? target.id).uuidString,
            "call_id": callID.uuidString,
        ]
        push["display_name"] = displayName
        push["handle"] = handle
        push["room_url"] = roomURL?.absoluteString
        push["token"] = token
        push["status_url"] = statusURL?.absoluteString
        push["ring_timeout"] = ringTimeout
        push["preconnect"] = preconnect
        deliverPush(push)
    }

    /// Deliver a cancel push for `callID`, shaped as the push contract says: no
    /// `target_id`.
    func cancel(callID: UUID, displayName: String? = nil) {
        var push: [AnyHashable: Any] = ["action": "cancel", "call_id": callID.uuidString]
        push["display_name"] = displayName
        deliverPush(push)
    }

    /// Deliver a raw push dictionary, recording PushKit's completion in the log.
    func deliverPush(_ push: [AnyHashable: Any]) {
        engine.handleIncomingPush(push) { [self] in
            pushCompletions += 1
            log.append("push-completed")
        }
    }
}

/// Yield the main actor until `condition` holds or the tick budget runs out, so a
/// test can await an event delivered through an async path (e.g. the transport
/// event stream) without a brittle fixed sleep.
@MainActor
func waitUntil(ticks: Int = 500, _ condition: () -> Bool) async {
    for _ in 0..<ticks {
        if condition() { return }
        await Task.yield()
    }
}

/// Yield the main actor a fixed number of times, so work that should NOT happen
/// (a timer that must stay inert) has had every chance to run.
@MainActor
func settle(ticks: Int = 200) async {
    for _ in 0..<ticks { await Task.yield() }
}

extension CallState {
    /// Case-only matchers so tests can assert state without pinning the
    /// associated `Date` of `.connected`.
    var isConnected: Bool { if case .connected = self { return true } else { return false } }
    var isConnecting: Bool { if case .connecting = self { return true } else { return false } }
    var reconnectingAttempt: Int? {
        if case .reconnecting(let n) = self { return n } else { return nil }
    }
    var failureReason: CallFailureReason? {
        if case .failed(let r) = self { return r } else { return nil }
    }
    var endedOutcome: CallOutcome? {
        if case .ended(let o) = self { return o } else { return nil }
    }

    /// A date-free label for transition logs, e.g. `reconnecting(1)`.
    var label: String {
        switch self {
        case .idle: "idle"
        case .incomingRinging: "incomingRinging"
        case .dialing: "dialing"
        case .connecting: "connecting"
        case .connected: "connected"
        case .reconnecting(let attempt): "reconnecting(\(attempt))"
        case .ended(let outcome): "ended(\(outcome.rawValue))"
        case .failed(let reason): "failed(\(reason.rawValue))"
        }
    }
}

extension CallCue {
    /// A short label for event logs, e.g. `start(connecting)`, `stop`, `connected`.
    var label: String {
        switch self {
        case .start(let loop): "start(\(loop))"
        case .stop: "stop"
        case .moment(let moment): "\(moment)"
        }
    }
}
