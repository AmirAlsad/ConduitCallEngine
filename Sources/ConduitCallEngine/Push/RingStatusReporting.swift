//
//  RingStatusReporting.swift
//  ConduitCallEngine
//
//  Reports an inbound ring's terminal status to the push's `status_url`, when it
//  carried one, so the server that rang learns whether the ring was answered,
//  declined, arrived mid-call, was suppressed by Focus/DND, rang out, or was
//  withdrawn by the caller. The receipt is a
//  JSON POST of `call_id` and `status`, with the host's bearer when it supplies
//  one. Fire-and-forget: a receipt never blocks or fails call handling. Receipts
//  reveal Focus and busy state to that server.
//

import Foundation

package enum RingStatus: String, Sendable {
    case answered
    case declined
    case busy
    case suppressedByFocus = "suppressed_by_focus"
    case unanswered
    case canceled
}

@MainActor
package protocol RingStatusReporting: AnyObject {
    func report(_ status: RingStatus, callID: UUID, endpoint: URL, apiKey: String)
}

@MainActor
final class RingStatusReporter: RingStatusReporting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func report(_ status: RingStatus, callID: UUID, endpoint: URL, apiKey: String) {
        let request = Self.request(status, callID: callID, endpoint: endpoint, apiKey: apiKey)
        let session = session
        Task {
            do {
                _ = try await session.data(for: request)
                Log.info(.network, "Reported ring status \(status.rawValue)")
            } catch {
                Log.warning(.network, "Ring-status report failed: \(error)")
            }
        }
    }

    /// The receipt's request: a JSON POST of `call_id` and `status`, keys sorted. The
    /// id is in lowercase RFC 4122 form, as most servers write theirs (servers must
    /// still compare case-insensitively).
    static func request(_ status: RingStatus, callID: UUID, endpoint: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: String] = [
            "call_id": callID.uuidString.lowercased(),
            "status": status.rawValue,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}
