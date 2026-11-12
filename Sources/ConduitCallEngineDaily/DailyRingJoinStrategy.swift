//
//  DailyRingJoinStrategy.swift
//  ConduitCallEngine
//
//  EXPERIMENTAL, not supported API: exposed only as SPI so a debug build can run the
//  device test that decides whether, and how, `PipecatDailyTransport` may join a call
//  while it is still ringing. Nobody knows yet whether a Daily join during a ring
//  disturbs the ringtone or the audio session, because Daily configures
//  `AVAudioSession` itself. Any case other than `.unsupported` may change or go away.
//
//    @_spi(RingJoinExperiment) import ConduitCallEngineDaily
//    PipecatDailyTransport(ringJoinStrategy: .agentAudioUnsubscribedUntilAnswer)
//

/// How `PipecatDailyTransport` joins a call that may still be ringing. Experimental.
@_spi(RingJoinExperiment)
public enum DailyRingJoinStrategy: String, CaseIterable, Sendable {
    /// The default: `canConnectWhileRinging` is false and the transport behaves as it
    /// does without this switch.
    case unsupported = "none"
    /// D1: join with Daily's default subscriptions (the agent's audio subscribed from
    /// the join). The agent is reported connected once it is ready, as without the switch.
    case defaultSubscriptions = "D1"
    /// D2: join with the agent's audio unsubscribed and subscribe at the first attach
    /// (after the answer, once CallKit activates the session). The Pipecat client only
    /// sends client-ready once the agent's audio is playable, so the bot is not ready
    /// before then; the agent is reported connected once the call is joined and a
    /// remote participant is in it.
    case agentAudioUnsubscribedUntilAnswer = "D2"
    /// D3: as D2, with the agent's audio staged (prepared to subscribe quickly) instead
    /// of unsubscribed.
    case agentAudioStagedUntilAnswer = "D3"
}

extension DailyRingJoinStrategy {
    /// The agent's audio from the join until the first attach; `nil` keeps Daily's default.
    var agentAudioUntilAnswer: DailyRemoteAudio? {
        switch self {
        case .unsupported, .defaultSubscriptions: nil
        case .agentAudioUnsubscribedUntilAnswer: .unsubscribed
        case .agentAudioStagedUntilAnswer: .staged
        }
    }

    /// Whether the call counts as connected once joined with a remote participant
    /// present, because the bot cannot become ready while its audio is held back.
    var reportsPresenceAsReady: Bool {
        agentAudioUntilAnswer != nil
    }
}
