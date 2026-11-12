//
//  SimulatedEngineTests.swift
//  ConduitCallEngineTests
//
//  Drives a `CallEngine` the way a host does in its own tests: created by
//  `CallEngine.simulated` and steered only through `SimulatedCallSystem`'s public
//  API. Imports without `@testable` and uses no `package` symbol, so anything
//  these tests need is available to a host.
//

import Foundation
import Testing
import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
private final class RecordingHost: CallEngineDelegate {
    var targets: [UUID: CallTarget] = [:]
    var bearer: String?
    private(set) var states: [CallState] = []
    private(set) var records: [CallRecord] = []
    private(set) var cues: [CallCue] = []

    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? {
        targets[call.targetID]
    }

    func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState) {
        states.append(new)
    }

    func callEngine(_ engine: CallEngine, cue: CallCue) {
        cues.append(cue)
    }

    func callEngine(_ engine: CallEngine, didFinish record: CallRecord) {
        records.append(record)
    }

    func callEngine(_ engine: CallEngine, ringStatusBearerForTarget id: UUID) -> String? {
        bearer
    }
}

private struct StartRejected: Error {}

@MainActor
struct SimulatedEngineTests {
    private let system = SimulatedCallSystem()
    private let host = RecordingHost()
    private let transport = FakeTransport()
    private let engine: CallEngine
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let targetID = UUID()
    private let connection = CallConnection(url: URL(string: "https://example.invalid/room")!, token: "room-token")
    private let statusURL = URL(string: "https://example.invalid/status")!

    init() {
        let now = now
        // A sleep that returns at once would also end every ring, and every wait for
        // the agent after a connect, at once, so this suite runs without those
        // timeouts; the timeout tests bring their own sleep.
        engine = CallEngine.simulated(
            configuration: CallEngineConfiguration(ringTimeout: nil, joinTimeout: nil),
            system: system,
            now: { now },
            sleep: { _ in }
        )
        engine.delegate = host
        host.targets[targetID] = target
        engine.startPushRegistration()
    }

    private var target: CallTarget {
        let transport = transport
        let connection = connection
        return CallTarget(
            id: targetID,
            displayName: "Echo",
            handle: "echo@example.invalid",
            makeTransport: { transport },
            connect: { _ in connection }
        )
    }

    private func connectedOutgoingCall() async throws -> UUID {
        await engine.placeCall(target)
        #expect(system.deliverTransportEvent(.connected))
        return try #require(system.startedCallIDs.first)
    }

    /// Delivers a push for this suite's target and reports whether PushKit's
    /// completion ran.
    private func ring(callID: UUID) -> Bool {
        var completed = false
        system.deliverPush([
            "target_id": targetID.uuidString,
            "call_id": callID.uuidString,
            "status_url": statusURL.absoluteString,
        ]) { completed = true }
        return completed
    }

