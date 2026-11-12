//
//  CallCue.swift
//  ConduitCallEngine
//
//  The moments of a call a host may mark with its own sound or speech. The
//  engine plays nothing; it tells the host when, through
//  `CallEngineDelegate.callEngine(_:cue:)` and `CallEngine.repeatingCue`.
//

import Foundation

/// A moment a host may mark with its own sound or speech. The engine plays nothing.
///
/// Delivered through `CallEngineDelegate.callEngine(_:cue:)`, synchronously on the
/// main actor, right after the `callEngine(_:didChangeStateFrom:to:)` of the state
/// change that caused it and after any ring-status receipt of that change, except
/// where noted below (`.moment(.connected)`, hold and resume). The engine
/// guarantees, for every call:
///
/// - At most one repeating cue runs at a time. Every `start` is followed by exactly
///   one `stop`, before the next `start`, before `.moment(.connected)` or
///   `.moment(.reconnected)`, and no later than the transition that ends the call
///   (to `.ended`, `.failed` or `.idle`, a CallKit provider reset included).
/// - `.moment(.connectionLost)` is delivered once per outage, however the outage
///   escalates (a transport healing itself, then the engine's own retries), and is
///   followed by `.start(.retrying)`.
/// - A ring that is never answered (declined, timed out, cancelled, filtered,
///   busy, or ended before it could proceed) produces no cues: CallKit's ringtone
///   is the only sound. That includes a ring prepared while it rang.
/// - An answer to a pre-connected ring whose agent is already there produces
///   `.moment(.connected)` with no `.start(.connecting)` before it.
/// - `.moment(.connected)` comes only once CallKit has activated the call's audio
///   (`CallEngine.isAudioActivated`), so a sound played on it plays into a live
///   session: with the state change when the session is already active, otherwise
///   at the activation, with no state change. The loop the state change stopped is
///   stopped with the state change.
/// - Nothing plays while the call is on hold: `.moment(.held)` comes with no loop
///   running (a running one is stopped first), and the next cue is
///   `.moment(.resumed)`, followed by the loop the call's state wants, if any. An
///   outage that begins during the hold and is still going at the resume is marked
///   then, with `.moment(.connectionLost)` before the loop; a call that first
///   connected during the hold gets its `.moment(.connected)` then. Hold and resume cues
///   come when CallKit performs the hold action, not with a state change. A call
///   that ends while held gets no `.moment(.resumed)`: the hold ends with the call.
///
/// Closed: the package adds no case to this enum within a major version. Its payloads,
/// `RepeatingCue` and `CallMoment`, are open, so a `switch` that matches them inside
/// a cue (`case .moment(.connected):`) ends with `@unknown default`.
public enum CallCue: Equatable, Sendable {
    /// Begin a looping cue (a ringback, a "retrying" sound) and keep it going
    /// until the matching `stop`.
    case start(RepeatingCue)
    /// End the looping cue that is running.
    case stop
    /// A one-shot moment.
    case moment(CallMoment)
}

/// A cue a host plays on a loop until the engine says `stop`.
///
/// Open: later versions may add cases. End a `switch` over it with `@unknown default`,
/// which keeps it compiling, with a warning that names the new case, when one is added. A loop a host does not know can
/// be left silent: its `stop` still follows.
public enum RepeatingCue: Equatable, Sendable {
    /// The call is connecting: placed and accepted by CallKit, or answered, and
    /// waiting for the agent. Starts on the transition to `.connecting`, which an
    /// answer to a pre-connected ring whose agent is there skips.
    case connecting
    /// The connection dropped and the engine or the transport is trying to get it
    /// back. Starts on the transition from `.connected` to `.reconnecting`.
    case retrying
}

/// A one-shot moment of a call.
///
/// Open: later versions may add cases. End a `switch` over it with `@unknown default`,
/// which keeps it compiling, with a warning that names the new case, when one is added.
public enum CallMoment: Equatable, Sendable {
    /// The call connected for the first time (`.connecting` to `.connected`, or
    /// `.incomingRinging` to `.connected` for a pre-connected ring answered with its
    /// agent there), once CallKit has activated its audio and it is not held:
    /// delivered with that transition, or later at CallKit's activation or at the
    /// resume, whichever comes last. Once per call; a call that drops before it is
    /// delivered gets it, instead of `.reconnected`, when it is back.
    case connected
    /// The call came back after an outage (`.reconnecting` to `.connected`).
    case reconnected
    /// The connection dropped (`.connected` to `.reconnecting`, or at the resume
    /// for an outage that began on hold). Once per outage.
    case connectionLost
    /// The call was put on hold (`CallEngine.isOnHold` became true). A call that ends
    /// while held gets no `.resumed`.
    case held
    /// A held call was resumed (`CallEngine.isOnHold` became false).
    case resumed
}
