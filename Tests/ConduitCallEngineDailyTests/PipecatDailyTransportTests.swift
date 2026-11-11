//
//  PipecatDailyTransportTests.swift
//  ConduitCallEngineDailyTests
//
//  Links the Daily adapter. Its behavior needs Daily's WebRTC audio unit, which
//  aborts in the simulator, so it is verified on device.
//

import Testing
import ConduitCallEngine
import ConduitCallEngineDaily

@MainActor
struct PipecatDailyTransportTests {
    @Test func adapterIsACallTransport() {
        let type: any CallTransport.Type = PipecatDailyTransport.self
        #expect(type == PipecatDailyTransport.self)
    }
}