    /// Yields the main actor until `condition` holds or the budget runs out, for
    /// effects the engine applies on a later main-actor turn.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            await Task.yield()
        }
    }

    // MARK: - Outgoing

    @Test func outgoingCallConnects() async throws {
        await engine.placeCall(target)
        #expect(engine.state == .connecting)
        #expect(transport.connectCount == 1)
        #expect(transport.lastConnection == connection)

        #expect(system.deliverTransportEvent(.connected))

        #expect(engine.state == .connected(since: now))
        #expect(system.startedCallIDs.count == 1)
        #expect(host.states == [.dialing, .connecting, .connected(since: now)])
    }

    @Test func cuesReachTheHost() async throws {
        await engine.placeCall(target)
        #expect(engine.repeatingCue == .connecting)
        #expect(system.deliverTransportEvent(.connected))
        #expect(system.deliverTransportEvent(.disconnected(reason: .networkDropped)))
        #expect(engine.repeatingCue == .retrying)
        await engine.endCall()

        #expect(host.cues == [
            .start(.connecting), .stop, .moment(.connected),
            .moment(.connectionLost), .start(.retrying), .stop,
        ])
        #expect(engine.repeatingCue == nil)
    }

    @Test func rejectedOutgoingStartFailsTheCall() async {
        system.outgoingStartError = StartRejected()

        await engine.placeCall(target)

        #expect(engine.state == .failed(.unknown))
        #expect(transport.connectCount == 0)
        #expect(host.records.map(\.outcome) == [.failed])
    }

    @Test func transportEventsAreDroppedWithoutALiveTransport() async throws {
        #expect(!system.deliverTransportEvent(.disconnected(reason: .botLeft)))
        #expect(engine.state == .idle)
        #expect(host.records.isEmpty)

        _ = try await connectedOutgoingCall()
        await engine.endCall()

        #expect(!system.deliverTransportEvent(.connected))
        #expect(engine.state == .ended(.completed))
    }

    // MARK: - Incoming

    @Test func inboundRingIsAnsweredAndConnects() async {
        host.bearer = "receipt-bearer"
        let callID = UUID()

        #expect(ring(callID: callID))

        #expect(engine.state == .incomingRinging)
        #expect(system.reportedIncomingCalls == [
            SimulatedCallSystem.ReportedCall(
                id: callID,
                handle: CallTarget.defaultHandle(for: targetID),
                displayName: "Unknown"
            ),
        ])
        #expect(system.updatedCalls == [
            SimulatedCallSystem.ReportedCall(id: callID, handle: "echo@example.invalid", displayName: "Echo"),
        ])

        await system.answerIncomingCall()

        #expect(engine.state == .connecting)
        #expect(transport.connectCount == 1)
        #expect(system.ringReceipts == [
            SimulatedCallSystem.RingReceipt(status: "answered", callID: callID, endpoint: statusURL, bearer: "receipt-bearer"),
        ])

        #expect(system.deliverTransportEvent(.connected))
        #expect(engine.state == .connected(since: now))
    }

    @Test func anUnansweredRingTimesOutOnTheHostsClock() async throws {
        let system = SimulatedCallSystem()
        let sleeper = ManualSleeper()
        let engine = CallEngine.simulated(system: system, sleep: { await sleeper.sleep($0) })
        engine.delegate = host
        engine.startPushRegistration()
        let callID = UUID()
        system.deliverPush([
            "target_id": targetID.uuidString,
            "call_id": callID.uuidString,
            "status_url": statusURL.absoluteString,
            "ring_timeout": "30",
        ]) {}
        await settle { sleeper.pendingCount == 1 }
        #expect(sleeper.requested == [.seconds(30)])

        sleeper.wakeAll()
        await settle { engine.state == .idle }

        #expect(engine.state == .idle)
        #expect(host.records.map(\.missedReason) == [.ringTimedOut])
        #expect(host.records.first?.missedReason?.reachedUser == true)
        #expect(system.ringReceipts.map(\.status) == ["unanswered"])
        #expect(host.cues.isEmpty)
    }

    @Test func aCancelPushEndsTheRing() async throws {
        let callID = UUID()
        #expect(ring(callID: callID))
        var completed = false

        system.deliverPush(["action": "cancel", "call_id": callID.uuidString]) { completed = true }

        #expect(completed)
        #expect(engine.state == .idle)
        #expect(system.reportedIncomingCalls.map(\.id) == [callID, callID])
        #expect(host.records.map(\.missedReason) == [.canceledByCaller])
        #expect(system.ringReceipts.map(\.status) == ["canceled"])
    }

    @Test func theEngineAdvertisesItsPushFeatures() {
        #expect(CallEngine.supportedPushFeatures.isSuperset(of: ["cancel", "ring_timeout"]))
    }

    @Test func ringFilteredByFocusIsRecordedAsMissed() {
        system.incomingReportResult = .filteredByFocus
        let callID = UUID()

        #expect(ring(callID: callID))

        #expect(engine.state == .idle)
        #expect(host.records.map(\.outcome) == [.noAnswer])
        #expect(host.records.map(\.missedReason) == [.filteredByFocus])
        #expect(system.ringReceipts.map(\.status) == ["suppressed_by_focus"])
    }

    @Test func pushDuringALiveCallIsEndedAsBusy() async throws {
        _ = try await connectedOutgoingCall()
        let callID = UUID()

        #expect(ring(callID: callID))

        #expect(engine.state == .connected(since: now))
        #expect(transport.connectCount == 1)
        #expect(host.records.map(\.missedReason) == [.busy])
        #expect(system.ringReceipts.map(\.status) == ["busy"])
        #expect(system.ringReceipts.map(\.callID) == [callID])
    }

    // MARK: - System actions

    @Test func endFromTheSystemEndsTheCall() async throws {
        let callID = try await connectedOutgoingCall()

        system.endCallFromSystem(callID)

        #expect(engine.state == .ended(.completed))
        #expect(host.records.map(\.outcome) == [.completed])
        await settle { transport.disconnectCount == 1 }
        #expect(transport.disconnectCount == 1)
    }

    @Test func providerResetFailsTheCall() async throws {
        _ = try await connectedOutgoingCall()

        system.resetProvider()

        #expect(engine.state == .failed(.unknown))
        #expect(host.records.map(\.failureReason) == [.unknown])
        await settle { transport.disconnectCount == 1 }
        #expect(transport.disconnectCount == 1)
    }

    @Test func muteFromTheSystemTurnsTheMicOff() async throws {
        let callID = try await connectedOutgoingCall()
        await system.activateAudioSession()
        #expect(transport.isMicEnabled)

        system.setMutedFromSystem(callID, muted: true)

        #expect(engine.isMuted)
        await settle { !transport.isMicEnabled }
        #expect(!transport.isMicEnabled)
    }

    // MARK: - Audio session

    @Test func activationAttachesTheTransportAndEnablesTheMic() async throws {
        _ = try await connectedOutgoingCall()
        #expect(!transport.isAudioAttached)
        #expect(!transport.isMicEnabled)

        await system.activateAudioSession()

        #expect(engine.isAudioActivated)
        #expect(transport.isAudioAttached)
        #expect(transport.isMicEnabled)

        system.deactivateAudioSession()

        #expect(!engine.isAudioActivated)
        await settle { !transport.isAudioAttached }
        #expect(!transport.isAudioAttached)
    }

    @Test func interruptionPausesAndResumesTheMic() async throws {
        _ = try await connectedOutgoingCall()
        await system.activateAudioSession()

        system.beginAudioInterruption()

        #expect(engine.isInterrupted)
        await settle { !transport.isMicEnabled }
        #expect(!transport.isMicEnabled)

        system.endAudioInterruption(shouldResume: true)

        #expect(!engine.isInterrupted)
        await settle { transport.isMicEnabled }
        #expect(transport.isMicEnabled)
    }

    // MARK: - Hold

    @Test func holdFromTheSystemHoldsAndResumesTheCall() async throws {
        let callID = try await connectedOutgoingCall()
        await system.activateAudioSession()
        #expect(system.reportedSupportsHolding(callID) == true)

        #expect(await system.setHeldFromSystem(callID, onHold: true))
        #expect(engine.isOnHold)
        #expect(!transport.isMicEnabled)
        #expect(!transport.isAudioAttached)
        #expect(transport.sentSignals == [.held])

        #expect(await system.setHeldFromSystem(callID, onHold: false))
        #expect(!engine.isOnHold)
        #expect(transport.isAudioAttached)
        #expect(transport.isMicEnabled)
        #expect(transport.sentSignals == [.held, .resumed])
        #expect(Array(host.cues.suffix(2)) == [.moment(.held), .moment(.resumed)])
    }

    @Test func theHostsHoldGoesThroughCallKit() async throws {
        let callID = try await connectedOutgoingCall()

        await engine.setOnHold(true)

        #expect(system.holdRequests == [SimulatedCallSystem.HoldRequest(callID: callID, onHold: true)])
        #expect(engine.isOnHold)
    }

    @Test func holdingCanBeTurnedOff() async throws {
        let system = SimulatedCallSystem()
        let engine = CallEngine.simulated(
            configuration: CallEngineConfiguration(ringTimeout: nil, supportsHolding: false, joinTimeout: nil),
            system: system,
            sleep: { _ in }
        )
        await engine.placeCall(target)
        let callID = try #require(system.startedCallIDs.first)

        #expect(system.reportedSupportsHolding(callID) == false)
        #expect(!(await system.setHeldFromSystem(callID, onHold: true)))
        #expect(!engine.isOnHold)
    }

    // MARK: - Screenshot projection

    @Test func connectedProjectionShowsOnASimulatedEngine() {
        let call = ActiveCall(targetID: targetID, displayName: "Echo", direction: .outgoing)

        #expect(system.presentConnectedCall(call, secondsElapsed: 10, botSpeaking: true))

        #expect(engine.state == .connected(since: now.addingTimeInterval(-10)))
        #expect(engine.activeCall == call)
        #expect(engine.isBotSpeaking)
        #expect(host.states.isEmpty)
    }

    @Test func connectedProjectionNeedsAnAttachedEngine() {
        let call = ActiveCall(targetID: targetID, displayName: "Echo", direction: .outgoing)

        #expect(!SimulatedCallSystem().presentConnectedCall(call))
    }
}
