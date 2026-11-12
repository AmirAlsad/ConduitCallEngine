//
//  DailyAudioRouteTests.swift
//  ConduitCallEngineDailyTests
//
//  The route the adapter asks Daily to prefer, in the orders that matter: CallKit's
//  activation before or after the connect, the engine's request before or after,
//  a join while ringing, a reconnect and a session taken over, a hold, and devices
//  coming and going. "prefer <route>" in a session's call log is a request to
//  Daily's call client; "connect preferring <device>" is a join whose microphone
//  input names that Daily device. Whether Daily then keeps the route is device-only.
//

import AVFoundation
import Foundation
import Testing
import ConduitCallEngine
import PipecatClientIOS
@testable import ConduitCallEngineDaily

@MainActor
struct DailyAudioRouteTests {
    private final class Clients {
        var made: [FakePipecatTransport] = []
        var controls: [FakeDailyCallControl] = []
        var mics: [String] = ["earpiece", "speakerphone"]
        var outputPort: AVAudioSession.Port? = .builtInReceiver
        var portReads = 0
    }

    private let clients = Clients()
    private let connection = CallConnection(url: URL(string: "https://example.daily.co/room")!, token: "t")

    private func makeTransport() -> PipecatDailyTransport {
        PipecatDailyTransport(
            makePipecatTransport: { [clients] in
                let fake = FakePipecatTransport()
                fake.mics = clients.mics
                clients.made.append(fake)
                return fake
            },
            makePathMonitor: { FakePathMonitor() },
            makeCallControl: { [clients] transport in
                let control = FakeDailyCallControl(transport: transport as! FakePipecatTransport)
                clients.controls.append(control)
                return control
            },
            readOutputPort: { [clients] in
                clients.portReads += 1
                return clients.outputPort
            }
        )
    }

    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: - Activation and the connect

    /// The usual order for a call the user places: CallKit activates the earpiece
    /// before the credentials arrive. Daily is given the earpiece before the join,
    /// and the join names it, so Daily starts managing the session there.
    @Test func anActivationBeforeTheConnectGivesDailyTheRouteBeforeTheJoin() async throws {
        let transport = makeTransport()

        await transport.attachAudioSession()
        try await transport.connect(connection)

        let fake = try #require(clients.made.first)
        #expect(fake.calls == ["prefer earpiece", "connect preferring earpiece"])
    }

