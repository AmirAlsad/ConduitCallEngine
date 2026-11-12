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
//  documented hook to defer activation to CallKit, so the transport joins with the
//  mic DISABLED and enables capture only via `setMicEnabled`, which the engine
//  calls after CallKit activation, so the mic is never hot before activation.
//  Nor can playout be paused, so `detachAudioSession` (a hold, CallKit deactivating
//  the session) stops the agent's audio by unsubscribing from it and
//  `attachAudioSession` subscribes again (`DailyRemoteAudioGate`). A call that is
//  never detached, and was not joined while ringing, keeps Daily's default
//  subscription.
//
//  Interruptions: Daily heals short network outages inside its SDK without changing
//  the Pipecat transport state, so nothing in the client's callbacks reports them.
//  Once connected, the transport watches the device's network path instead
//  (`DailyInterruptionReporter`): losing it emits `.reconnecting`, getting it back
//  emits `.connected`. This reflects the path, not Daily's media state.
//
//  Connecting while ringing is supported (`canConnectWhileRinging`). A join made
//  while the call rings (`connectWhileRinging`) unsubscribes from the agent's audio
//  before it joins and keeps it unsubscribed until the first attach, which comes
//  after the answer once CallKit activates the session and subscribes again,
//  returning once Daily has the subscription. Joined with Daily's default
//  subscriptions during a ring, a device test (iPhone 17, iOS 27.0) heard no agent
//  audio for the whole call and the route flipped between speaker and earpiece;
//  joined unsubscribed, the ring was silent and the answered call played the agent
//  cleanly. Pipecat's client sends client-ready only for playable audio, so the bot
//  cannot report ready while it is held back: for such a join, and any later one on
//  this transport before the first attach, the agent being in the room counts as
//  ready. A join while detached after an attach (a held call reconnecting) joins
//  unsubscribed and waits for bot-ready, which comes after the resume's attach.
//  Every other join (an outgoing call, an answer that joins after the ring, a
//  reconnect of an attached call) keeps Daily's default subscriptions and waits
//  for bot-ready.
//
//  A `connect` while the client is still in the call never joins on that client:
//  while Daily heals the call it is refused, and on a session whose bot never got
//  ready it takes the session over with a new client. See
//  `DailyConnectionGate.planConnect`.
//
//  Teardown: `disconnect()` sends the end-call signal, leaves, then releases the
//  Pipecat client, whose Daily transport and call client otherwise outlive the call.
//  A released client cannot connect again, so a `connect` after `disconnect()`
//  builds a new client; the old one's late callbacks no longer reach the transport.
//

import Foundation
import ConduitCallEngine
import PipecatClientIOS
import PipecatClientIOSDaily

/// The Daily transport: the Pipecat iOS client in a Daily room, behind
/// `CallTransport`. `CallConnection.url` is the Daily room URL and `token` its meeting
/// token; the call is `.connected` once the Pipecat client is ready or the bot
/// reports ready, or, for a join made while the call rings, once the agent is in the
/// room. Supports joining while ringing. Main-actor isolated; create one per call, on
/// a device only (Daily's WebRTC audio aborts in the simulator). The Integration
/// Guide, section 11, has what the server side must do.
@MainActor
public final class PipecatDailyTransport: CallTransport {
    public nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private let makePipecatTransport: @MainActor () -> Transport
    private let makePathMonitor: @MainActor () -> NetworkPathMonitoring
    private let makeCallControl: @MainActor (any Transport) -> DailyCallControlling?
    private var remoteAudio = DailyRemoteAudioGate()

    /// A Pipecat client and the mapper that is its delegate. `disconnect()` takes the
    /// session away and releases its client, so a later `connect` builds a new one.
    private struct Session {
        let client: PipecatClient
        // `PipecatClient.delegate` is weak, so the session keeps the mapper alive as
        // long as the client is in use. The mapper holds neither the client nor the transport.
        let events: PipecatEventMapper
        /// `nil` when the Pipecat transport is not Daily's (tests).
        let callControl: DailyCallControlling?
    }

