//
//  LiveKitEndCallSignal.swift
//  ConduitCallEngine
//
//  When `LiveKitTransport.disconnect()` sends the end-call signal, kept pure and
//  SDK-free so it is unit-testable. The signal is sent unless the room is already
//  leaving: a room that is still connecting (the host disconnects right after
//  starting a connect) or reconnecting may already be visible to the agent, which
//  would otherwise wait out its grace window. LiveKit holds a data send made while
//  the room is connecting or reconnecting until the data channel opens, so the send
//  is bounded: disconnecting never waits longer than `deadline` for it.
//

enum LiveKitEndCallSignal {
    /// The room's connection state, mirrored so the policy is testable without the SDK.
    enum RoomPhase: CaseIterable {
        case disconnected, connecting, reconnecting, connected, disconnecting
    }

    /// The longest `disconnect()` waits for the room to finish connecting and for the
    /// signal to be handed to the data channel, before it leaves regardless.
    static let deadline: Duration = .seconds(2)

    static func shouldSend(in phase: RoomPhase) -> Bool {
        switch phase {
        case .connecting, .reconnecting, .connected: true
        case .disconnecting, .disconnected: false
        }
    }

    /// Runs `operation` and returns when it finishes or when `deadline` passes,
    /// whichever is first. An operation still running at the deadline is cancelled
    /// and left to end on its own (leaving the room fails LiveKit's pending sends).
    static func run(
        within deadline: Duration,
        _ operation: @escaping @Sendable () async -> Void
    ) async {
        let (finished, finish) = AsyncStream.makeStream(of: Void.self)
        let work = Task {
            await operation()
            finish.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            finish.finish()
        }
        for await _ in finished {}
        timer.cancel()
        work.cancel()
    }
}
