//
//  DailyRemoteAudioGate.swift
//  ConduitCallEngine
//
//  Decides what the agent's audio subscription should be on a Daily call, kept pure
//  and SDK-free so every rule is unit-testable. Daily owns the audio session and
//  offers no way to pause playout, so the adapter stops the agent's audio by
//  unsubscribing from it: the engine's `detachAudioSession()` (a hold, CallKit
//  deactivating the session, teardown) unsubscribes, and `attachAudioSession()`
//  subscribes again.
//
//  A call that is never detached after an attach keeps Daily's default subscription
//  and is never touched, so a call without a hold behaves as before. A gate made with
//  `untilFirstAttach` holds the agent's audio in that state from the join until the
//  first attach.
//
//  Changes are applied one at a time, always toward the latest wanted state, so a
//  quick hold and resume ends where the engine left it. A connect or disconnect
//  starts a new session: what was applied to the old one no longer counts, and an
//  application still in flight for it is ignored when it completes. A change Daily
//  refused is not retried until something changes (an attach or detach, the join
//  completing, a new session), so a refused change before the join is tried again
//  once the call is joined.
//

enum DailyRemoteAudio: String, Equatable, Sendable {
    case subscribed
    case staged
    case unsubscribed
}

struct DailyRemoteAudioGate {
    /// One change to apply, tagged with the session it was decided for.
    struct Application: Equatable {
        let state: DailyRemoteAudio
        let session: Int
    }

    /// The agent's audio from the join until the first attach; `nil` leaves Daily's default.
    let untilFirstAttach: DailyRemoteAudio?
    private(set) var isAttached = false
    private(set) var hasAttached = false
    private(set) var hasDetachedAfterAttach = false
    /// What Daily has accepted in this session; `nil` if nothing yet.
    private(set) var applied: DailyRemoteAudio?
    private(set) var isApplying = false
    private(set) var session = 0
    private var refused: DailyRemoteAudio?

    init(untilFirstAttach: DailyRemoteAudio? = nil) {
        self.untilFirstAttach = untilFirstAttach
    }

    /// The subscription the agent's audio should have now; `nil` leaves Daily's default.
    var wanted: DailyRemoteAudio? {
        if isAttached {
            return untilFirstAttach != nil || hasDetachedAfterAttach ? .subscribed : nil
        }
        return hasAttached ? .unsubscribed : untilFirstAttach
    }

    mutating func attach() {
        isAttached = true
        hasAttached = true
        refused = nil
    }

    mutating func detach() {
        if isAttached { hasDetachedAfterAttach = true }
        isAttached = false
        refused = nil
    }

    /// A connect is about to join, or a disconnect released the session.
    mutating func sessionDidReset() {
        session += 1
        applied = nil
        isApplying = false
        refused = nil
    }

    mutating func joinDidComplete() {
        refused = nil
    }

    /// The next change to apply, or `nil` if there is none or one is in flight.
    mutating func beginApplying() -> Application? {
        guard !isApplying, let wanted, wanted != applied, wanted != refused else { return nil }
        isApplying = true
        return Application(state: wanted, session: session)
    }

    mutating func applyDidSucceed(_ application: Application) {
        guard application.session == session else { return }
        isApplying = false
        applied = application.state
    }

    mutating func applyDidFail(_ application: Application) {
        guard application.session == session else { return }
        isApplying = false
        refused = application.state
    }
}