    private var session: Session?

    /// A transport that joins with the mic off and builds its Pipecat client when
    /// first connected.
    public convenience init() {
        self.init(makePipecatTransport: { PipecatClientIOSDaily.DailyTransport() })
    }

    /// True: a join while the call rings (`connectWhileRinging(_:)`) holds the agent's
    /// audio unsubscribed until `attachAudioSession()`, so nothing is heard before
    /// the answer, and joins with the mic off, as every join does. Daily still
    /// manages `AVAudioSession` itself; on the device tested, a ring joined this way
    /// left the ringtone and the answered call's audio and route undisturbed.
    public nonisolated var canConnectWhileRinging: Bool { true }

    init(
        makePipecatTransport: @escaping @MainActor () -> Transport,
        makePathMonitor: @escaping @MainActor () -> NetworkPathMonitoring = { SystemNetworkPathMonitor() },
        makeCallControl: @escaping @MainActor (any Transport) -> DailyCallControlling? = DailyCallClientControl.make(for:)
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
        self.makePipecatTransport = makePipecatTransport
        self.makePathMonitor = makePathMonitor
        self.makeCallControl = makeCallControl
        self.session = makeSession()
    }

    private func makeSession() -> Session {
        // Join with the mic disabled; capture is enabled only on CallKit activation
        // (via setMicEnabled), preserving the audio-session-ownership invariant.
        let pipecatTransport = makePipecatTransport()
        let client = PipecatClient(
            options: PipecatClientOptions(
                transport: pipecatTransport,
                enableMic: false,
                enableCam: false
            )
        )
        let callControl = makeCallControl(pipecatTransport)
        let events = PipecatEventMapper(
            continuation: continuation,
            pathMonitor: makePathMonitor(),
            isRemotePresent: { [weak callControl] in callControl?.hasRemoteParticipant ?? false }
        )
        client.delegate = events
        return Session(client: client, events: events, callControl: callControl)
    }

    // MARK: - CallTransport

    /// Joins as `connect(_:)` does, with the agent's audio unsubscribed from before
    /// the join until the first `attachAudioSession()`, and with the agent's presence
    /// in the room counting as ready for this join and any other made before that
    /// attach (the bot cannot report ready while its audio is unsubscribed).
    public func connectWhileRinging(_ connection: CallConnection) async throws {
        remoteAudio.holdAgentBackUntilFirstAttach()
        try await connect(connection)
    }

    public func connect(_ connection: CallConnection) async throws {
        var session = self.session ?? makeSession()
        self.session = session
        let plan = session.events.gate.planConnect(
            sessionIsInCall: Self.statesInCall.contains(session.client.state),
            interruption: session.events.interruptions.phase
        )
        switch plan {
        case .join:
            break
        case .reportConnected:
            Log.info(.transport, "Daily connect: the session healed by itself; reporting it connected")
            session.events.reportConnectedAgain()
            return
        case .refuse:
            Log.warning(.transport, "Daily connect: Daily is still healing the call (\(session.client.state)); not rejoining")
            throw TransportError.connectionFailed("Daily session is still in the call")
        case .takeOver:
            Log.warning(.transport, "Daily connect: the session's bot never got ready (\(session.client.state)); leaving it and joining with a new client")
            let stale = session
            session = makeSession()
            self.session = session
            await Self.retire(stale)
            // The host's disconnect() may have ended the new session meanwhile.
            guard self.session?.client === session.client else {
                throw TransportError.connectionFailed("Daily transport was disconnected while taking a session over")
            }
        }
        // Presence counts as ready only for a join the bot cannot get ready in.
        session.events.gate.connectDidStart(readyOnPresence: remoteAudio.holdsAgentBack)
        session.events.interruptions.connectDidStart()
        remoteAudio.sessionDidReset()
        if remoteAudio.holdsAgentBack {
            Log.info(.transport, "Daily connect while ringing: agent audio before the first attach: unsubscribed, ready on presence")
        }
        // Before the join, so a held call that reconnects joins with the agent silent.
        await applyRemoteAudio().value
        do {
            let params = DailyTransportConnectionParams(
                roomUrl: connection.url.absoluteString, token: connection.token
            )
            try await session.client.connect(transportParams: params)
        } catch {
            session.events.gate.connectDidFail()
            Log.error(.transport, "Daily connect failed: \(error)")
            throw TransportError.connectionFailed(CredentialRedaction.redact(String(describing: error)))
        }
        session.events.transportDidJoin()
        // Daily may not take a subscription change before the join; it does now.
        remoteAudio.joinDidComplete()
        await applyRemoteAudio().value
    }

