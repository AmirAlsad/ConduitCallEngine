//
//  HostMessageTests.swift
//  ConduitCallEngineTests
//
//  The host's own messages to its agent (`CallEngine.send(_:)`) and what the agent
//  sends the host (server messages, its output text, the user's transcript): sent
//  only when a signal could be, once, never with a reserved type and never to a
//  ring's transport before the answer; delivered to the delegate only while a call
//  is in progress, never during a ring, and not once the call has ended. Driven
//  through `SimulatedCallSystem`'s public API alone, as a host's tests would be.
//

import Foundation
import Testing
import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
private final class MessageHost: CallEngineDelegate {
    var target: CallTarget?
    private(set) var serverMessages: [Data] = []
    private(set) var outputs: [BotOutput] = []
    private(set) var transcripts: [UserTranscript] = []
    var received: Int { serverMessages.count + outputs.count + transcripts.count }

    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? { target }
    func callEngine(_ engine: CallEngine, didReceiveServerMessage data: Data) { serverMessages.append(data) }
    func callEngine(_ engine: CallEngine, didReceiveBotOutput output: BotOutput) { outputs.append(output) }
    func callEngine(_ engine: CallEngine, didReceiveUserTranscript transcript: UserTranscript) {
        transcripts.append(transcript)
    }
}

@MainActor
struct HostMessageTests {
    private let system = SimulatedCallSystem()
    private let host = MessageHost()
    private let engine: CallEngine
    private let targetID = UUID()
    private let connection = CallConnection(url: URL(string: "https://example.invalid/room")!, token: "t")
    private let made = Made()

    @MainActor
    private final class Made {
        var transports: [FakeTransport] = []
        var canConnectWhileRinging = false
        var last: FakeTransport { transports.last! }
    }

