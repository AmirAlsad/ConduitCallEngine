//
//  LiveKitUnderEngineTests.swift
//  ConduitCallEngineLiveKitTests
//
//  The real LiveKit adapter under the real engine (`LiveKitEngineRig`), in the
//  situations where the engine's calls meet the way LiveKit's `Room` sequences
//  its work.
//

import Foundation
import Testing
import ConduitCallEngine
import ConduitCallEngineTesting
@testable import ConduitCallEngineLiveKit

@MainActor
struct LiveKitUnderEngineTests {

    // MARK: - A disconnect while the room is still setting up

    /// The user declines a pre-connected ring just as the transport starts joining:
    /// LiveKit's `Room` is still `.disconnected` while `connect` sets it up, so its
    /// `disconnect` does nothing. The join must not complete into a room nobody leaves.
    @Test(.timeLimit(.minutes(1)))
    func aRingDeclinedWhileTheRoomSetsUpLeavesTheRoom() async throws {
        let rig = LiveKitEngineRig()
        rig.ringPreparation = .media
        rig.refreshTarget()
        rig.prepareRoom = { $0.holdsSetUp = true }
        let id = rig.ring()
        await waitUntil { rig.room?.isHoldingSetUp == true }
        let room = try #require(rig.room)

        rig.system.endCallFromSystem(id)
        await drain()
        room.releaseSetUp()
        await waitUntil { room.leaveCount == 1 && room.phase == .disconnected }

        #expect(room.leaveCount == 1)
        #expect(room.published == ["end-call"]) // the agent saw the device join
        #expect(room.phase == .disconnected)
        #expect(rig.engine.state == .ended(.declined))
    }

    @Test(.timeLimit(.minutes(1)))
    func anOutgoingCallEndedWhileTheRoomSetsUpLeavesTheRoom() async throws {
        let rig = LiveKitEngineRig()
        rig.prepareRoom = { $0.holdsSetUp = true }
        let placing = Task { await rig.engine.placeCall(rig.target) }
        await waitUntil { rig.room?.isHoldingSetUp == true }
        let room = try #require(rig.room)

        await rig.engine.endCall()
        await drain()
        room.releaseSetUp()
        await placing.value
        await waitUntil { room.leaveCount == 1 && room.phase == .disconnected }

        #expect(room.leaveCount == 1)
        #expect(room.phase == .disconnected)
        #expect(rig.engine.state == .ended(.canceled))
    }

    // MARK: - A hold and resume during a reconnect attempt's join

    /// A connected call whose room dropped: the engine's first attempt is joining a
    /// room that stays `.connecting`.
    private func attemptJoining(_ rig: LiveKitEngineRig) async throws -> (FakeLiveKitRoom, UUID) {
        await rig.engine.placeCall(rig.target)
        await rig.system.activateAudioSession()
        await waitUntil { rig.engine.state.isConnected }
        rig.sleeper.wakeAll() // the first connect's bound, stale once connected
        let room = try #require(rig.room)
        let id = try #require(rig.system.startedCallIDs.first)

        room.holdsJoin = true
        room.drop()
        await waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.wakeAll() // attempt 1's backoff
        await waitUntil { room.isHoldingJoin }
        #expect(rig.engine.state == .reconnecting(attempt: 1))
        return (room, id)
    }

    /// The hold leaves attempt 1's join running; the resume starts attempt 1 again at
    /// once on the same transport. Two `Room.connect`s on one room tear each other
    /// down; the newer connect must supersede the older one instead.
    @Test(.timeLimit(.minutes(1)))
    func aQuickHoldAndResumeDuringAJoinEndsInOneJoin() async throws {
        let rig = LiveKitEngineRig()
        let (room, id) = try await attemptJoining(rig)

        await rig.system.setHeldFromSystem(id, onHold: true)
        await rig.system.setHeldFromSystem(id, onHold: false)
        await waitUntil { room.log.filter { $0.hasPrefix("connect") }.count == 3 && room.isHoldingJoin }
        room.completeJoin()
        await waitUntil { rig.engine.state.isConnected }

        #expect(rig.engine.state.isConnected)
        #expect(room.phase == .connected)
        #expect(rig.requests.map(\.purpose) == [.outgoing, .reconnect(attempt: 1), .reconnect(attempt: 1)])
        #expect(room.log.filter { $0.hasPrefix("connect") } == [
            "connect wss://example.livekit.cloud/room-1",
            "connect wss://example.livekit.cloud/room-2",
            "connect wss://example.livekit.cloud/room-3",
        ])
        #expect(!rig.sleeper.requested.contains(.seconds(2))) // no second attempt was scheduled
    }
}
