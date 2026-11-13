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
    // The floors are the versions this release was built, tested and run on a device with,
    // the set Package.resolved pins.
    dependencies: [
        // 1.3.0: PipecatDailyTransport releases its client after each call, which frees Daily's
        // call client only from pipecat-client-ios-daily 1.3.0 (`release()`).
        .package(url: "https://github.com/pipecat-ai/pipecat-client-ios.git", from: "1.3.0"),
        .package(url: "https://github.com/pipecat-ai/pipecat-client-ios-daily.git", from: "1.3.0"),
        // ConduitCallEngineDaily calls Daily's API itself (subscriptions, app messages, the
        // preferred audio device), and Daily makes breaking changes in minor releases, so a new
        // Daily minor version is taken only after it has been tried here.
        .package(url: "https://github.com/daily-co/daily-client-ios.git", .upToNextMinor(from: "0.41.0")),
        // From 2.18.0 a reconnect LiveKit gives up on always ends with the room disconnected
        // (client-sdk-swift PR #1144), which LiveKitTransport relies on; 2.19.0 is the version
        // this release was verified with.
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.19.0"),
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
        // A host built in the Swift 6 language mode, with its complete concurrency
        // checking: uses the public surface of every product, with a host-written
        // transport and delegate, and must build without warnings or workarounds.
        .testTarget(
            name: "ConduitCallEngineSwift6Tests",
            dependencies: [
                "ConduitCallEngine",
                "ConduitCallEngineDaily",
                "ConduitCallEngineLiveKit",
                "ConduitCallEngineTesting",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
