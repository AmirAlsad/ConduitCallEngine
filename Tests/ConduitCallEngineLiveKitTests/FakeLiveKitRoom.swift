//
//  FakeLiveKitRoom.swift
//  ConduitCallEngineLiveKitTests
//
//  Stands in for a LiveKit `Room`, which needs LiveKit's WebRTC audio and a server.
//  It sequences its operations as `Room` does (client-sdk-swift 2.19.0), because the
//  transport's rules depend on that sequencing:
//
//  - `connect` first cleans the room up and sets it up, and only then reports
//    `.connecting`; in that window the room is still `.disconnected`.
//  - `disconnect` does nothing while the room is `.disconnected` or `.disconnecting`.
//  - Cleaning up fails a connect in progress, and a connect that fails cleans up in
//    turn, so two connects on one room tear each other down.
//  - A connect is cancellation-aware: cancelled, it cleans up and throws.
//  - Cleaning up a room with remote participants reports each of them leaving.
//  - Participants already in the room arrive with the join response, while the
//    room is still `.connecting`, without a participant-joined callback.
//  - A full reconnect cleans the participants up with notifications on, and each
//    remote's departure is reported while the remotes are still listed: `Room`
//    empties `remoteParticipants` only after every participant's cleanup, and its
//    delegate call, has returned (`Room.cleanUpParticipants`).
//

import Foundation
import ConduitCallEngine
@testable import ConduitCallEngineLiveKit

@MainActor
final class FakeLiveKitRoom: LiveKitRoomControlling {
    struct NotConnected: Error {}
    struct TornDown: Error {}

    weak var events: RoomEventMapper?
    private(set) var phase: LiveKitEndCallSignal.RoomPhase = .disconnected
    private(set) var remotes = 0
    var hasRemoteParticipants: Bool { remotes > 0 }

    /// What the transport asked of the room, in order: `connect <url>`, `leave`,
    /// `publish <t>`, `mic <on|off>`.
    private(set) var log: [String] = []
    /// The client messages published, by their `t`.
    var published: [String] { log.compactMap { $0.hasPrefix("publish ") ? String($0.dropFirst(8)) : nil } }
    var leaveCount: Int { log.filter { $0 == "leave" }.count }

    /// Whether `connect` waits, after its clean-up and before the room reports
    /// `.connecting`, until `releaseSetUp()`.
    var holdsSetUp = false
    /// Whether `connect` waits while `.connecting` until `completeJoin()`.
    var holdsJoin = false
    /// Whether a held join ignores its task's cancellation until `completeJoin()`,
    /// as a join deep in LiveKit's connect sequence can for a while.
    var holdsJoinThroughCancellation = false
    /// Whether the agent is in the room a join enters.
    var agentWaitsInRoom = true
    /// When set, publishing fails with it.
    var publishError: (any Error)?

    private var generation = 0
    private var setUpWaiter: CheckedContinuation<Void, Never>?
    private var joinWaiter: CheckedContinuation<Void, Never>?

    var isHoldingSetUp: Bool { setUpWaiter != nil }
    var isHoldingJoin: Bool { joinWaiter != nil }

    func connect(url: String, token: String) async throws {
        log.append("connect \(url)")
        await cleanUp()
        if holdsSetUp { await withCheckedContinuation { setUpWaiter = $0 } }
        do {
            try Task.checkCancellation()
        } catch {
            await cleanUp()
            throw error
        }
        let mine = generation
        phase = .connecting
        events?.roomDidStartConnecting()
        if agentWaitsInRoom { remotes = 1 } // the join response
        if holdsJoin {
            await withTaskCancellationHandler {
                await withCheckedContinuation { joinWaiter = $0 }
            } onCancel: {
                Task { @MainActor in
                    if !self.holdsJoinThroughCancellation { self.completeJoin() }
                }
            }
        }
        do {
            guard generation == mine else { throw TornDown() }
            try Task.checkCancellation()
        } catch {
            await cleanUp()
            throw error
        }
        phase = .connected
        events?.roomDidConnect(hasRemote: remotes > 0)
    }

    func disconnect() async {
        guard phase != .disconnected, phase != .disconnecting else { return }
        phase = .disconnecting
        log.append("leave")
        await cleanUp()
    }

    func publish(_ data: Data) async throws {
        if let publishError { throw publishError }
        guard phase == .connected else { throw NotConnected() }
        let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let type = (message?["data"] as? [String: Any])?["t"] as? String ?? "?"
        log.append("publish \(type)")
    }

    func setMicrophone(enabled: Bool) async throws {
        log.append("mic \(enabled ? "on" : "off")")
    }

    func releaseSetUp() {
        setUpWaiter?.resume()
        setUpWaiter = nil
    }

    func completeJoin() {
        joinWaiter?.resume()
        joinWaiter = nil
    }

    /// The agent joins the room.
    func agentJoins() {
        remotes += 1
        if phase == .connected { events?.remoteDidJoin() }
    }

    /// The agent leaves the room.
    func agentLeaves() {
        guard remotes > 0 else { return }
        remotes -= 1
        events?.remoteDidLeave(remotesRemain: remotes > 0)
    }

    /// LiveKit runs a full reconnect: the room goes `.reconnecting`, its cleanup reports
    /// each remote leaving while they are still listed, then the rejoin brings back
    /// the agent if it is still in the room, and the reconnect completes connected.
    func fullReconnect(agentStillThere: Bool) {
        phase = .reconnecting
        events?.reconnectDidStart()
        if remotes > 0 { events?.remoteDidLeave(remotesRemain: true) }
        remotes = agentStillThere ? 1 : 0
        phase = .connected
        events?.reconnectDidComplete(roomConnected: true, remotesPresent: remotes > 0)
    }

    /// The connection is lost and LiveKit gives up on it.
    func drop() {
        phase = .disconnected
        remotes = 0
        events?.roomDidDisconnect()
    }

    private func cleanUp() async {
        await Task.yield()
        generation += 1
        let wasUp = phase != .disconnected
        if remotes > 0 {
            remotes = 0
            events?.remoteDidLeave(remotesRemain: false)
        }
        phase = .disconnected
        if wasUp { events?.roomDidDisconnect() }
        if let joinWaiter {
            self.joinWaiter = nil
            joinWaiter.resume()
        }
    }
}

@MainActor
final class FakeLiveKitAudioEngine: LiveKitAudioEngineControlling {
    private(set) var isAvailable = false
    /// Every availability the transport set, in order.
    private(set) var availabilityHistory: [Bool] = []
    /// While positive, making the engine available fails, as LiveKit's did after a
    /// phone call (`Audio engine returned error code: -4010`), and counts down.
    var startsToFail = 0
    private(set) var isRunning = false

    struct StartRefused: Error {}

    func setAvailable(_ available: Bool) throws {
        availabilityHistory.append(available)
        if available, startsToFail > 0 {
            startsToFail -= 1
            isRunning = false
            throw StartRefused()
        }
        isAvailable = available
        isRunning = available
    }

    var stateDescription: String { "fake engine available \(isAvailable) running \(isRunning)" }
}
