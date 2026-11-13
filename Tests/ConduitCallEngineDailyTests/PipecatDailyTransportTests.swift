//
//  PipecatDailyTransportTests.swift
//  ConduitCallEngineDailyTests
//
//  The adapter over a real `PipecatClient` whose Daily transport is replaced by a
//  fake, because Daily's WebRTC audio unit aborts in the simulator. Covers teardown
//  (the end-call signal goes out before the leave, and the client is released after
//  it, without touching a client a later connect created) and the RTVI client
//  messages that carry call-control signals. Audio and the real Daily call client
//  are verified on device.
//

import Foundation
import Testing
import ConduitCallEngine
import ConduitCallEngineTesting
import PipecatClientIOS
@testable import ConduitCallEngineDaily

@MainActor
struct PipecatDailyTransportTests {
    private final class Clients {
        var made: [FakePipecatTransport] = []
        var controls: [FakeDailyCallControl] = []
        var joinOnConnect = true
        var refusesBeforeJoin = false
        var pathMonitors: [FakePathMonitor] = []
    }

    /// Everything the transport has emitted, in order.
    private final class EventLog {
        var events: [TransportEvent] = []
    }

    private let clients = Clients()
    private let connection = CallConnection(url: URL(string: "https://example.daily.co/room")!, token: "t")

    /// The end-call flush returns at once unless the test brings a `sleep`; the
    /// attach's bound never runs out by itself.
    private func makeTransport(
        sleep: @escaping @MainActor (Duration) async -> Void = { _ in }
    ) -> PipecatDailyTransport {
        PipecatDailyTransport(
            makePipecatTransport: { [clients] in
                let fake = FakePipecatTransport()
                fake.joinsOnConnect = clients.joinOnConnect
                clients.made.append(fake)
                return fake
            },
            makePathMonitor: { [clients] in
                let monitor = FakePathMonitor()
                clients.pathMonitors.append(monitor)
                return monitor
            },
            makeCallControl: { [clients] transport in
                let control = FakeDailyCallControl(transport: transport as! FakePipecatTransport)
                control.refusesBeforeJoin = clients.refusesBeforeJoin
                clients.controls.append(control)
                return control
            },
            readOutputPort: { nil },
            sleep: sleep,
            attachBoundSleep: { try? await SimulatedCallSystem.sleepUntilCancelled($0) }
        )
    }

    private func clientsJoinOnConnect(_ joins: Bool) {
        clients.joinOnConnect = joins
    }

    private func record(_ transport: PipecatDailyTransport) -> EventLog {
        let log = EventLog()
        Task { @MainActor in
            for await event in transport.events { log.events.append(event) }
        }
        return log
    }

    /// Lets the main-actor hops queued by SDK callbacks and path deliveries run.
    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// The events that steer the engine, without `.connecting` and media chatter.
    private func callEvents(_ log: EventLog) -> [TransportEvent] {
        log.events.filter {
            switch $0 {
            case .connected, .reconnecting, .disconnected, .error: true
            default: false
            }
        }
    }

