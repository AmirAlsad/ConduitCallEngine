//
//  DailyAudioRouteGateTests.swift
//  ConduitCallEngineDailyTests
//
//  Which route a Daily call asks Daily to prefer, and when: the route CallKit
//  activated the call on, from the first attach; the engine's request over it; never
//  before the first attach of a join made while ringing; a Bluetooth or wired device
//  followed when it comes and left when it goes; and changes applied one at a time,
//  per session, against what Daily reports after the join.
//

import AVFoundation
import Testing
@testable import ConduitCallEngineDaily

struct DailyAudioRouteGateTests {
    // MARK: - Routes

    @Test(arguments: [
        (AVAudioSession.Port.builtInReceiver, DailyAudioRoute.earpiece),
        (.builtInSpeaker, .speaker),
        (.bluetoothHFP, .bluetooth),
        (.bluetoothA2DP, .bluetooth),
        (.bluetoothLE, .bluetooth),
        (.headphones, .wired),
        (.headsetMic, .wired),
    ])
    func anOutputPortNamesItsRoute(port: AVAudioSession.Port, route: DailyAudioRoute) {
        #expect(DailyAudioRoute(outputPort: port) == route)
    }

    /// Car audio is not Daily's `bluetooth`: Daily would not find it and would fall
    /// back to its default, and following it as Bluetooth could move a car call to
    /// the earpiece. These stay Daily's choice, as before.
    @Test(arguments: [AVAudioSession.Port.carAudio, .usbAudio, .airPlay, .HDMI, .lineOut])
    func aPortDailyCannotNameIsLeftToDaily(port: AVAudioSession.Port) {
        #expect(DailyAudioRoute(outputPort: port) == nil)
    }

    @Test(arguments: [
        ("earpiece", DailyAudioRoute.earpiece),
        ("speakerphone", .speaker),
        ("bluetooth", .bluetooth),
        ("wired", .wired),
    ])
    func aDailyDeviceIDNamesItsRoute(id: String, route: DailyAudioRoute) {
        #expect(DailyAudioRoute(deviceID: id) == route)
    }

    @Test func anUnknownDeviceIDNamesNoRoute() {
        #expect(DailyAudioRoute(deviceID: "airplay") == nil)
    }

    // MARK: - What is wanted

    @Test func nothingIsWantedBeforeTheFirstAttach() {
        var gate = DailyAudioRouteGate()
        gate.devicesDidChange([.earpiece, .speaker])
        gate.sessionDidReset()

        #expect(gate.wanted == nil)
        let next = gate.beginApplying()
        #expect(next == nil)
    }

    @Test func theFirstAttachKeepsTheRouteTheCallIsOn() {
        var gate = DailyAudioRouteGate()

        let first = gate.attach(activeRoute: .earpiece, devices: [.earpiece, .speaker])

        #expect(first)
        #expect(gate.wanted == .earpiece)
        #expect(gate.wantedReason == "the call's route")
    }

    /// A resume's attach does not re-read the route: the call stays where it began.
    @Test func aLaterAttachKeepsTheFirstRoute() {
        var gate = DailyAudioRouteGate()
        gate.attach(activeRoute: .earpiece, devices: [])

        let first = gate.attach(activeRoute: .speaker, devices: [])

        #expect(!first)
        #expect(gate.wanted == .earpiece)
    }

    @Test func aRouteDailyCannotNameLeavesTheCallToDaily() {
        var gate = DailyAudioRouteGate()
        gate.attach(activeRoute: nil, devices: [.earpiece, .speaker])

        #expect(gate.wanted == nil)
    }

    @Test func theEngineRequestWinsOverTheCallsRoute() {
        var gate = DailyAudioRouteGate()
        gate.attach(activeRoute: .earpiece, devices: [])

        gate.engineDidRequest(.speaker)

        #expect(gate.wanted == .speaker)
        #expect(gate.wantedReason == "engine request")
    }

    @Test func anEngineRequestBeforeTheFirstAttachIsWantedAtOnce() {
        var gate = DailyAudioRouteGate()

        gate.engineDidRequest(.speaker)

        #expect(gate.wanted == .speaker)
    }

    @Test func aJoinWhileRingingWantsNothingUntilTheFirstAttach() {
        var gate = DailyAudioRouteGate()
        gate.holdUntilFirstAttach()
        gate.engineDidRequest(.speaker)
        #expect(gate.wanted == nil)

        gate.attach(activeRoute: .earpiece, devices: [])

        #expect(gate.wanted == .speaker)
    }

    @Test func holdingAfterTheFirstAttachChangesNothing() {
        var gate = DailyAudioRouteGate()
        gate.attach(activeRoute: .earpiece, devices: [])

        gate.holdUntilFirstAttach()

        #expect(gate.wanted == .earpiece)
    }

    // MARK: - Devices coming and going

    private func followingEarpiece(devices: Set<DailyAudioRoute> = [.earpiece, .speaker]) -> DailyAudioRouteGate {
        var gate = DailyAudioRouteGate()
        gate.attach(activeRoute: .earpiece, devices: devices)
        return gate
    }

    @Test(arguments: [DailyAudioRoute.bluetooth, .wired])
    func aHeadsetConnectedMidCallIsFollowed(headset: DailyAudioRoute) {
        var gate = followingEarpiece()

        gate.devicesDidChange([.earpiece, .speaker, headset])

        #expect(gate.wanted == headset)
    }

