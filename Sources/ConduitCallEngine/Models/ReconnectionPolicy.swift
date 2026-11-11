//
//  ReconnectionPolicy.swift
//  ConduitCallEngine
//
//  The exponential-backoff policy for recovering a dropped media connection while
//  CallKit still believes the call is up. Pure and deterministic so it unit-tests
//  in isolation; the engine runs the loop and injects the actual sleep.
//

import Foundation

package struct ReconnectionPolicy: Equatable, Sendable {
    /// Maximum number of reconnection attempts before the call is declared lost.
    package let maxAttempts: Int
    package let baseDelaySeconds: Double
    package let maxDelaySeconds: Double

    package init(maxAttempts: Int, baseDelaySeconds: Double, maxDelaySeconds: Double) {
        self.maxAttempts = maxAttempts
        self.baseDelaySeconds = baseDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
    }

    package static let `default` = ReconnectionPolicy(
        maxAttempts: 6,
        baseDelaySeconds: 1,
        maxDelaySeconds: 30
    )

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
