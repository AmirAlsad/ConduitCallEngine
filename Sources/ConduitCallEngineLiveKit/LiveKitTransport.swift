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
//  Connecting while the call still rings is supported (`canConnectWhileRinging`):
//  joining the room touches no audio. LiveKit does not configure the session (the
//  automatic configuration is off), the remote audio it subscribes to only queues a
//  playout request while the engine is unavailable, the mic is published only by
//  `setMicEnabled(true)`, and route changes only emit `.audioDevicesChanged`.
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

    /// True: `connect` configures and activates no audio session, starts no audio I/O
    /// and plays nothing until `attachAudioSession()`, and `send(_:)` reaches the agent
    /// over the room's data channel as soon as the room is connected.
    public nonisolated var canConnectWhileRinging: Bool { true }

    // MARK: - CallTransport

    public func connect(_ connection: CallConnection) async throws {
        let plan = roomEvents.gate.planConnect(
            roomPhase: LiveKitEndCallSignal.RoomPhase(room.connectionState),
            remotesPresent: !room.remoteParticipants.isEmpty
        )
        switch plan {
        case .join:
            break
        case .reportConnected:
            Log.info(.transport, "LiveKit connect: the room healed by itself; reporting it connected")
            continuation.yield(.connected)
            return
        case .refuse:
            Log.warning(.transport, "LiveKit connect: the room is still reconnecting; not rejoining")
            throw TransportError.connectionFailed("LiveKit is still reconnecting")
        }
        roomEvents.gate = LiveKitConnectGate()
        roomEvents.wasBotSpeaking = false
        do {
            // Engine off until CallKit activates — unless activation already
            // happened (also keeps the engine alive across a mid-call reconnect).
            try AudioManager.shared.setEngineAvailability(isSessionAttached ? .default : .none)
            Log.info(.audio, "LiveKit connect: audio engine \(isSessionAttached ? "available (attached)" : "unavailable until attach")")
            try await room.connect(url: connection.url.absoluteString, token: connection.token ?? "")
        } catch {
            Log.error(.transport, "LiveKit connect failed: \(error)")
            throw mapConnectError(error)
        }
    }

    public func disconnect() async {
        roomEvents.gate.userRequestedDisconnect = true
        await publishClientMessage("end-call")
        await room.disconnect()
    }

    /// Delivers a call-control signal as an RTVI client message on the data channel,
    /// like the end-call signal, and returns within `LiveKitEndCallSignal.deadline`.
    public func send(_ signal: CallSignal) async {
        await publishClientMessage(signal.rawValue)
    }

    /// Publishes an RTVI client message reliably, so LiveKit retransmits it rather
    /// than dropping it under backpressure (its default is lossy). A Pipecat bot must
    /// read it from the raw data event, because Pipecat's LiveKit input does not
    /// deliver client RTVI messages to its RTVI processor. See `LiveKitEndCallSignal`
    /// for when it is sent; it is never retried.
    private func publishClientMessage(_ type: String) async {
        guard let payload = LiveKitEndCallSignal.payload(type: type) else { return }
        let room = room
        let finished = await LiveKitEndCallSignal.run(within: LiveKitEndCallSignal.deadline) {
            // A publish issued before the connect has set up the room's transports
            // would not start the publisher's negotiation, so let the connect finish first.
            while room.connectionState == .connecting {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            let phase = LiveKitEndCallSignal.RoomPhase(room.connectionState)
            guard LiveKitEndCallSignal.shouldSend(in: phase) else {
                Log.info(.transport, "LiveKit client message \(type) dropped: the room is \(phase)")
                return
            }
            do {
                try await room.localParticipant.publish(data: payload, options: DataPublishOptions(reliable: true))
                Log.info(.transport, "LiveKit client message \(type) sent (reliable)")
            } catch {
                Log.warning(.transport, "LiveKit client message \(type) publish failed: \(error)")
            }
        }
        if !finished {
            Log.warning(.transport, "LiveKit client message \(type) not handed to the data channel within \(LiveKitEndCallSignal.deadline); left pending")
        }
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

    /// CallKit activated the session (or a hold ended): let LiveKit's audio engine run,
    /// which resumes the playout and capture it was asked for while unavailable.
    public func attachAudioSession() async {
        isSessionAttached = true
        do {
            try AudioManager.shared.setEngineAvailability(.default)
            Log.info(.audio, "LiveKit attach: audio engine available (playout restored); running=\(AudioManager.shared.isEngineRunning)")
        } catch {
            Log.error(.audio, "LiveKit setEngineAvailability(.default) error: \(error)")
        }
    }

    /// A hold, CallKit's deactivation or teardown: stop LiveKit's audio engine, so
    /// neither playout nor capture runs, while the room stays connected.
    public func detachAudioSession() async {
        isSessionAttached = false
        do {
            try AudioManager.shared.setEngineAvailability(.none)
            Log.info(.audio, "LiveKit detach: audio engine unavailable (playout and capture stopped); running=\(AudioManager.shared.isEngineRunning)")
        } catch {
            Log.error(.audio, "LiveKit setEngineAvailability(.none) error: \(error)")
        }
    }

    private func mapConnectError(_ error: Error) -> TransportError {
        let kind: LiveKitConnectFailure.Kind
        switch (error as? LiveKitError)?.type {
        case .insufficientPermissions: kind = .insufficientPermissions
        case .validation: kind = .validation(message: (error as? LiveKitError)?.message)
        default: kind = .other
        }
        return LiveKitConnectFailure.isRejectedCredentials(kind)
            ? .authenticationFailed
            : .connectionFailed(String(describing: error))
    }
}

private extension LiveKitEndCallSignal.RoomPhase {
    init(_ state: ConnectionState) {
        switch state {
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .reconnecting: self = .reconnecting
        case .connected: self = .connected
        case .disconnecting: self = .disconnecting
        @unknown default: self = .disconnected
        }
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

    init(continuation: AsyncStream<TransportEvent>.Continuation) {
        self.continuation = continuation
    }

    private func onRoomConnected(hasRemote: Bool) {
        if let event = gate.roomDidConnect() { continuation.yield(event) }
        if hasRemote, let event = gate.remoteDidJoin() { continuation.yield(event) }
    }

    private func onReconnectStarted() {
        if let event = gate.reconnectDidStart() { continuation.yield(event) }
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
            Task { @MainActor in self.onReconnectStarted() }
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
        Task { @MainActor in self.onReconnectStarted() }
    }

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode mode: ReconnectMode) {
        // The engine's `.reconnecting` display recovers on a fresh `.connected`, but
        // only if the gate finds the room usable. The connection state is the one this
        // completion was reported with. The remotes are read after the hop: LiveKit
        // applies a full reconnect's join response in a detached task.
        let isRoomConnected = room.connectionState == .connected
        Task { @MainActor in
            guard let event = self.gate.reconnectDidComplete(
                roomConnected: isRoomConnected, remotesPresent: !room.remoteParticipants.isEmpty
            ) else { return }
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
