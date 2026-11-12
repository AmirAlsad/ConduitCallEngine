//
//  DailyCallControl.swift
//  ConduitCallEngine
//
//  The seam over the Daily call client that `PipecatDailyTransport` reaches past
//  Pipecat for: the agent's audio subscription and whether a remote participant is in
//  the call. Pipecat exposes the call client (`DailyTransport.dailyCallClient`) but
//  neither operation. Tests replace it, because the Pipecat transport they use is a fake.
//

import Daily
import Foundation
import PipecatClientIOS
import PipecatClientIOSDaily

@MainActor
protocol DailyCallControlling: AnyObject {
    /// Sets the subscription to every remote participant's microphone track.
    func setRemoteAudio(_ state: DailyRemoteAudio) async throws
    var hasRemoteParticipant: Bool { get }
    /// Sends `json` as a Daily app message to everyone in the call, returning once
    /// Daily has sent it, or throwing if it could not.
    func sendAppMessage(_ json: Data) async throws
    /// The remote participants' microphone state and subscription, for logs.
    var remoteAudioDescription: String { get }
}

/// Controls the call client of a Pipecat `DailyTransport`. Holds the transport weakly:
/// the Pipecat client owns it, and a released transport has no call client.
@MainActor
final class DailyCallClientControl: DailyCallControlling {
    private weak var transport: PipecatClientIOSDaily.DailyTransport?

    init(transport: PipecatClientIOSDaily.DailyTransport) {
        self.transport = transport
    }

    static func make(for transport: any Transport) -> DailyCallControlling? {
        (transport as? PipecatClientIOSDaily.DailyTransport).map(DailyCallClientControl.init)
    }

    private struct NoCallClient: Swift.Error {}

    /// Changes the base subscription profile, which every participant has unless given
    /// another, so the agent is covered whether it is already in the call, joins later
    /// or rejoins. Pipecat bots publish their voice as the microphone track.
    func setRemoteAudio(_ state: DailyRemoteAudio) async throws {
        guard let callClient = transport?.dailyCallClient else { throw NoCallClient() }
        let microphone = MicrophoneSubscriptionSettingsUpdate(subscriptionState: .set(state.dailyState))
        let profiles: SubscriptionProfileSettingsUpdatesByProfile = [
            .base: .set(MediaSubscriptionSettingsUpdate(microphone: .set(microphone))),
        ]
        _ = try await callClient.updateSubscriptionProfiles(.set(profiles))
    }

    var hasRemoteParticipant: Bool {
        !(transport?.dailyCallClient?.participants.remote.isEmpty ?? true)
    }

    /// The call Pipecat's Daily transport makes for a message (`sendAppMessage(json:to:)`
    /// to everyone), in the form that reports Daily's result.
    func sendAppMessage(_ json: Data) async throws {
        guard let callClient = transport?.dailyCallClient else { throw NoCallClient() }
        try await callClient.sendAppMessage(json: json, to: .all)
    }

    var remoteAudioDescription: String {
        guard let remote = transport?.dailyCallClient?.participants.remote, !remote.isEmpty else {
            return "no remote participant"
        }
        return remote.values.map { participant in
            let microphone = participant.media?.microphone
            return "mic \(String(describing: microphone?.state)), subscribed \(String(describing: microphone?.subscribed))"
        }
        .joined(separator: "; ")
    }
}

private extension DailyRemoteAudio {
    var dailyState: SubscriptionState {
        switch self {
        case .subscribed: .subscribed
        case .unsubscribed: .unsubscribed
        }
    }
}
