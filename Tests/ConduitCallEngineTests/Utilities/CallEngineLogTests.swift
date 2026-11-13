//
//  CallEngineLogTests.swift
//  ConduitCallEngineTests
//
//  The host's view of the package's logging: a handler receives every event at or
//  above the minimum level, a message below it is never built, and no message
//  carries a credential. The settings are process-wide and other suites log while
//  these run, so the suite is serialized and its assertions look for their own
//  events rather than for exact lists.
//

import Foundation
import Synchronization
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

/// Collects events from any thread.
private final class LogSink: Sendable {
    private let collected = Mutex<[CallEngineLog.Event]>([])
    var events: [CallEngineLog.Event] { collected.withLock { $0 } }
    func record(_ event: CallEngineLog.Event) { collected.withLock { $0.append(event) } }
}

@Suite(.serialized)
@MainActor
struct CallEngineLogTests {
    /// Run `body` with `sink` as the handler and `level` as the minimum, then restore both.
    private func capturing(
        at level: CallEngineLog.Level = .debug,
        _ body: (LogSink) async throws -> Void
    ) async rethrows {
        _ = QuietEngineLog.installed
        let sink = LogSink()
        let previous = (CallEngineLog.handler, CallEngineLog.minimumLevel)
        CallEngineLog.handler = { sink.record($0) }
        CallEngineLog.minimumLevel = level
        defer { (CallEngineLog.handler, CallEngineLog.minimumLevel) = previous }
        try await body(sink)
    }

    @Test func aHandlerReceivesTheEventWithItsLevelAndCategory() async {
        let marker = UUID().uuidString
        await capturing { sink in
            Log.warning(.transport, "marker \(marker)")
            #expect(sink.events.filter { $0.message.contains(marker) } == [
                CallEngineLog.Event(level: .warning, category: .transport, message: "marker \(marker)"),
            ])
        }
    }

    @Test func anEventBelowTheMinimumIsDroppedWithoutBuildingItsMessage() async {
        let marker = UUID().uuidString
        let built = Mutex(0)
        func message() -> String {
            built.withLock { $0 += 1 }
            return "marker \(marker)"
        }
        await capturing(at: .warning) { sink in
            Log.debug(.call, message())
            Log.info(.call, message())
            #expect(built.withLock { $0 } == 0)
            Log.error(.call, message())
            #expect(built.withLock { $0 } == 1)
            #expect(sink.events.filter { $0.message.contains(marker) }.map(\.level) == [.error])
        }
    }

    @Test func eventsCanBeLoggedFromAnyThread() async {
        let marker = UUID().uuidString
        await capturing { sink in
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<20 {
                    group.addTask { Log.info(.audio, "marker \(marker) \(index)") }
                }
            }
            #expect(sink.events.filter { $0.message.contains(marker) }.count == 20)
        }
    }

    /// The diagnostic a host needs about CallKit's raw activations: one the engine
    /// ignores is logged, though `isAudioActivated` does not show it.
    @Test func anActivationTheEngineIgnoresIsLogged() async throws {
        try await capturing { sink in
            let system = SimulatedCallSystem()
            let engine = CallEngine.simulated(
                configuration: CallEngineConfiguration(ringTimeout: nil, joinTimeout: nil),
                system: system,
                now: { testEpoch },
                sleep: parkedSleep
            )
            engine.startPushRegistration()
            // CallKit has not accepted the report yet, so the ring rings on.
            system.completesIncomingReportsLater = true
            system.deliverPush(["target_id": UUID().uuidString, "call_id": UUID().uuidString]) {}
            #expect(engine.state == .incomingRinging)

            await system.activateAudioSession()

            #expect(!engine.isAudioActivated)
            let ignored = try #require(sink.events.last { $0.message.contains("unanswered ring; ignored") })
            #expect(ignored.level == .warning)
            #expect(ignored.category == .callKit)
        }
    }

    /// A host that withholds the mic and never releases it finds out from the log.
    @Test func aWithholdTheBoundEndsIsLoggedAsAWarning() async throws {
        try await capturing { sink in
            let system = SimulatedCallSystem()
            let engine = CallEngine.simulated(system: system, now: { testEpoch }, sleep: parkedSleep)
            let target = CallTarget(
                id: UUID(),
                displayName: "Assistant",
                makeTransport: { FakeTransport() },
                connect: { _ in CallConnection(url: URL(string: "https://example.invalid/room")!, token: "t") }
            )
            engine.setMicWithheld(true)
            await engine.placeCall(target)
            system.deliverTransportEvent(.connected)
            await system.activateAudioSession()

            #expect(system.fireTimer(.micWithholdTimeout))

            let released = try #require(sink.events.last { $0.message.contains("mic was still withheld") })
            #expect(released.level == .warning)
            #expect(released.category == .call)
            #expect(released.message.contains("\(Duration.seconds(5))"))
            await engine.endCall()
        }
    }

    // MARK: - Redaction

    @Test(arguments: [
        ("wss://agent.example.com/rtc?access_token=abc.def&auto_subscribe=1 failed",
         "wss://agent.example.com/rtc?<redacted> failed"),
        ("https://user:pa55@example.daily.co/room?t=secret#frag",
         "https://example.daily.co/room?<redacted>#<redacted>"),
        ("Authorization: Bearer abc123.def", "Authorization: <redacted> <redacted>"),
        ("sent with Bearer abc123", "sent with Bearer <redacted>"),
        ("token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl rejected", "token <redacted> rejected"),
        ("CallConnection(url: https://x.example/room, token: Optional(\"s3cret\"))",
         "CallConnection(url: https://x.example/room, token: <redacted>)"),
        (#"{"api_key": "k-123", "status": "busy"}"#, #"{"api_key": <redacted>, "status": "busy"}"#),
        ("password=hunter2&user=me", "password=<redacted>&user=me"),
        ("join failed: meeting_token=abc123&room=x", "join failed: meeting_token=<redacted>&room=x"),
        ("Daily join failed: dailyToken: s3cret", "Daily join failed: dailyToken: <redacted>"),
        (#"{"meetingToken": "xyz", "room": "a"}"#, #"{"meetingToken": <redacted>, "room": "a"}"#),
        ("client_secret=abc&grant=x", "client_secret=<redacted>&grant=x"),
        ("x_api_key: k-1 rejected", "x_api_key: <redacted> rejected"),
    ])
    func credentialsAreRemoved(_ input: String, _ expected: String) {
        #expect(CredentialRedaction.redact(input) == expected)
    }

    @Test(arguments: [
        "VoIP push token invalidated",
        "Ring preparation: credentials failed: connectionFailed(\"backend down\")",
        "Connected",
        "Daily connect: the session's bot never got ready (connected); leaving it and joining with a new client",
        "Daily meeting token rejected by the room",
        "tokenExpired: true",
    ])
    func messagesWithoutCredentialsAreUnchanged(_ message: String) {
        #expect(CredentialRedaction.redact(message) == message)
    }

    @Test func aHandlerNeverSeesACredential() async {
        let marker = UUID().uuidString
        await capturing { sink in
            Log.error(.network, "\(marker) POST https://example.com/status?key=abc failed: Bearer xyz")
            let event = sink.events.first { $0.message.contains(marker) }
            #expect(event?.message == "\(marker) POST https://example.com/status?<redacted> failed: Bearer <redacted>")
        }
    }
}