    /// The client states in which `PipecatClient.connect` throws `BotAlreadyStartedError`.
    private static let statesInCall: Set<TransportState> = [.authenticating, .connecting, .connected, .ready]

    public func disconnect() async {
        guard let session else { return }
        self.session = nil
        remoteAudio.sessionDidReset()
        session.events.gate.userDidRequestDisconnect()
        session.events.interruptions.userDidRequestDisconnect()
        let client = session.client
        // Deliberate hangup: an explicit end-call message lets the remote side end
        // at once instead of waiting out the grace period it may give a dropped
        // participant. Sent once Daily has joined, whether or not the bot is ready;
        // before the join there is no one to tell. The brief sleep lets the message
        // flush before the leave.
        if Self.sendClientMessage("end-call", on: client) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        do { try await client.disconnect() }
        catch { Log.error(.transport, "Daily disconnect error: \(error)") }
        // Pipecat's Daily transport and its Daily call client stay alive (a reference
        // cycle through the client options) until release(), even after the leave.
        // Released after the leave so the end-call signal and the leave go out first.
        client.release()
        client.delegate = nil
    }

    /// Leaves a session the call no longer uses, without the end-call signal (the call
    /// goes on in the session that replaces it, possibly in the same room), and
    /// releases its client. Its delegate is detached first, so nothing it reports,
    /// the leave included, reaches the engine.
    private static func retire(_ session: Session) async {
        session.events.gate.userDidRequestDisconnect()
        session.events.interruptions.userDidRequestDisconnect()
        let client = session.client
        client.delegate = nil
        do { try await client.disconnect() }
        catch { Log.error(.transport, "Daily leave of a replaced session failed: \(error)") }
        client.release()
    }

    /// Delivers a call-control signal as an RTVI client message, the end-call
    /// signal's envelope with the signal's raw value as `t`, through Daily's call
    /// client, whose app-message send reports a result (Pipecat's own send discards
    /// it): `.sent` once Daily has sent it, `.failed` when the call is not joined or
    /// Daily could not send it.
    @discardableResult
    public func send(_ signal: CallSignal) async -> CallSignalDelivery {
        guard let session else {
            Log.info(.transport, "Daily client message \(signal.rawValue) dropped: no session")
            return .failed
        }
        let state = session.client.state
        guard Self.statesJoined.contains(state) else {
            Log.info(.transport, "Daily client message \(signal.rawValue) dropped: the call is not joined (\(state))")
            return .failed
        }
        guard let callControl = session.callControl else {
            return Self.sendClientMessage(signal.rawValue, on: session.client) ? .sent : .failed
        }
        do {
            let json = try JSONEncoder().encode(RTVIMessageOutbound.clientMessage(msgType: signal.rawValue))
            try await callControl.sendAppMessage(json)
            Log.info(.transport, "Daily client message \(signal.rawValue) sent")
            return .sent
        } catch {
            Log.warning(.transport, "Daily client message \(signal.rawValue) failed: \(error)")
            return .failed
        }
    }

