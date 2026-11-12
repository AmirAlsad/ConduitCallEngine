//
//  CallTransport.swift
//  ConduitCallEngine
//
//  The engine's seam over a real-time media SDK. The `ConduitCallEngineDaily` and
//  `ConduitCallEngineLiveKit` products provide adapters, and a host can write its
//  own; no SDK type crosses this protocol. The engine drives a `CallTransport`
//  from the main actor and consumes its `events`.
//
//  AUDIO-SESSION INVARIANT: a transport must NOT seize the microphone or activate
//  the audio session on its own. Media attaches only when the engine calls
//  `attachAudioSession()`, which it does only after CallKit's `providerDidActivate`.
//  CallKit owns the session; the transport attaches to it.
//
//  A conforming type isolated to the main actor (as the package's adapters are)
//  must declare `events` as `nonisolated`, because the requirement is nonisolated.
//

import Foundation

public protocol CallTransport: AnyObject {
    /// The single channel by which transport state leaves the adapter.
    var events: AsyncStream<TransportEvent> { get }

    func connect(_ connection: CallConnection) async throws
    func disconnect() async
    func setMicEnabled(_ enabled: Bool) async

    /// The audio routes the user can pick from (speaker, earpiece, Bluetooth, …).
    /// Routing goes through the transport so an SDK that manages its own audio
    /// session, and would otherwise re-assert its choice, honors the selection.
    func availableAudioDevices() async -> [AudioDeviceInfo]
    func selectedAudioDevice() async -> AudioDeviceInfo?
    func setAudioDevice(_ id: String) async

    /// Start media on the CallKit-activated session. Called ONLY once CallKit has
    /// activated it and the call is not on hold (on activation, on creation if
    /// activation came first, or on resuming from hold).
    func attachAudioSession() async
    /// Stop media when CallKit deactivates the session, the call is put on hold,
    /// or the call ends. Can be called more than once in a row; make it idempotent.
    func detachAudioSession() async

    /// Deliver a call-control signal to the remote agent. Best effort: the engine
    /// does not wait for or retry a delivery, and sends a signal only while the
    /// transport has reported `.connected`. Must not throw, must return promptly
    /// when the connection is gone, and may be called again with the same signal.
    /// The default implementation drops the signal.
    func send(_ signal: CallSignal) async
}

extension CallTransport {
    /// Drops the signal: a transport that does not implement `send(_:)` leaves its
    /// agent uninformed, and the call works as before.
    public func send(_ signal: CallSignal) async {}
}
