//
//  DeterministicHostTests.swift
//  ConduitCallEngineTests
//
//  Every feature a host tests, driven through `SimulatedCallSystem`'s public API
//  alone and without sleeping or polling: each step either returns once the
//  engine has applied it, or is followed by `awaitPendingWork()`,
//  `awaitRingPreparation()` or `awaitPendingReconnect()`. The engine keeps its
//  default timeouts and real-time sleep, so no timer runs out unless a test ends it
//  with `fireTimer(_:)`. Imports without `@testable`.
//

import Foundation
import Testing
import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
private final class Host: CallEngineDelegate {
    var target: CallTarget?
    private(set) var records: [CallRecord] = []
    private(set) var cues: [CallCue] = []

    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? { target }
    func callEngine(_ engine: CallEngine, cue: CallCue) { cues.append(cue) }
    func callEngine(_ engine: CallEngine, didFinish record: CallRecord) { records.append(record) }
}

@MainActor
struct DeterministicHostTests {
    private let system = SimulatedCallSystem()
    private let host = Host()
    private let engine: CallEngine
    private let targetID = UUID()
    private let connection = CallConnection(url: URL(string: "https://example.invalid/room")!, token: "t")
    private let statusURL = URL(string: "https://example.invalid/status")!
    /// The transports the target made, in order.
    private let made = Made()

    @MainActor
    private final class Made {
        var transports: [FakeTransport] = []
        var canConnectWhileRinging = false
        var last: FakeTransport { transports.last! }
    }

    init() {
        engine = CallEngine.simulated(system: system)
        engine.delegate = host
        engine.startPushRegistration()
        host.target = target()
    }

    private func target(preparation: RingPreparation = .none) -> CallTarget {
        let made = made
        let connection = connection
        return CallTarget(
            id: targetID,
            displayName: "Agent",
            handle: nil,
            ringPreparation: preparation,
            makeTransport: {
                let transport = FakeTransport()
                transport.canConnectWhileRinging = made.canConnectWhileRinging
                made.transports.append(transport)
                return transport
            },
            connect: { _ in connection }
        )
    }

    private func ring(_ callID: UUID, preconnect: String? = nil) {
        var push: [AnyHashable: Any] = [
            "target_id": targetID.uuidString,
            "call_id": callID.uuidString,
            "status_url": statusURL.absoluteString,
        ]
        push["preconnect"] = preconnect
        system.deliverPush(push) {}
    }

