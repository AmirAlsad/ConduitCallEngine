// swift-tools-version: 6.1
// 6.1 is required by LiveKit's manifest. Sources still compile in Swift 5 mode.

import PackageDescription

let package = Package(
    name: "ConduitCallEngine",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "ConduitCallEngine", targets: ["ConduitCallEngine"]),
        .library(name: "ConduitCallEngineDaily", targets: ["ConduitCallEngineDaily"]),
        .library(name: "ConduitCallEngineLiveKit", targets: ["ConduitCallEngineLiveKit"]),
        .library(name: "ConduitCallEngineTesting", targets: ["ConduitCallEngineTesting"]),
    ],
    // WARNING: never add any `small-webrtc` package or `stasel/WebRTC` here. An un-prefixed
    // WebRTC linked next to Daily's embedded one duplicates the `RTC*` symbols and crashes Daily calls.
    dependencies: [
        .package(url: "https://github.com/pipecat-ai/pipecat-client-ios.git", from: "1.2.0"),
        .package(url: "https://github.com/pipecat-ai/pipecat-client-ios-daily.git", from: "1.2.0"),
        // ConduitCallEngineDaily imports Daily itself (subscriptions, app messages). The floor is
        // the one pipecat-client-ios-daily already sets, so declaring it changes no resolution.
        .package(url: "https://github.com/daily-co/daily-client-ios.git", from: "0.38.0"),
        // Floor at 2.18.0: from that version a reconnect LiveKit gives up on always ends with the
        // room disconnected (client-sdk-swift PR #1144), which LiveKitTransport relies on. It also
        // pulls LiveKitWebRTC 144.7559.10 or later (App Review binary-scan hygiene).
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.18.0"),
    ],
    targets: [
        // Core must never import a transport SDK.
        .target(
            name: "ConduitCallEngine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ConduitCallEngineDaily",
            dependencies: [
                "ConduitCallEngine",
                .product(name: "PipecatClientIOS", package: "pipecat-client-ios"),
                .product(name: "PipecatClientIOSDaily", package: "pipecat-client-ios-daily"),
                .product(name: "Daily", package: "daily-client-ios"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ConduitCallEngineLiveKit",
            dependencies: [
                "ConduitCallEngine",
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Linked by apps for simulator fallbacks: must not import Testing or XCTest.
        .target(
            name: "ConduitCallEngineTesting",
            dependencies: ["ConduitCallEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ConduitCallEngineTests",
            dependencies: ["ConduitCallEngine", "ConduitCallEngineTesting"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The adapter test targets also run the real adapters under a simulated engine.
        .testTarget(
            name: "ConduitCallEngineDailyTests",
            dependencies: ["ConduitCallEngineDaily", "ConduitCallEngineTesting"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ConduitCallEngineLiveKitTests",
            dependencies: ["ConduitCallEngineLiveKit", "ConduitCallEngineTesting"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