    /// A connected call whose device lost its network path, so the transport has
    /// reported `.reconnecting` and Daily is healing inside its SDK. The Pipecat
    /// client stays `.ready` throughout, as it does on a device.
    private func callInterruptedWhileDailyHeals(
        _ transport: PipecatDailyTransport
    ) async throws -> (FakePipecatTransport, FakePathMonitor) {
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)
        fake.becomeReady()
        await drain()
        let monitor = try #require(clients.pathMonitors.first)
        monitor.deliver(true) // the monitor's initial delivery
        monitor.deliver(false)
        await drain()
        return (fake, monitor)
    }

    @Test func adapterIsACallTransport() {
        let type: any CallTransport.Type = PipecatDailyTransport.self
        #expect(type == PipecatDailyTransport.self)
    }

    @Test func disconnectSendsTheEndCallThenLeavesThenReleasesTheClient() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)
        fake.becomeReady()

        await transport.disconnect()

        #expect(fake.calls == ["connect", "send client-message", "disconnect", "release"])
    }

    /// A joined call whose bot never became ready still has a bot that can hear the
    /// app message, and would otherwise wait out its grace window.
    @Test func disconnectSendsTheEndCallWhenJoinedButTheBotWasNeverReady() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)

        await transport.disconnect()

        #expect(fake.calls == ["connect", "send client-message", "disconnect", "release"])
    }

    @Test func disconnectSendsNoEndCallBeforeTheCallIsJoined() async throws {
        clientsJoinOnConnect(false)
        let transport = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)

        await transport.disconnect()

        #expect(fake.calls == ["connect", "disconnect", "release"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aReleasedClientNoLongerReachesTheTransport() async throws {
        let transport = makeTransport()
        let log = record(transport)
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)
        fake.becomeReady()
        await transport.disconnect()
        await drain()
        let eventsAtDisconnect = log.events.count

        fake.delegate?.onBotStartedSpeaking()
        fake.delegate?.onTransportStateChanged(state: .ready)
        await drain()

        #expect(fake.delegate == nil)
        #expect(log.events.count == eventsAtDisconnect)
    }

    @Test func aConnectAfterDisconnectUsesAFreshClient() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        await transport.disconnect()

        try await transport.connect(connection)

        #expect(clients.made.count == 2)
        #expect(clients.made.last?.calls == ["connect"])
    }

    /// The release that ends one disconnect must not reach the client of a connect
    /// that started while that disconnect was still flushing its end-call signal.
    @Test(.timeLimit(.minutes(1)))
    func aConnectDuringTheDisconnectKeepsItsClient() async throws {
        let flush = HandSleeper()
        let transport = makeTransport(sleep: flush.sleep)
        try await transport.connect(connection)
        let first = try #require(clients.made.first)
        first.becomeReady()

        let disconnecting = Task { await transport.disconnect() }
        await waitUntil { flush.pendingCount == 1 } // flushing the end-call signal
        #expect(first.calls.last == "send client-message")
        try await transport.connect(connection)
        flush.wakeAll()
        await disconnecting.value

        let second = try #require(clients.made.last)
        #expect(clients.made.count == 2)
        #expect(first.calls.last == "release")
        #expect(second.calls == ["connect"])
        #expect(second.delegate != nil)
    }

    // MARK: - The engine's connect while Daily is still healing

    /// The engine's own reconnect, after Daily has healed for 30 s without a word,
    /// calls `connect` on a session that is still up. The attempt cannot join (the
    /// session is still in the call), but it must not stop the reporting that tells
    /// the engine when Daily's heal ends.
    @Test(.timeLimit(.minutes(1)))
    func aConnectWhileDailyHealsKeepsTheHealReportable() async throws {
        let transport = makeTransport()
        let log = record(transport)
        let (fake, monitor) = try await callInterruptedWhileDailyHeals(transport)
        #expect(callEvents(log) == [.connected, .reconnecting])

        await #expect(throws: TransportError.self) { try await transport.connect(connection) }
        monitor.deliver(true)
        await drain()

        #expect(callEvents(log) == [.connected, .reconnecting, .connected])
        #expect(fake.calls == ["connect"])
    }

    /// The network came back and Daily healed, but the engine's reconnect was already
    /// under way: the session is usable, so the attempt reports it connected rather
    /// than failing or leaving the call.
    @Test(.timeLimit(.minutes(1)))
    func aConnectAfterDailyHealedReportsConnected() async throws {
        let transport = makeTransport()
        let log = record(transport)
        let (fake, monitor) = try await callInterruptedWhileDailyHeals(transport)
        monitor.deliver(true)
        await drain()

        try await transport.connect(connection)
        await drain()

        #expect(callEvents(log) == [.connected, .reconnecting, .connected, .connected])
        #expect(fake.calls == ["connect"])
    }

    /// Daily gives up after the engine's attempt was refused: the drop is still reported,
    /// and the next attempt joins afresh.
    @Test(.timeLimit(.minutes(1)))
    func aDropAfterARefusedConnectIsReportedAndTheNextConnectJoins() async throws {
        let transport = makeTransport()
        let log = record(transport)
        let (fake, _) = try await callInterruptedWhileDailyHeals(transport)
        await #expect(throws: TransportError.self) { try await transport.connect(connection) }

        fake.setState(state: .disconnected) // Daily left the call
        await drain()
        #expect(callEvents(log) == [.connected, .reconnecting, .disconnected(reason: .networkDropped)])

        try await transport.connect(connection)
        fake.becomeReady()
        await drain()
        #expect(fake.calls == ["connect", "connect"])
        #expect(callEvents(log).last == .connected)
    }

    /// A join whose bot never got ready is not healing anything: the engine connects
    /// again only once it gave up on it. The session is left without the end-call
    /// signal (the call goes on, possibly in the same room) and released, and a new
    /// client joins; nothing the old one reports reaches the engine any more.
    @Test(.timeLimit(.minutes(1)))
    func aConnectWhileTheBotIsNotReadyTakesTheSessionOver() async throws {
        let transport = makeTransport()
        let log = record(transport)
        try await transport.connect(connection)
        let stale = try #require(clients.made.first)

        try await transport.connect(connection)
        stale.becomeReady() // a late bot-ready from the room the call left
        await drain()
        #expect(callEvents(log).isEmpty)

        let fresh = try #require(clients.made.last)
        fresh.becomeReady()
        await drain()

        #expect(clients.made.count == 2)
        #expect(stale.calls == ["connect", "disconnect", "release"])
        #expect(stale.delegate == nil)
        #expect(fresh.calls == ["connect"])
        #expect(callEvents(log) == [.connected])
    }

    /// The host's teardown while the take-over is still leaving the old session: the
    /// new session is the one it ends, and the connect does not join.
    @Test(.timeLimit(.minutes(1)))
    func aDisconnectDuringATakeOverEndsItWithoutAJoin() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        let stale = try #require(clients.made.first)
        stale.leaveSuspends = true

        let takingOver = Task { try await transport.connect(connection) }
        await waitUntilLeaving(stale)
        await transport.disconnect()
        stale.finishLeaving()

        await #expect(throws: TransportError.self) { try await takingOver.value }
        let fresh = try #require(clients.made.last)
        #expect(clients.made.count == 2)
        #expect(fresh.calls == ["disconnect", "release"])
    }

    private func waitUntilLeaving(
        _ fake: FakePipecatTransport,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await waitUntil(sourceLocation: sourceLocation) { fake.calls.contains("disconnect") }
    }

    // MARK: - Call-control signals

    /// The RTVI client message last handed to Daily, decoded.
    private func lastMessage(_ fake: FakePipecatTransport) throws -> [String: Any] {
        let data = try #require(fake.sentMessages.last)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test(arguments: CallSignal.allCases)
    func aSignalIsSentAsAnRTVIClientMessage(signal: CallSignal) async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)
        fake.becomeReady()

        await transport.send(signal)

        let message = try lastMessage(fake)
        #expect(message["label"] as? String == "rtvi-ai")
        #expect(message["type"] as? String == "client-message")
        #expect((message["id"] as? String)?.count == 8)
        let data = try #require(message["data"] as? [String: Any])
        #expect(data["t"] as? String == signal.rawValue)
        #expect(data["d"] is NSNull)
    }

    /// Pipecat's `sendClientMessage` refuses until the bot is ready, which on a call
    /// joined while ringing can be after the answer the signal reports.
    @Test func aSignalIsSentOnceJoinedEvenIfTheBotIsNotReady() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)

        await transport.send(.connected)

        #expect(fake.calls == ["connect", "send client-message"])
    }

    @Test func aSignalBeforeTheCallIsJoinedIsDropped() async throws {
        clientsJoinOnConnect(false)
        let transport = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)

        await transport.send(.held)

        #expect(fake.calls == ["connect"])
    }

    @Test func aSignalAfterDisconnectIsDropped() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)
        fake.becomeReady()
        await transport.disconnect()

        await transport.send(.held)

        #expect(fake.calls == ["connect", "send client-message", "disconnect", "release"])
        #expect(clients.made.count == 1)
    }

    /// The engine sends the call's current state again when a signal did not leave
    /// the device, so the adapter must say which it was.
    @Test func aSignalReportsWhetherDailySentIt() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        let control = try #require(clients.controls.first)
        try #require(clients.made.first).becomeReady()

        #expect(await transport.send(.held) == .sent)
        control.appMessageError = FakeDailyCallControl.Refused()
        #expect(await transport.send(.resumed) == .failed)
        await transport.disconnect()
        #expect(await transport.send(.resumed) == .failed)
    }

    @Test func aSignalBeforeTheCallIsJoinedFails() async throws {
        clientsJoinOnConnect(false)
        let transport = makeTransport()
        try await transport.connect(connection)

        #expect(await transport.send(.connected) == .failed)
    }

    @Test func aRepeatedSignalIsSentEachTime() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)
        fake.becomeReady()

        await transport.send(.held)
        await transport.send(.held)

        #expect(fake.calls == ["connect", "send client-message", "send client-message"])
    }

    // MARK: - Being held

    /// A connected call, attached as after CallKit's activation.
    private func attachedCall(_ transport: PipecatDailyTransport) async throws -> FakePipecatTransport {
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)
        fake.becomeReady()
        await transport.attachAudioSession()
        await drain()
        return fake
    }

    @Test func aCallThatIsNeverDetachedKeepsDailysSubscription() async throws {
        let transport = makeTransport()
        await transport.attachAudioSession()

        let fake = try await attachedCall(transport)

        #expect(fake.calls == ["connect"])
    }

    @Test func aHoldUnsubscribesTheAgentAudioAndAResumeSubscribesIt() async throws {
        let transport = makeTransport()
        let fake = try await attachedCall(transport)

        await transport.setMicEnabled(false)
        await transport.detachAudioSession()
        await drain()
        #expect(fake.calls == ["connect", "agent audio unsubscribed"])

        await transport.attachAudioSession()
        await drain()
        #expect(fake.calls == ["connect", "agent audio unsubscribed", "agent audio subscribed"])
    }

    /// A hold followed by CallKit's deactivation detaches twice.
    @Test func aSecondDetachChangesNothing() async throws {
        let transport = makeTransport()
        let fake = try await attachedCall(transport)

        await transport.detachAudioSession()
        await drain()
        await transport.detachAudioSession()
        await drain()

        #expect(fake.calls == ["connect", "agent audio unsubscribed"])
    }

    @Test func aQuickHoldAndResumeEndsWithTheAgentAudible() async throws {
        let transport = makeTransport()
        let fake = try await attachedCall(transport)
        let control = try #require(clients.controls.first)
        control.suspensions = 5

        await transport.detachAudioSession()
        await Task.yield()
        await transport.attachAudioSession()
        await drain()

        #expect(fake.calls.last == "agent audio subscribed")
    }

    /// A held call that drops reconnects on the same client; the agent stays silent
    /// from the join on, not just once a later attach or detach arrives.
    @Test(.timeLimit(.minutes(1)))
    func aReconnectWhileHeldJoinsWithTheAgentAudioOff() async throws {
        let transport = makeTransport()
        let fake = try await attachedCall(transport)
        await transport.detachAudioSession()
        await drain()
        fake.setState(state: .disconnected)
        await drain()

        try await transport.connect(connection)

        #expect(fake.calls == ["connect", "agent audio unsubscribed", "agent audio unsubscribed", "connect"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aChangeDailyRefusesBeforeTheJoinIsAppliedOnceJoined() async throws {
        clients.refusesBeforeJoin = true
        let transport = makeTransport()
        let fake = try await attachedCall(transport)
        await transport.detachAudioSession()
        await drain()
        fake.setState(state: .disconnected)
        await drain()

        try await transport.connect(connection)

        #expect(fake.calls == ["connect", "agent audio unsubscribed", "connect", "agent audio unsubscribed"])
    }

    /// The engine's teardown detaches, then disconnects at once: the leave is not
    /// held up by a subscription change, which the released session no longer gets.
    @Test(.timeLimit(.minutes(1)))
    func aTeardownDetachDoesNotHoldUpTheLeave() async throws {
        let transport = makeTransport()
        let fake = try await attachedCall(transport)
        let control = try #require(clients.controls.first)
        control.holdsRemoteAudio = true // a subscription change Daily never finishes

        await transport.detachAudioSession()
        await transport.disconnect()

        #expect(fake.calls == ["connect", "send client-message", "disconnect", "release"])
        control.releaseRemoteAudio()
        await drain()
        #expect(fake.calls == ["connect", "send client-message", "disconnect", "release"])
    }

    // MARK: - Connecting while ringing

    private let bot = Participant(id: ParticipantId(id: "bot"), name: "bot", local: false)

    @Test func theTransportCanConnectWhileRinging() {
        #expect(makeTransport().canConnectWhileRinging)
    }

    /// The ring's join unsubscribes from the agent's audio before it joins, and the
    /// agent's presence is the readiness: the bot cannot report ready unheard.
    @Test(.timeLimit(.minutes(1)))
    func aJoinWhileRingingHoldsTheAgentAudioBackUntilTheAttach() async throws {
        let transport = makeTransport()
        let log = record(transport)

        try await transport.connectWhileRinging(connection)
        let fake = try #require(clients.made.first)
        fake.delegate?.onBotConnected(participant: bot)
        await drain()
        #expect(fake.calls == ["agent audio unsubscribed", "connect"])
        #expect(callEvents(log) == [.connected])

        // The engine's order: the attach CallKit's activation brings, then the answer.
        await transport.attachAudioSession()
        await transport.send(.connected)
        await drain()
        #expect(fake.calls == ["agent audio unsubscribed", "connect", "agent audio subscribed", "send client-message"])

        fake.becomeReady()
        await drain()
        #expect(callEvents(log) == [.connected])
    }

    @Test(.timeLimit(.minutes(1)))
    func aJoinWhileRingingWithTheBotAlreadyThereConnectsOnTheJoin() async throws {
        let transport = makeTransport()
        let log = record(transport)
        try #require(clients.controls.first).hasRemoteParticipant = true

        try await transport.connectWhileRinging(connection)
        await drain()

        #expect(callEvents(log) == [.connected])
    }

    @Test(.timeLimit(.minutes(1)))
    func aJoinWhileRingingRefusedBeforeTheJoinHoldsTheAgentBackOnceJoined() async throws {
        clients.refusesBeforeJoin = true
        let transport = makeTransport()

        try await transport.connectWhileRinging(connection)

        let fake = try #require(clients.made.first)
        #expect(fake.calls == ["connect", "agent audio unsubscribed"])
    }

    /// The attach that ends the hold-back returns once Daily has the subscription, so
    /// the `call-connected` the engine sends next reaches an agent the user can hear.
    @Test(.timeLimit(.minutes(1)))
    func theAttachThatEndsARingJoinsHoldBackReturnsOnceSubscribed() async throws {
        let transport = makeTransport()
        try await transport.connectWhileRinging(connection)
        let fake = try #require(clients.made.first)
        try #require(clients.controls.first).suspensions = 20

        await transport.attachAudioSession()

        #expect(fake.calls.last == "agent audio subscribed")
    }

    /// Presence counts as ready only for a join made while the agent's audio is held
    /// back. The reconnect of an answered ring is a normal join: it waits for bot-ready.
    @Test(.timeLimit(.minutes(1)))
    func presenceCountsOnlyForAJoinWhileTheAgentIsHeldBack() async throws {
        let transport = makeTransport()
        let log = record(transport)
        try await transport.connectWhileRinging(connection)
        let fake = try #require(clients.made.first)
        fake.delegate?.onBotConnected(participant: bot)
        await drain()
        #expect(callEvents(log) == [.connected]) // the ring's join, held back
        await transport.attachAudioSession()
        fake.setState(state: .disconnected) // a drop after the answer
        await drain()

        try await transport.connect(connection) // the engine's reconnect
        fake.delegate?.onBotConnected(participant: bot)
        await drain()
        #expect(callEvents(log) == [.connected, .disconnected(reason: .networkDropped)])

        fake.becomeReady()
        await drain()
        #expect(callEvents(log) == [.connected, .disconnected(reason: .networkDropped), .connected])
    }

    /// A normal join before any attach (an outgoing call CallKit has not activated
    /// yet, or an answer that joins before the activation): Daily's default
    /// subscriptions, untouched, and readiness from bot-ready, as before.
    @Test(.timeLimit(.minutes(1)))
    func aNormalJoinBeforeTheFirstAttachKeepsDefaultSubscriptions() async throws {
        let transport = makeTransport()
        let log = record(transport)
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)

        fake.delegate?.onBotConnected(participant: bot)
        await drain()
        #expect(callEvents(log).isEmpty)

        await transport.attachAudioSession()
        fake.becomeReady()
        await drain()
        #expect(callEvents(log) == [.connected])
        #expect(fake.calls == ["connect"])
    }

    /// A ring's join that fails, then the engine's unprepared connect after the
    /// answer, before CallKit activated: the agent's audio stays held back until the
    /// first attach, whichever join comes first.
    @Test(.timeLimit(.minutes(1)))
    func aJoinBeforeTheFirstAttachOfARingJoinedTransportStaysHeldBack() async throws {
        let transport = makeTransport()
        let log = record(transport)
        try await transport.connectWhileRinging(connection)
        let first = try #require(clients.made.first) // joined; its bot never came

        try await transport.connect(connection) // takes the session over
        let second = try #require(clients.made.last)
        second.botJoins()
        await drain()

        #expect(clients.made.count == 2)
        #expect(first.calls == ["agent audio unsubscribed", "connect", "disconnect", "release"])
        #expect(second.calls == ["agent audio unsubscribed", "connect"])
        #expect(callEvents(log) == [.connected])

        await transport.attachAudioSession()
        #expect(second.calls.last == "agent audio subscribed")
    }

    /// Once attached, a call is under way: a later join keeps the subscription the
    /// call has, so a join after an attach is never held back.
    @Test(.timeLimit(.minutes(1)))
    func aJoinWhileRingingAfterAnAttachIsNotHeldBack() async throws {
        let transport = makeTransport()
        await transport.attachAudioSession()
        await drain()

        try await transport.connectWhileRinging(connection)

        let fake = try #require(clients.made.first)
        #expect(fake.calls == ["connect"])
    }
}
