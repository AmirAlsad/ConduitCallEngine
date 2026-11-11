# ConduitCallEngine

An iOS library that turns a voice agent into a phone call. It presents the call through CallKit (system call UI, lock screen, Bluetooth and CarPlay routing), receives agent-initiated calls through PushKit VoIP pushes, runs the call state machine, owns the audio-session policy during a call, reconnects after network drops, and carries audio over WebRTC through pluggable transports.

Your app describes each call with a small `CallTarget` value: an id, a display name, an optional CallKit handle, a factory for the transport, and an async `connect` closure that returns a room URL and token however your app obtains them. The engine reports call state and finished calls back to you. It knows about calls, not about agents, accounts, persistence or UI. An app with one built-in agent and an app with many are the same to the engine: the first one just has one target.

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

## Requirements

- iOS 18 or later.
- Xcode 16.3 or later. The package manifest uses swift-tools-version 6.1 because the LiveKit SDK's manifest requires it. The sources compile in the Swift 5 language mode.
- A physical iPhone for real calls (see [Device-only reality](#device-only-reality)).
- For incoming calls: a paid Apple Developer account, the Push Notifications capability, and an APNs key on your server.

The manifest's dependency floors are `pipecat-client-ios` 1.2.0, `pipecat-client-ios-daily` 1.2.0 and LiveKit `client-sdk-swift` 2.15.1. These are minimums SwiftPM may resolve above, not tested versions; see [Verified SDK versions](#verified-sdk-versions).

## Installation

Add the package by URL in Xcode (File > Add Package Dependencies) or in a manifest:

```swift
.package(url: "https://github.com/AmirAlsad/ConduitCallEngine.git", from: "0.1.0")
```

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
            handle: nil,
            makeTransport: { LiveKitTransport() },
            // Runs for the first connect and again before every reconnect attempt.
            connect: {
                if let inline { return inline }
                return try await Assistant.fetchConnection()
            }
        )
    }

    /// Ask your own backend for a room URL and token. The request is yours to define.
    static func fetchConnection() async throws -> CallConnection {
        var request = URLRequest(url: URL(string: "https://agent.example.com/connect")!)
        request.httpMethod = "POST"
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
- **An agent that joins the room.** The engine reports a call as connected only once the agent is present and ready. See [Integration Guide, section 11](Docs/IntegrationGuide.md#11-what-the-server-side-must-do).
- **VoIP token delivery.** The engine hands you the PushKit token; getting it to your server is your code.
- **The server that rings the app.** It sends APNs VoIP pushes in the shape described in [Docs/PushContract.md](Docs/PushContract.md).
- **Any in-app UI, call history, and missed-call notifications.** Drive them from `CallEngine`'s observable state and the delegate callbacks.
- **Project configuration.** Capabilities, background modes and usage descriptions; see [Integration Guide, section 3](Docs/IntegrationGuide.md#3-project-setup).

## Device-only reality

CallKit and PushKit do not run in the iOS Simulator, and the Daily and LiveKit WebRTC stacks abort when they start audio there. A real two-way call can only be tested on a device.

The `ConduitCallEngineTesting` product covers the rest. `CallEngine.simulated()` builds an engine over a `SimulatedCallSystem`, which stands in for CallKit, PushKit, audio interruptions and ring-status receipts, and `FakeTransport` stands in for the WebRTC transport. Use them behind `#if targetEnvironment(simulator)` to run your app's UI in the simulator, and in your own unit tests to deliver pushes, answer, mute and end calls from the system side, activate the audio session, interrupt audio, and inject transport events. See [Integration Guide, section 12](Docs/IntegrationGuide.md#12-simulator-and-unit-testing).

## Verified SDK versions

The transport SDK versions this package has been verified against on a device:

| Product | SDK | Version | Verified on |
|---|---|---|---|
| TODO: filled in after device verification | | | |

## Documentation

- [Docs/IntegrationGuide.md](Docs/IntegrationGuide.md): everything needed to wire the engine into a real app, from project setup to a device checklist and troubleshooting.
- [Docs/PushContract.md](Docs/PushContract.md): the APNs request and payload your server sends to ring the app, and the ring-status receipts it gets back.
- [Example/](Example/): a host app for one fixed agent, built twice: `ExampleDaily` links the Daily adapter and `ExampleLiveKit` links the LiveKit adapter.
- [CHANGELOG.md](CHANGELOG.md).

## Provenance and license

Extracted from [Conduit](https://github.com/AmirAlsad/Conduit), an open-source iOS app for calling your own voice agents, which is the engine's first host.

MIT. See [LICENSE](LICENSE).