    /// Sends an RTVI client message (`{"id", "label": "rtvi-ai", "type": "client-message",
    /// "data": {"t": type, "d": null}}`) as a Daily app message to everyone in the call,
    /// and returns whether it was handed to Daily. It goes through the Pipecat transport
    /// rather than `PipecatClient.sendClientMessage`, which refuses until the bot is
    /// ready: Daily delivers app messages once the call is joined, and a Pipecat bot's
    /// RTVI processor handles client messages without waiting for client-ready.
    /// Delivery is fire and forget; Daily reports no result to it.
    @discardableResult
    private static func sendClientMessage(_ type: String, on client: PipecatClient) -> Bool {
        let state = client.state
        guard statesJoined.contains(state) else {
            Log.info(.transport, "Daily client message \(type) dropped: the call is not joined (\(state))")
            return false
        }
        do {
            try client.transport.sendMessage(message: .clientMessage(msgType: type))
            Log.info(.transport, "Daily client message \(type) sent")
            return true
        } catch {
            Log.warning(.transport, "Daily client message \(type) failed: \(error)")
            return false
        }
    }

    /// The client states in which the Daily call is joined, so an app message reaches the bot.
    private static let statesJoined: Set<TransportState> = [.connected, .ready]

    public func setMicEnabled(_ enabled: Bool) async {
        guard let client = session?.client else { return }
        do { try await client.enableMic(enable: enabled) }
        catch { Log.error(.transport, "Daily enableMic(\(enabled)) error: \(error)") }
    }

    // Daily models the iOS audio routes (speaker / receiver / Bluetooth / wired) as
    // its "mic" devices and honors `updateMic` — unlike a manual AVAudioSession
    // override, which Daily's own session management would re-assert.
    public func availableAudioDevices() async -> [AudioDeviceInfo] {
        session?.client.getAllMics().map { AudioDeviceInfo(id: $0.id.id, name: $0.name) } ?? []
    }

    public func selectedAudioDevice() async -> AudioDeviceInfo? {
        session?.client.selectedMic.map { AudioDeviceInfo(id: $0.id.id, name: $0.name) }
    }

    public func setAudioDevice(_ id: String) async {
        guard let client = session?.client else { return }
        do { try await client.updateMic(micId: MediaDeviceId(id: id)) }
        catch { Log.error(.audio, "Daily setAudioDevice(\(id)) error: \(error)") }
    }

    /// Daily owns the AVAudioSession, so attaching only lets the agent be heard again
    /// after a detach (or, on a call joined while ringing, for the first
    /// time); the mic stays off until the engine enables it. Returns once Daily has the
    /// subscription, within `attachBound`, so what the engine sends after the attach
    /// (`call-connected`, `call-resumed`) reaches an agent the user can hear.
    public func attachAudioSession() async {
        remoteAudio.attach()
        Log.info(.audio, "Daily attach: agent audio wanted \(Self.describe(remoteAudio.wanted))")
        await Self.wait(for: applyRemoteAudio(), atMost: Self.attachBound)
    }

    /// Stops the agent's playout by unsubscribing from its audio (the engine closes the
    /// mic first). Returns without waiting for Daily, so a teardown is not held up.
    public func detachAudioSession() async {
        remoteAudio.detach()
        Log.info(.audio, "Daily detach: agent audio wanted \(Self.describe(remoteAudio.wanted))")
        applyRemoteAudio()
    }

    /// The longest `attachAudioSession()` waits for Daily to apply a subscription.
    private static let attachBound: Duration = .seconds(2)

    /// The application of subscription changes in progress.
    private var remoteAudioApplication: Task<Void, Never>?

    /// Applies the gate's wanted subscription until Daily has it, one change at a time
    /// and always toward the latest wanted state. A call while an application runs
    /// returns that one, which picks up the latest state.
    @discardableResult
    private func applyRemoteAudio() -> Task<Void, Never> {
        if let remoteAudioApplication { return remoteAudioApplication }
        let task = Task { [weak self] in
            await self?.applyRemoteAudioChanges()
            self?.remoteAudioApplication = nil
        }
        remoteAudioApplication = task
        return task
    }

    /// Waits for `task`, or for `bound` to pass, whichever comes first.
    private static func wait(for task: Task<Void, Never>, atMost bound: Duration) async {
        let (outcome, report) = AsyncStream.makeStream(of: Void.self)
        let waiter = Task {
            await task.value
            report.yield()
        }
        let timer = Task {
            try? await Task.sleep(for: bound)
            report.yield()
        }
        for await _ in outcome { break }
        waiter.cancel()
        timer.cancel()
        report.finish()
    }

