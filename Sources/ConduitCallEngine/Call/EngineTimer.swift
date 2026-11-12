//
//  EngineTimer.swift
//  ConduitCallEngine
//
//  The engine's timers, each running on the `sleep` injected into the engine. Named
//  so a simulated system can run one out early (`CallEngine.fireTimer(_:)`).
//

import Foundation

package enum EngineTimer: Hashable, CaseIterable, Sendable {
    /// The ring timeout (`CallEngineConfiguration.ringTimeout`, or the push's).
    case ringTimeout
    /// The wait for the agent after a connect returned (`joinTimeout`), on a call's
    /// first connect, a reconnect attempt, or a ring's join.
    case joinTimeout
    /// The wait for a transport that reported `.reconnecting`.
    case selfHealTimeout
    /// The backoff before the next reconnect attempt.
    case reconnectBackoff
    /// The wait before a signal that did not leave the device is sent again.
    case signalRetry
    /// The rest of `minimumConnectingDuration`, while a call whose transport is
    /// ready is held in `.connecting`.
    case minimumConnecting
    /// The bound on a host's withhold of the mic (`micWithholdTimeout`), from the
    /// moment the call is connected with its audio activated.
    case micWithholdTimeout
}
