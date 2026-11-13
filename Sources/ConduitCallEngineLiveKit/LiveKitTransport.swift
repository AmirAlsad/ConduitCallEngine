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
//  Joins are the transport's own: `room.connect` runs in a task the transport keeps,
//  because LiveKit's `Room` cannot take two connects at once (each one's cleanup fails
//  the other) and ignores a disconnect while it is still setting a connect up. A newer
//  `connect` cancels a join still in flight and waits for its cleanup before joining
//  (a hold and resume during a reconnect attempt's join brings one), and `disconnect()`
//  lets a join in flight finish before it signals and leaves; a join it could not
//  wait for leaves the room itself when it completes.
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

/// The LiveKit transport: a LiveKit room behind `CallTransport`, with LiveKit's
/// audio engine kept off until CallKit activates the session. `CallConnection.url`
/// is the LiveKit server URL (`wss://...`) and `token` an access token with a join
/// grant; the call is `.connected` once the room is connected and a remote
/// participant is present. Supports joining while ringing. Main-actor isolated;
/// create one per call, on a device only (LiveKit's WebRTC audio aborts in the
/// simulator). Turns off LiveKit's automatic `AVAudioSession` configuration for the
/// whole process. The Integration Guide, section 11, has what the server side must do.
@MainActor
public final class LiveKitTransport: CallTransport {
    public nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation

    private let room: LiveKitRoomControlling
    private let audioEngine: LiveKitAudioEngineControlling
    // `Room` holds its delegates weakly, so this strong reference keeps the mapper alive
    // as long as the room. The mapper holds neither the room nor the transport.
    private let roomEvents: RoomEventMapper
    private var routeObserver: NSObjectProtocol?
    /// Whether CallKit has activated the audio session (attach/detach edges).
    /// Activation and connect are unordered: when credential resolution is slow,
    /// activation lands mid-connect, and an unconditional `.none` there would stomp
    /// it — LiveKit's audio engine then never starts and the call has no mic.
    private var isSessionAttached = false
    /// Why the last attach could not start LiveKit's audio engine; nil once it did,
    /// and after a detach.
    private var attachFailure: String?

    /// The join in flight: `room.connect`, in a task of the transport's own.
    private var join: (id: Int, task: Task<Void, any Error>)?
    private var joinCount = 0
    /// Joins that were in flight when `disconnect()` left the room: LiveKit ignored that
    /// leave if the room had not moved to connecting yet, so each leaves by itself.
    private var joinsToLeave: Set<Int> = []
    /// Counts `disconnect()` calls, so a connect that waited for an earlier join to
    /// end can tell the host left meanwhile.
    private var disconnectCount = 0
    /// Counts `connect(_:)` calls, so of two connects waiting for the same earlier
    /// join to end, only the newer one joins.
    private var connectCount = 0

    /// A transport over a new `Room`.
    public convenience init() {
        // Manual audio: CallKit owns the AVAudioSession; the engine starts only
        // inside the CallKit activation window (see attachAudioSession).
        self.init(makeRoom: { LiveKitSDKRoom(delegate: $0) }, audioEngine: LiveKitSDKAudioEngine())
    }

