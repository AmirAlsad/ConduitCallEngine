//
//  DailyInterruptionGate.swift
//  ConduitCallEngine
//
//  Decides when a Daily call reports a network interruption, kept pure and
//  SDK-free so every rule is unit-testable. Daily heals short outages inside its
//  SDK without changing the Pipecat transport state, so `PipecatDailyTransport`
//  infers them from the device's network path and feeds the path here.
//
//  Only a call that has reported `.connected` is watched. Losing the path emits
//  `.reconnecting` once; getting it back emits `.connected`, unless the transport
//  reported a disconnect in between (then the engine's own reconnect owns the
//  call, and that attempt is dead). Nothing is emitted after the host asks to
//  disconnect. Each connect attempt starts from a fresh gate.
//

import ConduitCallEngine

struct DailyInterruptionGate {
    enum Phase: Equatable {
        /// This attempt has not reported `.connected`, or its transport disconnected.
        case waitingForConnect
        case connected
        /// The path was lost after connect and has not come back.
        case interrupted
        /// The host asked to disconnect; final for this attempt.
        case closed
    }

    private(set) var phase: Phase = .waitingForConnect

    /// Whether the network path matters now. The adapter watches it only then.
    var isWatchingPath: Bool {
        phase == .connected || phase == .interrupted
    }

    mutating func callDidConnect() {
        guard phase == .waitingForConnect else { return }
        phase = .connected
    }

    mutating func pathDidBecomeUnsatisfied() -> TransportEvent? {
        guard phase == .connected else { return nil }
        phase = .interrupted
        return .reconnecting
    }

    mutating func pathDidBecomeSatisfied() -> TransportEvent? {
        guard phase == .interrupted else { return nil }
        phase = .connected
        return .connected
    }

    mutating func transportDidDisconnect() {
        guard phase != .closed else { return }
        phase = .waitingForConnect
    }

    mutating func userDidRequestDisconnect() {
        phase = .closed
    }
}
