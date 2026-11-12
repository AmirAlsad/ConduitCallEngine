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
/// change that caused it and after any ring-status receipt of that change. The
/// engine guarantees, for every call:
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
///   is the only sound.
/// - Nothing plays while the call is on hold: `.moment(.held)` comes with no loop
///   running (a running one is stopped first), and the next cue is
///   `.moment(.resumed)`, followed by the loop the call's state wants, if any. An
///   outage that begins during the hold and is still going at the resume is marked
///   then, with `.moment(.connectionLost)` before the loop; a call that first
///   connected during the hold gets its `.moment(.connected)` then. Hold and resume cues
///   come when CallKit performs the hold action, not with a state change.
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
public enum RepeatingCue: Equatable, Sendable {
    /// The call is connecting: placed and accepted by CallKit, or answered, and
    /// waiting for the agent. Starts on the transition to `.connecting`.
    case connecting
    /// The connection dropped and the engine or the transport is trying to get it
    /// back. Starts on the transition from `.connected` to `.reconnecting`.
    case retrying
}

/// A one-shot moment of a call.
public enum CallMoment: Equatable, Sendable {
    /// The call connected for the first time (`.connecting` to `.connected`, or
    /// at the resume for a call that connected on hold). Once per call.
    case connected
    /// The call came back after an outage (`.reconnecting` to `.connected`).
    case reconnected
    /// The connection dropped (`.connected` to `.reconnecting`, or at the resume
    /// for an outage that began on hold). Once per outage.
    case connectionLost
    /// The call was put on hold (`CallEngine.isOnHold` became true).
    case held
    /// A held call was resumed (`CallEngine.isOnHold` became false).
    case resumed
}
