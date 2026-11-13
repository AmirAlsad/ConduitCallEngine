//
//  ReconnectionPolicyTests.swift
//  ConduitCallEngineTests
//
//  The exponential-backoff policy in isolation.
//

import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

struct ReconnectionPolicyTests {
    private let policy = ReconnectionPolicy(maxAttempts: 6, baseDelaySeconds: 1, maxDelaySeconds: 30)

    @Test(arguments: [
        (1, Duration.seconds(1)),
        (2, Duration.seconds(2)),
        (3, Duration.seconds(4)),
        (4, Duration.seconds(8)),
        (5, Duration.seconds(16)),
        (6, Duration.seconds(30)), // 32 capped at 30
        (7, Duration.seconds(30)), // stays capped
    ])
    func delayGrowsExponentiallyAndCaps(attempt: Int, expected: Duration) {
        #expect(policy.delay(forAttempt: attempt) == expected)
    }

    @Test func zeroOrNegativeAttemptHasNoDelay() {
        #expect(policy.delay(forAttempt: 0) == .zero)
    }

    @Test func canAttemptWithinBudget() {
        #expect(policy.canAttempt(1))
        #expect(policy.canAttempt(6))
        #expect(!policy.canAttempt(7))
    }

    @Test func selfHealIsWaitedForAsLongAsTheLongestBackoff() {
        #expect(policy.transportHealTimeout == .seconds(30))
        #expect(policy.transportHealTimeout == policy.delay(forAttempt: 7))
    }
}
