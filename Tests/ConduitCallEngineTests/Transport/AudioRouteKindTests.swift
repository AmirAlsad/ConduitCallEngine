//
//  AudioRouteKindTests.swift
//  ConduitCallEngineTests
//
//  The device-id → route-kind mapping. Mapping by id, not name, is the whole point:
//  Daily's Bluetooth device NAME contains "Speaker".
//

import Testing
import ConduitCallEngine

struct AudioRouteKindTests {
    @Test(arguments: [
        ("speakerphone", AudioRouteKind.speaker),
        ("bluetooth", AudioRouteKind.bluetooth),
        ("earpiece", AudioRouteKind.receiver),
        ("wired", AudioRouteKind.wired),
        ("usb-something", AudioRouteKind.other),
    ])
    func deviceIDMapsToKind(id: String, expected: AudioRouteKind) {
        #expect(AudioRouteKind(deviceID: id) == expected)
    }

    @Test func bluetoothIdMapsToBluetoothNotSpeaker() {
        // Daily's bluetooth device is named "Bluetooth Speaker & Mic" — mapping by
        // name would mislabel it "Speaker". The id "bluetooth" must win.
        #expect(AudioRouteKind(deviceID: "bluetooth") == .bluetooth)
    }
}
