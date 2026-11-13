//
//  RingPreparation.swift
//  ConduitCallEngine
//
//  Pre-connect: how much of an incoming call the engine prepares while the phone
//  is still ringing, so the agent is ready the moment the user answers. Audio
//  still waits for CallKit: nothing attaches audio, opens the mic or changes the
//  route before CallKit activates the session after the answer.
//

import Foundation

/// How much of an incoming call the engine prepares while it rings.
///
/// The tier a ring gets is the lowest of three: what the push asks for (its
/// `preconnect` key, `IncomingCall.requestedPreparation`), what the host's target
/// allows (`CallTarget.ringPreparation`), and, for `.media`, whether the target's
/// transport can connect while ringing (`CallTransport.canConnectWhileRinging`;
/// if not, `.media` becomes `.credentials`). Any of them at `.none` gives the
/// ring exactly the behaviour it would have without pre-connect.
///
/// Closed: the package adds no case to this enum within a minor version while it is
/// 0.x (from 1.0, within a major version), so a
/// `switch` may list every case. The tiers are ordered
/// (`Comparable`) from least to most.
public enum RingPreparation: Int, CaseIterable, Comparable, Sendable {
    /// Nothing before the answer: the engine fetches credentials and connects
    /// once the user answers.
    case none
    /// Run the target's `connect` during the ring and keep the credentials; the
    /// transport joins when the user answers.
    case credentials
    /// Also create the transport and join during the ring, with no audio attached
    /// and the mic closed until CallKit activates the session after the answer. An
    /// answer while the agent is already there goes straight to `.connected`.
    case media

    public static func < (lhs: RingPreparation, rhs: RingPreparation) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Where the preparation of the ringing call stands, for diagnostics
/// (`CallEngine.ringPreparationPhase`). The call's `state` stays
/// `.incomingRinging` through every phase.
///
/// Open: later versions may add cases. End a `switch` over it with `@unknown default`,
/// which keeps it compiling, with a warning that names the new case, when one is added.
public enum RingPreparationPhase: Equatable, Sendable {
    /// Nothing is being prepared: no ring, a ring whose tier is `.none`, or a ring
    /// that has been answered or has ended.
    case idle
    /// The target's `connect` is running for the ring.
    case fetchingCredentials
    /// The credentials arrived and are kept for the answer (`.credentials`).
    case credentialsReady
    /// The transport is joining the room during the ring (`.media`). Once its
    /// `connect(_:)` has returned, the agent has `CallEngineConfiguration.joinTimeout`
    /// to be there, or the preparation fails.
    case connecting
    /// The transport reported `.connected` during the ring: the agent is there.
    case ready
    /// The preparation failed. The ring rings on, and an answer connects as it
    /// would without pre-connect, with a new transport and fresh credentials.
    case failed
}
