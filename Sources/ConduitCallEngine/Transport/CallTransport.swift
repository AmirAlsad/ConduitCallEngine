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

/// The engine's seam over a real-time media SDK: the bundled `PipecatDailyTransport`
/// and `LiveKitTransport`, `FakeTransport`, or a host's own. The engine calls every
/// requirement from the main actor; the requirements themselves are not isolated,
/// so a main-actor class or an actor can conform. The Integration Guide, section
/// 10, has the full contract.
public protocol CallTransport: AnyObject {
    /// The single channel by which transport state leaves the adapter; the engine
    /// reads it from the transport's creation until the call's teardown. Synchronous
    /// and nonisolated: a main-actor conformer declares it `nonisolated`.
    var events: AsyncStream<TransportEvent> { get }

    /// Join `connection`. Called for a call's first connect (unless a ring prepared
    /// at the `.media` tier joined it with `connectWhileRinging(_:)`) and once per
    /// engine reconnect attempt, on the same instance, possibly while the SDK is
    /// still healing the previous session. Throw `TransportError.authenticationFailed`
    /// only for credentials the server rejected; report `.connected` through `events`
    /// once the agent can hear the user, not when this returns.
    func connect(_ connection: CallConnection) async throws
    /// Join `connection` while an incoming call still rings, before the answer and
    /// before CallKit activates the audio session (pre-connect's `.media` tier).
    /// Called only on a transport whose `canConnectWhileRinging` is true, once per
    /// ring, in place of `connect(_:)`; every later connect of the call (a reconnect
    /// attempt, or the unprepared connect after a preparation that failed following
    /// the answer) is `connect(_:)`. The contract is `connect(_:)`'s, plus
    /// `canConnectWhileRinging`'s: nothing audible, no audio session work and no
    /// capture until `attachAudioSession()`. Implement it when a join during a ring
    /// must differ from one made for a call already under way (the Daily adapter
    /// holds the agent's audio back until that attach); the default implementation
    /// calls `connect(_:)`.
    func connectWhileRinging(_ connection: CallConnection) async throws
    /// Leave because the call is over, sending an end-call signal to the agent if the
    /// protocol has one, and report `.disconnected(reason: .requestedByUser)`.
    func disconnect() async
    /// Turn capture on or off. Can come before `connect(_:)` has joined, where it must
    /// be harmless: the engine sets it again once the transport reports `.connected`.
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
    /// Why the audio the last `attachAudioSession()` was to start did not start, or
    /// nil if it started (or the transport cannot tell). Asked after each attach, as
    /// a media command after the attach and the mic command issued with it; for a
    /// failure, the engine attaches again a few times, half a second, one and two
    /// seconds apart, while the call stays activated and not held, and what it sends
    /// the agent after the attach (`CallSignal.resumed`, `.connected`) waits for
    /// that. Report a start your SDK refused (an error from starting its audio
    /// engine), not media that is merely silent. A later detach or successful
    /// attach clears it. The default implementation returns nil.
    func audioStartFailure() async -> String?

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

    /// Whether the engine may join this transport while an incoming call is still
    /// ringing (`connectWhileRinging(_:)`), before the answer and before CallKit
    /// activates the audio session (pre-connect's `.media` tier). True only if that
    /// join completes without configuring or activating `AVAudioSession`, starting audio
    /// input or output, or making the remote party audible, until the engine calls
    /// `attachAudioSession()` after CallKit's activation, and `send(_:)` reaches the
    /// remote agent, which waits for `CallSignal.connected` before it speaks. Read
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

    /// Joins as `connect(_:)` does: a transport that does not implement it joins
    /// the same way during a ring as for any other connect.
    public func connectWhileRinging(_ connection: CallConnection) async throws {
        try await connect(connection)
    }

    /// Nil: a transport that does not implement it is taken to have started its audio.
    public func audioStartFailure() async -> String? { nil }

    /// Drops the signal: a transport that does not implement `send(_:)` leaves its
    /// agent uninformed, and the call works as before.
    @discardableResult
    public func send(_ signal: CallSignal) async -> CallSignalDelivery { .unsupported }
}