    private let ping = CallMessage(type: "ping")
    private let serverMessage = TransportEvent.serverMessage(Data(#"{"kind":"note","n":1}"#.utf8))
    private let output = BotOutput(text: "Hello there.", isSpoken: true, aggregatedBy: "sentence")
    private let transcript = UserTranscript(text: "Hi", isFinal: true)

    init() {
        engine = CallEngine.simulatedForTesting(
            configuration: CallEngineConfiguration(supportsHolding: true),
            system: system
        )
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

    /// An outgoing call, connected with CallKit's audio active.
    private func connectedCall() async throws -> (UUID, FakeTransport) {
        await engine.placeCall(target())
        await system.activateAudioSession()
        #expect(system.deliverTransportEvent(.connected))
        await system.awaitPendingWork()
        return (try #require(system.startedCallIDs.last), made.last)
    }

    private func deliverAgentEvents() {
        system.deliverTransportEvent(serverMessage)
        system.deliverTransportEvent(.botOutput(output))
        system.deliverTransportEvent(.userTranscript(transcript))
    }

    // MARK: - Sending

    @Test func aMessageWithNoCallIsNotSent() async {
        #expect(await engine.send(ping) == .failed)
        #expect(made.transports.isEmpty)
    }

    @Test func aMessageOnAConnectedCallIsSentOnceAndItsResultReturned() async throws {
        let (_, transport) = try await connectedCall()
        let payload = try #require(CallMessage(type: "set-context", data: Data(#"{"screen":"home"}"#.utf8)))

        #expect(await engine.send(payload) == .sent)
        transport.messageDeliveries = [.failed, .unsupported]
        #expect(await engine.send(ping) == .failed)
        #expect(await engine.send(ping) == .unsupported)
        await system.awaitPendingWork()

        // Never queued or sent again, and kept apart from the engine's own signals.
        #expect(transport.sentMessages == [payload, ping, ping])
        #expect(transport.sentSignals == [.connected])
        #expect(transport.commands.filter { if case .message = $0 { true } else { false } }.count == 3)
    }

    @Test func aMessageOnAHeldCallIsSent() async throws {
        let (callID, transport) = try await connectedCall()
        #expect(await system.setHeldFromSystem(callID, onHold: true))

        #expect(await engine.send(ping) == .sent)
        #expect(transport.sentMessages == [ping])
    }

    @Test(arguments: Array(CallMessage.reservedTypes) + [""])
    func aMessageWithAReservedTypeIsRefused(_ type: String) async throws {
        let (_, transport) = try await connectedCall()

        #expect(await engine.send(CallMessage(type: type)) == .failed)
        #expect(transport.sentMessages.isEmpty)
    }

    @Test func theReservedTypesAreTheEnginesOwn() {
        #expect(CallMessage.reservedTypes == ["end-call", "call-connected", "call-held", "call-resumed"])
    }

    @Test func aMessageIsSentOnceTheTransportHasJoinedBeforeTheAgentIsThere() async throws {
        await engine.placeCall(target())
        let transport = made.last
        #expect(engine.state == .connecting) // joined, waiting for the agent

        #expect(await engine.send(ping) == .sent)
        #expect(transport.sentMessages == [ping])
    }

    @Test func aMessageWhileTheTransportIsStillJoiningIsNotSent() async throws {
        let pending = FakeTransport()
        pending.suspendConnect = true
        let target = CallTarget(
            id: targetID, displayName: "Agent", handle: nil,
            makeTransport: { pending }, connect: { [connection] _ in connection }
        )
        let placing = Task { await engine.placeCall(target) }
        await waitUntil { pending.connectCount == 1 }

        #expect(await engine.send(ping) == .failed)
        #expect(pending.sentMessages.isEmpty)
        pending.releaseConnect()
        await placing.value
    }

    @Test func aMessageWhileReconnectingIsNotSent() async throws {
        let (_, transport) = try await connectedCall()
        #expect(system.deliverTransportEvent(.disconnected(reason: .networkDropped)))
        #expect(engine.state == .reconnecting(attempt: 1))

        #expect(await engine.send(ping) == .failed)
        #expect(transport.sentMessages.isEmpty)
    }

    @Test func aMessageAfterTheCallEndedIsNotSent() async throws {
        let (callID, transport) = try await connectedCall()
        system.endCallFromSystem(callID)
        await system.awaitPendingWork()

        #expect(await engine.send(ping) == .failed)
        #expect(transport.sentMessages.isEmpty)
    }

    // MARK: - Receiving

    @Test func whatTheAgentSendsReachesTheDelegateDuringTheCall() async throws {
        _ = try await connectedCall()

        deliverAgentEvents()

        #expect(host.serverMessages == [Data(#"{"kind":"note","n":1}"#.utf8)])
        #expect(host.outputs == [output])
        #expect(host.transcripts == [transcript])
    }

    @Test func whatTheAgentSendsWhileConnectingReachesTheDelegate() async throws {
        await engine.placeCall(target())
        #expect(engine.state == .connecting)

        deliverAgentEvents()

        #expect(host.received == 3)
    }

    @Test func whatTheAgentSendsOnceTheCallEndedIsDropped() async throws {
        let (callID, _) = try await connectedCall()
        system.endCallFromSystem(callID)
        await system.awaitPendingWork()
        #expect(engine.state == .ended(.completed))

        deliverAgentEvents()

        #expect(host.received == 0)
    }

    @Test func whatTheAgentSendsAfterAResetIsDropped() async throws {
        let (callID, _) = try await connectedCall()
        system.endCallFromSystem(callID)
        engine.reset()

        deliverAgentEvents()

        #expect(host.received == 0)
    }

    @Test func emittedEventsReachTheDelegateThroughTheTransportsStream() async throws {
        let (_, transport) = try await connectedCall()

        transport.emit(.userTranscript(transcript))
        await waitUntil { !host.transcripts.isEmpty }

        #expect(host.transcripts == [transcript])
    }

    // MARK: - A pre-connected ring

    @Test func nothingReachesOrLeavesAPreconnectedRingBeforeTheAnswer() async throws {
        made.canConnectWhileRinging = true
        host.target = target(preparation: .media)
        let callID = UUID()
        system.deliverPush([
            "target_id": targetID.uuidString,
            "call_id": callID.uuidString,
            "preconnect": "media",
        ]) {}
        #expect(await system.awaitRingPreparation() == .connecting)
        #expect(system.deliverTransportEvent(.connected))
        #expect(engine.ringPreparationPhase == .ready)
        let transport = made.last

        #expect(await engine.send(ping) == .failed)
        deliverAgentEvents()
        #expect(transport.sentMessages.isEmpty)
        #expect(host.received == 0)
        #expect(engine.ringPreparationPhase == .ready) // the events changed nothing about the ring

        await system.answerIncomingCall()
        await system.activateAudioSession()
        await system.awaitPendingWork()
        #expect(engine.state.isConnected)

        deliverAgentEvents()
        #expect(await engine.send(ping) == .sent)
        #expect(host.received == 3)
        #expect(transport.sentMessages == [ping])
    }
}
