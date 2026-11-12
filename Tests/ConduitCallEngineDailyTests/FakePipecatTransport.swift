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

import PipecatClientIOS

@MainActor
final class FakePipecatTransport: Transport {
    private(set) var calls: [String] = []
    var delegate: PipecatClientDelegate?
    var onMessage: ((RTVIMessageInbound) -> Void)?
    private var currentState: TransportState = .disconnected

    required init() {}

    /// The bot reported ready, so the client can send it messages.
    func becomeReady() {
        setState(state: .ready)
    }

    func initialize(options: PipecatClientOptions) {}
    func initDevices() async throws {}

    func release() {
        calls.append("release")
    }

    func connect(transportParams: TransportConnectionParams?) async throws {
        calls.append("connect")
        setState(state: .connected)
    }

    func disconnect() async throws {
        calls.append("disconnect")
        setState(state: .disconnected)
    }

    func getAllMics() -> [MediaDeviceInfo] { [] }
    func getAllCams() -> [MediaDeviceInfo] { [] }
    func updateMic(micId: MediaDeviceId) async throws {}
    func updateCam(camId: MediaDeviceId) async throws {}
    func selectedMic() -> MediaDeviceInfo? { nil }
    func selectedCam() -> MediaDeviceInfo? { nil }
    func enableMic(enable: Bool) async throws {}
    func enableCam(enable: Bool) async throws {}
    func isCamEnabled() -> Bool { false }
    func isMicEnabled() -> Bool { false }

    func sendMessage(message: RTVIMessageOutbound) throws {
        calls.append("send \(message.type)")
    }

    func state() -> TransportState { currentState }

    func setState(state: TransportState) {
        currentState = state
        delegate?.onTransportStateChanged(state: state)
    }

    func tracks() -> Tracks? { nil }
}
