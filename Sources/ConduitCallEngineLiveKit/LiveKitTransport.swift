//
//  LiveKitTransport.swift
//  ConduitCallEngine
//
//  Native LiveKit transport behind the engine's `CallTransport` seam. Unlike Daily,
//  LiveKit supports manual audio: the transport disables its automatic
//  `AVAudioSession` management and gates its audio engine on CallKit activation
//  (`attachAudioSession`/`detachAudioSession` → `AudioManager.setEngineAvailability`).
//  Because CallKit then truly owns the session, the native call-screen route button
//  moves the audio, and `setAudioDevice` routes via `AVAudioSession`
//  (`LiveKitAudioRouter`). RTVI-style signals are re-derived from LiveKit: `.connected`
//  when the room is connected and a remote participant is present, bot-speaking
//  from active speakers. Device-only (WebRTC audio aborts in the simulator).
//

import AVFoundation
import Foundation
import ConduitCallEngine
import LiveKit

@MainActor
public final class LiveKitTransport: CallTransport {
    public nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation

    private let room: Room
    // `Room` holds its delegates weakly, so this strong reference keeps the mapper alive
    // as long as the room. The mapper holds neither the room nor the transport.
    private let roomEvents: RoomEventMapper
    private var routeObserver: NSObjectProtocol?
    /// Whether CallKit has activated the audio session (attach/detach edges).
    /// Activation and connect are unordered: when credential resolution is slow,
    /// activation lands mid-connect, and an unconditional `.none` there would stomp
    /// it — LiveKit's audio engine then never starts and the call has no mic.
    private var isSessionAttached = false

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation

        // Manual audio: CallKit owns the AVAudioSession; the engine starts only
        // inside the CallKit activation window (see attachAudioSession).
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        let roomEvents = RoomEventMapper(continuation: continuation)
        self.roomEvents = roomEvents
        self.room = Room(delegate: roomEvents)

        // The route can change from the native CallKit screen too — keep a host's
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
        // An abandoned SDK reconnect left the room to be disconnected; a connect
        // running alongside that teardown would be torn down with it.
        await roomEvents.roomReset?.value
        roomEvents.gate = LiveKitConnectGate()
        roomEvents.wasBotSpeaking = false
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
        roomEvents.gate.userRequestedDisconnect = true
        await sendEndCallSignal()
        await room.disconnect()
    }

    /// Deliberate hangup: tell the remote side to end now instead of waiting out
    /// the grace period it may give a dropped participant. Sent as an RTVI client
    /// message over the data channel; a Pipecat bot must read it from the raw data
    /// event, because Pipecat's LiveKit input does not deliver client RTVI messages
    /// to its RTVI processor.
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

/// Translates `Room`'s delegate callbacks into `TransportEvent`s. Kept out of the public
/// type so hosts cannot invoke SDK callbacks on a live transport. The callbacks arrive off
/// the main actor and hop to it before touching the gate.
@MainActor
private final class RoomEventMapper: NSObject, RoomDelegate {
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    var gate = LiveKitConnectGate()
    var wasBotSpeaking = false
    /// Disconnects a room whose reconnect the SDK abandoned while still reporting it
    /// connected, so the engine's next connect starts from a disconnected room.
    private(set) var roomReset: Task<Void, Never>?

    init(continuation: AsyncStream<TransportEvent>.Continuation) {
        self.continuation = continuation
    }

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

    nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from oldState: ConnectionState) {
        switch state {
        case .connecting:
            continuation.yield(.connecting)
        case .connected:
            let hasRemote = !room.remoteParticipants.isEmpty
            Task { @MainActor in self.onRoomConnected(hasRemote: hasRemote) }
        case .reconnecting:
            // Hop like the completion does, so a reconnect that starts right after
            // one completes cannot overtake that completion's `.connected`.
            Task { @MainActor in self.continuation.yield(.reconnecting) }
        default:
            break
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            if let event = self.gate.remoteDidJoin() { self.continuation.yield(event) }
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let remotesRemain = !room.remoteParticipants.isEmpty
        Task { @MainActor in
            if let event = self.gate.remoteDidLeave(remotesRemain: remotesRemain) {
                self.continuation.yield(event)
            }
        }
    }

    nonisolated func room(_ room: Room, didStartReconnectWithMode mode: ReconnectMode) {
        Task { @MainActor in self.continuation.yield(.reconnecting) }
    }

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode mode: ReconnectMode) {
        // The engine's `.reconnecting` display recovers on a fresh `.connected`, but
        // only if the gate finds the room usable; otherwise this is the drop.
        let isRoomConnected = room.connectionState == .connected
        let remotesPresent = !room.remoteParticipants.isEmpty
        Task { @MainActor in
            guard let event = self.gate.reconnectDidComplete(
                roomConnected: isRoomConnected, remotesPresent: remotesPresent
            ) else { return }
            if case .disconnected = event {
                self.roomReset = Task { await room.disconnect() }
            }
            self.continuation.yield(event)
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            if let event = self.gate.roomDidDisconnect() { self.continuation.yield(event) }
        }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        let remoteSpeakers = participants.compactMap { $0 as? RemoteParticipant }
        let botSpeaking = !remoteSpeakers.isEmpty
        let level = remoteSpeakers.map(\.audioLevel).max() ?? 0
        Task { @MainActor in self.onSpeakers(botSpeaking: botSpeaking, level: level) }
    }
}
