//
//  Swift6HostTests.swift
//  ConduitCallEngineSwift6Tests
//
//  A host written in the Swift 6 language mode, with complete concurrency checking:
//  a transport of its own (one main-actor class, one actor), a delegate, targets and
//  a configuration kept in globals, the log hook, and the Testing product driving
//  calls. It imports nothing with `@testable` or `@preconcurrency` and uses no
//  `package` symbol, so it compiles only against what a host sees; this target
//  building without a warning is the proof that a Swift 6 host can use the package.
//

import ConduitCallEngine
import ConduitCallEngineDaily
import ConduitCallEngineLiveKit
import ConduitCallEngineTesting
import Foundation
import Synchronization
import Testing

// MARK: - Values a host keeps in globals and statics (they must be Sendable)

let hostConfiguration = CallEngineConfiguration(
    unknownCallerName: "Agent",
    isPushToTalkEnabled: { false },
    ringTimeout: nil,
    supportsHolding: true,
    joinTimeout: nil
)

let roomConnection = CallConnection(url: URL(string: "https://example.invalid/room")!, token: "room-token")

enum HostTargets {
    static let agentID = UUID()

    /// A target whose transport is a fresh `FakeTransport` and whose credentials are fixed.
    static let fake = CallTarget(
        id: agentID,
        displayName: "Agent",
        handle: nil,
        makeTransport: { FakeTransport() },
        connect: { _ in roomConnection }
    )

    /// The bundled adapters, as a Swift 6 host builds targets on them. Never called
    /// here: their WebRTC stacks abort in the simulator.
    static func adapterTargets() -> [CallTarget] {
        [
            CallTarget(id: UUID(), displayName: "Daily", handle: "daily@example.invalid",
                       makeTransport: { PipecatDailyTransport() }, connect: { _ in roomConnection }),
            CallTarget(id: UUID(), displayName: "LiveKit", handle: nil,
                       makeTransport: { LiveKitTransport() }, connect: { _ in roomConnection },
                       ringPreparation: .media),
        ]
    }
}

// MARK: - A host-written transport on the main actor, the shape the guide shows

@MainActor
final class MainActorTransport: CallTransport {
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private(set) var connections: [CallConnection] = []
    private(set) var isAttached = false
    private(set) var isMicOn = false
    private(set) var signals: [CallSignal] = []
    private(set) var disconnects = 0
    private var device = "speaker"

