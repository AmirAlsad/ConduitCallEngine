//
//  PipecatDailyTransportTests.swift
//  ConduitCallEngineDailyTests
//
//  The adapter over a real `PipecatClient` whose Daily transport is replaced by a
//  fake, because Daily's WebRTC audio unit aborts in the simulator. Covers teardown:
//  the end-call signal goes out before the leave, and the client is released after
//  it, without touching a client a later connect created. Audio and the real Daily
//  call client are verified on device.
//

import Foundation
import Testing
import ConduitCallEngine
@testable import ConduitCallEngineDaily

@MainActor
struct PipecatDailyTransportTests {
    private final class Clients {
        var made: [FakePipecatTransport] = []
        var pathMonitors: [FakePathMonitor] = []
    }

    /// Everything the transport has emitted, in order.
    private final class EventLog {
        var events: [TransportEvent] = []
    }

    private let clients = Clients()
    private let connection = CallConnection(url: URL(string: "https://example.daily.co/room")!, token: "t")

    private func makeTransport() -> PipecatDailyTransport {
        PipecatDailyTransport(
            makePipecatTransport: { [clients] in
                let fake = FakePipecatTransport()
                clients.made.append(fake)
                return fake
            },
            makePathMonitor: { [clients] in
                let monitor = FakePathMonitor()
                clients.pathMonitors.append(monitor)
                return monitor
            }
        )
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

    @Test func disconnectReleasesTheClientWhenTheBotWasNeverReady() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)

        await transport.disconnect()

        #expect(fake.calls == ["connect", "disconnect", "release"])
    }

    @Test func aReleasedClientNoLongerReachesTheTransport() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)

        await transport.disconnect()

        #expect(fake.delegate == nil)
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

    /// A join whose bot is not ready yet is still this attempt: a second connect that
    /// arrives meanwhile must not stop its bot-ready from being reported.
    @Test(.timeLimit(.minutes(1)))
    func aConnectWhileTheBotIsNotReadyLetsTheBotReadyThrough() async throws {
        let transport = makeTransport()
        let log = record(transport)
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)

        await #expect(throws: TransportError.self) { try await transport.connect(connection) }
        fake.becomeReady()
        await drain()

        #expect(callEvents(log) == [.connected])
        #expect(fake.calls == ["connect"])
    }
}
