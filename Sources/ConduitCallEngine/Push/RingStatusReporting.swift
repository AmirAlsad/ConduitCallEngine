//
//  RingStatusReporting.swift
//  ConduitCallEngine
//
//  Reports an inbound ring's terminal status back to the agent's own server, when
//  the push carried a `status_url` — so a server that really needed to reach the
//  user learns whether the ring was answered, declined, arrived mid-call, or was
//  suppressed by Focus/DND. Fire-and-forget: a receipt must never block or fail
//  call handling. See `docs/INBOUND_CALLS.md` for the contract (and its privacy
//  note — receipts reveal Focus/busy state, but only to a server the user already
//  opted into).
//

import Foundation

package enum RingStatus: String, Sendable {
    case answered
    case declined
    case busy
    case suppressedByFocus = "suppressed_by_focus"
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
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: String] = [
            "call_id": callID.uuidString,
            "status": status.rawValue,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

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
}
