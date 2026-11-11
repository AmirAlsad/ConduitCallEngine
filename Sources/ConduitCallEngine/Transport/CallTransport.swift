//
//  CallTransport.swift
//  ConduitCallEngine
//
//  The seam over the Pipecat iOS client. Concrete adapters (DailyTransport,
//  later LiveKitTransport) live in this folder and conform here; nothing outside
//  references an SDK type. The call engine drives a `CallTransport` and
//  consumes its `events`.
//
//  AUDIO-SESSION INVARIANT: a transport must NOT seize the microphone or activate
//  the audio session on its own. Media attaches only when the engine calls
//  `attachAudioSession()`, which it does only after CallKit's `providerDidActivate`.
//  CallKit owns the session; the transport attaches to it.
//

import Foundation

public protocol CallTransport: AnyObject {
    /// The single channel by which transport state leaves the adapter.
    var events: AsyncStream<TransportEvent> { get }

    func connect(_ connection: CallConnection) async throws
    func disconnect() async
    func setMicEnabled(_ enabled: Bool) async

    /// The audio routes the user can pick from (speaker, earpiece, Bluetooth, …).
    /// Routing goes through the transport so the SDK — which manages its own audio
    /// session and would otherwise re-assert its choice — honors the selection.
    func availableAudioDevices() async -> [AudioDeviceInfo]
    func selectedAudioDevice() async -> AudioDeviceInfo?
    func setAudioDevice(_ id: String) async

    /// Start media on the CallKit-activated session. Called ONLY once CallKit has
    /// activated it (on activation, or on creation if activation came first).
    func attachAudioSession() async
    /// Stop media when CallKit deactivates the session or the call ends.
    func detachAudioSession() async
}