    private func applyRemoteAudioChanges() async {
        while let application = remoteAudio.beginApplying() {
            guard let callControl = session?.callControl else {
                remoteAudio.applyDidFail(application)
                Log.info(.audio, "Daily agent audio not set to \(application.state): no Daily call client")
                return
            }
            Log.info(.audio, "Daily agent audio -> \(application.state) (\(Self.playoutEffect(of: application.state)))")
            do {
                try await callControl.setRemoteAudio(application.state)
                remoteAudio.applyDidSucceed(application)
                Log.info(.audio, "Daily agent audio is \(application.state): \(callControl.remoteAudioDescription)")
            } catch {
                remoteAudio.applyDidFail(application)
                Log.warning(.audio, "Daily agent audio -> \(application.state) refused: \(error)")
            }
        }
    }

    private static func describe(_ state: DailyRemoteAudio?) -> String {
        state.map { "\($0)" } ?? "unchanged (Daily default)"
    }

    private static func playoutEffect(of state: DailyRemoteAudio) -> String {
        state == .subscribed ? "playout restored" : "playout stopped"
    }
}

/// Translates the Pipecat client's delegate callbacks into `TransportEvent`s. Kept
/// out of the public type so hosts cannot invoke SDK callbacks on a live transport.
@MainActor
private final class PipecatEventMapper: PipecatClientDelegate {
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    let interruptions: DailyInterruptionReporter
    var gate: DailyConnectionGate
    private let isRemotePresent: @MainActor () -> Bool

    init(
        continuation: AsyncStream<TransportEvent>.Continuation,
        pathMonitor: NetworkPathMonitoring,
        isRemotePresent: @escaping @MainActor () -> Bool
    ) {
        self.continuation = continuation
        self.interruptions = DailyInterruptionReporter(pathMonitor: pathMonitor) { continuation.yield($0) }
        self.gate = DailyConnectionGate()
        self.isRemotePresent = isRemotePresent
    }

    nonisolated func onTransportStateChanged(state: TransportState) {
        Task { @MainActor in self.mapState(state) }
    }

    private func mapState(_ state: TransportState) {
        switch state {
        case .initializing, .initialized, .authenticating, .authenticated, .connecting:
            continuation.yield(.connecting)
        case .connected:
            continuation.yield(.connecting)
            transportDidJoin()
        case .ready:
            reportReady()
        case .disconnecting:
            break
        case .disconnected:
            if let event = gate.transportDidDisconnect() { continuation.yield(event) }
            interruptions.transportDidDisconnect()
        case .error:
            continuation.yield(.error(.connectionFailed("transport error")))
        @unknown default:
            break
        }
    }

    func reportConnectedAgain() {
        continuation.yield(.connected)
    }

    private func reportReady() {
        reportConnected(gate.transportDidBecomeReady())
    }

    /// The Daily call is joined. Counts as connected only for a gate that takes
    /// presence as ready.
    func transportDidJoin() {
        let event = gate.transportDidJoin(remotePresent: isRemotePresent())
        if event != nil { Log.info(.transport, "Daily connected on presence: joined with a remote participant") }
        reportConnected(event)
    }

    private func reportConnected(_ event: TransportEvent?) {
        guard let event else { return }
        continuation.yield(event)
        interruptions.callDidConnect()
    }

    nonisolated func onBotReady(botReadyData: BotReadyData) {
        Task { @MainActor in self.reportReady() }
    }

    nonisolated func onBotConnected(participant: Participant) {
        Task { @MainActor in
            let event = self.gate.botDidJoin()
            if event != nil { Log.info(.transport, "Daily connected on presence: the bot joined") }
            self.reportConnected(event)
        }
    }

    nonisolated func onBotDisconnected(participant: Participant) {
        Task { @MainActor in
            if let event = self.gate.botDidLeave() { self.continuation.yield(event) }
        }
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
        continuation.yield(.error(.underlying(CredentialRedaction.redact(String(describing: message)))))
    }
}
