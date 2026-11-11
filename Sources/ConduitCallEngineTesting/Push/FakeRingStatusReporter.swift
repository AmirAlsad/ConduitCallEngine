//
//  FakeRingStatusReporter.swift
//  ConduitCallEngine
//
//  Fake conforming to `RingStatusReporting`: records each receipt instead
//  of POSTing it.
//

import Foundation
import ConduitCallEngine

@MainActor
package final class FakeRingStatusReporter: RingStatusReporting {
    package init() {}

    package struct Report: Equatable {
        package let status: RingStatus
        package let callID: UUID
        package let endpoint: URL
        package let apiKey: String

        package init(status: RingStatus, callID: UUID, endpoint: URL, apiKey: String) {
            self.status = status
            self.callID = callID
            self.endpoint = endpoint
            self.apiKey = apiKey
        }
    }

    package private(set) var reports: [Report] = []
    /// Receives a label per receipt, for tests that assert order across fakes.
    package var onEvent: ((String) -> Void)?

    package func report(_ status: RingStatus, callID: UUID, endpoint: URL, apiKey: String) {
        onEvent?("receipt(\(status.rawValue))")
        reports.append(Report(status: status, callID: callID, endpoint: endpoint, apiKey: apiKey))
    }
}
