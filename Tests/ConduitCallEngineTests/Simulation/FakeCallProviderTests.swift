//
//  FakeCallProviderTests.swift
//  ConduitCallEngineTests
//
//  The fake provider holds call ids the way CallKit does, so the engine's
//  duplicate-id paths (a cancel push, a second delivery of a ring) are tested
//  against the refusal a device produces.
//

import Foundation
import Testing
@testable import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct FakeCallProviderTests {
    private let provider = FakeCallProvider()
    private let handle = CallHandle(value: "agent@example.invalid")

    private func report(_ id: UUID) -> IncomingCallReportError?? {
        var verdict: IncomingCallReportError??
        provider.reportIncomingCall(id: id, handle: handle, displayName: "Agent") { verdict = .some($0) }
        return verdict
    }

    @Test func aReportUnderAHeldIDIsADuplicate() {
        let id = UUID()
        #expect(report(id) == .some(nil))
        #expect(report(id) == .some(.duplicateCallID))
        #expect(provider.liveCallIDs == [id])
    }

    enum Release: String, CaseIterable, Sendable {
        case reportedEnded, endRequested, endedFromSystem, reset
    }

    @Test(arguments: Release.allCases)
    func anEndedCallsIDCanBeReportedAgain(release: Release) async {
        let id = UUID()
        _ = report(id)
        switch release {
        case .reportedEnded: provider.reportCallEnded(id, reason: .remoteEnded)
        case .endRequested: await provider.endCall(id)
        case .endedFromSystem: provider.simulateEndCall(id)
        case .reset: provider.simulateReset()
        }
        #expect(provider.liveCallIDs.isEmpty)
        #expect(report(id) == .some(nil))
    }

    @Test func aRefusedReportHoldsNothing() {
        provider.reportIncomingError = .filteredByFocus
        let id = UUID()
        #expect(report(id) == .some(.filteredByFocus))
        #expect(provider.liveCallIDs.isEmpty)
    }

    @Test func aStartedCallIsHeld() async throws {
        let id = UUID()
        provider.nextCallID = id
        _ = try await provider.startOutgoingCall(handle: handle, displayName: "Agent")
        #expect(report(id) == .some(.duplicateCallID))
    }

    @Test func theSimulatedSystemReportsTheDuplicateToo() {
        let system = SimulatedCallSystem()
        system.incomingReportResult = .duplicateCallID
        #expect(system.incomingReportResult == .duplicateCallID)
    }
}