    init(
        makeRoom: (RoomEventMapper) -> LiveKitRoomControlling,
        audioEngine: LiveKitAudioEngineControlling
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
        self.audioEngine = audioEngine
        let roomEvents = RoomEventMapper(continuation: continuation)
        self.roomEvents = roomEvents
        self.room = makeRoom(roomEvents)

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
        let disconnects = disconnectCount
        connectCount += 1
        let generation = connectCount
        if let previous = join {
            Log.info(.transport, "LiveKit connect: superseding the join still in flight")
            // The cancelled join's cleanup reports its room's participants leaving; that
            // attempt is over, so it must not report it as the agent's hangup.
            roomEvents.gate.userRequestedDisconnect = true
            previous.task.cancel()
            _ = await previous.task.result
            guard disconnectCount == disconnects else {
                throw TransportError.connectionFailed("LiveKit transport was disconnected")
            }
            guard connectCount == generation else {
                throw TransportError.connectionFailed("LiveKit connect superseded by a newer one")
            }
        }
        let plan = roomEvents.gate.planConnect(
            roomPhase: room.phase,
            remotesPresent: room.hasRemoteParticipants
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
        joinCount += 1
        let id = joinCount
        let room = room
        let result: Result<Void, any Error>
        do {
            // Engine off until CallKit activates — unless activation already
            // happened (also keeps the engine alive across a mid-call reconnect).
            try audioEngine.setAvailable(isSessionAttached)
            Log.info(.audio, "LiveKit connect: audio engine \(isSessionAttached ? "available (attached)" : "unavailable until attach")")
            let task = Task { @MainActor in
                try await room.connect(url: connection.url.absoluteString, token: connection.token ?? "")
            }
            join = (id, task)
            // The caller cancelling its connect cancels the join, as when it ran inline.
            result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        } catch {
            result = .failure(error)
        }
        if join?.id == id { join = nil }
        if joinsToLeave.remove(id) != nil {
            Log.warning(.transport, "LiveKit connect: the host disconnected while this join was in flight; leaving the room")
            await leaveRoom()
            throw TransportError.connectionFailed("LiveKit transport was disconnected while joining")
        }
        if case .failure(let error) = result {
            Log.error(.transport, "LiveKit connect failed: \(error)")
            throw mapConnectError(error)
        }
    }

    public func disconnect() async {
        disconnectCount += 1
        roomEvents.gate.userRequestedDisconnect = true
        let pending = join
        await publishClientMessage("end-call", after: pending?.task)
        await room.disconnect()
        guard let pending else { return }
        if join?.id == pending.id {
            joinsToLeave.insert(pending.id)
        } else if room.phase != .disconnected, room.phase != .disconnecting {
            // The join completed while the leave above found nothing to leave.
            await leaveRoom()
        }
    }

    /// Signals the end of the call and leaves.
    private func leaveRoom() async {
        await publishClientMessage("end-call")
        await room.disconnect()
    }

    /// Delivers a call-control signal as an RTVI client message on the data channel,
    /// like the end-call signal, and returns within `LiveKitEndCallSignal.deadline`:
    /// `.sent` once LiveKit took it on the reliable channel, `.failed` otherwise.
    @discardableResult
    public func send(_ signal: CallSignal) async -> CallSignalDelivery {
        await publishClientMessage(signal.rawValue)
    }

    /// Publishes an RTVI client message reliably, so LiveKit retransmits it rather
    /// than dropping it under backpressure (its default is lossy). A Pipecat bot must
    /// read it from the raw data event, because Pipecat's LiveKit input does not
    /// deliver client RTVI messages to its RTVI processor. See `LiveKitEndCallSignal`
    /// for when it is sent; it is never retried.
    /// `join`, when given, is a join in flight to let finish first, within the same bound.
    @discardableResult
    private func publishClientMessage(_ type: String, after join: Task<Void, any Error>? = nil) async -> CallSignalDelivery {
        guard let payload = LiveKitEndCallSignal.payload(type: type) else { return .failed }
        let room = room
        let outcome = PublishOutcome()
        let finished = await LiveKitEndCallSignal.run(within: LiveKitEndCallSignal.deadline) { @MainActor in
            if let join { _ = await join.result }
            // A publish issued before the connect has set up the room's transports
            // would not start the publisher's negotiation, so let the connect finish first.
            while room.phase == .connecting {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            let phase = room.phase
            guard LiveKitEndCallSignal.shouldSend(in: phase) else {
                Log.info(.transport, "LiveKit client message \(type) dropped: the room is \(phase)")
                return
            }
            do {
                try await room.publish(payload)
                outcome.isSent = true
                Log.info(.transport, "LiveKit client message \(type) sent (reliable)")
            } catch {
                Log.warning(.transport, "LiveKit client message \(type) publish failed: \(error)")
            }
        }
        if !finished {
            Log.warning(.transport, "LiveKit client message \(type) not handed to the data channel within \(LiveKitEndCallSignal.deadline); left pending")
        }
        return outcome.isSent ? .sent : .failed
    }

    public func setMicEnabled(_ enabled: Bool) async {
        do {
            try await room.setMicrophone(enabled: enabled)
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
    /// which resumes the playout and capture it was asked for while unavailable. A
    /// start LiveKit refuses is logged with the session's state and reported through
    /// `audioStartFailure()`; the attach after such a failure takes the engine down
    /// first, since asking LiveKit again for the availability it already holds may
    /// change nothing.
    public func attachAudioSession() async {
        isSessionAttached = true
        if let previous = attachFailure {
            Log.info(.audio, "LiveKit attach after a failed start (\(previous)): making the engine unavailable first")
            do { try audioEngine.setAvailable(false) }
            catch { Log.warning(.audio, "LiveKit setEngineAvailability(.none) before attaching again failed: \(error)") }
        }
        do {
            try audioEngine.setAvailable(true)
            attachFailure = nil
            Log.info(.audio, "LiveKit attach: audio engine available (playout restored); running=\(audioEngine.isRunning)")
        } catch {
            attachFailure = "setEngineAvailability(.default) failed: \(error)"
            Log.error(.audio, "LiveKit attach: setEngineAvailability(.default) error: \(error); \(audioEngine.stateDescription); session: \(Self.sessionDescription)")
        }
    }

    public func audioStartFailure() async -> String? { attachFailure }

    /// A hold, CallKit's deactivation or teardown: stop LiveKit's audio engine, so
    /// neither playout nor capture runs, while the room stays connected.
    public func detachAudioSession() async {
        isSessionAttached = false
        attachFailure = nil
        do {
            try audioEngine.setAvailable(false)
            Log.info(.audio, "LiveKit detach: audio engine unavailable (playout and capture stopped); running=\(audioEngine.isRunning)")
        } catch {
            Log.error(.audio, "LiveKit setEngineAvailability(.none) error: \(error)")
        }
    }

    /// The audio session as it stands, for logs.
    private static var sessionDescription: String {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        return """
        category \(session.category.rawValue), mode \(session.mode.rawValue), options \(session.categoryOptions.rawValue), \
        otherAudioPlaying \(session.isOtherAudioPlaying), sampleRate \(session.sampleRate), \
        inputAvailable \(session.isInputAvailable), inputs \(route.inputs.map(\.portType.rawValue)), \
        outputs \(route.outputs.map(\.portType.rawValue))
        """
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
            : .connectionFailed(CredentialRedaction.redact(String(describing: error)))
    }
}

/// Whether a bounded publish handed its message to the data channel.
@MainActor
private final class PublishOutcome {
    var isSent = false
}

/// Translates the room's callbacks into `TransportEvent`s. Kept out of the public type
/// so hosts cannot invoke SDK callbacks on a live transport. `Room`'s delegate callbacks
/// arrive off the main actor and hop to the main-actor intake below before touching the
/// gate; a test's room double calls the intake directly.
@MainActor
final class RoomEventMapper: NSObject, RoomDelegate {
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    var gate = LiveKitConnectGate()
    var wasBotSpeaking = false

    init(continuation: AsyncStream<TransportEvent>.Continuation) {
        self.continuation = continuation
    }

    // MARK: - Main-actor intake

    func roomDidStartConnecting() {
        gate.roomDidStartConnecting()
        continuation.yield(.connecting)
    }

    func roomDidConnect(hasRemote: Bool) {
        if let event = gate.roomDidConnect() { continuation.yield(event) }
        if hasRemote, let event = gate.remoteDidJoin() { continuation.yield(event) }
    }

    func reconnectDidStart() {
        if let event = gate.reconnectDidStart() { continuation.yield(event) }
    }

    func remoteDidJoin() {
        if let event = gate.remoteDidJoin() { continuation.yield(event) }
    }

    func remoteDidLeave(remotesRemain: Bool) {
        if let event = gate.remoteDidLeave(remotesRemain: remotesRemain) { continuation.yield(event) }
    }

    func reconnectDidComplete(roomConnected: Bool, remotesPresent: Bool) {
        if let event = gate.reconnectDidComplete(roomConnected: roomConnected, remotesPresent: remotesPresent) {
            continuation.yield(event)
        }
    }

    func roomDidDisconnect() {
        if let event = gate.roomDidDisconnect() { continuation.yield(event) }
    }

    func speakersDidUpdate(botSpeaking: Bool, level: Float) {
        if botSpeaking != wasBotSpeaking {
            wasBotSpeaking = botSpeaking
            continuation.yield(botSpeaking ? .botStartedSpeaking : .botStoppedSpeaking)
        }
        if botSpeaking { continuation.yield(.remoteAudioLevel(level)) }
    }

    // MARK: - RoomDelegate

    nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from oldState: ConnectionState) {
        switch state {
        case .connecting:
            // Hopped too, so a departure the connect's own cleanup reports first is
            // judged before the gate knows this attempt's room is connecting.
            Task { @MainActor in self.roomDidStartConnecting() }
        case .connected:
            let hasRemote = !room.remoteParticipants.isEmpty
            Task { @MainActor in self.roomDidConnect(hasRemote: hasRemote) }
        case .reconnecting:
            // Hop like the completion does, so a reconnect that starts right after
            // one completes cannot overtake that completion's `.connected`.
            Task { @MainActor in self.reconnectDidStart() }
        default:
            break
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in self.remoteDidJoin() }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let remotesRemain = !room.remoteParticipants.isEmpty
        Task { @MainActor in self.remoteDidLeave(remotesRemain: remotesRemain) }
    }

    nonisolated func room(_ room: Room, didStartReconnectWithMode mode: ReconnectMode) {
        Task { @MainActor in self.reconnectDidStart() }
    }

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode mode: ReconnectMode) {
        // The engine's `.reconnecting` display recovers on a fresh `.connected`, but
        // only if the gate finds the room usable. The connection state is the one this
        // completion was reported with. The remotes are read after the hop: LiveKit
        // applies a full reconnect's join response in a detached task.
        let isRoomConnected = room.connectionState == .connected
        Task { @MainActor in
            self.reconnectDidComplete(roomConnected: isRoomConnected, remotesPresent: !room.remoteParticipants.isEmpty)
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in self.roomDidDisconnect() }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        let remoteSpeakers = participants.compactMap { $0 as? RemoteParticipant }
        let botSpeaking = !remoteSpeakers.isEmpty
        let level = remoteSpeakers.map(\.audioLevel).max() ?? 0
        Task { @MainActor in self.speakersDidUpdate(botSpeaking: botSpeaking, level: level) }
    }
}