    /// An outgoing call, connected with CallKit's audio active.
    private func connectedCall() async throws -> (UUID, FakeTransport) {
        await engine.placeCall(target())
        await system.activateAudioSession()
        #expect(system.deliverTransportEvent(.connected))
        await system.awaitPendingWork()
        return (try #require(system.startedCallIDs.last), made.last)
    }

    // MARK: - Rings

    @Test(arguments: [RingPreparation.none, .credentials, .media])
    func aRingAtEachTierIsAnsweredIntoACall(_ tier: RingPreparation) async throws {
        made.canConnectWhileRinging = true
        host.target = target(preparation: tier)
        let callID = UUID()
        let preconnect: String? = switch tier {
        case .none: nil
        case .credentials: "credentials"
        case .media: "media"
        }
        ring(callID, preconnect: preconnect)

        let phase = await system.awaitRingPreparation()
        #expect(phase == [.none: .idle, .credentials: .credentialsReady, .media: .connecting][tier])
        if tier == .media { #expect(system.deliverTransportEvent(.connected)) }
        #expect(engine.state == .incomingRinging)

        await system.answerIncomingCall()
        await system.activateAudioSession()
        if tier != .media { #expect(system.deliverTransportEvent(.connected)) }
        await system.awaitPendingWork()

        #expect(engine.state.isConnected)
        #expect(made.transports.count == 1)
        #expect(made.last.isAudioAttached)
        #expect(made.last.isMicEnabled)
        #expect(made.last.sentSignals == [.connected])
        #expect(system.ringReceipts.map(\.status) == ["answered"])
    }

    @Test func aDeclinedRingIsRecordedAndItsTransportLeaves() async throws {
        made.canConnectWhileRinging = true
        host.target = target(preparation: .media)
        let callID = UUID()
        ring(callID, preconnect: "media")
        #expect(await system.awaitRingPreparation() == .connecting)

        system.endCallFromSystem(callID)
        await system.awaitPendingWork()

        #expect(engine.state == .ended(.declined))
        #expect(made.last.disconnectCount == 1)
        #expect(host.records.map(\.outcome) == [.declined])
        #expect(system.ringReceipts.map(\.status) == ["declined"])
    }

    @Test func aRingTimesOutWhenTheTestRunsItsTimerOut() async throws {
        ring(UUID())
        #expect(engine.state == .incomingRinging)

        #expect(system.fireTimer(.ringTimeout))

        #expect(engine.state == .idle)
        #expect(host.records.map(\.missedReason) == [.ringTimedOut])
        #expect(system.ringReceipts.map(\.status) == ["unanswered"])
        #expect(!system.fireTimer(.ringTimeout))
    }

    @Test func anAnsweredRingDoesNotTimeOut() async throws {
        ring(UUID())
        await system.answerIncomingCall()
        #expect(!system.fireTimer(.ringTimeout))
        #expect(engine.state == .connecting)
    }

    @Test func aCancelPushEndsAPreparedRing() async throws {
        made.canConnectWhileRinging = true
        host.target = target(preparation: .media)
        let callID = UUID()
        ring(callID, preconnect: "media")
        #expect(await system.awaitRingPreparation() == .connecting)

        system.deliverPush(["action": "cancel", "call_id": callID.uuidString]) {}
        await system.awaitPendingWork()

        #expect(engine.state == .idle)
        #expect(made.last.disconnectCount == 1)
        #expect(host.records.map(\.missedReason) == [.canceledByCaller])
    }

    // MARK: - Hold, interruption, activation, reset

    @Test func holdFromTheHostAndFromTheSystem() async throws {
        let (callID, transport) = try await connectedCall()

        await engine.setOnHold(true)
        await system.awaitPendingWork()
        #expect(engine.isOnHold)
        #expect(!transport.isMicEnabled)
        #expect(!transport.isAudioAttached)
        #expect(transport.sentSignals == [.connected, .held])

        #expect(await system.setHeldFromSystem(callID, onHold: false))
        #expect(!engine.isOnHold)
        #expect(transport.isMicEnabled)
        #expect(transport.isAudioAttached)
        #expect(transport.sentSignals == [.connected, .held, .resumed])
        #expect(Array(host.cues.suffix(2)) == [.moment(.held), .moment(.resumed)])
    }

    @Test func anInterruptionClosesAndReopensTheMic() async throws {
        let (_, transport) = try await connectedCall()

        system.beginAudioInterruption()
        await system.awaitPendingWork()
        #expect(engine.isInterrupted)
        #expect(!transport.isMicEnabled)

        system.endAudioInterruption(shouldResume: true)
        await system.awaitPendingWork()
        #expect(!engine.isInterrupted)
        #expect(transport.isMicEnabled)
    }

    @Test func aDeactivationDetachesAndAnActivationAttachesAgain() async throws {
        let (_, transport) = try await connectedCall()

        system.deactivateAudioSession()
        await system.awaitPendingWork()
        #expect(!engine.isAudioActivated)
        #expect(!transport.isAudioAttached)
        #expect(!transport.isMicEnabled)

        await system.activateAudioSession()
        #expect(transport.isAudioAttached)
        #expect(transport.isMicEnabled)
    }

    @Test func aMuteFromTheSystemClosesTheMic() async throws {
        let (callID, transport) = try await connectedCall()
        system.setMutedFromSystem(callID, muted: true)
        await system.awaitPendingWork()
        #expect(engine.isMuted)
        #expect(!transport.isMicEnabled)
    }

    @Test func aProviderResetFailsTheCallAndTearsItDown() async throws {
        let (_, transport) = try await connectedCall()
        system.resetProvider()
        await system.awaitPendingWork()
        #expect(engine.state == .failed(.unknown))
        #expect(transport.disconnectCount == 1)
        #expect(!transport.isAudioAttached)
    }

    @Test func anEndFromTheSystemTearsTheCallDown() async throws {
        let (callID, transport) = try await connectedCall()
        system.endCallFromSystem(callID)
        await system.awaitPendingWork()
        #expect(engine.state == .ended(.completed))
        #expect(transport.disconnectCount == 1)
    }

    // MARK: - Reconnection and timeouts

    @Test func aDroppedCallReconnectsWhenTheBackoffIsRunOut() async throws {
        let (_, transport) = try await connectedCall()
        #expect(system.deliverTransportEvent(.disconnected(reason: .networkDropped)))
        #expect(engine.state == .reconnecting(attempt: 1))

        #expect(system.fireTimer(.reconnectBackoff))
        await system.awaitPendingReconnect()
        #expect(transport.connectCount == 2)

        #expect(system.deliverTransportEvent(.connected))
        await system.awaitPendingWork()
        #expect(engine.state.isConnected)
        #expect(transport.isMicEnabled)
        #expect(host.cues.contains(.moment(.reconnected)))
    }

    @Test func aTransportThatDoesNotHealIsReconnectedWhenItsTimeoutIsRunOut() async throws {
        _ = try await connectedCall()
        #expect(system.deliverTransportEvent(.reconnecting))
        #expect(engine.state == .reconnecting(attempt: 0))

        #expect(system.fireTimer(.transportHealTimeout))
        #expect(engine.state == .reconnecting(attempt: 1))
    }

    @Test func anAttemptThatNeverConnectsCountsAsFailedWhenItsJoinTimeoutIsRunOut() async throws {
        _ = try await connectedCall()
        #expect(system.deliverTransportEvent(.disconnected(reason: .networkDropped)))
        #expect(system.fireTimer(.reconnectBackoff))
        await system.awaitPendingReconnect()

        #expect(system.fireTimer(.joinTimeout))
        #expect(engine.state == .reconnecting(attempt: 2))
    }

    @Test func anAgentThatNeverComesFailsTheCallWhenTheJoinTimeoutIsRunOut() async throws {
        await engine.placeCall(target())
        #expect(engine.state == .connecting)

        #expect(system.fireTimer(.joinTimeout))
        await system.awaitPendingWork()

        #expect(engine.state == .failed(.agentUnreachable))
        #expect(made.last.disconnectCount == 1)
        #expect(host.records.map(\.failureReason) == [.agentUnreachable])
    }

    @Test func aSignalThatFailedIsSentAgainWhenTheRetryIsRunOut() async throws {
        let (_, transport) = try await connectedCall()
        transport.signalDeliveries = [.failed]

        await engine.setOnHold(true)
        await system.awaitPendingWork()
        #expect(transport.sentSignals == [.connected, .held])

        #expect(system.fireTimer(.signalRetry))
        await system.awaitPendingWork()
        #expect(transport.sentSignals == [.connected, .held, .held])
        #expect(!system.fireTimer(.signalRetry))
    }

    @Test func noTimerRunsWithoutACall() {
        #expect(SimulatedCallSystem.EngineTimer.allCases.allSatisfy { !system.fireTimer($0) })
    }

    // MARK: - Simulator conveniences

    @Test func eachOutgoingCallGetsItsOwnCallKitID() async throws {
        let (first, _) = try await connectedCall()
        await engine.endCall()
        let (second, _) = try await connectedCall()
        #expect(first != second)
        #expect(system.startedCallIDs == [first, second])
    }

    @Test func aFakeTransportCanReportConnectedByItself() async throws {
        let transport = FakeTransport(reportsConnectedAfter: .zero)
        try await transport.connect(connection)
        var events = transport.events.makeAsyncIterator()
        #expect(await events.next() == .connected)
    }

    @Test func connectedIsConnectedAndReconnectingIsNot() {
        #expect(CallState.connected(since: .now).isConnected)
        #expect(!CallState.reconnecting(attempt: 0).isConnected)
        #expect(!CallState.connecting.isConnected)
    }
}