    init() {
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    nonisolated var canConnectWhileRinging: Bool { true }

    func connect(_ connection: CallConnection) async throws {
        connections.append(connection)
        continuation.yield(.connecting)
    }

    func disconnect() async {
        disconnects += 1
        continuation.yield(.disconnected(reason: .requestedByUser))
    }

    func setMicEnabled(_ enabled: Bool) async { isMicOn = enabled }

    func availableAudioDevices() async -> [AudioDeviceInfo] {
        [AudioDeviceInfo(id: "speaker", name: "Speaker"), AudioDeviceInfo(id: "bluetooth-1", name: "AirPods")]
    }

    func selectedAudioDevice() async -> AudioDeviceInfo? {
        await availableAudioDevices().first { $0.id == device }
    }

    func setAudioDevice(_ id: String) async { device = id }

    func attachAudioSession() async { isAttached = true }

    func detachAudioSession() async { isAttached = false }

    func send(_ signal: CallSignal) async -> CallSignalDelivery {
        signals.append(signal)
        return .sent
    }
}

// MARK: - A host-written transport that is an actor

actor ActorTransport: CallTransport {
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private(set) var connectCount = 0
    private(set) var isMicOn = false

    init() {
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    func connect(_ connection: CallConnection) async throws { connectCount += 1 }
    func disconnect() async {}
    func setMicEnabled(_ enabled: Bool) async { isMicOn = enabled }
    func availableAudioDevices() async -> [AudioDeviceInfo] { [] }
    func selectedAudioDevice() async -> AudioDeviceInfo? { nil }
    func setAudioDevice(_ id: String) async {}
    func attachAudioSession() async {}
    func detachAudioSession() async {}
    // `send(_:)` and `canConnectWhileRinging` come from the protocol's defaults.
}

// MARK: - A delegate implementing every callback

@MainActor
final class Swift6Host: CallEngineDelegate {
    var targets: [UUID: CallTarget] = [:]
    private(set) var states: [CallState] = []
    private(set) var cues: [CallCue] = []
    private(set) var records: [CallRecord] = []
    private(set) var phases: [RingPreparationPhase] = []
    private(set) var tokens: [Data] = []
    private(set) var spoken: [String] = []

    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? {
        targets[call.targetID]
    }

    func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState) {
        states.append(new)
    }

    func callEngine(_ engine: CallEngine, cue: CallCue) {
        cues.append(cue)
        switch cue {
        case .start(.connecting): spoken.append("ringback")
        case .start(.retrying): spoken.append("retrying")
        case .stop: spoken.append("stop")
        case .moment(.connected), .moment(.reconnected): spoken.append("connected")
        case .moment(.connectionLost): spoken.append("lost")
        case .moment(.held), .moment(.resumed): break
        @unknown default: break
        }
    }

    func callEngine(
        _ engine: CallEngine,
        didChangeRingPreparationPhaseFrom old: RingPreparationPhase,
        to new: RingPreparationPhase
    ) {
        phases.append(new)
    }

    func callEngine(_ engine: CallEngine, didFinish record: CallRecord) {
        records.append(record)
    }

    func callEngine(_ engine: CallEngine, ringStatusBearerForTarget id: UUID) -> String? {
        "bearer"
    }

    func callEngine(_ engine: CallEngine, didUpdateVoIPPushToken token: Data) {
        tokens.append(token)
    }
}

/// Collects log events from any thread.
final class LogCollector: Sendable {
    private let events = Mutex<[CallEngineLog.Event]>([])
    var all: [CallEngineLog.Event] { events.withLock { $0 } }
    func record(_ event: CallEngineLog.Event) { events.withLock { $0.append(event) } }
}

// MARK: - Every enum, switched the way the documentation says

func describe(_ state: CallState) -> String {
    switch state {
    case .idle: "idle"
    case .incomingRinging: "ringing"
    case .dialing: "dialing"
    case .connecting: "connecting"
    case .connected(let since): "connected \(since)"
    case .reconnecting(let attempt): "reconnecting \(attempt)"
    case .ended(let outcome): "ended \(describe(outcome))"
    case .failed(let reason): "failed \(describe(reason))"
    }
}

func describe(_ outcome: CallOutcome) -> String {
    switch outcome {
    case .completed, .failed, .declined, .noAnswer, .canceled: outcome.rawValue
    }
}

func describe(_ reason: CallFailureReason) -> String {
    switch reason {
    case .badToken, .agentUnreachable, .lostConnection, .transportError, .unknown: reason.rawValue
    @unknown default: "other"
    }
}

func describe(_ reason: MissedCallReason) -> String {
    switch reason {
    case .busy, .filteredByFocus, .ringTimedOut, .canceledByCaller: "\(reason.rawValue) \(reason.reachedUser)"
    @unknown default: "other"
    }
}

func describe(_ purpose: ConnectRequest.Purpose) -> String {
    switch purpose {
    case .outgoing: "outgoing"
    case .answered: "answered"
    case .ringing(let joinsBeforeAnswer): "ringing \(joinsBeforeAnswer)"
    case .reconnect(let attempt): "reconnect \(attempt)"
    @unknown default: "answered"
    }
}

func describe(_ event: TransportEvent) -> String {
    switch event {
    case .connecting, .connected, .reconnecting, .botStartedSpeaking, .botStoppedSpeaking,
         .userStartedSpeaking, .userStoppedSpeaking, .audioDevicesChanged:
        "\(event)"
    case .disconnected(let reason):
        switch reason {
        case .requestedByUser, .networkDropped, .authFailed, .botLeft, .unknown: "\(reason)"
        @unknown default: "other"
        }
    case .remoteAudioLevel(let level): "\(level)"
    case .error(let error):
        switch error {
        case .connectionFailed(let message), .underlying(let message): message
        case .authenticationFailed: "auth"
        @unknown default: "other"
        }
    @unknown default: "other"
    }
}

func describe(_ phase: RingPreparationPhase, _ preparation: RingPreparation, _ signal: CallSignal,
              _ delivery: CallSignalDelivery, _ route: AudioRouteKind, _ level: CallEngineLog.Level,
              _ category: CallEngineLog.Category) -> [String] {
    var parts: [String] = []
    switch phase {
    case .idle, .fetchingCredentials, .credentialsReady, .connecting, .ready, .failed: parts.append("\(phase)")
    @unknown default: parts.append("other")
    }
    switch preparation {
    case .none, .credentials, .media: parts.append("\(preparation)")
    }
    switch signal {
    case .answered, .held, .resumed: parts.append(signal.rawValue)
    @unknown default: parts.append("other")
    }
    switch delivery {
    case .sent, .failed, .unsupported: parts.append("\(delivery)")
    }
    switch route {
    case .receiver, .speaker, .bluetooth, .wired, .other: parts.append("\(route)")
    }
    switch level {
    case .debug, .info, .warning, .error: parts.append("\(level)")
    }
    switch category {
    case .call, .callKit, .transport, .audio, .network: parts.append(category.rawValue)
    @unknown default: parts.append("other")
    }
    return parts
}

/// A clock and a sleep a host test controls, both on the main actor.
@MainActor
final class HostClock {
    var current = Date(timeIntervalSince1970: 1_000_000)
    private(set) var sleeps: [Duration] = []
    func now() -> Date { current }
    func sleep(_ duration: Duration) async throws { sleeps.append(duration) }
}

// MARK: - Tests

@MainActor
struct Swift6HostTests {
    let system = SimulatedCallSystem()
    let host = Swift6Host()
    let engine: CallEngine

