//
//  FakeDailyCallControl.swift
//  ConduitCallEngineDailyTests
//
//  Stands in for the Daily call client behind a session's Pipecat transport. Each
//  subscription change and preferred-device request is recorded in the fake Pipecat
//  transport's call log ("agent audio <state>", "prefer <route>"), so tests see it
//  in order with the join and the leave.
//

import Foundation
@testable import ConduitCallEngineDaily

@MainActor
final class FakeDailyCallControl: DailyCallControlling {
    struct Refused: Error {}

    private let transport: FakePipecatTransport
    var hasRemoteParticipant: Bool {
        get { isRemotePresent || transport.isBotPresent }
        set { isRemotePresent = newValue }
    }
    private var isRemotePresent = false
    /// Changes are refused until the call is joined, as Daily might.
    var refusesBeforeJoin = false
    /// Each change suspends this many times before completing, so others can interleave.
    var suspensions = 0

    init(transport: FakePipecatTransport) {
        self.transport = transport
    }

    func setRemoteAudio(_ state: DailyRemoteAudio) async throws {
        for _ in 0..<suspensions { await Task.yield() }
        if refusesBeforeJoin, ![.connected, .ready].contains(transport.state()) { throw Refused() }
        transport.record("agent audio \(state)")
        transport.remoteAudioDidChange(state)
    }

    /// When set, app messages fail with it.
    var appMessageError: (any Error)?

    func sendAppMessage(_ json: Data) async throws {
        if let appMessageError { throw appMessageError }
        transport.recordAppMessage(json)
    }

    var remoteAudioDescription: String { "fake" }

    /// What Daily reports as its preferred device: the last route it accepted, until
    /// a test makes Daily drop it.
    var preferredAudioRoute: DailyAudioRoute?
    /// Preferred-device requests are refused while set.
    var refusesRoutes = false
    /// Each preferred-device request suspends this many times before completing.
    var routeSuspensions = 0

    func setPreferredAudioRoute(_ route: DailyAudioRoute) async throws {
        for _ in 0..<routeSuspensions { await Task.yield() }
        if refusesRoutes { throw Refused() }
        transport.record("prefer \(route)")
        preferredAudioRoute = route
    }

    var audioRouteDescription: String { "fake" }
}
