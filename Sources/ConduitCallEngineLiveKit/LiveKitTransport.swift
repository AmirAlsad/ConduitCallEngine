//
//  LiveKitTransport.swift
//  ConduitCallEngine
//
//  Native LiveKit transport behind the engine's `CallTransport` seam. Unlike Daily,
//  LiveKit supports manual audio: we disable its automatic `AVAudioSession`
//  management and gate its audio engine on CallKit activation
//  (`attachAudioSession`/`detachAudioSession` → `AudioManager.setEngineAvailability`).
//  Because CallKit then truly owns the session, the native call-screen route button
//  moves the audio and the in-app picker routes via `AVAudioSession`
//  (`LiveKitAudioRouter`). RTVI-style signals are re-derived from LiveKit: `.connected`
//  when the room and the agent (a remote participant) are both ready, bot-speaking
//  from active speakers. Device-only (WebRTC audio aborts in the simulator).
//

import AVFoundation
import Foundation
import ConduitCallEngine
import LiveKit

@MainActor
public final class LiveKitTransport: NSObject, CallTransport {
    public nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation

    private var room: Room!
    private var gate = LiveKitConnectGate()
    private var wasBotSpeaking = false
    private var routeObserver: NSObjectProtocol?
    /// Whether CallKit has activated the audio session (attach/detach edges).
    /// Activation and connect are unordered (see potential_skills/callkit.md):
    /// on a cold launch the pairing fetch is slow enough that activation lands
    /// mid-connect, and an unconditional `.none` there would stomp it — the
    /// engine then never starts and the call has no mic.
    private var isSessionAttached = false

    public override init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
        super.init()

        // Manual audio: CallKit owns the AVAudioSession; the engine starts only
        // inside the CallKit activation window (see attachAudioSession).
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        self.room = Room(delegate: self)

        // The route can change from the native CallKit screen too — keep the in-app
        // picker in sync. Continuation is thread-safe, so yield directly.
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [continuation] _ in
            continuation.yield(.audioDevicesChanged)
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    // MARK: - CallTransport

    public func connect(_ connection: CallConnection) async throws {
        gate = LiveKitConnectGate()
        wasBotSpeaking = false
        do {
            // Engine off until CallKit activates — unless activation already
            // happened (also keeps the engine alive across a mid-call reconnect).
            try AudioManager.shared.setEngineAvailability(isSessionAttached ? .default : .none)
            try await room.connect(url: connection.url.absoluteString, token: connection.token ?? "")
        } catch {
            Log.error(.transport, "LiveKit connect failed: \(error)")
            throw mapConnectError(error)
        }
    }

    public func disconnect() async {
        gate.userRequestedDisconnect = true
        await sendEndCallSignal()
        await room.disconnect()
    }

    /// Deliberate hangup: tell the engine to end NOW instead of burning its
    /// human-absent grace window (which exists for genuine drops — design §2.5).
    /// RTVI client-message shape over the data channel; the reference engine
    /// listens on the raw data event because Pipecat's LiveKit input path doesn't
    /// deliver client RTVI messages to its RTVI processor.
    private func sendEndCallSignal() async {
        guard room.connectionState == .connected else { return }
        let message: [String: Any] = [
            "id": String(UUID().uuidString.prefix(8)),
            "label": "rtvi-ai",
            "type": "client-message",
            "data": ["t": "end-call"],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        do { try await room.localParticipant.publish(data: payload) }
        catch { Log.warning(.transport, "end-call signal publish failed: \(error)") }
    }

    public func setMicEnabled(_ enabled: Bool) async {
        do {
            _ = try await room.localParticipant.setMicrophone(enabled: enabled)
        } catch {
            Log.error(.transport, "LiveKit setMicrophone(\(enabled)) error: \(error)")
        }
    }

    public func availableAudioDevices() async -> [AudioDeviceInfo] {
        LiveKitAudioRouter.availableDevices()
    }

    public func selectedAudioDevice() async -> AudioDeviceInfo? {
        guard let id = LiveKitAudioRouter.selectedDeviceID() else { return nil }
        return LiveKitAudioRouter.availableDevices().first { $0.id == id }
    }

    public func setAudioDevice(_ id: String) async {
        LiveKitAudioRouter.select(id)
    }

    public func attachAudioSession() async {
        // CallKit activated the session — let LiveKit's engine run now.
        isSessionAttached = true
        do { try AudioManager.shared.setEngineAvailability(.default) }
        catch { Log.error(.audio, "LiveKit setEngineAvailability(.default) error: \(error)") }
    }

    public func detachAudioSession() async {
        isSessionAttached = false
        do { try AudioManager.shared.setEngineAvailability(.none) }
        catch { Log.error(.audio, "LiveKit setEngineAvailability(.none) error: \(error)") }
    }

    // MARK: - Event mapping (main-actor)

    private func onRoomConnected(hasRemote: Bool) {
        if let event = gate.roomDidConnect() { continuation.yield(event) }
        if hasRemote, let event = gate.remoteDidJoin() { continuation.yield(event) }
    }

    private func onSpeakers(botSpeaking: Bool, level: Float) {
        if botSpeaking != wasBotSpeaking {
            wasBotSpeaking = botSpeaking
            continuation.yield(botSpeaking ? .botStartedSpeaking : .botStoppedSpeaking)
        }
        if botSpeaking { continuation.yield(.remoteAudioLevel(level)) }
    }

    private func mapConnectError(_ error: Error) -> TransportError {
        if let lkError = error as? LiveKitError {
            if lkError.type == .insufficientPermissions { return .authenticationFailed }
            let description = String(describing: lkError).lowercased()
            if ["unauthorized", "401", "permission", "token"].contains(where: description.contains) {
                return .authenticationFailed
            }
        }
        return .connectionFailed(String(describing: error))
    }
}

// MARK: - RoomDelegate (called off the main actor → hop before touching state)

extension LiveKitTransport: RoomDelegate {
    public nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from oldState: ConnectionState) {
        switch state {
        case .connecting:
            continuation.yield(.connecting)
        case .connected:
            let hasRemote = !room.remoteParticipants.isEmpty
            Task { @MainActor in self.onRoomConnected(hasRemote: hasRemote) }
        case .reconnecting:
            continuation.yield(.reconnecting)
        default:
            break
        }
    }

    public nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            if let event = self.gate.remoteDidJoin() { self.continuation.yield(event) }
        }
    }

    public nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let remotesRemain = !room.remoteParticipants.isEmpty
        Task { @MainActor in
            if let event = self.gate.remoteDidLeave(remotesRemain: remotesRemain) {
                self.continuation.yield(event)
            }
        }
    }

    public nonisolated func room(_ room: Room, didStartReconnectWithMode mode: ReconnectMode) {
        continuation.yield(.reconnecting)
    }

    public nonisolated func room(_ room: Room, didCompleteReconnectWithMode mode: ReconnectMode) {
        // The engine's `.reconnecting` display recovers on a fresh `.connected`.
        continuation.yield(.connected)
    }

    public nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in self.continuation.yield(self.gate.roomDidDisconnect()) }
    }

    public nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        let remoteSpeakers = participants.compactMap { $0 as? RemoteParticipant }
        let botSpeaking = !remoteSpeakers.isEmpty
        let level = remoteSpeakers.map(\.audioLevel).max() ?? 0
        Task { @MainActor in self.onSpeakers(botSpeaking: botSpeaking, level: level) }
    }
}
