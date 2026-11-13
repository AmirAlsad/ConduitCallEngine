# ConduitCallEngine

An iOS library that turns a voice agent into a phone call. It presents the call through CallKit (system call UI, lock screen, Bluetooth and CarPlay routing), receives agent-initiated calls through PushKit VoIP pushes, runs the call state machine, owns the audio-session policy during a call, reconnects after network drops, and carries audio over WebRTC through pluggable transports. Over the same connection it carries your app's own messages to the agent, and hands your app the agent's messages, its output text for captions and the user's transcript.

Your app describes each call with a small `CallTarget` value: an id, a display name, an optional CallKit handle, a factory for the transport, and an async `connect` closure that returns a room URL and token however your app obtains them, told by a `ConnectRequest` whether it is for a new call or a reconnect, and which call (its CallKit id, on every request). The engine reports call state and finished calls back to you. It knows about calls, not about agents, accounts, persistence or UI. An app with one built-in agent and an app with many are the same to the engine: the first one just has one target.

What it does not include:

- **No UI.** The system call screen comes from CallKit. Any in-app call screen is yours, driven by the engine's observable state.
- **No persistence.** The engine hands you a `CallRecord` when a call finishes; storing history is up to you.
- **No backend.** The engine never talks to a server of its own. Your `connect` closure fetches credentials, your server sends the VoIP pushes, and the only request the engine makes itself is an optional ring-status receipt to a URL your push supplies.

## Products

| Product | Link it when | Brings in |
|---|---|---|
| `ConduitCallEngine` | Always. The engine, CallKit and PushKit handling, models, and the `CallTransport` protocol. | No WebRTC SDK. |
| `ConduitCallEngineDaily` | Your agent runs on Daily (for example a Pipecat bot in a Daily room). Provides `PipecatDailyTransport`. | Pipecat iOS client and Daily (`Daily.xcframework`, which embeds its own WebRTC). |
| `ConduitCallEngineLiveKit` | Your agent runs in a LiveKit room. Provides `LiveKitTransport`. | LiveKit Swift SDK (`LiveKitWebRTC`, a prefixed WebRTC build). |
| `ConduitCallEngineTesting` | You want to run the app in the iOS Simulator or unit-test your call handling. Provides `FakeTransport`, `SimulatedCallSystem` and `CallEngine.simulated(...)`. | Nothing beyond the core. Does not import XCTest or Swift Testing, so it can be linked into an app target. |

Link the core plus the adapter for the transport you use. Linking both adapters is supported. You can also write your own transport against `CallTransport` and link no adapter at all.

