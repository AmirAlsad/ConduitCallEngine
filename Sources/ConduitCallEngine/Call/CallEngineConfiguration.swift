//
//  CallEngineConfiguration.swift
//  ConduitCallEngine
//
//  The host's settings for the call engine. `isPushToTalkEnabled` is a closure so a
//  mid-call settings flip is honoured on the next mic decision.
//

import Foundation

/// The host's settings for a `CallEngine`, fixed when the engine is created.
// Unchecked only because the package compiles in the Swift 5 mode: every stored
// property is a value, and `isPushToTalkEnabled` is main-actor isolated, a function
// type Swift 6 treats as Sendable (SE-0434).
public struct CallEngineConfiguration: @unchecked Sendable {
    /// The caller name a ring shows when the push carries none. Default `"Unknown"`.
    public var unknownCallerName: String
    /// How long an incoming call rings before the engine ends it as unanswered:
    /// CallKit is told `.unanswered`, the host gets a `CallRecord` with
    /// `missedReason: .ringTimedOut`, and an `unanswered` receipt is sent when the
    /// push asked for receipts. Measured from the push, with the engine's injected
    /// sleep. A push's `ring_timeout` can shorten it (to no less than 10 seconds)
    /// but never lengthen it. nil sets no limit of the engine's own: the ring then
    /// lasts until it is answered, declined or cancelled, unless the push carries
    /// `ring_timeout`, which still applies. Default 60 seconds.
    public var ringTimeout: Duration?
    /// How long the engine waits for the transport to report `.connected` once a
    /// `CallTransport.connect(_:)` has returned without throwing: the transport has
    /// joined, and the agent has that long to be ready. When it runs out on a
    /// call's first connect, the call fails as `.agentUnreachable`; on an engine
    /// reconnect attempt, the attempt counts as failed, and the next one is
    /// scheduled with its backoff or the call fails as `.lostConnection` once the
    /// retry budget is spent; on a ring's pre-connected join, the preparation fails.
    /// Time on hold does not count on a first connect: a hold stops the wait, and the
    /// resume starts it again in full (a reconnect attempt is paused by the hold
    /// anyway). Measured with the engine's injected sleep. nil waits indefinitely, as
    /// 0.1 did. Default 30 seconds.
    public var joinTimeout: Duration?
    /// For calls the user placed (`CallEngine.placeCall(_:)`) only: the shortest time
    /// an outgoing call stays `.connecting`, counted from the connecting cue
    /// (`CallCue.start(.connecting)`). It exists so a host's outgoing ringback can
    /// finish its first tone: set it to the length of that tone (plus any delay
    /// before it starts), so a call whose transport is ready sooner still rings that
    /// long. It never applies to an incoming call: an answered call becomes
    /// `.connected` as soon as its transport reports `.connected`, and a ring whose
    /// pre-connected agent is there at the answer goes straight to `.connected`.
    ///
    /// On an outgoing call the engine holds the call in `.connecting` (and does not
    /// report it connected to CallKit, deliver `.moment(.connected)`, open the mic,
    /// send `CallSignal.connected` or start the call's duration) until both the
    /// transport has reported `.connected` and this much time has passed since the
    /// connecting loop last started: the transition to `.connecting`, or the resume
    /// of a call held while connecting, which starts the loop and this wait again in
    /// full.
    ///
    /// The transport's readiness, not the delayed state, ends the wait bounded by
    /// `joinTimeout`. While the engine holds a ready connection, what the transport
    /// reports about it (a drop, healing itself, the agent leaving, rejected
    /// credentials, a failed connect) is applied to the call it made: the engine
    /// reports the connection at once, then handles the event, so the call ends up
    /// where it would have without the minimum. What the user or the system does
    /// (ending the call, a provider reset, a hold, mute, an interruption, CallKit
    /// deactivating the audio) applies to the call as it stands, connecting: a call
    /// ended then was never connected (`.canceled`). Measured with the engine's
    /// injected clock and sleep. Keep it to a few seconds: the agent and the user
    /// wait it out. Default zero (no minimum).
    public var minimumOutgoingConnectingDuration: Duration
    /// The longest the host can keep the mic closed with `CallEngine.setMicWithheld(_:)`
    /// once the call is connected and CallKit has activated its audio, whichever
    /// comes last (or from the withhold, if that is later). When it runs out, the
    /// engine releases the withhold itself, logs a warning, and the mic follows the
    /// rest of its rule again; `CallEngine.isMicWithheld` turns false. It bounds a
    /// host that forgets to release, so set it a little beyond your longest
    /// connected sound; there is no unbounded setting, since a mic the
    /// user cannot see is closed is the failure it prevents. Measured with the
    /// engine's injected sleep. Default 5 seconds.
    public var micWithholdTimeout: Duration
    /// Whether calls are reported to CallKit as holdable. When true (the default),
    /// iOS can put the call on hold (for example to answer or place a phone call)
    /// and the host can hold it with `CallEngine.setOnHold(_:)`; see
    /// `CallEngine.isOnHold`. When false, CallKit offers no hold for the call, and a
    /// phone call that starts during it ends it.
    public var supportsHolding: Bool
    /// Whether the engine resumes a call iOS held for another call once that call
    /// has ended. When the system holds the call (a `CXSetHeldCallAction` your app
    /// did not request with `CallEngine.setOnHold(_:)`, as when the user takes a
    /// phone call), the engine watches the other calls on the device through
    /// CallKit's call observer; once every call it saw during the hold has ended and
    /// no other call is left, it asks CallKit to resume its call, as the user's
    /// resume would. CallKit does not do this for an app's calls itself. A call
    /// still up (a third call, a call on hold) keeps it held; a hold your app
    /// requested is never resumed by the engine, nor one your app asked to keep
    /// with `setOnHold(true)`. A system hold during which no other call is seen
    /// (the user holding from the system call screen) stays until it is resumed.
    /// No effect when `supportsHolding` is false. Default true.
    public var resumesAfterSystemHold: Bool
    /// Whether the engine moves a call to the loudspeaker when nothing external is
    /// connected. When true, once per call, after CallKit has activated its audio
    /// and the transport's route list is available, the engine selects the speaker
    /// if the transport lists no Bluetooth or wired route (0.1's hands-free
    /// default). When false (the default), the engine makes no route change of its
    /// own: the call starts where iOS puts it, which for a CallKit call with
    /// nothing connected is the earpiece, like a phone call. Either way the user's
    /// choice (`CallEngine.selectAudioDevice(_:)`, the system call screen's route
    /// button where the transport allows it, Bluetooth, CarPlay) is never
    /// overridden, and no route is read or changed before CallKit's activation.
    public var defaultsToSpeaker: Bool
    /// Whether the mic follows a push-to-talk button (`CallEngine.setPushToTalkActive(_:)`)
    /// instead of mute. Called on the main actor at each mic decision, so a setting
    /// changed mid-call takes effect at the next one. Default `{ false }`.
    public var isPushToTalkEnabled: @MainActor () -> Bool

    public init(
        unknownCallerName: String = "Unknown",
        ringTimeout: Duration? = .seconds(60),
        joinTimeout: Duration? = .seconds(30),
        minimumOutgoingConnectingDuration: Duration = .zero,
        micWithholdTimeout: Duration = .seconds(5),
        supportsHolding: Bool = true,
        resumesAfterSystemHold: Bool = true,
        defaultsToSpeaker: Bool = false,
        isPushToTalkEnabled: @escaping @MainActor () -> Bool = { false }
    ) {
        self.unknownCallerName = unknownCallerName
        self.ringTimeout = ringTimeout
        self.joinTimeout = joinTimeout
        self.minimumOutgoingConnectingDuration = minimumOutgoingConnectingDuration
        self.micWithholdTimeout = micWithholdTimeout
        self.supportsHolding = supportsHolding
        self.resumesAfterSystemHold = resumesAfterSystemHold
        self.defaultsToSpeaker = defaultsToSpeaker
        self.isPushToTalkEnabled = isPushToTalkEnabled
    }
}
