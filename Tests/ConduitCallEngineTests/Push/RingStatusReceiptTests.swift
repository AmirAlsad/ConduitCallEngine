//
//  RingStatusReceiptTests.swift
//  ConduitCallEngineTests
//
//  The bytes of a ring-status receipt. The `call_id` is the lowercase RFC 4122
//  form, which is what most servers generate and compare against; the push
//  contract still tells servers to compare ids case-insensitively.
//

import Foundation
import Testing
@testable import ConduitCallEngine

@MainActor
struct RingStatusReceiptTests {
    private let callID = UUID(uuidString: "0B9F3C1E-7A2D-4E58-B6C4-91D2E0F3A7B5")!
    private let endpoint = URL(string: "https://agent.example.com/rings/status")!

    @Test func theReceiptBodyCarriesTheLowercaseCallID() throws {
        let request = RingStatusReporter.request(.answered, callID: callID, endpoint: endpoint, apiKey: "secret")

        let body = try #require(request.httpBody)
        #expect(String(decoding: body, as: UTF8.self)
            == #"{"call_id":"0b9f3c1e-7a2d-4e58-b6c4-91d2e0f3a7b5","status":"answered"}"#)
        #expect(request.httpMethod == "POST")
        #expect(request.url == endpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func aReceiptWithoutABearerHasNoAuthorization() {
        let request = RingStatusReporter.request(.suppressedByFocus, callID: callID, endpoint: endpoint, apiKey: "")

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) }
            == #"{"call_id":"0b9f3c1e-7a2d-4e58-b6c4-91d2e0f3a7b5","status":"suppressed_by_focus"}"#)
    }
}
