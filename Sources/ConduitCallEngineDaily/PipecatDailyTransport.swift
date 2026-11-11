//
//  PipecatDailyTransport.swift
//  ConduitCallEngine
//
//  The real Daily transport: wraps the Pipecat iOS client (`PipecatClient` + the
//  Daily `DailyTransport`) behind the engine's `CallTransport` protocol. Translates the
//  RTVI/Daily delegate callbacks into the engine's SDK-agnostic `TransportEvent`s —
//  no RTVI/Daily type leaks upward.
//
//  Named `PipecatDailyTransport` to avoid colliding with the SDK's own
//  `DailyTransport`.
//
//  Audio-session note: the Daily SDK manages `AVAudioSession` itself and has no
//  documented hook to defer activation to CallKit, so we join with the mic
//  DISABLED and only enable capture via `setMicEnabled` — which the engine calls
//  after CallKit activation — so the mic is never hot before activation. `attachAudioSession`/`detachAudioSession` are no-ops here
//  because Daily owns the session; they exist to satisfy the seam.
//

import Foundation
import ConduitCallEngine
import PipecatClientIOS
import PipecatClientIOSDaily

@MainActor
public final class PipecatDailyTransport: CallTransport {
    public nonisolated let events: AsyncStream<TransportEvent>

    private let client: PipecatClient
    // `PipecatClient.delegate` is weak, so this strong reference keeps the mapper alive
    // as long as the client. The mapper holds neither the client nor the transport.
    private let clientEvents: PipecatEventMapper

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.clientEvents = PipecatEventMapper(continuation: continuation)
        // Join with the mic disabled; capture is enabled only on CallKit activation
        // (via setMicEnabled), preserving the audio-session-ownership invariant.
        self.client = PipecatClient(
            options: PipecatClientOptions(
                transport: PipecatClientIOSDaily.DailyTransport(),
                enableMic: false,
                enableCam: false
            )
        )
        self.client.delegate = clientEvents
    }

    // MARK: - CallTransport

    public func connect(_ connection: CallConnection) async throws {
        clientEvents.didReportConnected = false
        clientEvents.userRequestedDisconnect = false
        do {
            let params = DailyTransportConnectionParams(
                roomUrl: connection.url.absoluteString, token: connection.token
            )
            try await client.connect(transportParams: params)
        } catch {
            Log.error(.transport, "Daily connect failed: \(error)")
            throw TransportError.connectionFailed(String(describing: error))
        }
    }

    public func disconnect() async {
        clientEvents.userRequestedDisconnect = true
        // Deliberate hangup: explicit end signal so the engine ends at once
        // instead of waiting out its human-absent grace window (design §2.5).
        // Throws when the bot was never ready — exactly when there's no one to
        // tell. The brief sleep lets the app message flush before the leave.
        if (try? client.sendClientMessage(msgType: "end-call")) != nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
        do { try await client.disconnect() }
        catch { Log.error(.transport, "Daily disconnect error: \(error)") }
    }

    public func setMicEnabled(_ enabled: Bool) async {
        do { try await client.enableMic(enable: enabled) }
        catch { Log.error(.transport, "Daily enableMic(\(enabled)) error: \(error)") }
    }

    // Daily models the iOS audio routes (speaker / receiver / Bluetooth / wired) as
    // its "mic" devices and honors `updateMic` — unlike a manual AVAudioSession
    // override, which Daily's own session management would re-assert.
    public func availableAudioDevices() async -> [AudioDeviceInfo] {
        client.getAllMics().map { AudioDeviceInfo(id: $0.id.id, name: $0.name) }
    }

    public func selectedAudioDevice() async -> AudioDeviceInfo? {
        client.selectedMic.map { AudioDeviceInfo(id: $0.id.id, name: $0.name) }
    }

    public func setAudioDevice(_ id: String) async {
        do { try await client.updateMic(micId: MediaDeviceId(id: id)) }
        catch { Log.error(.audio, "Daily setAudioDevice(\(id)) error: \(error)") }
    }

    public func attachAudioSession() async {
        // Daily owns the AVAudioSession; nothing to attach here. The CallKit-owned
        // activation handshake for Daily is the M3 on-device spike.
    }

    public func detachAudioSession() async {
        // See attachAudioSession.
    }
}

/// Translates the Pipecat client's delegate callbacks into `TransportEvent`s. Kept
/// out of the public type so hosts cannot invoke SDK callbacks on a live transport.
@MainActor
private final class PipecatEventMapper: PipecatClientDelegate {
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    var didReportConnected = false
    var userRequestedDisconnect = false

    init(continuation: AsyncStream<TransportEvent>.Continuation) {
        self.continuation = continuation
    }

    nonisolated func onTransportStateChanged(state: TransportState) {
        Task { @MainActor in self.mapState(state) }
    }

    private func mapState(_ state: TransportState) {
        switch state {
        case .initializing, .initialized, .authenticating, .authenticated, .connecting, .connected:
            continuation.yield(.connecting)
        case .ready:
            emitConnectedOnce()
        case .disconnecting:
            break
        case .disconnected:
            continuation.yield(.disconnected(reason: userRequestedDisconnect ? .requestedByUser : .networkDropped))
        case .error:
            continuation.yield(.error(.connectionFailed("transport error")))
        @unknown default:
            break
        }
    }

    private func emitConnectedOnce() {
        guard !didReportConnected else { return }
        didReportConnected = true
        continuation.yield(.connected)
    }

    nonisolated func onBotReady(botReadyData: BotReadyData) {
        Task { @MainActor in self.emitConnectedOnce() }
    }

    nonisolated func onBotDisconnected(participant: Participant) {
        continuation.yield(.disconnected(reason: .botLeft))
    }

    nonisolated func onDisconnected() {
        // Authoritative disconnect is driven by onTransportStateChanged(.disconnected);
        // this is left to the state mapping to avoid double-emitting.
    }

    nonisolated func onBotStartedSpeaking() { continuation.yield(.botStartedSpeaking) }
    nonisolated func onBotStoppedSpeaking() { continuation.yield(.botStoppedSpeaking) }
    nonisolated func onUserStartedSpeaking() { continuation.yield(.userStartedSpeaking) }
    nonisolated func onUserStoppedSpeaking() { continuation.yield(.userStoppedSpeaking) }

    nonisolated func onRemoteAudioLevel(level: Float, participant: Participant) {
        continuation.yield(.remoteAudioLevel(level))
    }

    nonisolated func onAvailableMicsUpdated(mics: [MediaDeviceInfo]) {
        continuation.yield(.audioDevicesChanged)
    }

    nonisolated func onMicUpdated(mic: MediaDeviceInfo?) {
        continuation.yield(.audioDevicesChanged)
    }

    nonisolated func onSpeakerUpdated(speaker: MediaDeviceInfo?) {
        continuation.yield(.audioDevicesChanged)
    }

    nonisolated func onError(message: RTVIMessageInbound) {
        continuation.yield(.error(.underlying(String(describing: message))))
    }
}
