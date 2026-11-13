//
//  FakePipecatTransport.swift
//  ConduitCallEngineDailyTests
//
//  Stands in for the Pipecat client's Daily transport, which needs Daily's WebRTC
//  audio unit and aborts in the simulator. It records what the real Pipecat client
//  asks of its transport, so `PipecatDailyTransport`'s teardown can be checked.
//
//  It holds its delegate strongly, unlike Pipecat's Daily transport, the way an
//  SDK object with a callback still in flight does: a delegate the adapter did not
//  detach stays reachable, so tests can tell whether it was detached.
//
//  It also models when a Pipecat bot becomes ready, which depends on the agent's
//  audio subscription: Pipecat's Daily transport sends client-ready only once a
//  remote participant's microphone is playable, which needs it subscribed, and a
//  Pipecat bot sends bot-ready only in reply (`botJoins()`). A held call whose
//  agent's audio is unsubscribed therefore cannot become ready.
//

import Foundation
import PipecatClientIOS
@testable import ConduitCallEngineDaily

@MainActor
final class FakePipecatTransport: Transport {
    private(set) var calls: [String] = []
    /// Every message the client handed over, as the JSON Pipecat's Daily transport
    /// encodes it for Daily's app message.
    private(set) var sentMessages: [Data] = []
    /// Every value the adapter passed to `enableMic(enable:)`, in order.
    private(set) var micHistory: [Bool] = []
    /// Whether `connect` leaves the client joined (`.connected`), as a Daily join that
    /// completes does; `false` leaves it `.connecting`.
    var joinsOnConnect = true
    var delegate: PipecatClientDelegate?
    var onMessage: ((RTVIMessageInbound) -> Void)?
    private var currentState: TransportState = .disconnected

    /// Whether the bot is in the room (`botJoins()`, before or after the client joins);
    /// a joined client sees it. A client that leaves the call starts without it.
    private(set) var isBotPresent = false
    /// Whether a bot that becomes able to hear the client answers client-ready with
    /// bot-ready, as a Pipecat bot does. False stands for a bot that never gets ready.
    var botAnswersClientReady = true
    /// The agent's audio subscription as Daily last accepted it; nil is Daily's
    /// default, which subscribes.
    private(set) var remoteAudio: DailyRemoteAudio?
    /// Whether this join sent client-ready (Pipecat resets it when the call is left).
    private(set) var sentClientReady = false
    /// The ids of the audio devices Daily lists (`earpiece`, `speakerphone`, ...).
    var mics: [String] = []
    /// Runs inside each join, as Daily's own work at the join does.
    var onJoin: (() -> Void)?

    required init() {}

    /// The bot joins the room and publishes its voice. Once the agent's audio is
    /// playable the client sends client-ready, and the bot answers bot-ready.
    func botJoins() {
        isBotPresent = true
        if [.connected, .ready].contains(currentState) {
            delegate?.onBotConnected(participant: Participant(id: ParticipantId(id: "bot"), name: "bot", local: false))
        }
        sendClientReadyIfPlayable()
    }

    /// Daily accepted a change to the agent's audio subscription.
    func remoteAudioDidChange(_ state: DailyRemoteAudio) {
        remoteAudio = state
        sendClientReadyIfPlayable()
    }

    /// Pipecat's Daily transport sends client-ready on the first participant update
    /// with the remote microphone playable, which Daily reports only while subscribed.
    private func sendClientReadyIfPlayable() {
        guard !sentClientReady, isBotPresent, currentState == .connected,
              (remoteAudio ?? .subscribed) == .subscribed
        else { return }
        sentClientReady = true
        if botAnswersClientReady { becomeReady() }
    }

    /// The bot reported ready, so the client can send it messages.
    func becomeReady() {
        setState(state: .ready)
    }

    /// Adds a call made on this session's Daily call client, so tests see it in order
    /// with what the Pipecat client asked of the transport.
    func record(_ call: String) {
        calls.append(call)
    }

    func initialize(options: PipecatClientOptions) {}

