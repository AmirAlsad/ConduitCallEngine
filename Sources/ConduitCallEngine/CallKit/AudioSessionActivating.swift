//
//  AudioSessionActivating.swift
//  ConduitCallEngine
//
//  Stands for the `AVAudioSession` CallKit activates or deactivates for a call,
//  as handed to `CallProviderDelegate`. The engine performs no operation on it:
//  CallKit owns the session, and media follows activation through the transport.
//  The engine only reads it for logs. The real implementation wraps
//  `AVAudioSession`; the fake lets tests drive activation without a live session.
//

import Foundation

@MainActor
package protocol AudioSessionActivating: AnyObject {
    /// The session as it stands, for logs: category, mode, options, other audio,
    /// sample rate, input availability and the route.
    var diagnosticDescription: String { get }
}