    init() {
        engine = CallEngine.simulated(configuration: hostConfiguration, system: system, now: { .now }, sleep: { _ in })
        engine.delegate = host
        engine.startPushRegistration()
    }

    @Test func aMainActorTransportCarriesAPlacedCall() async throws {
        let transport = MainActorTransport()
        let target = CallTarget(id: UUID(), displayName: "Agent", handle: nil,
                                makeTransport: { transport }, connect: { _ in roomConnection })

        await engine.placeCall(target)
        #expect(transport.connections == [roomConnection])
        await system.activateAudioSession()
        #expect(system.deliverTransportEvent(.connected))
        #expect(engine.state.isActive)
        #expect(transport.isAttached)
        #expect(transport.isMicOn)

        await engine.setMuted(true)
        #expect(!transport.isMicOn)
        await engine.setOnHold(true)
        #expect(engine.isOnHold)
        #expect(await system.setHeldFromSystem(try #require(system.startedCallIDs.last), onHold: false))
        #expect(!engine.isOnHold)
        await engine.selectAudioDevice("bluetooth-1")
        engine.markEndedByUser()
        await engine.endCall()

        #expect(engine.endedByUser)
        #expect(host.records.map(\.outcome) == [.completed])
        #expect(host.spoken.contains("connected"))
        #expect(transport.signals.contains(.held))
        engine.reset()
        #expect(engine.state == .idle)
    }

    @Test func anActorTransportCarriesAPlacedCall() async throws {
        let transport = ActorTransport()
        let target = CallTarget(id: UUID(), displayName: "Agent", handle: nil,
                                makeTransport: { transport }, connect: { _ in roomConnection })

        await engine.placeCall(target)
        #expect(system.deliverTransportEvent(.connected))
        #expect(await transport.connectCount == 1)
        #expect(!transport.canConnectWhileRinging)
        #expect(await transport.send(.held) == .unsupported)
        await engine.endCall()
        #expect(host.records.map(\.outcome) == [.completed])
    }

    @Test func aPreconnectedRingIsAnsweredWithTheTestingProduct() async throws {
        let transport = FakeTransport()
        transport.canConnectWhileRinging = true
        host.targets[HostTargets.agentID] = CallTarget(
            id: HostTargets.agentID, displayName: "Agent", handle: nil,
            makeTransport: { transport }, connect: { _ in roomConnection }, ringPreparation: .media
        )
        let callID = UUID()
        var completed = false
        system.deliverPush([
            "target_id": HostTargets.agentID.uuidString,
            "call_id": callID.uuidString,
            "preconnect": "media",
        ]) { completed = true }
        #expect(completed)
        #expect(await system.awaitRingPreparation() == .connecting)
        #expect(system.deliverTransportEvent(.connected))
        #expect(engine.ringPreparationPhase == .ready)

        await system.answerIncomingCall()
        await system.activateAudioSession()
        await system.awaitPendingWork()
        #expect(engine.state.isConnected)
        #expect(transport.sentSignals == [.answered])
        #expect(engine.activeCall?.direction == .incoming)
        #expect(host.phases == [.fetchingCredentials, .connecting, .ready, .idle])
        system.endCallFromSystem(callID)
        await system.awaitPendingWork()
        #expect(transport.disconnectCount == 1)
        #expect(host.records.first?.direction == .incoming)
    }

    @Test func timersRunOutWhenTheHostSays() async throws {
        let system = SimulatedCallSystem()
        let engine = CallEngine.simulated(system: system)
        engine.delegate = host
        engine.startPushRegistration()
        host.targets[HostTargets.agentID] = HostTargets.fake
        system.deliverPush(["target_id": HostTargets.agentID.uuidString, "call_id": UUID().uuidString]) {}
        #expect(system.fireTimer(.ringTimeout))
        #expect(host.records.last?.missedReason == .ringTimedOut)
        #expect(SimulatedCallSystem.EngineTimer.allCases.allSatisfy { !system.fireTimer($0) })
        _ = FakeTransport(reportsConnectedAfter: .seconds(1)).reportsConnectedAfter
    }

