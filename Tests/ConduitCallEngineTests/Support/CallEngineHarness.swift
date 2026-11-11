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

    private(set) var connectCount = 0
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
            connect: { [self] in try await connect() }
        )
    }

    private func connect() async throws -> CallConnection {
        connectCount += 1
        if suspend {
            await withCheckedContinuation { pending.append($0) }
        }
        if let error { throw error }
        return connection
    }

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
    }

    private(set) var events: [Event] = []
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

    init(
        policy: ReconnectionPolicy = .default,
        pushToTalk: Bool = false,
        now: @escaping () -> Date = { Date() }
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
            configuration: CallEngineConfiguration(unknownCallerName: "Agent", isPushToTalkEnabled: { pushToTalk }),
            callProvider: provider,
            interruptionObserver: interruption,
            ringStatusReporter: ringStatusReporter,
            pushRegistry: pushRegistry,
            policy: policy,
            now: now,
            sleep: { _ in }
        )
        engine.delegate = delegate
    }

    /// The live call's transport (or the next call's, before it is placed).
    var transport: FakeTransport { transports.current }

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
        statusURL: URL? = nil
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
