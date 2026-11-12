//
//  FakeDailyCallControl.swift
//  ConduitCallEngineDailyTests
//
//  Stands in for the Daily call client behind a session's Pipecat transport. Each
//  subscription change is recorded in the fake Pipecat transport's call log
//  ("agent audio <state>"), so tests see it in order with the join and the leave.
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

    var remoteAudioDescription: String { "fake" }
}