    @Test func theFollowedHeadsetLeavingReturnsTheCallToTheEarpiece() {
        var gate = followingEarpiece()
        gate.devicesDidChange([.earpiece, .speaker, .bluetooth])

        gate.devicesDidChange([.earpiece, .speaker])

        #expect(gate.wanted == .earpiece)
    }

    @Test func theFollowedHeadsetLeavingFollowsAnotherStillThere() {
        var gate = followingEarpiece(devices: [.earpiece, .speaker, .wired])
        gate.devicesDidChange([.earpiece, .speaker, .wired, .bluetooth])

        gate.devicesDidChange([.earpiece, .speaker, .wired])

        #expect(gate.wanted == .wired)
    }

    @Test func aCallStartedOnAHeadsetFallsBackToTheEarpieceWhenItLeaves() {
        var gate = DailyAudioRouteGate()
        gate.attach(activeRoute: .bluetooth, devices: [.earpiece, .speaker, .bluetooth])

        gate.devicesDidChange([.earpiece, .speaker])

        #expect(gate.wanted == .earpiece)
    }

    /// A device list that only arrives after the attach is the baseline: a headset
    /// already connected then is not a new one.
    @Test func theFirstDeviceListIsOnlyABaseline() {
        var gate = DailyAudioRouteGate()
        gate.attach(activeRoute: .speaker, devices: [])

        gate.devicesDidChange([.earpiece, .speaker, .bluetooth])

        #expect(gate.wanted == .speaker)
        #expect(gate.knownDevices == [.earpiece, .speaker, .bluetooth])
    }

    @Test func aDeviceThatIsNotTheFollowedOneLeavingChangesNothing() {
        var gate = followingEarpiece(devices: [.earpiece, .speaker, .wired])

        gate.devicesDidChange([.earpiece, .speaker])

        #expect(gate.wanted == .earpiece)
    }

    @Test func anEmptyDeviceListIsIgnored() {
        var gate = followingEarpiece()

        gate.devicesDidChange([])

        #expect(gate.knownDevices == [.earpiece, .speaker])
        #expect(gate.wanted == .earpiece)
    }

    /// The user's pick, or the speaker default, stays put; Daily falls back by
    /// itself when that device goes, and returns to it when it comes back.
    @Test func devicesDoNotMoveAnEngineRequest() {
        var gate = followingEarpiece()
        gate.engineDidRequest(.speaker)

        gate.devicesDidChange([.earpiece, .speaker, .bluetooth])

        #expect(gate.wanted == .speaker)
    }

    @Test func devicesMoveNothingForACallLeftToDaily() {
        var gate = DailyAudioRouteGate()
        gate.attach(activeRoute: nil, devices: [.earpiece, .speaker])

        gate.devicesDidChange([.earpiece, .speaker, .bluetooth])

        #expect(gate.wanted == nil)
    }

    // MARK: - Applying

    @Test func theWantedRouteIsAppliedOnce() throws {
        var gate = followingEarpiece()

        let begun = gate.beginApplying()
        let application = try #require(begun)
        #expect(application.route == .earpiece)
        let whileInFlight = gate.beginApplying()
        #expect(whileInFlight == nil)
        gate.applyDidSucceed(application)

        let afterwards = gate.beginApplying()
        #expect(afterwards == nil)
        #expect(gate.applied == .earpiece)
    }

    @Test func aChangeWhileApplyingIsAppliedNext() throws {
        var gate = followingEarpiece()
        let begun = gate.beginApplying()
        let first = try #require(begun)

        gate.engineDidRequest(.speaker)
        gate.applyDidSucceed(first)

        let next = gate.beginApplying()
        #expect(next?.route == .speaker)
    }

    @Test func aNewSessionIsGivenTheRouteAgain() throws {
        var gate = followingEarpiece()
        let application = gate.beginApplying()
        gate.applyDidSucceed(try #require(application))

        gate.sessionDidReset()

        let next = gate.beginApplying()
        #expect(next?.route == .earpiece)
    }

    @Test func anApplicationForAnOldSessionIsIgnored() throws {
        var gate = followingEarpiece()
        let begun = gate.beginApplying()
        let stale = try #require(begun)
        gate.sessionDidReset()

        gate.applyDidSucceed(stale)

        #expect(gate.applied == nil)
        let next = gate.beginApplying()
        #expect(next?.session == stale.session + 1)
    }

    @Test func aRefusedRouteWaitsForTheJoin() throws {
        var gate = followingEarpiece()
        let application = gate.beginApplying()
        gate.applyDidFail(try #require(application))
        let beforeTheJoin = gate.beginApplying()
        #expect(beforeTheJoin == nil)

        gate.joinDidComplete(reported: nil)

        let next = gate.beginApplying()
        #expect(next?.route == .earpiece)
    }

    /// After the join, what Daily reports is what it has: a preference it dropped
    /// at the join is asked for again, one it kept is not.
    @Test func aPreferenceDailyDroppedAtTheJoinIsAskedForAgain() throws {
        var gate = followingEarpiece()
        let application = gate.beginApplying()
        gate.applyDidSucceed(try #require(application))

        gate.joinDidComplete(reported: nil)

        let next = gate.beginApplying()
        #expect(next?.route == .earpiece)
    }

    @Test func aPreferenceDailyKeptAtTheJoinIsNotAskedForAgain() throws {
        var gate = followingEarpiece()
        let application = gate.beginApplying()
        gate.applyDidSucceed(try #require(application))

        gate.joinDidComplete(reported: .earpiece)

        let next = gate.beginApplying()
        #expect(next == nil)
    }
}
