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
