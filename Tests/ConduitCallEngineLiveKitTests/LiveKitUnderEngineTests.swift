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

    // MARK: - The agent hears that the user is on the line

    @Test(.timeLimit(.minutes(1)))
    func anOutgoingCallPublishesCallConnectedOnceTheUserCanTalk() async throws {
        let rig = LiveKitEngineRig()
        await rig.engine.placeCall(rig.target)
        await waitUntil { rig.engine.state.isConnected }
        await rig.system.awaitPendingWork()
        let room = try #require(rig.room)
        #expect(room.published.isEmpty) // CallKit has not activated the audio

        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()

        #expect(room.published == ["call-connected"])
    }

    // MARK: - The mic opens once the call is connected

    /// CallKit activates while the room is still joining: the mic is not published
    /// until the agent is there.
    @Test(.timeLimit(.minutes(1)))
    func theMicOpensWhenTheAgentIsThereNotAtTheActivation() async throws {
        let rig = LiveKitEngineRig()
        rig.prepareRoom = { $0.holdsJoin = true }
        let placing = Task { await rig.engine.placeCall(rig.target) }
        await waitUntil { rig.room?.isHoldingJoin == true }
        let room = try #require(rig.room)
        await rig.system.activateAudioSession()
        await rig.system.awaitPendingWork()
        #expect(!room.log.contains("mic on"))

        room.completeJoin()
        await placing.value
        await waitUntil { rig.engine.state.isConnected }
        await rig.system.awaitPendingWork()

        #expect(room.log.last(where: { $0.hasPrefix("mic ") }) == "mic on")
        #expect(room.published == ["call-connected"])
    }

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

    // MARK: - An agent that leaves a ring before the device saw it ready

    /// The push contract: an agent that leaves before the device saw it there does
    /// not end the ring; the preparation is dropped and an answer connects afresh.
    @Test(.timeLimit(.minutes(1)))
    func anAgentLeavingARingBeforeTheRoomConnectedDropsThePreparation() async throws {
        let rig = LiveKitEngineRig()
        rig.ringPreparation = .media
        rig.refreshTarget()
        rig.prepareRoom = { $0.holdsJoin = true }
        let id = rig.ring()
        await waitUntil { rig.room?.isHoldingJoin == true }
        let room = try #require(rig.room)
        #expect(room.hasRemoteParticipants) // arrived with the join response

        room.agentLeaves()
        await waitUntil { rig.engine.ringPreparationPhase == .failed }

        #expect(rig.engine.ringPreparationPhase == .failed)
        #expect(rig.engine.state == .incomingRinging)
        #expect(rig.host.records.isEmpty)

        rig.prepareRoom = { _ in }
        await rig.system.answerIncomingCall()
        #expect(rig.requests.map(\.purpose) == [.ringing(joinsBeforeAnswer: true), .answered])
        #expect(rig.requests.last?.callID == id)
        #expect(rig.rooms.count == 2)
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

    // MARK: - A full reconnect

    /// LiveKit's full reconnect reports the agent leaving as part of its cleanup, but
    /// with the agent still listed (client-sdk-swift 2.19.0, `Room.cleanUpParticipants`),
    /// so it is not the agent's hangup: the call recovers.
    @Test(.timeLimit(.minutes(1)))
    func aFullReconnectWithTheAgentStillThereKeepsTheCall() async throws {
        let rig = LiveKitEngineRig()
        await rig.engine.placeCall(rig.target)
        let room = try #require(rig.room)
        await waitUntil { rig.engine.state.isConnected }
        #expect(rig.engine.state.isConnected)

        room.fullReconnect(agentStillThere: true)
        await waitUntil { rig.host.transitions.count >= 5 }

        #expect(rig.engine.state.isConnected)
        let lastTwo = Array(rig.host.transitions.suffix(2))
        #expect(lastTwo.first == .reconnecting(attempt: 0))
        #expect(lastTwo.last?.isConnected == true)
        #expect(rig.host.records.isEmpty)
    }

    /// The agent left while the device was offline: the rejoin finds nobody, and the
    /// call ends as the agent's hangup (#21).
    @Test(.timeLimit(.minutes(1)))
    func aFullReconnectIntoAnEmptyRoomEndsTheCall() async throws {
        let rig = LiveKitEngineRig()
        await rig.engine.placeCall(rig.target)
        let room = try #require(rig.room)
        await waitUntil { rig.engine.state.isConnected }

        room.fullReconnect(agentStillThere: false)
        await waitUntil { rig.engine.state.isTerminal }

        #expect(rig.engine.state == .ended(.completed))
    }
}
