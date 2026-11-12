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
import PipecatClientIOS
@_spi(RingJoinExperiment) @testable import ConduitCallEngineDaily

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

    private func makeTransport(ringJoinStrategy: DailyRingJoinStrategy = .unsupported) -> PipecatDailyTransport {
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
            ringJoinStrategy: ringJoinStrategy
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
        let transport = makeTransport()
        try await transport.connect(connection)
        let first = try #require(clients.made.first)
        first.becomeReady()

        let disconnecting = Task { await transport.disconnect() }
        while first.calls.contains("send client-message") == false { await Task.yield() }
        try await transport.connect(connection)
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

    private func waitUntilLeaving(_ fake: FakePipecatTransport) async {
        for _ in 0..<1000 where !fake.calls.contains("disconnect") { await Task.yield() }
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

        await transport.send(.answered)

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
    @Test func aTeardownDetachDoesNotHoldUpTheLeave() async throws {
        let transport = makeTransport()
        let fake = try await attachedCall(transport)

        await transport.detachAudioSession()
        await transport.disconnect()
        await drain()

        #expect(fake.calls == ["connect", "send client-message", "disconnect", "release"])
    }

    // MARK: - Connecting while ringing (experimental strategies)

    private let bot = Participant(id: ParticipantId(id: "bot"), name: "bot", local: false)

    @Test func byDefaultTheTransportCannotConnectWhileRinging() {
        #expect(makeTransport().canConnectWhileRinging == false)
    }

    @Test(arguments: DailyRingJoinStrategy.allCases.filter { $0 != .unsupported })
    func anExperimentalStrategyCanConnectWhileRinging(strategy: DailyRingJoinStrategy) {
        #expect(makeTransport(ringJoinStrategy: strategy).canConnectWhileRinging)
    }

    /// D1 joins as without the switch: nothing touches the agent's audio, and the call
    /// connects when the bot is ready, not when it is merely present.
    @Test(.timeLimit(.minutes(1)))
    func defaultSubscriptionsJoinsAsBefore() async throws {
        let transport = makeTransport(ringJoinStrategy: .defaultSubscriptions)
        let log = record(transport)
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)

        fake.delegate?.onBotConnected(participant: bot)
        await drain()
        #expect(callEvents(log).isEmpty)

        fake.becomeReady()
        await transport.attachAudioSession()
        await drain()
        #expect(callEvents(log) == [.connected])
        #expect(fake.calls == ["connect"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        (DailyRingJoinStrategy.agentAudioUnsubscribedUntilAnswer, DailyRemoteAudio.unsubscribed),
        (.agentAudioStagedUntilAnswer, .staged),
    ])
    func aRingJoinHoldsTheAgentAudioBackUntilTheAttach(
        strategy: DailyRingJoinStrategy, heldBack: DailyRemoteAudio
    ) async throws {
        let transport = makeTransport(ringJoinStrategy: strategy)
        let log = record(transport)

        try await transport.connect(connection)
        let fake = try #require(clients.made.first)
        fake.delegate?.onBotConnected(participant: bot)
        await drain()
        #expect(fake.calls == ["agent audio \(heldBack)", "connect"])
        #expect(callEvents(log) == [.connected])

        await transport.send(.answered)
        await transport.attachAudioSession()
        await drain()
        #expect(fake.calls == ["agent audio \(heldBack)", "connect", "send client-message", "agent audio subscribed"])

        fake.becomeReady()
        await drain()
        #expect(callEvents(log) == [.connected])
    }

    @Test(.timeLimit(.minutes(1)))
    func aRingJoinWithTheBotAlreadyThereConnectsOnTheJoin() async throws {
        let transport = makeTransport(ringJoinStrategy: .agentAudioUnsubscribedUntilAnswer)
        let log = record(transport)
        try #require(clients.controls.first).hasRemoteParticipant = true

        try await transport.connect(connection)
        await drain()

        #expect(callEvents(log) == [.connected])
    }

    @Test(.timeLimit(.minutes(1)))
    func aRingJoinRefusedBeforeTheJoinHoldsTheAgentBackOnceJoined() async throws {
        clients.refusesBeforeJoin = true
        let transport = makeTransport(ringJoinStrategy: .agentAudioUnsubscribedUntilAnswer)

        try await transport.connect(connection)

        let fake = try #require(clients.made.first)
        #expect(fake.calls == ["connect", "agent audio unsubscribed"])
    }

    /// An outgoing call through the same transport is attached before it joins, so
    /// the agent's audio is never held back.
    @Test(.timeLimit(.minutes(1)))
    func aRingJoinStrategyAttachedBeforeTheJoinKeepsTheAgentAudible() async throws {
        let transport = makeTransport(ringJoinStrategy: .agentAudioUnsubscribedUntilAnswer)
        await transport.attachAudioSession()
        await drain()

        try await transport.connect(connection)

        let fake = try #require(clients.made.first)
        let audioChanges = fake.calls.filter { $0.hasPrefix("agent audio") }
        #expect(audioChanges.allSatisfy { $0 == "agent audio subscribed" })
        #expect(fake.calls.contains("connect"))
    }
}
