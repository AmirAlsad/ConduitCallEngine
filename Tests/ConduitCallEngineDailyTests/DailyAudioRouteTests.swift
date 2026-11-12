//
//  DailyAudioRouteTests.swift
//  ConduitCallEngineDailyTests
//
//  The route the adapter asks Daily to prefer, in the orders that matter: CallKit's
//  activation before or after the connect, the engine's request before or after,
//  a join while ringing, a reconnect and a session taken over, a hold, and devices
//  coming and going. "prefer <route>" in a session's call log is a request to
//  Daily's call client, "prefer <route> for the join" the preferred device alone,
//  before a join that starts before the activation; "connect preferring <device>" is
//  a join whose microphone input names that Daily device. Whether Daily then keeps
//  the route is device-only.
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
        var availableInputs: [AVAudioSession.Port] = [.builtInMic]
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
            },
            readAvailableInputs: { [clients] in clients.availableInputs }
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

    /// Credentials first: CallKit has not activated yet, so the join starts on a
    /// provisional earpiece, given as the preferred device alone and named by the
    /// join. The activation then reads the loudspeaker Daily may have configured
    /// meanwhile, which nobody asked for, and keeps the earpiece.
    @Test func aJoinBeforeTheActivationStartsOnTheEarpiece() async throws {
        clients.outputPort = .builtInSpeaker
        let transport = makeTransport()
        try await transport.connect(connection)
        let fake = try #require(clients.made.first)
        #expect(fake.calls == ["prefer earpiece for the join", "connect preferring earpiece"])

        await transport.attachAudioSession()

        #expect(fake.calls == ["prefer earpiece for the join", "connect preferring earpiece"])
        #expect(clients.portReads == 2)
    }

    @Test(arguments: [
        (AVAudioSession.Port.builtInSpeaker, "prefer speaker", "speakerphone"),
        (.bluetoothHFP, "prefer bluetooth", "bluetooth"),
        (.headphones, "prefer wired", "wired"),
    ])
    func theRouteAtActivationIsTheOneKept(port: AVAudioSession.Port, request: String, device: String) async throws {
        clients.outputPort = port
        let transport = makeTransport()
        await transport.attachAudioSession()

        try await transport.connect(connection)

        #expect(clients.made.first?.calls == [request, "connect preferring \(device)"])
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

        #expect(clients.made.first?.calls == ["prefer speaker for the join", "connect preferring speakerphone"])
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

        #expect(clients.made.first?.calls == ["prefer earpiece for the join", "connect preferring earpiece"])
    }

    // MARK: - Joining while ringing

    /// A ring's join gives Daily only its provisional route, as the preferred device
    /// alone before the join; an engine request waits for the first attach after the
    /// answer, which gives it in full.
    @Test func aJoinWhileRingingGivesDailyOnlyAProvisionalRouteBeforeTheFirstAttach() async throws {
        let transport = makeTransport()
        try await transport.connectWhileRinging(connection)
        await transport.setAudioDevice("speakerphone")
        let fake = try #require(clients.made.first)
        #expect(fake.calls == ["agent audio unsubscribed", "prefer earpiece for the join", "connect preferring earpiece"])
        #expect(clients.portReads == 1)

        await transport.attachAudioSession()

        #expect(fake.calls == [
            "agent audio unsubscribed", "prefer earpiece for the join", "connect preferring earpiece",
            "prefer speaker", "agent audio subscribed",
        ])
        #expect(clients.portReads == 2)
    }

    /// The device case: nothing connected, and Daily's join leaves the session on
    /// the loudspeaker and drops the preference. Nothing is asked of Daily during
    /// the ring after the join; the answer's attach asks for the earpiece, and the
    /// loudspeaker is never asked for.
    @Test func aRingAnsweredWithNothingConnectedEndsOnTheEarpiece() async throws {
        clients.outputPort = .builtInSpeaker
        let transport = makeTransport()
        let fake = try #require(clients.made.first)
        let control = try #require(clients.controls.first)
        fake.onJoin = { control.preferredAudioRoute = nil }
        try await transport.connectWhileRinging(connection)
        fake.announceMics(["earpiece", "speakerphone"])
        await drain()
        #expect(fake.calls == ["agent audio unsubscribed", "prefer earpiece for the join", "connect preferring earpiece"])

        await transport.attachAudioSession()

        #expect(fake.calls == [
            "agent audio unsubscribed", "prefer earpiece for the join", "connect preferring earpiece",
            "prefer earpiece", "agent audio subscribed",
        ])
        #expect(!fake.calls.contains { $0.contains("speaker") })
    }

    @Test func aRingJoinedWithABluetoothHeadsetConnectedStaysOnIt() async throws {
        clients.mics = ["earpiece", "speakerphone", "bluetooth"]
        clients.availableInputs = [.builtInMic, .bluetoothHFP]
        let transport = makeTransport()
        try await transport.connectWhileRinging(connection)
        let fake = try #require(clients.made.first)
        #expect(fake.calls == ["agent audio unsubscribed", "prefer bluetooth for the join", "connect preferring bluetooth"])
        clients.outputPort = .bluetoothHFP

        await transport.attachAudioSession()

        #expect(fake.calls.filter { $0.hasPrefix("prefer") } == ["prefer bluetooth for the join"])
    }

    /// Car audio is Daily's: a ring with it connected asks Daily for nothing.
    @Test func aRingJoinedInTheCarIsLeftToDaily() async throws {
        clients.availableInputs = [.builtInMic, .carAudio]
        let transport = makeTransport()

        try await transport.connectWhileRinging(connection)

        #expect(clients.made.first?.calls == ["agent audio unsubscribed", "connect"])
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

        #expect(fake.calls == ["prefer earpiece for the join", "connect preferring earpiece", "connect preferring earpiece"])
        #expect(clients.portReads == 2)
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
