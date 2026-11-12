//
//  CallEngineConfiguration.swift
//  ConduitCallEngine
//
//  The host's settings for the call engine. `isPushToTalkEnabled` is a closure so a
//  mid-call settings flip is honoured on the next mic decision.
//

import Foundation

public struct CallEngineConfiguration {
    /// The caller name a ring shows when the push carries none.
    public var unknownCallerName: String
    public var isPushToTalkEnabled: @MainActor () -> Bool
    /// How long an incoming call rings before the engine ends it as unanswered:
    /// CallKit is told `.unanswered`, the host gets a `CallRecord` with
    /// `missedReason: .ringTimedOut`, and an `unanswered` receipt is sent when the
    /// push asked for receipts. Measured from the push, with the engine's injected
    /// sleep. A push's `ring_timeout` can shorten it (to no less than 10 seconds)
    /// but never lengthen it. nil sets no limit of the engine's own: the ring then
    /// lasts until it is answered, declined or cancelled, unless the push carries
    /// `ring_timeout`, which still applies. Default 60 seconds.
    public var ringTimeout: Duration?
    /// Whether calls are reported to CallKit as holdable. When true (the default),
    /// iOS can put the call on hold (for example to answer or place a phone call)
    /// and the host can hold it with `CallEngine.setOnHold(_:)`; see
    /// `CallEngine.isOnHold`. When false, CallKit offers no hold for the call, and a
    /// phone call that starts during it ends it.
    public var supportsHolding: Bool
    /// How long the engine waits for the transport to report `.connected` after an
    /// engine reconnect attempt's `CallTransport.connect(_:)` has returned. When it
    /// runs out, the attempt counts as failed: the next one is scheduled with its
    /// backoff, or the call fails as `.lostConnection` once the retry budget is
    /// spent. Measured with the engine's injected sleep. nil waits indefinitely,
    /// as 0.1 did. Default 30 seconds.
    public var joinTimeout: Duration?

    public init(
        unknownCallerName: String = "Unknown",
        isPushToTalkEnabled: @escaping @MainActor () -> Bool = { false },
        ringTimeout: Duration? = .seconds(60),
        supportsHolding: Bool = true,
        joinTimeout: Duration? = .seconds(30)
    ) {
        self.unknownCallerName = unknownCallerName
        self.isPushToTalkEnabled = isPushToTalkEnabled
        self.ringTimeout = ringTimeout
        self.supportsHolding = supportsHolding
        self.joinTimeout = joinTimeout
    }
}
