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
//  `attachAudioSession`/`detachAudioSession` are no-ops here because Daily owns the
//  session; they exist to satisfy the seam.
//
//  Interruptions: Daily heals short network outages inside its SDK without changing
//  the Pipecat transport state, so nothing in the client's callbacks reports them.
//  Once connected, the transport watches the device's network path instead
//  (`DailyInterruptionReporter`): losing it emits `.reconnecting`, getting it back
//  emits `.connected`. This reflects the path, not Daily's media state.
//
//  A `connect` while the client is still in the call (the engine reconnecting by
//  itself while Daily heals) does not rejoin: see `DailyConnectionGate.planConnect`.
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

@MainActor
public final class PipecatDailyTransport: CallTransport {
    public nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private let makePipecatTransport: @MainActor () -> Transport
    private let makePathMonitor: @MainActor () -> NetworkPathMonitoring

    /// A Pipecat client and the mapper that is its delegate. `disconnect()` takes the
    /// session away and releases its client, so a later `connect` builds a new one.
    private struct Session {
        let client: PipecatClient
        // `PipecatClient.delegate` is weak, so the session keeps the mapper alive as
        // long as the client is in use. The mapper holds neither the client nor the transport.
        let events: PipecatEventMapper
    }

    private var session: Session?

    public convenience init() {
        self.init(makePipecatTransport: { PipecatClientIOSDaily.DailyTransport() })
    }

    init(
        makePipecatTransport: @escaping @MainActor () -> Transport,
        makePathMonitor: @escaping @MainActor () -> NetworkPathMonitoring = { SystemNetworkPathMonitor() }
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
        self.makePipecatTransport = makePipecatTransport
        self.makePathMonitor = makePathMonitor
        self.session = makeSession()
    }

    private func makeSession() -> Session {
        // Join with the mic disabled; capture is enabled only on CallKit activation
        // (via setMicEnabled), preserving the audio-session-ownership invariant.
        let client = PipecatClient(
            options: PipecatClientOptions(
                transport: makePipecatTransport(),
                enableMic: false,
                enableCam: false
            )
        )
        let events = PipecatEventMapper(continuation: continuation, pathMonitor: makePathMonitor())
        client.delegate = events
        return Session(client: client, events: events)
    }

    // MARK: - CallTransport

    public func connect(_ connection: CallConnection) async throws {
        let session = self.session ?? makeSession()
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
            Log.warning(.transport, "Daily connect: the session is still in the call (\(session.client.state)); not rejoining")
            throw TransportError.connectionFailed("Daily session is still in the call")
        }
        session.events.gate.connectDidStart()
        session.events.interruptions.connectDidStart()
        do {
            let params = DailyTransportConnectionParams(
                roomUrl: connection.url.absoluteString, token: connection.token
            )
            try await session.client.connect(transportParams: params)
        } catch {
            session.events.gate.connectDidFail()
            Log.error(.transport, "Daily connect failed: \(error)")
            throw TransportError.connectionFailed(String(describing: error))
        }
    }

    /// The client states in which `PipecatClient.connect` throws `BotAlreadyStartedError`.
    private static let statesInCall: Set<TransportState> = [.authenticating, .connecting, .connected, .ready]

    public func disconnect() async {
        guard let session else { return }
        self.session = nil
        session.events.gate.userDidRequestDisconnect()
        session.events.interruptions.userDidRequestDisconnect()
        let client = session.client
        // Deliberate hangup: an explicit end-call message lets the remote side end
        // at once instead of waiting out the grace period it may give a dropped
        // participant. Throws when the bot was never ready — exactly when there's
        // no one to tell. The brief sleep lets the message flush before the leave.
        if (try? client.sendClientMessage(msgType: "end-call")) != nil {
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

    public func attachAudioSession() async {
        // Daily owns the AVAudioSession, so there is nothing to attach; the mic
        // stays off until the engine enables it after activation.
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
    let interruptions: DailyInterruptionReporter
    var gate = DailyConnectionGate()

    init(continuation: AsyncStream<TransportEvent>.Continuation, pathMonitor: NetworkPathMonitoring) {
        self.continuation = continuation
        self.interruptions = DailyInterruptionReporter(pathMonitor: pathMonitor) { continuation.yield($0) }
    }

    nonisolated func onTransportStateChanged(state: TransportState) {
        Task { @MainActor in self.mapState(state) }
    }

    private func mapState(_ state: TransportState) {
        switch state {
        case .initializing, .initialized, .authenticating, .authenticated, .connecting, .connected:
            continuation.yield(.connecting)
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
        guard let event = gate.transportDidBecomeReady() else { return }
        continuation.yield(event)
        interruptions.callDidConnect()
    }

    nonisolated func onBotReady(botReadyData: BotReadyData) {
        Task { @MainActor in self.reportReady() }
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
        continuation.yield(.error(.underlying(String(describing: message))))
    }
}
