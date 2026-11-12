//
//  LiveKitEndCallSignal.swift
//  ConduitCallEngine
//
//  How `LiveKitTransport` sends its RTVI client messages (the end-call signal from
//  `disconnect()` and the call-control signals from `send(_:)`), kept pure and
//  SDK-free so it is unit-testable. A message is sent unless the room is already
//  leaving: a room that is still connecting (the host disconnects right after
//  starting a connect) or reconnecting may already be visible to the agent, which
//  would otherwise wait out its grace window. LiveKit holds a data send made while
//  the room is connecting or reconnecting until the data channel opens, so the send
//  is bounded: no caller waits longer than `deadline` for it.
//
//  The bytes are the RTVI client-message envelope a Pipecat bot parses from LiveKit's
//  raw data-received event: `{"id": "<8 characters>", "label": "rtvi-ai",
//  "type": "client-message", "data": {"t": "<name>"}}`.
//

import Foundation

enum LiveKitEndCallSignal {
    /// The room's connection state, mirrored so the policy is testable without the SDK.
    enum RoomPhase: CaseIterable {
        case disconnected, connecting, reconnecting, connected, disconnecting
    }

    /// The longest `disconnect()` waits for the room to finish connecting and for the
    /// signal to be handed to the data channel, before it leaves regardless.
    static let deadline: Duration = .seconds(2)

    /// The envelope for the client message named `type`, as UTF-8 JSON.
    static func payload(type: String, id: String = String(UUID().uuidString.prefix(8))) -> Data? {
        let message: [String: Any] = [
            "id": id,
            "label": "rtvi-ai",
            "type": "client-message",
            "data": ["t": type],
        ]
        return try? JSONSerialization.data(withJSONObject: message)
    }

    static func shouldSend(in phase: RoomPhase) -> Bool {
        switch phase {
        case .connecting, .reconnecting, .connected: true
        case .disconnecting, .disconnected: false
        }
    }

    /// Runs `operation` and returns when it finishes or when `deadline` passes,
    /// whichever is first, with whether it finished. An operation still running at
    /// the deadline is cancelled and left to end on its own (leaving the room fails
    /// LiveKit's pending sends).
    @discardableResult
    static func run(
        within deadline: Duration,
        _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let (outcome, report) = AsyncStream.makeStream(of: Bool.self)
        let work = Task {
            await operation()
            report.yield(true)
            report.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            report.yield(false)
            report.finish()
        }
        var finished = false
        for await value in outcome {
            finished = value
            break
        }
        timer.cancel()
        work.cancel()
        return finished
    }
}