    @Test func aHostClockDrivesTheEngine() async throws {
        let clock = HostClock()
        let engine = CallEngine.simulated(configuration: hostConfiguration, now: clock.now, sleep: clock.sleep)
        await engine.placeCall(HostTargets.fake)
        clock.current += 30
        await engine.endCall()
        #expect(engine.state == .ended(.canceled))
    }

    @Test func theFakeTransportCanBeUsedFromAnyContext() async {
        let transport = FakeTransport()
        await Task.detached {
            transport.emit(.botStartedSpeaking)
            transport.canConnectWhileRinging = true
        }.value
        #expect(transport.canConnectWhileRinging)
        #expect(transport.connectCount == 0)
        transport.finish()
    }

    @Test func aHostCanReceiveTheLogFromSwift6() async {
        let collector = LogCollector()
        let previous = (CallEngineLog.handler, CallEngineLog.minimumLevel)
        CallEngineLog.handler = { collector.record($0) }
        CallEngineLog.minimumLevel = .debug
        defer { (CallEngineLog.handler, CallEngineLog.minimumLevel) = previous }

        await engine.placeCall(HostTargets.fake)
        #expect(system.deliverTransportEvent(.connected))
        await engine.endCall()

        #expect(collector.all.contains { $0.category == .call })
        CallEngineLog.writeToOSLog(CallEngineLog.Event(level: .info, category: .call, message: "from a Swift 6 host"))
    }

    @Test func theRestOfTheSurfaceIsUsable() async throws {
        let incoming = IncomingCall(callID: UUID(), targetID: UUID(), displayName: "A", handle: "a@example.invalid",
                                    connection: roomConnection, requestedPreparation: .credentials)
        let request = ConnectRequest(purpose: .ringing(joinsBeforeAnswer: false), callID: incoming.callID)
        let record = CallRecord(targetID: incoming.targetID, direction: .incoming, startedAt: .now, duration: 0,
                                outcome: .noAnswer, missedReason: .ringTimedOut)
        let active = ActiveCall(targetID: incoming.targetID, displayName: "A", direction: .incoming)

        #expect(describe(request.purpose) == "ringing false")
        #expect(describe(record.missedReason!) == "ringTimedOut true")
        #expect(describe(.failed(.agentUnreachable)) == "failed agentUnreachable")
        #expect(describe(.error(.connectionFailed("x"))) == "x")
        #expect(describe(.idle, .media, .held, .sent, AudioRouteKind(deviceID: "Speaker"), .info, .callKit).count == 7)
        #expect(CallTarget.defaultHandle(for: incoming.targetID).hasSuffix("@calltarget.invalid"))
        #expect(CallEngine.supportedPushFeatures.contains("preconnect"))
        #expect(AudioRouteKind(portType: .bluetoothHFP) == .bluetooth)
        _ = AudioRouteKind.active
        #expect(HostTargets.adapterTargets().count == 2)
        #expect(CallState.idle.isTerminal == false)

        system.deliverVoIPPushToken(Data([1, 2]))
        #expect(host.tokens == [Data([1, 2])])
        #expect(engine.voipPushToken == Data([1, 2]))
        #expect(system.presentConnectedCall(active, secondsElapsed: 10, botSpeaking: false))
        #expect(engine.repeatingCue == nil)
        _ = (engine.isAudioActivated, engine.isInterrupted, engine.isBotSpeaking, engine.audioDevices,
             engine.selectedAudioDeviceID, engine.isMuted)
        await engine.setPushToTalkActive(true)
        system.incomingReportResult = .filteredByFocus
        system.completesIncomingReportsLater = false
        system.outgoingStartError = nil
        system.suspendsOutgoingStarts = false
        _ = (system.reportedIncomingCalls, system.updatedCalls, system.ringReceipts, system.holdRequests,
             system.pendingOutgoingStartCount, system.voipPushToken)
        _ = system.reportedSupportsHolding(UUID())
        system.beginAudioInterruption()
        system.endAudioInterruption(shouldResume: true)
        system.deactivateAudioSession()
        system.resetProvider()
        system.setMutedFromSystem(UUID(), muted: true)
        await system.awaitPendingReconnect()
        _ = SimulatedCallSystem.RingReceipt(status: "answered", callID: UUID(), endpoint: roomConnection.url, bearer: "")
        _ = SimulatedCallSystem.HoldRequest(callID: UUID(), onHold: true)
        _ = SimulatedCallSystem.ReportedCall(id: UUID(), handle: "h", displayName: "d")
    }
}
