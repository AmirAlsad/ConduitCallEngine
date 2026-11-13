//
//  ReconnectionPolicy.swift
//  ConduitCallEngine
//
//  The exponential-backoff policy for recovering a dropped media connection while
//  CallKit still believes the call is up, and how long a transport healing itself
//  is waited for before the engine reconnects on its own. Pure and deterministic
//  so it unit-tests in isolation; the engine runs the loop and injects the sleep.
//

import Foundation

package struct ReconnectionPolicy: Equatable, Sendable {
    /// Maximum number of reconnection attempts before the call is declared lost.
    package let maxAttempts: Int
    package let baseDelaySeconds: Double
    package let maxDelaySeconds: Double
    /// How long a transport that reported `.reconnecting` may take to report
    /// `.connected` or `.disconnected` before the engine treats it as dropped.
    package let transportHealTimeoutSeconds: Double

    package init(
        maxAttempts: Int,
        baseDelaySeconds: Double,
        maxDelaySeconds: Double,
        transportHealTimeoutSeconds: Double = 30
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelaySeconds = baseDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
        self.transportHealTimeoutSeconds = transportHealTimeoutSeconds
    }

    /// The self-heal bound is the backoff cap: the engine never leaves a dropped
    /// call longer than that without trying something itself.
    package static let `default` = ReconnectionPolicy(
        maxAttempts: 6,
        baseDelaySeconds: 1,
        maxDelaySeconds: 30,
        transportHealTimeoutSeconds: 30
    )

    package var transportHealTimeout: Duration { .seconds(transportHealTimeoutSeconds) }

    /// Whether an attempt numbered `attempt` (1-based) is still within budget.
    package func canAttempt(_ attempt: Int) -> Bool {
        attempt <= maxAttempts
    }

    /// Backoff before the given 1-based attempt: `base * 2^(n-1)`, capped.
    package func delay(forAttempt attempt: Int) -> Duration {
        guard attempt >= 1 else { return .zero }
        let raw = baseDelaySeconds * pow(2, Double(attempt - 1))
        return .seconds(min(raw, maxDelaySeconds))
    }
}
