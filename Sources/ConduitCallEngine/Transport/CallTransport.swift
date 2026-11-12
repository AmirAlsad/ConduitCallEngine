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
//  The requirements are not actor-isolated. A conforming type isolated to the main
//  actor (as the package's adapters are) must declare the synchronous ones,
//  `events` and `canConnectWhileRinging`, `nonisolated`; the async ones it may keep
//  on the main actor, where the engine calls them.
//

import Foundation

public protocol CallTransport: AnyObject {
    /// The single channel by which transport state leaves the adapter. Synchronous
    /// and nonisolated: a main-actor conformer declares it `nonisolated`.
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

    /// Deliver a call-control signal to the remote agent, and say what became of it.
    /// Best effort: the engine never waits on a delivery for anything else, and sends
    /// a signal only while the transport has reported `.connected`. Return `.sent`
    /// once the signal is handed to the connection, `.failed` when it could not be
    /// (the engine then sends the call's current state again, a few times with a
    /// growing wait, and on the next connection), and `.unsupported` if you carry no
    /// signals. Must not throw, must return promptly when the connection is gone
    /// (bound your wait), and may be called again with the same signal. The default
    /// implementation drops the signal and returns `.unsupported`.
    @discardableResult
    func send(_ signal: CallSignal) async -> CallSignalDelivery

    /// Whether the engine may call `connect(_:)` while an incoming call is still
    /// ringing, before the answer and before CallKit activates the audio session
    /// (pre-connect's `.media` tier). True only if this transport's `connect(_:)`
    /// then joins without configuring or activating `AVAudioSession`, starting audio
    /// input or output, or making the remote party audible, until the engine calls
    /// `attachAudioSession()` after CallKit's activation, and `send(_:)` reaches the
    /// remote agent, which waits for `CallSignal.answered` before it speaks. Read
    /// once per ring, right after `CallTarget.makeTransport` creates the transport.
    /// The default implementation returns false, which keeps the transport at the
    /// `.credentials` tier: it joins only once the user answers. Synchronous and
    /// nonisolated, like `events`: a main-actor conformer declares it `nonisolated`
    /// (it is typically a constant).
    var canConnectWhileRinging: Bool { get }
}

extension CallTransport {
    /// False: a transport that does not declare it is never connected during a ring.
    public var canConnectWhileRinging: Bool { false }

    /// Drops the signal: a transport that does not implement `send(_:)` leaves its
    /// agent uninformed, and the call works as before.
    @discardableResult
    public func send(_ signal: CallSignal) async -> CallSignalDelivery { .unsupported }
}
