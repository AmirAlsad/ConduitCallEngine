//
//  WaitUntilTests.swift
//  ConduitCallEngineTests
//
//  `waitUntil` is how these tests wait for work that arrives on later main-actor
//  turns. A wait that runs out must fail the test where it waited, not leave the
//  expectation after it to fail for a reason the log does not show.
//

import Testing

@MainActor
struct WaitUntilTests {
    @Test func aWaitThatRunsOutRecordsAnIssue() async {
        await withKnownIssue {
            await waitUntil(ticks: 3) { false }
        }
    }

    @Test func aConditionThatHoldsEndsTheWaitWithoutAnIssue() async {
        var checks = 0
        await waitUntil(ticks: 10) {
            checks += 1
            return checks == 3
        }
        #expect(checks == 3)
    }
}