    /// Reports the device list, as Pipecat's Daily transport does when it initializes
    /// its devices, the first connect's first step.
    func initDevices() async throws {
        if !mics.isEmpty { delegate?.onAvailableMicsUpdated(mics: getAllMics()) }
    }

    /// Daily's device list changed to `ids`.
    func announceMics(_ ids: [String]) {
        mics = ids
        delegate?.onAvailableMicsUpdated(mics: getAllMics())
    }

    func release() {
        calls.append("release")
    }

    /// When set, `connect` records the join and then fails with it.
    var connectError: (any Error)?

    func connect(transportParams: TransportConnectionParams?) async throws {
        calls.append(Self.joinDevice(transportParams).map { "connect preferring \($0)" } ?? "connect")
        if let connectError { throw connectError }
        onJoin?()
        setState(state: joinsOnConnect ? .connected : .connecting)
        if joinsOnConnect, isBotPresent {
            delegate?.onBotConnected(participant: Participant(id: ParticipantId(id: "bot"), name: "bot", local: false))
        }
        sendClientReadyIfPlayable()
    }

    /// The device the join's microphone input names: the only string in the join
    /// settings `PipecatDailyTransport` builds (Pipecat keeps them private).
    private static func joinDevice(_ params: TransportConnectionParams?) -> String? {
        guard let params,
              let settings = Mirror(reflecting: params).children.first(where: { $0.label == "joinSettings" })?.value
        else { return nil }
        return strings(in: settings).first
    }

    private static func strings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        return Mirror(reflecting: value).children.flatMap { strings(in: $0.value) }
    }

    /// The pending join completes (for a fake made with `joinsOnConnect` false).
    func completeJoin() {
        setState(state: .connected)
        sendClientReadyIfPlayable()
    }

    /// When true, `disconnect` waits for `finishLeaving()` before the call is left.
    var leaveSuspends = false
    private var leaving: CheckedContinuation<Void, Never>?

    func finishLeaving() {
        leaveSuspends = false
        leaving?.resume()
        leaving = nil
    }

    func disconnect() async throws {
        calls.append("disconnect")
        if leaveSuspends { await withCheckedContinuation { leaving = $0 } }
        setState(state: .disconnected)
    }

    func getAllMics() -> [MediaDeviceInfo] {
        mics.map { MediaDeviceInfo(id: MediaDeviceId(id: $0), name: $0) }
    }
    func getAllCams() -> [MediaDeviceInfo] { [] }
    func updateMic(micId: MediaDeviceId) async throws {}
    func updateCam(camId: MediaDeviceId) async throws {}
    func selectedMic() -> MediaDeviceInfo? { nil }
    func selectedCam() -> MediaDeviceInfo? { nil }
    /// When true, each `enableMic(enable:)` is also recorded in `calls` ("mic on",
    /// "mic off").
    var recordsMic = false
    /// When set, `enableMic(enable:)` fails with it.
    var micError: (any Error)?

    func enableMic(enable: Bool) async throws {
        if let micError { throw micError }
        micHistory.append(enable)
        if recordsMic { calls.append(enable ? "mic on" : "mic off") }
    }
    func enableCam(enable: Bool) async throws {}
    func isCamEnabled() -> Bool { false }
    func isMicEnabled() -> Bool { false }

    func sendMessage(message: RTVIMessageOutbound) throws {
        calls.append("send \(message.type)")
        sentMessages.append(try JSONEncoder().encode(message))
    }

    /// An app message the adapter sent on the Daily call client directly, logged as
    /// Pipecat's own send of the same message is.
    func recordAppMessage(_ json: Data) {
        let type = (try? JSONSerialization.jsonObject(with: json) as? [String: Any])?["type"] as? String ?? "?"
        calls.append("send \(type)")
        sentMessages.append(json)
    }

    func state() -> TransportState { currentState }

    func setState(state: TransportState) {
        currentState = state
        if state == .disconnected {
            sentClientReady = false
            isBotPresent = false
        }
        delegate?.onTransportStateChanged(state: state)
    }

    func tracks() -> Tracks? { nil }
}
