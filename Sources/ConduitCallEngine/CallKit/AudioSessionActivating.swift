//
//  AudioSessionActivating.swift
//  ConduitCallEngine
//
//  Stands for the `AVAudioSession` CallKit activates or deactivates for a call,
//  as handed to `CallProviderDelegate`. The engine performs no operation on it in
//  the normal course of a call: CallKit owns the session, and media follows
//  activation through the transport. The engine reads it for logs, and the
//  experimental recovery after an audio interruption (`SessionInterruptionRecovery`,
//  off by default) may configure or activate it again. The real implementation
//  wraps `AVAudioSession`; the fake lets tests drive activation without a live
//  session.
//

import Foundation

@MainActor
package protocol AudioSessionActivating: AnyObject {
    /// The session as it stands, for logs: category, mode, options, other audio,
    /// sample rate, input availability and the route.
    var diagnosticDescription: String { get }
    /// Sets the call's category, mode and options again. Experimental (E-A, E-B).
    /// Returns what was done and its result, for logs.
    func reapplyCallConfiguration() -> String
    /// Activates the session again, once. Experimental (E-B) only: CallKit owns
    /// activation. Returns the result, for logs.
    func activateAgain() -> String
}