    /// Credentials first: the join has no route to name (CallKit has not activated
    /// yet), so the route goes to Daily at the attach.
    @Test func anActivationAfterTheConnectGivesDailyTheRouteAtTheAttach() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)
        #expect(fake.calls == ["connect"])

        await transport.attachAudioSession()

        #expect(fake.calls == ["connect", "prefer earpiece"])
    }

    @Test(arguments: [
        (AVAudioSession.Port.builtInSpeaker, "prefer speaker"),
        (.bluetoothHFP, "prefer bluetooth"),
        (.headphones, "prefer wired"),
    ])
    func theRouteAtActivationIsTheOneKept(port: AVAudioSession.Port, request: String) async throws {
        clients.outputPort = port
        let transport = makeTransport()
        try await transport.connect(connection)

        await transport.attachAudioSession()

        #expect(clients.made.first?.calls == ["connect", request])
    }

    @Test func aRouteDailyCannotNameIsLeftToDaily() async throws {
        clients.outputPort = .carAudio
        let transport = makeTransport()
        await transport.attachAudioSession()

        try await transport.connect(connection)

        #expect(clients.made.first?.calls == ["connect"])
    }

    // MARK: - The engine's request

    @Test func anEngineRequestBeforeTheJoinIsGivenToDailyBeforeIt() async throws {
        let transport = makeTransport()
        await transport.setAudioDevice("speakerphone")

        try await transport.connect(connection)

        #expect(clients.made.first?.calls == ["prefer speaker", "connect preferring speakerphone"])
    }

    /// The speaker default, or the user's pick, after the attach kept the earpiece.
    @Test func anEngineRequestAfterTheAttachWins() async throws {
        let transport = makeTransport()
        await transport.attachAudioSession()
        try await transport.connect(connection)

        await transport.setAudioDevice("speakerphone")
        await transport.attachAudioSession() // a resume

        let fake = try #require(clients.made.first)
        #expect(fake.calls == ["prefer earpiece", "connect preferring earpiece", "prefer speaker"])
        #expect(clients.controls.first?.preferredAudioRoute == .speaker)
    }

    @Test func anEngineRequestForADeviceDailyDoesNotHaveIsIgnored() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)

        await transport.setAudioDevice("airplay")

        #expect(clients.made.first?.calls == ["connect"])
    }

    // MARK: - Joining while ringing

    /// Nothing reaches Daily before the first attach of a ring's join, not even an
    /// engine request; the attach after the answer gives it the route.
    @Test func aJoinWhileRingingAsksDailyForNoRouteBeforeTheFirstAttach() async throws {
        let transport = makeTransport()
        try await transport.connectWhileRinging(connection)
        await transport.setAudioDevice("speakerphone")
        let fake = try #require(clients.made.first)
        #expect(fake.calls == ["agent audio unsubscribed", "connect"])
        #expect(clients.portReads == 0)

        await transport.attachAudioSession()

        #expect(fake.calls == ["agent audio unsubscribed", "connect", "prefer speaker", "agent audio subscribed"])
        #expect(clients.portReads == 1)
    }

    // MARK: - Reconnects, takeovers and holds

    /// A reconnect that rejoins on the same Daily client after Daily left: the client
    /// keeps the preference it was given, and the join names it again.
    @Test func aRejoinKeepsTheRoute() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        await transport.attachAudioSession()
        let fake = try #require(clients.made.first)
        fake.setState(state: .disconnected) // Daily left the call
        await drain()

        try await transport.connect(connection)

        #expect(fake.calls == ["connect", "prefer earpiece", "connect preferring earpiece"])
        #expect(clients.portReads == 1)
    }

    /// A session whose bot never got ready is left and replaced; the new Daily
    /// client is given the route before its join.
    @Test func aSessionTakenOverKeepsTheRoute() async throws {
        let transport = makeTransport()
        try await transport.connect(connection)
        await transport.attachAudioSession()
        await transport.setAudioDevice("speakerphone")

        try await transport.connect(connection) // the bot never got ready

        let fresh = try #require(clients.made.last)
        #expect(clients.made.count == 2)
        #expect(fresh.calls == ["prefer speaker", "connect preferring speakerphone"])
    }

    @Test func aConnectAfterDisconnectKeepsTheRoute() async throws {
        let transport = makeTransport()
        await transport.attachAudioSession()
        try await transport.connect(connection)
        await transport.disconnect()

        try await transport.connect(connection)

        #expect(clients.made.last?.calls == ["prefer earpiece", "connect preferring earpiece"])
    }

    @Test func aHoldAndResumeChangeNoRoute() async throws {
        let transport = makeTransport()
        await transport.attachAudioSession()
        try await transport.connect(connection)
        clients.outputPort = .builtInSpeaker

        await transport.detachAudioSession()
        await transport.attachAudioSession()

        let fake = try #require(clients.made.first)
        #expect(fake.calls.filter { $0.hasPrefix("prefer") } == ["prefer earpiece"])
        #expect(clients.portReads == 1)
    }

    // MARK: - What Daily reports after the join

    @Test func aPreferenceDailyDropsAtTheJoinIsGivenAgain() async throws {
        let transport = makeTransport()
        await transport.attachAudioSession()
        let fake = try #require(clients.made.first)
        let control = try #require(clients.controls.first)
        fake.onJoin = { control.preferredAudioRoute = nil }

        try await transport.connect(connection)

        #expect(fake.calls == ["prefer earpiece", "connect preferring earpiece", "prefer earpiece"])
    }

    @Test func aRequestDailyRefusedBeforeTheJoinIsRetriedAfterIt() async throws {
        let transport = makeTransport()
        let control = try #require(clients.controls.first)
        control.refusesRoutes = true
        await transport.attachAudioSession()
        let fake = try #require(clients.made.first)
        fake.onJoin = { control.refusesRoutes = false }

        try await transport.connect(connection)

        #expect(fake.calls == ["connect preferring earpiece", "prefer earpiece"])
    }

    // MARK: - Devices coming and going

    @Test(.timeLimit(.minutes(1)))
    func aHeadsetConnectedMidCallIsFollowedAndItsLeavingReturnsToTheEarpiece() async throws {
        let transport = makeTransport()
        await transport.attachAudioSession()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)

        fake.announceMics(["earpiece", "speakerphone", "bluetooth"])
        await drain()
        fake.announceMics(["earpiece", "speakerphone"])
        await drain()

        #expect(fake.calls.filter { $0.hasPrefix("prefer") } == [
            "prefer earpiece", "prefer bluetooth", "prefer earpiece",
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func aHeadsetDoesNotMoveTheUsersPick() async throws {
        let transport = makeTransport()
        await transport.attachAudioSession()
        try await transport.connect(connection)
        await transport.setAudioDevice("speakerphone")
        let fake = try #require(clients.made.first)

        fake.announceMics(["earpiece", "speakerphone", "bluetooth"])
        await drain()

        #expect(fake.calls.last == "prefer speaker")
    }
}
