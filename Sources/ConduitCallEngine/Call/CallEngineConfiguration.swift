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
    /// Whether calls are reported to CallKit as holdable. When true (the default),
    /// iOS can put the call on hold (for example to answer or place a phone call)
    /// and the host can hold it with `CallEngine.setOnHold(_:)`; see
    /// `CallEngine.isOnHold`. When false, CallKit offers no hold for the call, and a
    /// phone call that starts during it ends it.
    public var supportsHolding: Bool
    /// Whether the mic follows a push-to-talk button (`CallEngine.setPushToTalkActive(_:)`)
    /// instead of mute. Called on the main actor at each mic decision, so a setting
    /// changed mid-call takes effect at the next one. Default `{ false }`.
    public var isPushToTalkEnabled: @MainActor () -> Bool

    public init(
        unknownCallerName: String = "Unknown",
        ringTimeout: Duration? = .seconds(60),
        joinTimeout: Duration? = .seconds(30),
        supportsHolding: Bool = true,
        isPushToTalkEnabled: @escaping @MainActor () -> Bool = { false }
    ) {
        self.unknownCallerName = unknownCallerName
        self.ringTimeout = ringTimeout
        self.joinTimeout = joinTimeout
        self.supportsHolding = supportsHolding
        self.isPushToTalkEnabled = isPushToTalkEnabled
    }
}