**Which adapter?** Both gave working calls on a device as of 0.2.0. LiveKit's SDK is built to be driven by CallKit; Daily's manages audio itself, and the adapter works around that with behaviour confirmed in a small number of runs. If you can choose, LiveKit is the lower-risk choice; if you are on Daily, it works, with a few remaining differences. The comparison, with the versions and device it was made on, is in [Choosing a transport](Docs/IntegrationGuide.md#choosing-a-transport).

## Requirements

- iOS 18 or later.
- Xcode 26 or later. The sources use names from the iOS 26 SDK, so they do not compile with Xcode 16. The package manifest uses swift-tools-version 6.1 because the LiveKit SDK's manifest requires it, and the sources compile in the Swift 5 language mode. Your app can use either mode: in the Swift 6 language mode, with complete concurrency checking, every public API (including `CallTransport` and `CallEngineDelegate` conformances and the Testing product) compiles without warnings, `@preconcurrency` or `nonisolated(unsafe)`. `CallTarget` and `CallEngineConfiguration` are `Sendable`, so a host can keep them in a `static let`.
- A physical iPhone for real calls (see [Device-only reality](#device-only-reality)).
- For incoming calls: a paid Apple Developer account, the Push Notifications capability, and an APNs key on your server.

The manifest's dependency floors are the versions this release was verified with: `pipecat-client-ios` 1.3.0, `pipecat-client-ios-daily` 1.3.0, LiveKit `client-sdk-swift` 2.19.0, and `daily-client-ios` 0.41.x (up to the next minor version only, because the Daily adapter calls Daily's API directly and Daily makes breaking changes in minor releases). SwiftPM may resolve Pipecat and LiveKit above them; see [Verified SDK versions](#verified-sdk-versions) for how to stay on the verified set. The LiveKit floor is also a requirement: LiveKit before 2.18.0 can report a reconnect it gave up on as complete, which the adapter no longer handles (see [the LiveKit notes](Docs/IntegrationGuide.md#livekit-livekittransport)).

## Installation

Add the package by URL in Xcode (File > Add Package Dependencies) or in a manifest:

```swift
.package(url: "https://github.com/AmirAlsad/ConduitCallEngine.git", .upToNextMinor(from: "0.2.0"))
```

In Xcode, choose the dependency rule "Up to Next Minor Version". While the package is 0.x, a minor release (0.3) may break source compatibility or change defaults, and `from: "0.2.0"` would accept it; up to the next minor version takes only 0.2.x fixes.

Then add `ConduitCallEngine` and one adapter product to your app target, and `ConduitCallEngineTesting` if you want simulator support.

**What SwiftPM downloads.** SwiftPM resolves every dependency the package declares, whichever products you link. A LiveKit-only app still downloads the Daily and Pipecat packages, and a Daily-only app still downloads LiveKit. Nothing from a product you do not link is compiled, linked or embedded in your app.

**Do not add a second WebRTC.** Daily embeds its own un-prefixed WebRTC. If your app links the Daily product and any other package that ships an un-prefixed WebRTC (for example one built on `stasel/WebRTC`), the duplicated Objective-C classes crash Daily calls at runtime, while the app builds and launches normally. LiveKit's WebRTC is prefixed and coexists with Daily. See [the WebRTC duplication rule](Docs/IntegrationGuide.md#the-webrtc-duplication-rule) for how to check.

## Quick start

A complete host for one fixed agent on LiveKit. For Daily, import `ConduitCallEngineDaily` and return `PipecatDailyTransport()` instead. Before this runs on a device you need the project setup in [Integration Guide, section 3](Docs/IntegrationGuide.md#3-project-setup).

```swift
import ConduitCallEngine
import ConduitCallEngineLiveKit
import SwiftUI
import UIKit

@MainActor
enum Assistant {
    /// Stable for the life of the install. Your server sends it in the VoIP push as `target_id`.
    static let id = UUID(uuidString: "6F1E0A52-3B7C-4D8E-9A41-2C5D7E9B0A13")!

    static func target(inline: CallConnection? = nil) -> CallTarget {
        CallTarget(
            id: id,
            displayName: "Assistant",
            makeTransport: { LiveKitTransport() },
            // Runs for the first connect and again before every reconnect attempt;
            // its `ConnectRequest` argument says which.
            connect: { _ in
                if let inline { return inline }
                return try await Assistant.fetchConnection()
            }
        )
    }

    /// Ask your own backend for a room URL and token. The request is yours to define.
    static func fetchConnection() async throws -> CallConnection {
        var request = URLRequest(url: URL(string: "https://agent.example.com/connect")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Tells your agent this app sends `call-connected`, so it greets on it (see below).
        request.httpBody = try JSONEncoder().encode(["call_signals": [CallSignal.connected.rawValue]])
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: break
        case 401, 403: throw TransportError.authenticationFailed // the call fails as .badToken
        case let status: throw TransportError.connectionFailed("HTTP \(status)")
        }
        let body = try JSONDecoder().decode(Credentials.self, from: data)
        return CallConnection(url: body.url, token: body.token)
    }

    private struct Credentials: Decodable {
        let url: URL
        let token: String
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, CallEngineDelegate {
    // `CallEngine.delegate` is weak; the app delegate lives for the whole process.
    private(set) lazy var engine: CallEngine = {
        let engine = CallEngine()
        engine.delegate = self
        return engine
    }()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Here, not when a screen appears: a VoIP push can launch the app in the background.
        engine.startPushRegistration()
        return true
    }

    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? {
        call.targetID == Assistant.id ? Assistant.target(inline: call.connection) : nil
    }

    func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState) {
        print("call state: \(old) -> \(new)")
    }

    func callEngine(_ engine: CallEngine, didFinish record: CallRecord) {
        print("call finished: \(record.outcome), \(record.duration) s")
    }

    func callEngine(_ engine: CallEngine, didUpdateVoIPPushToken token: Data) {
        // Send the token to the server that will ring this device (Integration Guide, section 7).
    }
}

@main
struct AssistantApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup { CallScreen(engine: appDelegate.engine) }
    }
}

struct CallScreen: View {
    let engine: CallEngine

    var body: some View {
        VStack(spacing: 16) {
            Text(String(describing: engine.state))
            if engine.state.isActive && !engine.state.isTerminal {
                Button("End") { Task { await engine.endCall() } }
            } else {
                Button("Call") { Task { await engine.placeCall(Assistant.target()) } }
            }
        }
    }
}
```

`CallEngine` is `@Observable`, so a SwiftUI view that reads `engine.state` updates on its own. Incoming calls need no UI code: CallKit rings on the lock screen, and when the user answers, the engine connects through the target your delegate returned.

## What you still have to provide

- **Credentials.** The `connect` closure: a room URL and token for each call, from your backend or anywhere else. Throw `TransportError.authenticationFailed` for rejected credentials so the call fails as `.badToken` rather than a generic transport error.
- **An agent that joins the room.** The engine reports a call as connected only once the agent is present and ready. See [Integration Guide, section 13](Docs/IntegrationGuide.md#13-what-the-server-side-must-do).
- **`call_signals` in every credential request and in the token registration.** The engine tells the agent the user is on the line with a `call-connected` message; your app lists it as `"call_signals": ["call-connected"]` (the quick start's `fetchConnection` does), so the agent knows to greet on it rather than when the device joins. See [When your agent should start speaking](Docs/IntegrationGuide.md#when-your-agent-should-start-speaking).
- **VoIP token delivery.** The engine hands you the PushKit token; getting it to your server is your code, with the bundle id, the APNs environment, the target ids, `supportedPushFeatures.sorted()` and `call_signals` ([Integration Guide, section 7](Docs/IntegrationGuide.md#7-delivering-the-voip-token-to-your-server)). An app that only places calls needs none of this, nor the `voip` background mode.
- **The server that rings the app.** It sends APNs VoIP pushes in the shape described in [Docs/PushContract.md](Docs/PushContract.md), optionally bounds a ring with `ring_timeout`, withdraws it with a cancel push, or asks the device to connect while it rings with `preconnect`, and learns which of those a device understands from `CallEngine.supportedPushFeatures`, which your app sends it with the token. An unanswered ring ends by itself after 60 seconds unless you configure another `ringTimeout`.
- **A decision on pre-connect, if you take incoming calls.** A ring is prepared while it rings (credentials fetched, or the room joined with audio held until the answer) only when the push asks for it and your target's `ringPreparation` allows it, so the agent is ready when the user answers. The default, `.none`, keeps every ring as it was. See [Integration Guide, section 11](Docs/IntegrationGuide.md#pre-connect).
- **What your app and your agent say to each other, if anything.** `CallEngine.send(_:)` sends your app's own RTVI client message (a type and a JSON payload) on the call in progress, and your delegate gets the agent's RTVI server messages, its output text and the user's transcript, as JSON `Data` and small structs; the engine interprets none of it. Nothing is exchanged during a ring. See [Messages between your app and its agent](Docs/IntegrationGuide.md#host-messages).
- **Any in-app UI, call history, missed-call notifications and call sounds.** Drive them from `CallEngine`'s observable state and the delegate callbacks. The engine plays nothing, but tells you when a ringback, a "retrying" loop or a "connected" sound may belong through `callEngine(_:cue:)`, and `activeCall` tells you whether the call was placed or answered, and ready at the answer, so you can choose (see [Integration Guide, section 10](Docs/IntegrationGuide.md#cues)).
- **Project configuration.** Capabilities, background modes and usage descriptions; see [Integration Guide, section 3](Docs/IntegrationGuide.md#3-project-setup). Every call appears in the Phone app's Recents, and tapping one opens your app with a start-call request the engine leaves to you. Apple does not allow apps that use CallKit on the China mainland App Store.

## Experimental: call hold

A phone call the user accepts during an engine call ends the engine call, as in 0.1. `CallEngineConfiguration.supportsHolding` (off by default) lets iOS hold the call instead, and `CallEngine.setOnHold(_:)` hold it from your UI. It is experimental: do not enable it in a shipping app yet. On an iPhone 17 with iOS 27.0, in-app hold and resume with no other call restored two-way audio on both bundled transports, but resuming after a real phone call did not: on LiveKit every start of the audio engine failed (`LiveKitError` 801, "Audio engine returned error code: -4010"), and on Daily the audio was simply absent. See [Call hold](Docs/IntegrationGuide.md#call-hold).

## Device-only reality

CallKit and PushKit do not run in the iOS Simulator, and the Daily and LiveKit WebRTC stacks abort when they start audio there. A real two-way call can only be tested on a device.

The `ConduitCallEngineTesting` product covers the rest. `CallEngine.simulated()` builds an engine over a `SimulatedCallSystem` (`CallEngine.simulatedForTesting()` in unit tests, with a still clock and timers that wait for the test), which stands in for CallKit, PushKit, audio interruptions and ring-status receipts, and `FakeTransport` stands in for the WebRTC transport. Use them behind `#if targetEnvironment(simulator)` to run your app's UI in the simulator, and in your own unit tests to deliver pushes, answer, mute, hold and end calls from the system side, activate the audio session, interrupt audio, inject transport events and run the engine's timers out, deterministically, without sleeping or polling. See [Integration Guide, section 14](Docs/IntegrationGuide.md#14-simulator-and-unit-testing).

## Verified SDK versions

0.2 was verified on one device, with real calls, with this set:

| Product | SDK | Version |
|---|---|---|
| `ConduitCallEngineDaily` | `pipecat-client-ios` / `pipecat-client-ios-daily` | 1.3.0 / 1.3.0 |
| `ConduitCallEngineDaily` | `daily-client-ios` | 0.41.0 |
| `ConduitCallEngineLiveKit` | LiveKit `client-sdk-swift` (LiveKitWebRTC) | 2.19.0 (150.7871.4) |

**Device:** one iPhone 17 with iOS 27.0, on 2026-11-12. **Routes:** the loudspeaker, the earpiece, and AirPods Pro over Bluetooth (HFP). **Not tried:** CarPlay, wired headsets, other iPhone models, and any iOS version below 27.0: the package supports iOS 18 and later, but nothing below 27.0 has had a device run. What passed on both adapters (outgoing and incoming calls, pre-connected rings, ring timeout, cancel and decline, outages from 10 seconds to 2.5 minutes, a denied microphone permission, the starting route) and what did not is in [What has been verified](Docs/IntegrationGuide.md#what-has-been-verified). The messages between your app and its agent, new in 0.3, are verified in unit tests only.

These are the versions the package's `Package.resolved` pins, and the only set CI builds and tests (a weekly scheduled run also resolves the newest versions the manifest allows, to catch upstream changes). Your app does not use the package's `Package.resolved`: SwiftPM resolves the package's dependencies within the manifest's ranges as part of your app's graph, so Pipecat and LiveKit can resolve above this set. To stay on it:

- commit your app's own `Package.resolved` (in Xcode, `<App>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`), which pins every transitive package at the version it resolved; or
- add the SDK to your app as a direct dependency with an exact version, for example `.package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.19.0")`, which constrains the package's dependency to that version.

After changing any of these versions, make a real call on each adapter you link before you ship.

## Questions and problems

Report bugs and ask questions in [GitHub issues](https://github.com/AmirAlsad/ConduitCallEngine/issues), with the package version, the SDK versions your app resolved, the device and iOS version, and the engine's log around the problem ([Logging](Docs/IntegrationGuide.md#logging); the engine removes credentials from its messages, but check what you paste). Report a security problem privately, through GitHub's "Report a vulnerability" on the repository's Security tab, not in a public issue.

## Documentation

- [Docs/IntegrationGuide.md](Docs/IntegrationGuide.md): everything needed to wire the engine into a real app, from project setup to a device checklist and troubleshooting.
- [Docs/PushContract.md](Docs/PushContract.md): the APNs request and payload your server sends to ring the app, and the ring-status receipts it gets back.
- [Example/](Example/): a host app for one fixed agent, built twice: `ExampleDaily` links the Daily adapter and `ExampleLiveKit` links the LiveKit adapter.
- [CHANGELOG.md](CHANGELOG.md).

## Provenance and license

Extracted from [Conduit](https://github.com/AmirAlsad/Conduit), an open-source iOS app for calling your own voice agents, which is the engine's first host.

MIT. See [LICENSE](LICENSE).
