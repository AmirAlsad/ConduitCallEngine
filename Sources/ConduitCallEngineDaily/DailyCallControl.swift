//
//  DailyCallControl.swift
//  ConduitCallEngine
//
//  The seam over the Daily call client that `PipecatDailyTransport` reaches past
//  Pipecat for: the agent's audio subscription, whether a remote participant is in
//  the call, and the audio route Daily prefers. Pipecat exposes the call client
//  (`DailyTransport.dailyCallClient`) but none of these as needed (its `updateMic`
//  sets the preferred device only, which Daily resets at its next input change).
//  Tests replace it, because the Pipecat transport they use is a fake.
//

import ConduitCallEngine
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
    /// Asks Daily to prefer `route` for the call's audio, from now on and across its
    /// input changes, returning once Daily has it.
    func setPreferredAudioRoute(_ route: DailyAudioRoute) async throws
    /// Asks Daily to prefer `route` without changing its inputs, for a join that
    /// starts before CallKit's activation and names `route` in its microphone input.
    /// Daily keeps it, leaving the audio session alone, until its join starts
    /// managing the session.
    func setPreferredAudioRouteForTheJoin(_ route: DailyAudioRoute) async throws
    /// The route Daily reports as its preferred device; nil is Daily's own default.
    var preferredAudioRoute: DailyAudioRoute? { get }
    /// Daily's preferred and current audio device and its microphone input, for logs.
    var audioRouteDescription: String { get }
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

    /// Sets Daily's preferred audio device, which Daily applies at once when it
    /// manages the session (from the join on) and keeps until then, and names it in
    /// the microphone input settings: after every input change (the join's, a mic
    /// enable) Daily sets its preferred device from that setting, or, with none,
    /// back to its default, the loudspeaker.
    func setPreferredAudioRoute(_ route: DailyAudioRoute) async throws {
        guard let callClient = transport?.dailyCallClient else { throw NoCallClient() }
        try await callClient.setPreferredAudioDevice(route.dailyDevice)
        _ = try await callClient.updateInputs(.set(microphone: .set(settings: route.microphoneSettings)))
    }

    /// Daily's audio manager stores a preferred device and applies it only while it
    /// manages the session, which starts at the join.
    func setPreferredAudioRouteForTheJoin(_ route: DailyAudioRoute) async throws {
        guard let callClient = transport?.dailyCallClient else { throw NoCallClient() }
        try await callClient.setPreferredAudioDevice(route.dailyDevice)
    }

    var preferredAudioRoute: DailyAudioRoute? {
        transport?.dailyCallClient?.preferredAudioDevice.flatMap(DailyAudioRoute.init)
    }

    var audioRouteDescription: String {
        guard let callClient = transport?.dailyCallClient else { return "no Daily call client" }
        let preferred = callClient.preferredAudioDevice.map(\.deviceID) ?? "none (Daily default)"
        let input = callClient.inputs.microphone.settings.deviceID ?? "none"
        return "preferred \(preferred), current \(callClient.audioDevice.deviceID), mic input device \(input)"
    }

    /// The connection parameters of a join that prefers `route` from its start: the
    /// join's microphone input names it. `nil` joins with Daily's own choice.
    static func connectionParams(for connection: CallConnection, preferring route: DailyAudioRoute?) -> DailyTransportConnectionParams {
        DailyTransportConnectionParams(
            roomUrl: connection.url.absoluteString,
            token: connection.token,
            joinSettings: route.map { ClientSettingsUpdate(inputs: .set(microphone: .set(settings: $0.microphoneSettings))) }
        )
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

private extension DailyAudioRoute {
    init?(_ device: AudioDeviceType) {
        switch device {
        case .earpiece: self = .earpiece
        case .speakerphone: self = .speaker
        case .bluetooth: self = .bluetooth
        case .wired: self = .wired
        @unknown default: return nil
        }
    }

    var dailyDevice: AudioDeviceType {
        switch self {
        case .earpiece: .earpiece
        case .speaker: .speakerphone
        case .bluetooth: .bluetooth
        case .wired: .wired
        }
    }

    var microphoneSettings: Update<AudioMediaTrackSettingsUpdate> {
        .set(deviceID: .set(dailyDevice.deviceID))
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
