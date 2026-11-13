//
//  LiveKitHostMessageTests.swift
//  ConduitCallEngineLiveKitTests
//
//  Host messages over LiveKit's data channel, in the envelope of the call-control
//  signals with a `d`, and the RTVI messages an agent publishes that reach the
//  engine (a server message, its output text, the user's transcript), over a
//  `FakeLiveKitRoom`, without the engine.
//

import Foundation
import Testing
import ConduitCallEngine
@testable import ConduitCallEngineLiveKit

@MainActor
struct LiveKitHostMessageTests {
    private let connection = CallConnection(url: URL(string: "wss://example.livekit.cloud")!, token: "t")

    private final class EventLog {
        var events: [TransportEvent] = []
    }

    private func makeTransport() -> (LiveKitTransport, () -> FakeLiveKitRoom?) {
        var room: FakeLiveKitRoom?
        let transport = makeLiveKitTransport(
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

    private func record(_ transport: LiveKitTransport) -> EventLog {
        let log = EventLog()
        Task { @MainActor in
            for await event in transport.events { log.events.append(event) }
        }
        return log
    }

    private func agentEvents(_ log: EventLog) -> [TransportEvent] {
        log.events.filter {
            switch $0 {
            case .serverMessage, .botOutput, .userTranscript: true
            default: false
            }
        }
    }

    private func lastPayload(_ room: FakeLiveKitRoom) throws -> [String: Any] {
        let data = try #require(room.publishedPayloads.last)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Sending

    @Test(.timeLimit(.minutes(1)))
    func aHostMessageWithoutDataHasNoD() async throws {
        let (transport, room) = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(room())

        #expect(await transport.send(CallMessage(type: "ping")) == .sent)

        let message = try lastPayload(fake)
        #expect(message["label"] as? String == "rtvi-ai")
        #expect(message["type"] as? String == "client-message")
        #expect((message["id"] as? String)?.count == 8)
        #expect(message["data"] as? [String: String] == ["t": "ping"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aHostMessageCarriesItsDataAsD() async throws {
        let (transport, room) = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(room())
        let json = #"{"screen":"home","count":3,"on":true,"none":null,"list":[1,"two",{"x":false}]}"#

        #expect(await transport.send(try #require(CallMessage(type: "set-context", data: Data(json.utf8)))) == .sent)

        let data = try #require(try lastPayload(fake)["data"] as? [String: Any])
        #expect(data["t"] as? String == "set-context")
        let expected = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        #expect(data["d"] as? NSDictionary == expected)
    }

    @Test(arguments: [#""text""#, "42", "false", "[1,2]", "null"])
    func aHostMessageCarriesAnyJSONValueAsD(_ json: String) throws {
        let payload = try #require(LiveKitEndCallSignal.payload(type: "value", data: Data(json.utf8), id: "abcd1234"))

        let message = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let data = try #require(message["data"] as? [String: Any])
        let expected = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
        #expect((data["d"] as? NSObject) == (expected as? NSObject))
    }

    @Test(.timeLimit(.minutes(1)))
    func aHostMessageReportsWhetherLiveKitTookIt() async throws {
        let (transport, room) = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(room())

        fake.publishError = FakeLiveKitRoom.NotConnected()
        #expect(await transport.send(CallMessage(type: "ping")) == .failed)
        fake.publishError = nil
        #expect(await transport.send(CallMessage(type: "ping")) == .sent)
        fake.drop()
        #expect(await transport.send(CallMessage(type: "ping")) == .failed) // the room is gone
        #expect(fake.published == ["ping"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: Array(CallMessage.reservedTypes) + [""])
    func aHostMessageWithAReservedTypeIsNotPublished(_ type: String) async throws {
        let (transport, room) = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(room())

        #expect(await transport.send(CallMessage(type: type)) == .failed)
        #expect(fake.published.isEmpty)
    }

    // MARK: - What the agent sends the host

    private static func packet(_ json: String) -> Data { Data(json.utf8) }

    @Test func aServerMessageReachesTheEngineAsJSON() async throws {
        let (transport, room) = makeTransport()
        let log = record(transport)
        let mapper = try #require(room()?.events)

        mapper.dataDidArrive(Self.packet(#"{"label":"rtvi-ai","type":"server-message","id":"x","data":{"kind":"note","n":[1,true]}}"#))
        mapper.dataDidArrive(Self.packet(#"{"label":"rtvi-ai","type":"server-message","data":"just text"}"#))
        mapper.dataDidArrive(Self.packet(#"{"label":"rtvi-ai","type":"server-message"}"#))
        await waitUntil { agentEvents(log).count == 3 }

        let payloads = agentEvents(log).compactMap { event -> Any? in
            guard case .serverMessage(let json) = event else { return nil }
            return try? JSONSerialization.jsonObject(with: json, options: .fragmentsAllowed)
        }
        #expect(payloads.count == 3)
        #expect(payloads.first as? NSDictionary == ["kind": "note", "n": [1, true]] as NSDictionary)
        #expect(payloads.dropFirst().first as? String == "just text")
        #expect(payloads.last is NSNull)
    }

    @Test func theBotsOutputAndTheUsersTranscriptReachTheEngine() async throws {
        let (transport, room) = makeTransport()
        let log = record(transport)
        let mapper = try #require(room()?.events)

        mapper.dataDidArrive(Self.packet("""
            {"label":"rtvi-ai","type":"bot-output","data":{"text":"Hello.","aggregated_by":"sentence",\
            "will_be_spoken":true,"spoken_status":"completed",\
            "spoken_progress":{"accumulated_text":"Hello.","remaining_text":""},"segment_id":2}}
            """))
        mapper.dataDidArrive(Self.packet(#"{"label":"rtvi-ai","type":"bot-output","data":{"text":"Hi","aggregated_by":"word","spoken":true}}"#))
        mapper.dataDidArrive(Self.packet(#"{"label":"rtvi-ai","type":"user-transcription","data":{"text":"Hey","final":true,"user_id":"u"}}"#))
        mapper.dataDidArrive(Self.packet(#"{"label":"rtvi-ai","type":"user-transcription","data":{"text":"He"}}"#))
        await waitUntil { agentEvents(log).count == 4 }

        #expect(agentEvents(log) == [
            .botOutput(BotOutput(
                text: "Hello.", isSpoken: true, aggregatedBy: "sentence", spokenStatus: "completed",
                spokenProgress: BotOutput.SpokenProgress(accumulatedText: "Hello.", remainingText: ""), segmentID: 2
            )),
            .botOutput(BotOutput(text: "Hi", isSpoken: true, aggregatedBy: "word")),
            .userTranscript(UserTranscript(text: "Hey", isFinal: true)),
            .userTranscript(UserTranscript(text: "He", isFinal: false)),
        ])
    }

    /// Only RTVI messages the host is told about, in RTVI's shape, reach the engine.
    @Test func otherDataIsIgnored() async throws {
        let (transport, room) = makeTransport()
        let log = record(transport)
        let mapper = try #require(room()?.events)

        for json in [
            #"not json"#,
            #"[1,2]"#,
            #"{"type":"server-message","data":{}}"#, // no RTVI label
            #"{"label":"other","type":"server-message","data":{}}"#,
            #"{"label":"rtvi-ai","type":"bot-transcription","data":{"text":"x"}}"#,
            #"{"label":"rtvi-ai","type":"client-message","data":{"t":"end-call"}}"#,
            #"{"label":"rtvi-ai","type":"bot-output","data":{"text":"x"}}"#, // no aggregated_by
            #"{"label":"rtvi-ai","type":"user-transcription","data":{"final":true}}"#, // no text
            #"{"label":"rtvi-ai","type":"bot-output"}"#,
        ] {
            mapper.dataDidArrive(Self.packet(json))
        }
        mapper.dataDidArrive(Self.packet(#"{"label":"rtvi-ai","type":"server-message","data":{}}"#)) // a marker
        await waitUntil { !agentEvents(log).isEmpty }

        #expect(agentEvents(log) == [.serverMessage(Data("{}".utf8))])
    }
}
