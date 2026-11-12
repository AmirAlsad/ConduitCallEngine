//
//  LiveKitRoomControlling.swift
//  ConduitCallEngine
//
//  The seams between `LiveKitTransport` and the LiveKit SDK: the parts of a `Room`
//  and of LiveKit's audio engine the transport uses. The transport's rules about
//  when to join, leave and signal depend on how LiveKit sequences those operations,
//  so tests replace these with doubles that sequence them the same way; the real
//  implementations below are thin forwards to the SDK.
//

import Foundation
import ConduitCallEngine
import LiveKit

/// The parts of a LiveKit `Room` the transport uses. LiveKit's `Room.connect` cleans
/// the room up and sets it up before the room reports `.connecting`, and
/// `Room.disconnect` does nothing while the room is `.disconnected`, so a disconnect
/// in that window leaves nothing; a second `connect` cleans up whatever the first one
/// was doing.
@MainActor
protocol LiveKitRoomControlling: AnyObject, Sendable {
    var phase: LiveKitEndCallSignal.RoomPhase { get }
    var hasRemoteParticipants: Bool { get }
    func connect(url: String, token: String) async throws
    func disconnect() async
    /// Publishes `data` reliably on the room's data channel.
    func publish(_ data: Data) async throws
    func setMicrophone(enabled: Bool) async throws
}

/// LiveKit's audio engine: off until CallKit activates the session.
@MainActor
protocol LiveKitAudioEngineControlling: AnyObject {
    func setAvailable(_ available: Bool) throws
    var isRunning: Bool { get }
}

@MainActor
final class LiveKitSDKRoom: LiveKitRoomControlling {
    private let room: Room

    init(delegate: RoomDelegate) {
        room = Room(delegate: delegate)
    }

    var phase: LiveKitEndCallSignal.RoomPhase { LiveKitEndCallSignal.RoomPhase(room.connectionState) }
    var hasRemoteParticipants: Bool { !room.remoteParticipants.isEmpty }

    func connect(url: String, token: String) async throws {
        try await room.connect(url: url, token: token)
    }

    func disconnect() async {
        await room.disconnect()
    }

    func publish(_ data: Data) async throws {
        try await room.localParticipant.publish(data: data, options: DataPublishOptions(reliable: true))
    }

    func setMicrophone(enabled: Bool) async throws {
        _ = try await room.localParticipant.setMicrophone(enabled: enabled)
    }
}

/// LiveKit's process-wide audio engine, in manual-audio mode: LiveKit's automatic
/// `AVAudioSession` configuration is turned off, because CallKit owns the session.
@MainActor
final class LiveKitSDKAudioEngine: LiveKitAudioEngineControlling {
    init() {
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
    }

    func setAvailable(_ available: Bool) throws {
        try AudioManager.shared.setEngineAvailability(available ? .default : .none)
    }

    var isRunning: Bool { AudioManager.shared.isEngineRunning }
}

extension LiveKitEndCallSignal.RoomPhase {
    init(_ state: ConnectionState) {
        switch state {
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .reconnecting: self = .reconnecting
        case .connected: self = .connected
        case .disconnecting: self = .disconnecting
        @unknown default: self = .disconnected
        }
    }
}
