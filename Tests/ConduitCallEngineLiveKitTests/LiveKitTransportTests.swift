//
//  LiveKitTransportTests.swift
//  ConduitCallEngineLiveKitTests
//
//  The LiveKit adapter over a `FakeLiveKitRoom`, without the engine.
//

import Foundation
import Testing
import ConduitCallEngine
@testable import ConduitCallEngineLiveKit

@MainActor
struct LiveKitTransportTests {
    private let connection = CallConnection(url: URL(string: "wss://example.livekit.cloud")!, token: "t")

    private func makeTransport() -> (LiveKitTransport, () -> FakeLiveKitRoom?) {
        var room: FakeLiveKitRoom?
        let transport = LiveKitTransport(
            makeRoom: { mapper in
                let fake = FakeLiveKitRoom()
                fake.events = mapper
                room = fake
                return fake
            },
            audioEngine: FakeLiveKitAudioEngine()
        )
        return (transport, { room })
    }

    /// Two connects waiting for the same earlier join to end (two quick holds and
    /// resumes during a reconnect attempt's join): only the newer one joins, or the
    /// two `Room.connect`s would tear each other down.
    @Test(.timeLimit(.minutes(1)))
    func onlyTheNewestOfTheConnectsWaitingForAJoinJoins() async throws {
        let (transport, room) = makeTransport()
        let fake = try #require(room())
        fake.holdsJoin = true
        fake.holdsJoinThroughCancellation = true
        let first = Task { try await transport.connect(connection) }
        await waitUntil { fake.isHoldingJoin }

        let second = Task { try await transport.connect(connection) }
        await drain()
        let third = Task { try await transport.connect(connection) }
        await drain()
        fake.holdsJoin = false
        fake.completeJoin()

        await #expect(throws: (any Error).self) { try await first.value } // cancelled
        await #expect(throws: TransportError.self) { try await second.value }
        try await third.value
        #expect(fake.log.filter { $0.hasPrefix("connect") }.count == 2)
        #expect(fake.phase == .connected)
    }

    /// The engine sends the call's current state again when a signal did not leave
    /// the device, so the adapter must say which it was.
    @Test(.timeLimit(.minutes(1)))
    func aSignalReportsWhetherLiveKitTookIt() async throws {
        let (transport, room) = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(room())

        #expect(await transport.send(.held) == .sent)
        #expect(fake.published == ["call-held"])
        fake.publishError = FakeLiveKitRoom.NotConnected()
        #expect(await transport.send(.resumed) == .failed)
        fake.publishError = nil
        fake.drop()
        #expect(await transport.send(.resumed) == .failed) // the room is gone: dropped
        #expect(fake.published == ["call-held"])
    }
}
