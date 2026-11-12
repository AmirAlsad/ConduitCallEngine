# Integration guide

How to wire `ConduitCallEngine` into a real iOS app: what the engine owns, how to set up the project, the PushKit and audio-session rules it depends on, how to write a transport, what your server must do, how to test, and what goes wrong. The [README](../README.md) has a minimal working host; this guide explains why it looks the way it does.

Contents:

1. [What the engine does and does not do](#1-what-the-engine-does-and-does-not-do)
2. [Choosing products](#2-choosing-products)
3. [Project setup](#3-project-setup)
4. [Audio-session ownership](#4-audio-session-ownership)
5. [Launch-time PushKit registration](#5-launch-time-pushkit-registration)
6. [The push payload](#6-the-push-payload)
7. [Delivering the VoIP token to your server](#7-delivering-the-voip-token-to-your-server)
8. [One fixed target](#8-one-fixed-target)
9. [Many targets](#9-many-targets)
10. [Writing your own transport](#10-writing-your-own-transport)
11. [What the server side must do](#11-what-the-server-side-must-do), starting with [When your agent should start speaking](#when-your-agent-should-start-speaking)
12. [Simulator and unit testing](#12-simulator-and-unit-testing)
13. [Device verification checklist](#13-device-verification-checklist)
14. [Troubleshooting](#14-troubleshooting)
- [Known limitations](#known-limitations)

## 1. What the engine does and does not do

`CallEngine` is a `@MainActor`, `@Observable` class. You create one for the whole process, give it a delegate, and hand it a `CallTarget` for each call. It does:

- **CallKit.** Reports outgoing and incoming calls, so they get the system call screen, the lock screen, Bluetooth and CarPlay routing, the system mute and end buttons, and entries in the Phone app's Recents. It handles CallKit's answer, end, mute, hold and reset actions, so iOS can put the call on hold while the user takes a phone call, and the engine resumes it when that call ends.
- **PushKit.** Registers for VoIP pushes, reports every push as a call (iOS requires it), and passes you the VoIP token. Ends a ring nobody answers after a timeout, honours a server's cancel push, and, when the push and your target both ask for it, prepares the call while it rings ([pre-connect](#pre-connect)).
- **The call state machine.** One call at a time, with the states below, and a `CallRecord` when each call finishes.
- **Audio-session policy.** Configures the session for voice chat, lets CallKit activate it, attaches the transport only after activation, keeps the mic off until then, pauses the mic during interruptions (Siri, a phone call), stops media while the call is on hold, and routes to the loudspeaker by default when no headset or car is connected.
- **Reconnection.** After a mid-call network drop it retries with exponential backoff (six attempts, waiting 1, 2, 4, 8, 16 and 30 seconds) while CallKit keeps showing the call, and fails with `.lostConnection` when the budget runs out. A transport that says it is healing itself is given 30 seconds before the engine treats it as dropped and starts those retries, and an attempt whose transport joins but does not report `.connected` within 30 seconds counts as failed. A call whose agent is not ready within 30 seconds of its first join fails as `.agentUnreachable` (time on hold does not count).
- **Ring-status receipts.** When a push asks for them, it POSTs the ring's outcome to your server.

It does not: show any in-app UI, store anything, know what an agent or account is, fetch credentials, deliver the VoIP token to your server, or send pushes. Those are yours.

### What "connected" means

`.connected` means the transport is up **and** the agent is ready to hear the user, not merely that a WebRTC connection exists. Each adapter decides that from its SDK (Daily: the Pipecat client reaches its ready state or the bot reports ready; LiveKit: the room is connected and a remote participant is present; see [section 11](#11-what-the-server-side-must-do)). For an outgoing call, this is also the moment the engine tells CallKit the call connected, which starts the system call timer. If the agent is not ready within `joinTimeout` (30 seconds by default) of the transport's `connect(_:)` returning, the call fails as `.agentUnreachable`.

### States

```
idle -> dialing -> connecting -> connected <-> reconnecting(attempt:)
                                     |
                                     +-> ended(CallOutcome) | failed(CallFailureReason)

idle -> incomingRinging -> connecting -> ...   (after the user answers)
idle -> incomingRinging -> connected -> ...    (answered while a pre-connected agent was there)
```

| State | Meaning | `isActive` | `isTerminal` |
|---|---|---|---|
| `.idle` | No call. | false | false |
| `.incomingRinging` | A push is ringing. CallKit's system UI is the only surface; the app shows nothing until the user answers. A ring being prepared ([pre-connect](#pre-connect)) stays in this state; `ringPreparationPhase` says how far it got. | false | false |
| `.dialing` | `placeCall` was called; CallKit is starting the call. | true | false |
| `.connecting` | CallKit has the call; credentials are being fetched and the transport is joining. An answer to a pre-connected ring whose agent is already there skips it. | true | false |
| `.connected(since:)` | Transport and agent ready. `since` is the first connection time and is kept across reconnects. | true | false |
| `.reconnecting(attempt:)` | Media dropped while CallKit still shows the call. `attempt` is the engine's retry count; `0` means the transport reported a short interruption it is healing itself (LiveKit's own reconnect, or a lost network path on Daily, see [section 11](#11-what-the-server-side-must-do)) and no retry has been spent; after 30 seconds without recovery the engine moves to `1` and reconnects itself. | true | false |
| `.ended(CallOutcome)` | Finished. | true | true |
| `.failed(CallFailureReason)` | Could not be established or could not recover. | true | true |

Terminal states stay until you call `reset()` (typically when your call screen is dismissed), or until the next `placeCall` or incoming ring, which reset first. A ring that ends without the user taking it, other than by declining (Focus filtered it, its target is unknown, CallKit refused it, the CallKit provider reset, it timed out, or the caller cancelled it), goes straight back to `.idle` without a terminal state. A provider reset during a call that is dialing, connecting, connected or reconnecting fails it with `.failed(.unknown)`.

### Outcomes and failure reasons

| `CallOutcome` | When |
|---|---|
| `.completed` | The call connected, then ended by the user, the system UI, or the agent leaving. |
| `.canceled` | The user ended the call (in-app or from the system UI) after placing or answering it, before it connected. |
| `.declined` | The user declined an incoming call while it was still ringing. |
| `.noAnswer` | The agent left before the call ever connected, or a ring was missed: it never reached the user (busy, Focus), timed out, or was cancelled by the caller. The record's `missedReason` says which. |
| `.failed` | See the reason. |

A call that reaches `.ended(outcome)` is recorded with the same outcome, so a host can switch on either and show the same thing.

| `CallFailureReason` | Produced by |
|---|---|
| `.badToken` | `TransportError.authenticationFailed` thrown by the target's `connect` closure or by `transport.connect`, on the first connect or a reconnect attempt; a `.disconnected(reason: .authFailed)` event at any time; an `.error(.authenticationFailed)` event while connecting or reconnecting. |
| `.transportError` | Any other error from the first connect; any other `.error` event while connecting; a drop before the call ever connected. |
| `.lostConnection` | The reconnection budget ran out. |
| `.unknown` | CallKit refused to start an outgoing call, or reset its provider during a call. In a `CallRecord` only (the state goes from `.incomingRinging` back to `.idle`): CallKit refused to report an incoming call (other than Focus filtering) or reset its provider while it rang, or a ring arrived for a target your delegate did not resolve. |
| `.agentUnreachable` | The transport's first `connect(_:)` returned, but it did not report `.connected` within `joinTimeout` (30 seconds by default): the room was joined and the agent never became ready. |

`CallOutcome`, `CallDirection` and `CallFailureReason` have stable string raw values and are `Codable`, so you can persist them.

### The engine's API

| Member | Purpose |
|---|---|
| `init(configuration:)` | The real engine over CallKit and PushKit. Device only. |
| `delegate` | Your `CallEngineDelegate`. **Weak**: keep the delegate alive yourself. |
| `startPushRegistration()` | Start PushKit. Call once in `application(_:didFinishLaunchingWithOptions:)`; later calls do nothing. From then on the engine stays alive for the rest of the process. |
| `voipPushToken` | The current VoIP token, once PushKit has issued one. |
| `placeCall(_:) async` | Start an outgoing call to a target. Ignored unless the engine is idle or terminal. Returns after the first connect attempt has run, not when the call connects. |
| `endCall() async` | End the live call. Ignored while ringing (the user declines from the system UI). |
| `markEndedByUser()` | Set `endedByUser` synchronously, so your UI can dismiss in the same transaction as the tap, before `endCall()` runs. |
| `setMuted(_:) async` | Mute or unmute; mirrored to CallKit. Unmuting turns the transport's mic on once the call is connected and CallKit has activated the session, and while no interruption is in progress (see [section 4](#4-audio-session-ownership)). |
| `setPushToTalkActive(_:) async` | With push-to-talk enabled in the configuration, `true` holds the talk button and `false` releases it. The mic is on while the button is held, once the call is connected and CallKit has activated the session, and while no interruption is in progress. Does nothing when push-to-talk is disabled. |
| `setMicWithheld(_:)` | Keep the mic closed while your app plays its own sound into the call (a spoken "Connected"), and give it back; the agent is told the user is on the line (`call-connected`) at the release. Not mute, and synchronous, so a withhold made inside `callEngine(_:cue:)` is in place before the engine's next mic command. Ends with the call, and is released by the engine after `micWithholdTimeout`. See [Keeping the mic closed for your own sounds](#mic-withhold). |
| `setOnHold(_:) async` | Hold or resume the call from your own UI. The engine asks CallKit, which performs the hold through the engine, as it does for the system UI; `isOnHold` changes then, which on a device can be just after this returns. Does nothing unless the call is connecting, connected or reconnecting, or when `supportsHolding` is off. See [Call hold](#call-hold). |
| `selectAudioDevice(_:) async` | Route audio to one of `audioDevices`. Ignored until CallKit has activated the session (`audioDevices` is empty until then). |
| `reset()` | Return to idle from a terminal state. |
| `state`, `activeCall`, `isMuted`, `isOnHold`, `isBotSpeaking`, `isAudioActivated`, `isInterrupted`, `isMicWithheld`, `audioDevices`, `selectedAudioDeviceID`, `endedByUser` | Observable state for your UI. `activeCall` carries the target id, display name and direction of the current call, and `wasReadyAtAnswer`: whether an answered call's pre-connected agent was already there at the answer. |
| `repeatingCue` | The looping cue that should be playing now (`.connecting`, `.retrying`, or nil), for a UI that attaches mid-call. See [Cues](#cues). |
| `ringPreparationPhase` | How far the ringing call has been prepared (`.idle`, `.fetchingCredentials`, `.credentialsReady`, `.connecting`, `.ready`, `.failed`), for diagnostics. See [pre-connect](#pre-connect). |

`CallEngineConfiguration` has seven settings, in its initializer's order:

| Setting | Default | What it does |
|---|---|---|
| `unknownCallerName` | `"Unknown"` | The name a ring shows when the push carries none. |
| `ringTimeout` | 60 seconds | How long an incoming call rings before the engine ends it as unanswered. A push's `ring_timeout` can shorten it (to no less than 10 seconds) but not lengthen it. `nil` sets no limit of the engine's own; a push's `ring_timeout` still applies then. |
| `joinTimeout` | 30 seconds | How long the engine waits for `.connected` after a transport's `connect(_:)` has returned: on a call's first connect it then fails the call as `.agentUnreachable`, on a reconnect attempt it counts the attempt as failed, and on a ring's pre-connected join the preparation fails. `nil` waits indefinitely, as 0.1 did. |
| `minimumOutgoingConnectingDuration` | zero | For calls the user placed only: the shortest time an outgoing call stays `.connecting`, counted from `.start(.connecting)`. It exists so your outgoing ringback can finish its first tone: set it to that tone (plus any delay before it starts), so a placed call whose agent is ready sooner still rings that long. The engine itself holds the state, CallKit's connected report, `.moment(.connected)`, the mic and `call-connected` until then. It never applies to an incoming call: an answered call becomes `.connected` as soon as its transport is ready. See [Connecting for a minimum](#minimum-connecting). |
| `micWithholdTimeout` | 5 seconds | The longest `setMicWithheld(true)` keeps the mic closed once the call is connected and CallKit has activated its audio (or from the withhold, if later). The engine then releases it and logs a warning. There is no unbounded setting. See [Keeping the mic closed for your own sounds](#mic-withhold). |
| `supportsHolding` | true | Whether calls are reported to CallKit as holdable ([Call hold](#call-hold)). With it off, CallKit offers no hold for the call, and a phone call the user takes during it ends it. |
| `resumesAfterSystemHold` | true | Whether the engine resumes a call iOS held for another call once that call (and any other call seen during the hold) has ended ([Call hold](#call-hold)). A hold your app asked for is never resumed by the engine. |
| `isPushToTalkEnabled` | `{ false }` | Whether the mic follows a push-to-talk button instead of mute. A main-actor closure read at each mic decision, so a settings change mid-call takes effect on the next one. |

The configuration is `Sendable`, so it can live in a `static let`.

`CallEngine.supportedPushFeatures` (`["cancel", "ring_timeout", "preconnect"]`) is the set of optional push features this engine understands; send it to your server with the VoIP token ([section 7](#7-delivering-the-voip-token-to-your-server)).

### The delegate

Every callback is synchronous and on the main actor, made in the order the engine changes things. All have default implementations.

| Callback | When | Default |
|---|---|---|
| `callEngine(_:targetForIncomingCall:)` | Once per ring push (not for a duplicate of the call in progress, a cancel push, or a ring whose cancel already arrived), after the CallKit report is issued: inside the push handling for a ring, or once CallKit has answered the report for a push that arrives during another call. Return the `CallTarget`, or nil for an unknown target (the ring is then ended and recorded as failed, and the engine returns to idle). The target's `ringPreparation` decides, with the push's `IncomingCall.requestedPreparation`, how much of the ring is prepared ([pre-connect](#pre-connect)). | nil, so every ring is ended. Implement it if you take incoming calls. |
| `callEngine(_:didChangeStateFrom:to:)` | On every real state change, after the engine has set the transition's other fields, so `activeCall` and the rest are consistent when you read them. Not called when the state is set to the value it already has. | nothing |
| `callEngine(_:cue:)` | A moment to mark with your own sound or speech, right after the state change that caused it. See [Cues](#cues). | nothing |
| `callEngine(_:didChangeRingPreparationPhaseFrom:to:)` | On every real change of `ringPreparationPhase` ([pre-connect](#pre-connect)), with the property already updated. The phase leaves `.idle` only while ringing, never with a state change, and returns to it before the answer's transition out of `.incomingRinging`, or after an unanswered ring's `didFinish`. The first change can come inside the push handling (when CallKit accepts the report), so return promptly. For diagnostics. | nothing |
| `callEngine(_:didFinish:)` | Once per call, when it reaches its end: ended, failed, busy ring, Focus-filtered ring, a ring that timed out or that the caller cancelled, a ring that could not proceed, a CallKit provider reset. Not for a malformed push, a cancel push, or a ring whose cancel already arrived. | nothing |
| `callEngine(_:ringStatusBearerForTarget:)` | When a receipt is about to be sent, only for pushes that carried `status_url` and whose target your delegate resolved. Return the bearer for the `Authorization` header, or nil for none. | nil |
| `callEngine(_:didUpdateVoIPPushToken:)` | When PushKit issues or rotates the VoIP token. | nothing |
| `callEngineDidInvalidateVoIPPushToken(_:)` | When PushKit invalidates the VoIP token; `voipPushToken` is nil until PushKit issues a new one. | nothing |

### Logging

The engine and the bundled adapters log what they do: CallKit's actions and audio-session activations (including the ones the engine ignores, which `isAudioActivated` does not show), each connect and drop, signals, routes, receipts. By default the lines go to unified logging under your app's bundle identifier, in the categories `📞 [Call]`, `☎️ [CallKit]`, `🔌 [Transport]`, `🔊 [Audio]` and `🌐 [Network]`, and only warnings and errors are logged in a release build. To get them yourself, set a handler:

```swift
CallEngineLog.minimumLevel = .info // .debug in debug builds, .warning in release builds by default
CallEngineLog.handler = { event in
    DiagnosticTrace.record("\(event.category) \(event.level): \(event.message)")
    CallEngineLog.writeToOSLog(event) // keep Console output too
}
```

A handler replaces unified logging (call `writeToOSLog(_:)` to keep it). It is called synchronously on the thread that logs, which can be an SDK's callback queue, so it must be quick; `handler` and `minimumLevel` can be set from any thread. An event below `minimumLevel` is dropped before its message is built. No message carries a credential: URL queries, fragments and user info, bearer values, JSON Web Tokens and the values of keys such as `token=` are removed from every message, including the error descriptions of the SDKs and of your own `connect`, before your handler or Console sees it. The bundled adapters do the same to the messages of the `TransportError`s they build from SDK errors.

### Switching over the engine's enums

Every public enum says in its documentation whether it is closed or open.

- **Closed** enums gain no case within a major version, so a `switch` may list every case: `CallState`, `CallOutcome`, `CallDirection`, `CallCue`, `CallSignalDelivery`, `RingPreparation`, `AudioRouteKind`.
- **Open** enums may gain cases in any release, each listed in the changelog: `CallFailureReason`, `MissedCallReason`, `CallMoment`, `RepeatingCue`, `CallSignal`, `RingPreparationPhase`, `ConnectRequest.Purpose`, `TransportEvent`, `TransportError`, `TransportDisconnectReason`. End a `switch` over one with `@unknown default`. It compiles without a warning today, and when a case is added the switch still compiles, with a warning that names the new case, which takes the `@unknown default` branch until you handle it. A `switch` over a `CallCue` that matches its `RepeatingCue` or `CallMoment` payloads (`case .moment(.connected):`) needs one too.

Until 1.0, read "major version" as "minor version": 0.3 may add a case to a closed enum, listed as a breaking change, and no 0.2.x release does.

## 2. Choosing products

| You use | Link |
|---|---|
| Daily (for example a Pipecat bot in a Daily room) | `ConduitCallEngine` + `ConduitCallEngineDaily` |
| LiveKit | `ConduitCallEngine` + `ConduitCallEngineLiveKit` |
| Both, chosen per target | `ConduitCallEngine` + both adapters |
| Your own WebRTC SDK | `ConduitCallEngine` and your own `CallTransport` ([section 10](#10-writing-your-own-transport)) |
| Simulator runs and host unit tests | add `ConduitCallEngineTesting` |

The core imports no WebRTC SDK. `ConduitCallEngineTesting` imports neither XCTest nor Swift Testing, so linking it into the app target for simulator builds is safe.

### What gets downloaded

SwiftPM resolves every dependency the package manifest declares, whichever products you link: the Pipecat iOS client, its Daily transport, the Daily SDK, the LiveKit Swift SDK, and LiveKit's WebRTC and FFI frameworks. A LiveKit-only app still downloads the Daily and Pipecat packages, and a Daily-only app still downloads LiveKit. Only products you link are compiled, linked and embedded; the rest add resolution time, not app size.

### The WebRTC duplication rule

Never link a second, un-prefixed WebRTC into an app that links the Daily product. Daily's `Daily.xcframework` embeds its own WebRTC, whose Objective-C classes use the standard `RTC` prefix. A package built on `stasel/WebRTC` (and any other stock WebRTC build) ships the same class names. The Objective-C runtime maps each class name to one image, so with two copies loaded, some lookups resolve to the wrong copy, and Daily crashes in a failed dynamic cast the first time it processes participant tracks during a call. The app builds, links and launches normally, and the simulator is unaffected because it runs `FakeTransport`; only a real Daily call on a device shows it.

LiveKit's WebRTC (`LiveKitWebRTC`) is built with a different class prefix, so it coexists with Daily, and the two adapters can be linked together.

How to check:

- Run `Scripts/check-linkage.sh <path-to-.app> <daily|livekit>` on a built app (a device build; [Example/README.md](../Example/README.md) shows the commands). It fails unless the bundle embeds no `Frameworks/WebRTC.framework` and no un-prefixed `RTC*` Objective-C class is defined in more than one of the bundle's Mach-O images. It also checks that the app links only the adapter you name: for `daily`, `Daily.framework` is present and neither `LiveKitWebRTC.framework` nor LiveKit symbols are; for `livekit`, the reverse. An app that links both adapters therefore fails those single-adapter checks by design; for it, the duplicate-class result in the output is the one that matters, or do the manual check below.
- Inspect a device build by hand: the app bundle's `Frameworks/` must not contain a `WebRTC.framework`. `Daily.framework` and `LiveKitWebRTC.framework` are expected for the adapters you link.
- After any change to your transport dependencies, make a real Daily call on a device. That is the only test that catches this at runtime.

If you need a package that depends on stock WebRTC, it has to be rebuilt against a prefixed WebRTC first (Conduit did this for the Pipecat SmallWebRTC client by rebuilding it against `LiveKitWebRTC`).

## 3. Project setup

**Capabilities and entitlements**

- **Push Notifications**, which adds the `aps-environment` entitlement. Needed for VoIP pushes, which need a paid Apple Developer account and an App ID with push enabled. Development-signed builds get sandbox tokens; TestFlight and App Store builds get production tokens.
- No other entitlement. (Xcode's Background Modes capability only writes the `UIBackgroundModes` key below.) If you only place outgoing calls, you can leave out `startPushRegistration()` and the Push Notifications capability; the engine creates no `PKPushRegistry` until you call it.

**Info.plist**

| Key | Value | Why |
|---|---|---|
| `UIBackgroundModes` | `voip` and `audio` | `voip` lets PushKit wake or launch the app for a ring. `audio` keeps the call's audio running while the app is in the background or the screen is locked. |
| `NSMicrophoneUsageDescription` | A sentence explaining the mic carries the user's voice to the agent. | Required to record. The engine does not request permission itself; iOS prompts the first time the SDK opens the mic, which is during the first call. To prompt earlier, call `AVAudioApplication.requestRecordPermission` yourself at a suitable moment. |
| `NSCameraUsageDescription` | A sentence saying calls are audio only. | The WebRTC SDKs reference camera APIs, and App Store validation rejects a build without this key even when the app never uses the camera (ITMS-90683). The prompt never appears at runtime. |

**CallKit** needs no capability, entitlement or Info.plist key, and works only on a device. The engine configures the provider itself: email-type handles (so iOS shows the display name instead of a phone number), one call at a time, no video, and calls included in the Phone app's Recents. Those settings are not configurable in this version, and neither are a ringtone or a CallKit icon image.

## 4. Audio-session ownership

CallKit owns the audio session during a call. It activates the session when the call starts or is answered, and deactivates it when the call ends or is interrupted. The engine's rule follows from that: **a transport never activates the session or opens the mic on its own.** Media starts only after CallKit says the session is active.

What the engine does:

1. Before reporting a call, it sets the session category to `.playAndRecord` with mode `.voiceChat` and options for Bluetooth HFP, Bluetooth A2DP and ducking other audio. It does not activate the session.
2. When CallKit activates the session, the engine calls `transport.attachAudioSession()` and then `transport.setMicEnabled(_:)`: off while the call is still connecting, then, once it is connected, on unless the user muted (or, with push-to-talk enabled, only while the button is held).
3. When CallKit deactivates it, the engine calls `transport.detachAudioSession()`.
4. At teardown it calls `detachAudioSession()`, then `disconnect()`.

**Activation and connection arrive in either order**, and the engine handles every interleaving:

- CallKit can activate before the transport exists (while the call is dialing, or before `answer` runs for an incoming call). The engine remembers the activation and calls `attachAudioSession()` as soon as it creates the transport, before fetching credentials.
- CallKit can activate while credentials are being fetched or the transport is still joining. `attachAudioSession()` runs then, with the mic closed; the engine opens it when the call connects. The other order, connected before the activation, opens it at the activation.
- After an interruption, CallKit can activate the session again, before or after the interruption's end is reported, or without the end ever being reported. Both edges re-derive the mic from the same rule, and an activation of a call that is not held ends the interruption by itself, so the order does not matter.
- CallKit's activation does not say which call it is for. The engine counts it for the call in progress (dialing, connecting, connected or reconnecting, or a ring once CallKit has delivered its answer action) and clears `isAudioActivated` when that call ends, so an activation that arrives after its call ended is ignored rather than attaching the next call's transport early. CallKit activates an incoming call's session only after the user answers, so an activation during a ring nobody has answered is ignored too. Work an activation, deactivation, mute or route change starts is bound to the transport that was live when it started and does not touch a later call's transport.

How each adapter honors this:

- **LiveKit** runs in LiveKit's manual-audio mode: `LiveKitTransport` turns off LiveKit's automatic `AVAudioSession` configuration and keeps LiveKit's audio engine disabled until `attachAudioSession()`; `detachAudioSession()` disables it again, which stops playout and capture while the room stays connected. Because CallKit then really owns the session, the native call screen's audio route button works on LiveKit calls. The setting is process-wide in the LiveKit SDK; if your app also uses LiveKit outside these calls, account for it.
- **Daily** manages `AVAudioSession` itself and has no hook to defer to CallKit. `PipecatDailyTransport` joins with the mic disabled and enables it only through `setMicEnabled`, which the engine calls only after activation. Daily has no way to pause playout either, so a `detachAudioSession()` that follows an attach (a hold, or CallKit deactivating the session) unsubscribes from the agent's audio, and the next `attachAudioSession()` subscribes again; a call that is never detached keeps Daily's default subscription. A join while the call rings (pre-connect's `.media` tier) unsubscribes from the agent's audio before it joins, and the first `attachAudioSession()`, after the answer, subscribes; see [the Daily notes](#daily-pipecatdailytransport). One consequence of Daily owning the session is that the native call screen's route button cannot move Daily's audio (see [troubleshooting](#14-troubleshooting)); route through `engine.selectAudioDevice(_:)` from an in-app picker instead.

**One mic rule.** The transport's mic is on only once the call has been reported connected (it stays so while reconnecting) and while CallKit has activated the session (`isAudioActivated`), the call is not on hold (`isOnHold`), no interruption holds it (`isInterrupted` is false) and your app is not withholding it (`isMicWithheld`, [below](#mic-withhold)); beyond that it follows mute, or in push-to-talk mode whether the button is held (push-to-talk ignores mute). Every change to one of those inputs (an activation or deactivation, a hold or resume, the start or end of an interruption, `setMicWithheld(_:)` and the end of its bound, `setMuted(_:)`, a mute from the system call UI, `setPushToTalkActive(_:)`) and the call becoming connected re-derive the mic from that rule. The engine sends attach, detach and mic commands to the transport one after another in the order it issued them, and reads the rule when each mic command runs, so whatever order these arrive in, the transport ends up with the rule's current answer. An unmute or a push-to-talk press before the connection or the activation, or during an interruption, is remembered and takes effect when the rule allows it. Muting, releasing push-to-talk, a deactivation and the start of an interruption turn the mic off.

**When an interruption ends.** An interruption starts with `AVAudioSession`'s interruption-began notification and closes the mic. It ends, and the mic follows the rule again, at the first of:

- its end with `shouldResume`;
- CallKit activating the session while the call is not held. That is the system handing the audio back, and iOS does not always report the interruption's end: after a phone call it may never come;
- the resume of a held call whose session CallKit activated during the hold;
- its end without `shouldResume`, if CallKit had handed the session back since the interruption began;
- the end of the call.

An end without `shouldResume` before CallKit has handed the session back does not reopen the mic by itself: the mic stays closed, and `isInterrupted` stays true, until CallKit activates the session again or the user unmutes or presses push-to-talk. Nothing else ends an interruption: an unmute or a push-to-talk press during it is remembered for afterwards, and a hold, a resume without an activation, or a deactivation leaves it as it is. Whatever order these arrive in, and whether or not the end ever arrives, a call that is not held and gets its audio back from CallKit has an open mic (subject to mute).

<a id="call-hold"></a>**Call hold.** With `supportsHolding` on (the default), every call is reported to CallKit as holdable (and as not groupable and without DTMF), so when a phone call starts or arrives during an engine call, iOS can hold the engine call instead of ending it. The user, iOS, or your app through `setOnHold(_:)` holds and resumes it; each arrives as CallKit's hold action, which the engine performs only for the call it names and only while that call is connecting, connected or reconnecting (otherwise CallKit is told the action failed). A hold does not change `state`; it sets `isOnHold`, and:

1. The mic closes, through the same rule as above: the mic is on only once the call is connected, while the session is activated, the call is not on hold and nothing interrupts it. A mute, unmute or push-to-talk change while held is recorded and applies on resume.
2. The engine calls `transport.detachAudioSession()`, so media stops even if CallKit keeps the session active (as it may when your app holds a call with no other call up).
3. Once the call's transport has joined, the engine sends it `CallSignal.held` for the agent (see [section 10](#10-writing-your-own-transport)), also while the call still shows connecting: after its connect returned and while it waits for the agent, or with the agent there while a call the user placed waits out `minimumOutgoingConnectingDuration`. An agent in the room can be counting down to a greeting by then. A hold before the join is sent at the join; a held call that is reconnecting is told when it reconnects.
4. The looping cue, if one runs, stops, and `.moment(.held)` is delivered. No other cue is delivered until the resume.
5. A reconnect already scheduled is cancelled, and the call shows `reconnecting(attempt: 0)`. A connection that drops while held does the same instead of spending retries. A transport that heals itself while held recovers as usual.
6. A call that is still waiting for its agent (connecting, its transport joined) stops counting toward `joinTimeout`: the user is on another call, and an agent may be unable to get ready while the call's media is stopped (a Daily one is, see [section 11](#11-what-the-server-side-must-do)). The resume starts the wait again in full.

On resume, `isOnHold` clears; the engine calls `attachAudioSession()` if CallKit has the session activated (otherwise it attaches on the next activation), re-derives the mic, sends `CallSignal.resumed` if connected, and delivers `.moment(.resumed)` followed by whatever the call's state needs: `.moment(.connected)` if the call first connected during the hold, `.moment(.connectionLost)` and `.start(.retrying)` if the connection dropped during the hold, `.start(.retrying)` again if the outage began before it, `.start(.connecting)` if the call has not connected yet (which, on a call the user placed, starts `minimumOutgoingConnectingDuration` again). A call that connected during the hold gets `CallSignal.connected` after those cues, so a withhold you make inside its `.moment(.connected)` holds the signal back until your release, as on any other path. A reconnect the hold paused starts at once at attempt 1 with a fresh budget, and a call still waiting for its agent gets the full `joinTimeout` again from the resume. A transport that connects or reconnects while the call is held is told `held` again, and one that reconnects after a resume it missed is told `resumed`. Ending a held call is an ordinary end; held time counts in `CallRecord.duration`.

**When the other call ends.** CallKit does not resume an app's call when the call iOS held it for ends, so with `resumesAfterSystemHold` on (the default) the engine does. It tells a hold iOS made (a `CXSetHeldCallAction` your app did not request with `setOnHold(_:)`: the user accepting a phone call, or holding from the system call screen) from one your app asked for, and watches the other calls on the device through CallKit's call observer (`CXCallObserver`), ignoring its own. Once every other call it saw during such a hold has ended, however it ended, and no other call is left on the device (none ringing, connected or on hold), it asks CallKit to resume its call, exactly as your `setOnHold(false)` would, and everything a resume does follows, including the activation check below; Console shows `The call the system held for ended; resuming`. A third call still up keeps the call held until it ends too. The engine never resumes a hold your app asked for, nor a system hold your app then asked to keep with `setOnHold(true)`, nor a hold during which it saw no other call (the user holding from the system call screen with nothing else up), and it does nothing when the user resumed first. Set `resumesAfterSystemHold: false` to leave every hold to the user.

**A resume CallKit does not follow with an activation.** CallKit normally activates a resumed call's audio within a tenth of a second. After a phone call on iOS 27 it did not: the call was no longer held, and had no audio. So when a resume finds the session not activated, the engine gives CallKit 2 seconds (on its injected `sleep`), then asks again by requesting a hold and a resume of the call through CallKit, back to back, which is what brought the activation on the device; it does this at most 3 times per resume, waiting 2 seconds each time, and stops as soon as CallKit activates the audio, the call is held again, or it ends. The pair is invisible to your app: `isOnHold` does not change, no cue is delivered and the agent is sent no signal; Console shows `CallKit did not activate the audio within 2 seconds of the resume; holding and resuming the call to ask again (1 of 3)`. It never overrides a hold: a hold that the user, iOS or your app asks for while the pair is under way is performed, and the pair's resume is refused so CallKit keeps that hold. If CallKit refuses the pair's resume after performing its hold, the engine shows the call as held (`isOnHold`) so the user's resume asks CallKit again. Before fulfilling any resume while the session is not activated, the engine also sets the session's category and mode again (without activating it), as it does before reporting a call. If all three requests go unanswered, the call stays not held with no audio until CallKit activates it or the user holds and resumes it again, which starts a new round.

What CallKit does to the audio session around a hold is not documented by Apple. The engine is built so that any order works: whether CallKit deactivates the session on hold and activates it again on resume, sends interruptions around them, or does neither, media runs only while the session is activated and the call is not held, and the mic follows the rule above.

**Hands-free default.** Once per call, after it connects and the transport's device list is available, the engine selects the loudspeaker if the transport lists no Bluetooth or wired route. Like attach and the mic, all route work waits for CallKit's activation: before it (and after a deactivation, until the next activation) the engine reads no routes, applies no default and ignores `selectAudioDevice(_:)`, since an output-port override on a session that is not active is lost; a call that connects before CallKit activates gets its route list and the default at the activation. A call with nothing connected therefore plays on the speaker rather than the earpiece, and a call in the car stays in the car. This is not configurable in this version; the user can change routes afterwards.

**Your own audio during a call.** Do not change the session category or call `setActive` while a call is up. If you play audio cues during a call, play them into the session as it is.

**Pre-connected rings.** A ring prepared at the `.media` tier ([pre-connect](#pre-connect)) has a transport that joins while the phone rings. The engine keeps that transport apart from the call until the answer: it gets no `attachAudioSession()`, no `setMicEnabled(_:)`, no route reads or changes and no signals, mute and route requests do not reach it, and an activation during the ring, which can only be left over from an earlier call, is ignored. Once the user answers, the transport becomes the call's, and everything above applies, including route work waiting for CallKit's activation, which matters most here since such a call can be connected before it.

What a custom transport must do is in [section 10](#10-writing-your-own-transport).

## 5. Launch-time PushKit registration

Call `engine.startPushRegistration()` in `application(_:didFinishLaunchingWithOptions:)`, with the delegate already set.

Why there: when a ring arrives and the app is not running, iOS launches it in the background. No scene connects and no view appears, so registration in a view's `onAppear`, a scene delegate, or after sign-in never runs. PushKit delivers the push only to a registry that exists, and the engine creates it in `startPushRegistration()`.

Why it matters: iOS requires every VoIP push to report an incoming call to CallKit before the PushKit callback returns. An app that receives a VoIP push and does not report one is terminated, and if it keeps happening, iOS stops delivering VoIP pushes to the app. A push that arrives during a call and is not reported takes the live call down with the app.

The engine guarantees the report on every path. It reports first, synchronously inside the PushKit callback, under the identity in the payload, before touching its own state or calling your delegate. PushKit's completion handler is called after CallKit's completion, on every path.

| Push | What the engine does |
|---|---|
| Normal | Reports, asks your delegate for the target, rings. With `preconnect` and a target that allows it, prepares the call once CallKit accepts the report ([pre-connect](#pre-connect)). |
| Malformed (no valid `target_id` or `agent_id`) | Reports under a fresh id and the unknown-caller name, then ends it as failed. No state change, no delegate call, no record. |
| During another call (ringing, dialing, connecting, connected, reconnecting) | Reports, then ends it at once as unanswered; the live call is untouched. Your delegate gets a `CallRecord` with `missedReason: .busy`, and a `busy` receipt is sent if requested and your delegate resolves the target. |
| Carrying the `call_id` of the call in progress (a duplicate delivery) | Reports it and does nothing else: no end, no record, no receipt, no delegate call. |
| After a finished call that is still in a terminal state | Resets to idle and rings normally. |
| For a target your delegate does not resolve | Reports, then, once CallKit accepts the report, ends it as failed, records it (`outcome: .failed`, `failureReason: .unknown`) and returns to idle. |
| Filtered by Focus or Do Not Disturb | Records a missed call (`missedReason: .filteredByFocus`) and returns to idle. |
| Refused by CallKit for another reason | Records it as failed with `.unknown` and returns to idle. If CallKit refused it because it already holds a call under that `call_id`, the engine does not end that id in CallKit. |
| Nobody answers within the ring timeout | Ends it in CallKit as unanswered, records a missed call (`missedReason: .ringTimedOut`), sends `unanswered` if requested, and returns to idle. An answer CallKit delivered before the timeout always wins. |
| A cancel push (`"action": "cancel"`) for the ringing call | Reports it under the ring's id (CallKit refuses the duplicate), ends the ring as the caller hanging up, records a missed call (`missedReason: .canceledByCaller`), sends `canceled` if requested, and returns to idle. |
| A cancel push for the call in progress, already answered | Reports it; nothing else. |
| A cancel push for an id the engine does not know | Reports it (it rings) and ends it at once. No state change, no delegate call, no record. |
| A ring whose cancel already arrived (within 10 minutes) | Reports it and ends it at once. No state change, no delegate call, no record, no receipt. |

What your code must do to keep the guarantee:

- **Create one engine for the whole process.** Once `startPushRegistration()` has run, the engine keeps itself alive (its PushKit registry holds it), so a push is always reported even if your code lets go of the engine. Releasing it does not stop pushes or free it; a second engine that also starts registration would compete for PushKit, so do not create one.
- **Set `delegate` before `startPushRegistration()`.** A push waiting at launch can be delivered as soon as the registry exists (on the main queue, right after the current turn). The delegate is weak and has no default target, so a push handled before it is set resolves to no target and the ring is ended as an unknown target.
- **Resolve targets from memory.** `targetForIncomingCall` runs during push handling. Look the target up synchronously; do not start network or disk work there.
- **Do not create your own `PKPushRegistry` for VoIP.** The engine owns PushKit for the app.

## 6. The push payload

The full contract for server authors is in [PushContract.md](PushContract.md). In summary:

- `target_id` (or its alias `agent_id`) identifies the target; `call_id` becomes the CallKit call id. Both are UUID strings, in either case. Where the engine writes a call id as text, in ring-status receipts, it uses lowercase; when your code sends `IncomingCall.callID` or `ConnectRequest.callID` to your server, write `uuidString.lowercased()` to match (`uuidString` is uppercase).
- `display_name` and `handle` decide how the ring looks before your app is consulted. Without them it rings under `CallEngineConfiguration.unknownCallerName` and `CallTarget.defaultHandle(for:)` (`<id>@calltarget.invalid`).
- Once CallKit accepts the report, if the target your delegate returned has a different `displayName`, or a different handle (`handle`, or the default handle for its id when `handle` is nil), the engine updates the ring in place. Your target's values win.
- `room_url` and `token` together are inline credentials. Your delegate receives them as `IncomingCall.connection`; whether to use them is your choice. The usual pattern is a target whose `connect` closure returns the inline connection when there is one and fetches credentials otherwise, as in the README.
- `status_url` asks for ring-status receipts; the bearer comes from `ringStatusBearerForTarget`. Receipts are sent only for targets your delegate resolves, so a push for a target you do not know never makes the engine contact the URL it carries.
- `ring_timeout` shortens how long this ring may ring, within `CallEngineConfiguration.ringTimeout`.
- `preconnect` (`"credentials"` or `"media"`) asks the engine to prepare the call while it rings. Your delegate receives it as `IncomingCall.requestedPreparation`, and the ring gets it only as far as your target's `ringPreparation` allows ([pre-connect](#pre-connect)).
- `"action": "cancel"` with a `call_id` (and no `target_id`) withdraws a ring. Your delegate is not asked about a cancel; if it ends the ringing call, you get the missed-call record.

`IncomingCall` carries `callID`, `targetID`, the `displayName` and `handle` the ring was reported under (after fallbacks), `connection`, and `requestedPreparation`.

## 7. Delivering the VoIP token to your server

The engine receives the token; sending it to the server that will ring the device is your job.

**Where it arrives.** `callEngine(_:didUpdateVoIPPushToken:)` is called when PushKit issues or rotates the token. `engine.voipPushToken` returns the current one (nil until PushKit has issued it). Do not count on a callback at every launch; if your server might not have the token, read `voipPushToken` and send it.

**What to send.** Over your own authenticated API:

- the token, hex-encoded: `token.map { String(format: "%02x", $0) }.joined()`;
- the bundle id, from which the server derives the APNs topic (`<bundle id>.voip`);
- the APNs environment the build uses (sandbox for development-signed builds, production for TestFlight and the App Store), typically decided per build configuration;
- the target ids this device accepts rings for, and for each, the display name and handle your app uses, so the push can carry them and ring under the right name from the first frame;
- `CallEngine.supportedPushFeatures`, so the server sends `ring_timeout`, `preconnect` and cancel pushes only to devices that understand them. Send it again after an app update, since a newer engine may support more.
- `call_signals`, the raw values of `CallSignal.allCases`, if your transports deliver signals, so an agent the server starts for a ring before the device asks for credentials knows to wait for `call-connected` ([When your agent should start speaking](#when-your-agent-should-start-speaking)). Send the same list in the body of every credential request.

The token belongs to the install, not to a target: every target gets the same token.

**When to send it again.**

- On every `didUpdateVoIPPushToken` callback.
- When the user signs in, or turns on incoming calls for a target.
- When a target's display name or handle changes, so the server echoes current values.
- Tell the server to forget the token when the user signs out, or turns incoming calls off, and on `callEngineDidInvalidateVoIPPushToken(_:)`, when PushKit invalidates it. Reinstalling the app produces a new token; APNs answers pushes to the old one with 410.

Retry failed sends yourself; nothing in the engine retries them.

## 8. One fixed target

An app with one built-in agent is the simplest host. [`Example/`](../Example/) is a complete one, built twice from the same sources: `ExampleDaily` links the Daily adapter and `ExampleLiveKit` links the LiveKit adapter. Each also links `ConduitCallEngineTesting` for the simulator. The Xcode project is generated from `Example/project.yml` with XcodeGen and is not checked in; [Example/README.md](../Example/README.md) has the commands to generate it, build it, and run the linkage check.

What to look at:

- **The target** (`Example/Shared/ExampleAgent.swift`). A fixed `CallTarget` with a constant UUID. That UUID is what your server puts in the push as `target_id`. The transport comes from a per-app `makeTransport()` (`Example/ExampleDaily/Transport.swift` or `Example/ExampleLiveKit/Transport.swift`), which is the only code that differs between the two apps.
- **Credentials** (`Example/Shared/ExampleBackend.swift`). A placeholder for your backend: the engine needs only a URL and a token, obtained however you like. Replace it.
- **The engine and delegate** (`Example/Shared/AppDelegate.swift`). The app delegate owns the engine and is its delegate, which keeps the weak delegate alive, and starts push registration in `didFinishLaunchingWithOptions`. It resolves every incoming ring to the one target, and sends the VoIP token to the backend.
- **The UI** (`Example/Shared/CallView.swift`). A view that reads `engine.state` and calls `placeCall`, `setMuted` and `endCall`.
- **The simulator path.** Under `#if targetEnvironment(simulator)` the app builds `CallEngine.simulated(system:)` and a `FakeTransport` that reports `.connected` after a second, so the UI can be exercised without CallKit or WebRTC.

To make it place a real call: set your team and bundle ids, point `ExampleBackend` at a service that returns a room URL and token with an agent in that room, and run on a device. To ring it, send a push as described in [PushContract.md](PushContract.md) with `target_id` set to the example's UUID, to the token the app logged or registered.

## 9. Many targets

The engine has no list of targets; your delegate is the lookup.

**Resolving by id.** Keep your targets (agents, contacts, whatever your app calls them) in memory, keyed by a stable UUID that your server also knows. Build a `CallTarget` on demand:

```swift
func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? {
    guard let agent = agents.first(where: { $0.id == call.targetID }) else { return nil }
    return agent.callTarget(inline: call.connection)
}
```

Here `agents` and `callTarget(inline:)` are your own: the latter builds a `CallTarget` from your model, the same way for outgoing calls (without inline credentials) and incoming ones.

**A transport per target.** `makeTransport` is per target, so targets can use different transports. A target on Daily returns `PipecatDailyTransport()`, one on LiveKit returns `LiveKitTransport()`. The engine calls `makeTransport` once per call, before it fetches credentials, and reuses that transport for every later connect in the call (reconnect attempts, and the unprepared connect after a preparation that failed following the answer). The exception is a ring prepared at the `.media` tier: `makeTransport` runs during the ring, and if the preparation fails before the answer, again at the answer ([pre-connect](#pre-connect)), so return a new transport every time.

**Credentials per call.** `connect` runs for the first connection and again before every reconnect attempt, so it can mint fresh, short-lived credentials each time. Its `ConnectRequest` says which: `purpose` is `.outgoing` or `.answered` for a call's first connect and `.reconnect(attempt:)` for an engine retry, and `callID` is the ring's `call_id` on every request for an incoming call (nil for an outgoing one), so your backend can tell a reconnect from a new call and match it to the ring it sent. (`.ringing(joinsBeforeAnswer:)` is pre-connect's, below.) `Purpose` is open, so end a `switch` over it with `@unknown default` ([Switching over the engine's enums](#switching-over-the-engines-enums)); treat a case you do not know as the first connect of an incoming call. Throw `TransportError.authenticationFailed` when your backend rejects the user's credentials (a 401 or 403) so the call fails as `.badToken`, which your UI can explain differently from a network failure.

<a id="pre-connect"></a>**Pre-connect.** An incoming call can be prepared while it rings, so the agent is ready the moment the user answers. Three parties decide, and the ring gets the lowest of what they allow (`RingPreparation`):

1. **The server**, with the push's `preconnect` key (`"credentials"` or `"media"`; anything else is none), which reaches your delegate as `IncomingCall.requestedPreparation`. Only the server knows whether its agent waits for the answer before speaking; `"media"` is its promise that it does ([PushContract.md](PushContract.md#pre-connect)).
2. **You**, with `CallTarget.ringPreparation` on the target you return for the ring (default `.none`). You can decide per ring from `requestedPreparation`, for example only on Wi-Fi, or never when a credential request costs money (a backend that starts an agent for every request starts one for every ring).
3. **The transport**, for `.media`: its `canConnectWhileRinging` ([section 10](#10-writing-your-own-transport)). A transport that cannot join while ringing gets `.credentials`.

With any of them at none, the ring is exactly what it is without pre-connect: nothing is fetched or created before the answer.

| Tier | During the ring | When the user answers |
|---|---|---|
| `.credentials` | Your `connect` runs with `ConnectRequest.Purpose.ringing(joinsBeforeAnswer: false)` and the result is kept. | The transport is created (unless one was made for the ring) and joins with those credentials: `incomingRinging -> connecting -> connected`, as usual, minus the credential fetch. |
| `.media` | `makeTransport` runs and the transport's `canConnectWhileRinging` is read, then your `connect` runs with `.ringing(joinsBeforeAnswer: true)` and the transport joins, with no audio attached, the mic closed and the route untouched. The agent then has `joinTimeout` to be there, counted from the join, or the preparation fails. | If the agent is there (`ringPreparationPhase == .ready`), the call goes straight to `connected(since:)` at the answer, with `.moment(.connected)`, no `.connecting` and no `.start(.connecting)` (`activeCall.wasReadyAtAnswer` is true). Otherwise it is `connecting` until the agent is, and becomes `connected` the moment the agent is there; a fetch or join still under way continues, and no second fetch is made, unless the preparation then fails (below). |

What else to know:

- **Preparation starts once CallKit accepts the ring's report**, not when the push arrives, so a ring Focus filters, or CallKit refuses, fetches nothing. A ring answered before CallKit accepted it connects as without pre-connect.
- **`state` stays `.incomingRinging` for the whole ring**, and `isActive` false. `ringPreparationPhase` (`.idle`, `.fetchingCredentials`, `.credentialsReady`, `.connecting`, `.ready`, `.failed`) shows how far it got, for diagnostics, and `callEngine(_:didChangeRingPreparationPhaseFrom:to:)` reports each change; it changes no state. It is `.idle` again once the ring is answered (before the transition out of `.incomingRinging`) or ends (after the ring's `didFinish`).
- **A failed preparation never disturbs the ring.** Credentials that fail (rejected ones included), a join that throws, a drop, a rejected token or an error while joining, the agent leaving before it was there, or an agent that is not there within `joinTimeout` of the join, during the ring, set the phase to `.failed` and drop the ring's transport; the phone keeps ringing, and an answer then connects as without pre-connect: a new transport from `makeTransport`, and `connect` with `.answered`. So **`makeTransport` must return a new transport on every call**, as it is asked again after a failed preparation. An error once the agent is there is only logged, as during a call.
- **Nor does it make the answered call worse.** If the ring was answered while still being prepared and the preparation then fails before the agent is there (the same failures, the `joinTimeout` counted from the join rather than from the answer), the call stays `connecting` and connects as an unprepared answer would: your `connect` runs with `.answered`, and the call's transport (the one the ring made, not a new one) is connected again with the result, as on a reconnect attempt, so it must take its earlier session over. It does not get `disconnect()`, whose end-call signal could reach the agent of the room the fresh credentials name. This happens once; if that connect fails too, the call fails as it would have without pre-connect.
- **The agent leaving a ready ring is the caller cancelling it**: once the ring's transport reported the agent there, `.disconnected(reason: .botLeft)` before CallKit delivered an answer ends the ring as remote-ended, with a `CallRecord` (`outcome: .noAnswer`, `missedReason: .canceledByCaller`), a `canceled` receipt, and no cues. Between CallKit delivering the answer action and the engine handling it, the same event is a lost preparation, and the answer connects afresh; once the call has connected it is an agent hangup of the call. Before the agent was there, it is a failed preparation, during the ring or after the answer (above).
- **A ring that ends unanswered** (declined, timed out, cancelled, reset) cancels a credential fetch in flight and disconnects the ring's transport, which sends the end-call signal if it is connected. Records, receipts and cues are as for any ring. A second push during the ring (busy or a duplicate) leaves the preparation alone.
- **Credentials fetched for a ring are used for the call**, so they must stay valid for the ring and its call (the ring is bounded by `ringTimeout`, 60 seconds by default); reconnects ask again with `.reconnect(attempt:)`.
- **`CallSignal.connected`.** As on every call ([When your agent should start speaking](#when-your-agent-should-start-speaking)), the agent is told the user is on the line once the answered call is connected, CallKit has activated the audio, it is not held and you are not withholding the mic. For an agent that joined during the ring, it is the moment to speak.
- **Outgoing calls are not prepared.** There is no "prepare this target" API: credentials for a call the user may never place would start agents nobody talks to.

**History.** Write history from `callEngine(_:didFinish:)`. A `CallRecord` has `targetID`, `direction`, `startedAt`, `duration` (connected seconds, 0 if it never connected), `outcome`, `failureReason` and `missedReason`. Check `targetID` against your targets: a ring for an unknown target is recorded against the pushed id, which may match nothing of yours. `missedReason` has stable string raw values and is `Codable`, like `CallOutcome`. Record only from `didFinish`, not also from state transitions, or you will write two rows per call.

**In-call UI.** Present your call screen while `engine.state.isActive` is true. That excludes `.incomingRinging`, where CallKit's ring is the interface, and includes terminal states, so a failed call can stay on screen with its reason until the user closes it; call `reset()` on dismiss. When the user taps End, call `markEndedByUser()` and dismiss in the same transaction, then `await engine.endCall()`; `endedByUser` lets you tell a call your user ended in-app (dismiss at once) from a remote end or failure (show a result). It is set only by `markEndedByUser()` and `endCall()`: a call ended from the system UI, such as the lock screen, leaves it false. A ring that ends before the user takes it, including one for an unknown target, never makes the state active. Name the call from `activeCall?.displayName`.

**Transitions.** `didChangeStateFrom:to:` is synchronous and ordered, so it is the place for anything that must match the state exactly. A typical outgoing call delivers `idle -> dialing`, `dialing -> connecting`, `connecting -> connected`, then `connected -> ended(.completed)`. A drop delivers `connected -> reconnecting(attempt: 1)` and, on recovery, `reconnecting -> connected`. `reconnecting(attempt: 0)` means the transport is healing itself and the engine has spent no retry: a short interruption delivers `connected -> reconnecting(attempt: 0)` and then `reconnecting -> connected`, or, if the transport gives up or has not recovered within 30 seconds, `reconnecting(attempt: 0) -> reconnecting(attempt: 1)` and the engine's own retries. Both adapters report short interruptions this way. A ring that arrives while a finished call is still terminal delivers `ended -> idle -> incomingRinging`. An answered ring delivers `incomingRinging -> connecting`, or, for a pre-connected ring whose agent was already there, `incomingRinging -> connected` directly. For sounds, use cues instead of deriving them from these sequences.

<a id="cues"></a>**Cues.** The engine plays no sound. It tells you the moments at which you would play your own, through `callEngine(_:cue:)`:

| `CallCue` | When |
|---|---|
| `.start(.connecting)` | The call moved to `.connecting` (placed and accepted by CallKit, or answered), or a call held while connecting was resumed. On a call the user placed, loop a ringback until `.stop`, which comes no sooner than `minimumOutgoingConnectingDuration` later unless the call is held or ends, or its transport drops. On an answered call, `.stop` comes as soon as the agent is there, and what you play, if anything, is yours to choose (below). Not delivered for a pre-connected ring answered with its agent there, which goes straight to connected. |
| `.start(.retrying)` | The connection dropped (`.connected` to `.reconnecting`). Loop a "retrying" sound until `.stop`. |
| `.stop` | End the loop that is running. |
| `.moment(.connected)` | The call connected for the first time, including at the answer of a pre-connected ring whose agent was there, once CallKit has activated the call's audio: with the transition if the session is already active, otherwise at the activation. |
| `.moment(.reconnected)` | The call came back after an outage. |
| `.moment(.connectionLost)` | The connection dropped. Once per outage, followed by `.start(.retrying)`. |
| `.moment(.held)` | The call was put on hold. A running loop is stopped first; no other cue comes until `.moment(.resumed)`. |
| `.moment(.resumed)` | The call came back from hold. Followed by `.moment(.connected)` if the call first connected during the hold, and by the loop the call's state wants, if any, preceded by `.moment(.connectionLost)` if the connection dropped during the hold. |

What the engine guarantees, so you need no bookkeeping of your own:

- At most one loop runs at a time. Every `.start` is followed by exactly one `.stop` before the next `.start`, before `.moment(.connected)` or `.moment(.reconnected)`, and no later than the transition that ends the call, whatever ends it (a hangup, a failure, an exhausted retry budget, a CallKit provider reset).
- `.moment(.connectionLost)` comes once per outage, also when a transport's own healing escalates to the engine's retries (`reconnecting(attempt: 0) -> reconnecting(attempt: 1)` is not a second outage).
- A ring that is never answered (declined, timed out, cancelled, filtered by Focus, busy, or ended before it could proceed) produces no cues; CallKit's ringtone is the only sound. Preparing a ring produces none either.
- An answer to a pre-connected ring whose agent is there delivers `.moment(.connected)` with no `.start(.connecting)` before it.
- `.moment(.connected)` never comes before CallKit has activated the call's audio (`isAudioActivated`), so a sound you play on it plays into a live session. For a pre-connected ring answered with its agent there, and for any call that connects before the activation, it comes at the activation, with no state change; the ringback, if one ran, stopped with the state change. A call that drops before then gets it, instead of `.moment(.reconnected)`, when it is back.
- While the call is on hold, nothing plays: `.moment(.held)` comes with no loop running, and the next cue is `.moment(.resumed)`. A connection that drops and comes back during the hold is not marked; one still down at the resume is marked then, once. Hold and resume cues come when CallKit performs the hold action, not with a state change.
- Cues arrive synchronously on the main actor, right after the `didChangeStateFrom:to:` of the same change and after that change's ring-status receipt (so `answered` is sent before the ringback starts), except a `.moment(.connected)` that waited for CallKit's activation and the hold cues. `engine.repeatingCue` is already updated when a cue arrives.

<a id="which-call"></a>**Which call a cue is for.** The engine reports the moment; whether to make a sound is yours. A sound that suits a call the user placed can be wrong for one the user answered: a ringback after the user picked up sounds as if the user were the one calling. `engine.activeCall` is set whenever a cue is delivered, so read it there: `direction` tells a call the user placed (`.outgoing`) from one that rang in (`.incoming`), and `wasReadyAtAnswer` tells an answered call whose pre-connected agent was already there from one that had to connect after the answer. It turns true at the answer, before the transition, so the call's `.moment(.connected)` reads it even when that moment comes later, at CallKit's activation.

| The call | Its cues up to the connection | `activeCall` at those cues |
|---|---|---|
| Placed by the user | `.start(.connecting)`, `.stop` (no sooner than `minimumOutgoingConnectingDuration`), `.moment(.connected)` | `direction == .outgoing` |
| Answered with its agent there (a `.media` ring whose agent was ready) | `.moment(.connected)` only, at the answer, or at CallKit's activation if that comes later | `direction == .incoming`, `wasReadyAtAnswer == true` |
| Answered and still connecting (no preparation, a `.credentials` ring, a `.media` ring whose agent was not there yet, a failed preparation) | `.start(.connecting)`, `.stop` as soon as the agent is there, `.moment(.connected)` | `direction == .incoming`, `wasReadyAtAnswer == false` |

Reconnects, holds and resumes cue the same way for every call.

A host that speaks its cues, with a ringback only for calls the user placed:

```swift
func callEngine(_ engine: CallEngine, cue: CallCue) {
    let call = engine.activeCall // set whenever a cue is delivered
    switch cue {
    case .start(.connecting):
        if call?.direction == .outgoing {
            announcer.startRepeating(.connecting) // the user is calling: a ringback
        }
        // An answered call that is still connecting: play something or nothing.
        // (Conduit says "Connecting" once if it is still connecting a second later.)
    case .start(.retrying): announcer.startRepeating(.retrying)
    case .stop: announcer.stopRepeating()
    case .moment(.connected):
        // Answered with the agent there: the user is already talking to it.
        if call?.wasReadyAtAnswer != true { announcer.announce(.connected) }
    case .moment(.reconnected): announcer.announce(.connected)
    case .moment(.connectionLost): announcer.announce(.disconnected)
    case .moment(.held), .moment(.resumed): break
    @unknown default: break // a cue added later; its loop, if any, still gets its .stop
    }
}
```

`announcer` is yours. Staying silent for a call that was ready at the answer also means `call-connected` reaches the agent as soon as CallKit activates the audio, with no "Connected" of yours to wait out ([below](#mic-withhold)). During a hold your app's audio session is typically not active (the user is on another call), so play nothing for `.moment(.held)`; a short sound for `.moment(.resumed)` is reasonable. Play cues into the session as CallKit configured it (see [section 4](#4-audio-session-ownership)); a call screen that appears mid-call can start the loop `engine.repeatingCue` names.

<a id="minimum-connecting"></a>**Connecting for a minimum (calls the user placed).** A transport can be ready a second after the user dials, before a ringback has played one tone. Rather than cut the tone, or keep playing it while the call already shows connected, set `CallEngineConfiguration.minimumOutgoingConnectingDuration` to the tone's length (plus any delay before you start it). On a call the user placed, the engine then stays in `.connecting` until the transport has reported `.connected` and that long has passed since `.start(.connecting)`, so everything that marks the connection moves together: the state and `connected(since:)`, CallKit's connected report, `.stop` and `.moment(.connected)`, the mic, `call-connected` to the agent, and the record's duration. A call whose agent takes longer is not delayed further. It never applies to an incoming call: the user has heard the ringtone and picked up, so an answered call becomes `.connected` as soon as its transport is ready, and a pre-connected ring answered with its agent there goes straight to connected.

While the engine holds a placed call's ready connection:

- The transport's readiness ends the wait bounded by `joinTimeout`; a connect that returns after it starts none.
- What the transport reports about the connection is applied to the call it made, as without the minimum: a drop or a transport healing itself reports the connection, then reconnects (the call does not fail as one that never connected); the agent leaving reports it, then ends the call as `.completed`; rejected credentials or a connect that throws report it, then fail the call. The ringback is cut short then, since the call has moved on. An `.error` that a connected call only logs is only logged.
- What the user or the system does applies to the call as it stands, connecting: ending it is a `.canceled` call that was never reported connected, a provider reset fails it, mute, interruptions and a deactivation change only the mic. A hold stops the wait with the ringback, and the resume starts both again, the wait in full.

<a id="mic-withhold"></a>**Keeping the mic closed for your own sounds.** The engine opens the mic as soon as the call is connected and CallKit has activated its audio, and keeps it closed while the call is connecting, so a ringback needs nothing. If your app plays something when the call connects, such as a spoken "Connected", the mic picks it up, and on the loudspeaker the agent hears it: its speech recognition may take it for the user, and it may stop talking to listen. `setMicWithheld(true)` keeps the mic closed while you play; `setMicWithheld(false)` gives it back, and only then is the agent told the user is on the line (`call-connected`).

- It is one more input to the [one mic rule](#4-audio-session-ownership): the mic is on only when every other condition holds and you are not withholding it. Releasing re-derives the mic from the rule, so a call the user muted, or that is held or interrupted, stays closed.
- It is not mute. `isMuted`, CallKit's mute state and the system call UI do not change, and nothing but the mic and the timing of `call-connected` does: the agent stays audible, and states, cues, records, attach and detach are what they would be without it. Show `isMicWithheld` if you want the user to see why the mic is closed.
- It does not silence the agent. Only the user's mic is closed; anything the agent says while you play is heard over your sound.
- Call it at any time, including before a call exists (it applies to the next call) and from inside `callEngine(_:cue:)`. It is synchronous: a withhold made inside a cue is in place before the engine's mic command for the change that delivered the cue, so withholding at `.moment(.connected)` (and `.moment(.reconnected)`, if you speak there too) closes the mic before the engine would open it.
- It ends with the call, however the call ends (an unanswered ring included), so a withhold you forget to release does not reach the next call. Release it yourself in every path where your sound will not play: the call ends or fails while connecting, a hold (`.moment(.held)`), a provider reset.
- It is bounded. Once the call is connected with its audio activated (or from the withhold, if later), the engine releases a withhold after `CallEngineConfiguration.micWithholdTimeout` (default 5 seconds) and logs a warning through `CallEngineLog`, so a release that never comes, a sound that never reports its end, cannot leave the user with a mic that is silently dead. Set the timeout a little beyond your longest connected sound. A release before then stops the bound; a later withhold gets a bound of its own.

A host that withholds through its "Connected":

```swift
func callEngine(_ engine: CallEngine, cue: CallCue) {
    switch cue {
    case .start(.connecting) where engine.activeCall?.direction == .outgoing:
        announcer.startRepeating(.connecting) // the mic is closed until the call connects
    case .moment(.connected) where engine.activeCall?.wasReadyAtAnswer == true:
        break // nothing to play, nothing to withhold: the agent is told at once
    case .moment(.connected), .moment(.reconnected):
        engine.setMicWithheld(true)
        announcer.announce(.connected) { engine.setMicWithheld(false) } // the agent is told now
    case .moment(.held):
        engine.setMicWithheld(false) // the "Connected" it waited for will not come now
    // ... the other cues as above
    @unknown default: break
    }
}
```

A real host also checks that the completion belongs to the call it was made for, since a phrase can finish after its call ended and the next one began.

**Missed calls.** The engine posts no notifications. A record with a non-nil `missedReason` is a ring nobody answered or declined: `.busy` (another call was up) and `.filteredByFocus` never reached the user, while `.ringTimedOut` (it rang out) and `.canceledByCaller` (the server withdrew it) did; `missedReason.reachedUser` tells the two groups apart. Post a local notification for them if you want the user to know. Provisional notification authorization lets you deliver these quietly without an upfront permission prompt.

## 10. Writing your own transport

A transport carries audio between the device and the agent. Conform to `CallTransport`:

| Requirement | Contract |
|---|---|
| `events: AsyncStream<TransportEvent>` | The only way state leaves the transport. The engine reads it once per call, from creation until teardown. |
| `connect(_:) async throws` | Join `connection.url` with `connection.token`. Called once per attempt: first connect (unless a `.media` ring joined you with `connectWhileRinging(_:)`), then once per engine reconnect attempt, on the same instance, which can be while your SDK is still healing the previous session (see the rules below). Throw `TransportError.authenticationFailed` only for credentials the server rejected; it ends the call at once, even mid-reconnect. |
| `connectWhileRinging(_:) async throws` | The join of a `.media` ring, made during the ring before the answer, once per ring and only when `canConnectWhileRinging` is true; every later connect of the call is `connect(_:)`. Same contract as `connect(_:)`, plus `canConnectWhileRinging`'s. Optional: the default calls `connect(_:)`. Implement it when a join during a ring must differ from one for a call already under way, as the Daily adapter's does (it holds the agent's audio back until the first attach). |
| `disconnect() async` | Leave because the call is over. If your protocol has an explicit "end call" signal, send it here (see [section 11](#11-what-the-server-side-must-do)). |
| `setMicEnabled(_:) async` | Capture on or off. Can arrive before `connect` finishes; it must be harmless then, because the engine sets it again after `.connected`. Also used to pause the mic during interruptions. |
| `availableAudioDevices() async`, `selectedAudioDevice() async`, `setAudioDevice(_:) async` | The routes the user can pick, and switching between them, through your SDK so it does not revert the choice. |
| `attachAudioSession() async` | CallKit has activated the session and the call is not on hold: start audio I/O on it. Never activate the session or change its category yourself. Can be called before `connect`, again after an interruption, and on resuming from hold; make it idempotent. |
| `detachAudioSession() async` | CallKit deactivated the session, the call was put on hold, or the call is ending: stop audio I/O, playout included. Can be called mid-call, and twice in a row (a hold followed by CallKit's deactivation). |
| `send(_:) async -> CallSignalDelivery` | Declare it with exactly this signature: a `send(_:)` that returns nothing, or anything else, does not implement the requirement, and the engine then uses the default, which silently drops every signal. Deliver a `CallSignal` (`connected`, `held`, `resumed`) to the agent, and say what became of it: `.sent` once it is handed to the connection, `.failed` when it could not be (no connection, refused, or not handed over within your bound), `.unsupported` if you carry no signals. Optional: the default implementation drops it and returns `.unsupported`. Best effort: the engine never waits on a delivery for anything else, and sends only once the transport has reported `.connected`. After `.failed` it sends the call's current state again (not necessarily the same signal), after 1, 2, 4, 8, 16 and 30 seconds while the result stays `.failed`, then waits for the next connection, which is told the state anyway; `.unsupported` is never retried. Must not throw, must return promptly when the connection is gone (bound your wait), and may get the same signal again (`held` is repeated after every reconnect of a held call, `connected` after every reconnect, `resumed` until one is `.sent`). |
| `canConnectWhileRinging: Bool` | Whether the engine may join you while an incoming call still rings, with `connectWhileRinging(_:)` ([pre-connect](#pre-connect)'s `.media` tier). Optional: the default is `false`, which keeps the transport at `.credentials`. Return `true` only if, until `attachAudioSession()`, that join and everything it starts leave `AVAudioSession` alone (no category, mode, option or route change, no activation), start no audio input or output, and make nothing from the remote party audible, and your `send(_:)` reaches the agent, which waits for `call-connected`. Read once per ring, right after `makeTransport`. |

Rules that come from the device bugs this code survived:

- **`connect` must not undo an attach.** If attach can come before or during connect, track whether you are attached and have `connect` apply the current state, rather than resetting audio to "off" unconditionally. An unconditional reset after a slow credential fetch is what produced a dead mic on the first call after launch.
- **Being held is detach plus the mic.** The engine calls, in this order on hold: `setMicEnabled(false)`, `detachAudioSession()`, and, if connected, `send(.held)`. CallKit may then deactivate the session, which brings another `setMicEnabled(false)` and `detachAudioSession()`. On resume: `attachAudioSession()` (only if the session is still or again activated; otherwise at CallKit's next activation), `setMicEnabled(_:)` with the rule's answer, and, if connected, `send(.resumed)` once those two have returned (as `send(.connected)` waits for the attach and mic commands before it). Mic and attach commands reach the transport one after another in the order the engine issued them; signals go in their own ordered queue, so a slow `send` never delays the mic. Your `detachAudioSession()` must stop playout as well as capture, or the user hears the agent while on another call, and your `attachAudioSession()` must restart both. Keep the connection up while held.
- **Joining during a ring.** With `canConnectWhileRinging` true, the engine calls, during a `.media` ring: `connectWhileRinging(_:)` once, and nothing else: no `attachAudioSession()`, `setMicEnabled(_:)`, `send(_:)`, route reads (`availableAudioDevices()`, `selectedAudioDevice()`) or `setAudioDevice(_:)`. It reads your events then, but only to follow the preparation. If the ring ends unanswered, it calls `disconnect()` (no `detachAudioSession()`, since nothing was attached), possibly while that join is still under way. If the agent is not there within `joinTimeout` of the join returning, the engine drops the preparation (`disconnect()`, during the ring). If the user answered first, it instead calls `connect(_:)` again, on the same instance, with fresh `.answered` credentials, so the same rule as for a reconnect attempt applies: take the earlier session over. When the user answers with the agent there, the transport becomes the call's at once: `setMicEnabled(false)` (CallKit has not activated yet), then, after CallKit's activation, `attachAudioSession()`, `setMicEnabled(_:)` with the rule's answer, `send(.connected)`, and the route work (`availableAudioDevices()`, `selectedAudioDevice()`, and `setAudioDevice(_:)` for the hands-free default). When the user answers before the agent is there, the transport is the call's as well, and your `.connected` drives the usual sequence, with the route work waiting for activation. Your ring's join therefore runs long before `attachAudioSession()`, and must apply the attach state current when media starts, as the first rule says.
- **Emit `.connected` once the agent can hear the user**, not when the network connection opens. It drives the call timer, the user's "connected" cue, opening the mic, and `call-connected` (on a call the user placed, after `minimumOutgoingConnectingDuration`, when one is set). Do not make it wait for the local mic: the engine opens the mic only once you have reported it.
- **Follow `.reconnecting` with `.connected` or `.disconnected`.** The engine shows reconnecting while your SDK heals itself and waits up to 30 seconds for one of the two. After that it treats the transport as dropped: it does not call `disconnect()`, but runs its own reconnect, calling the target's `connect` for fresh credentials and then your `connect(_:)` on the same instance, possibly while your SDK is still trying to heal. If `.connected` arrives during the engine's attempt, the call recovers as usual: an attempt still waiting out its backoff or fetching credentials is cancelled, but a `connect(_:)` already under way is left to finish (it is not cancelled, so an SDK join that honours task cancellation is not abandoned), and its outcome is ignored. A hold during the attempt does the same.
- **`connect(_:)` must handle a session that is still up.** When it is called while your SDK is still healing the previous session (or has just healed it), it must leave the transport able to report how the call goes on. It is required to do one of these:
  - Report `.connected` and return, if the session has healed and the agent is there.
  - Take the session over: end it without the end-call signal (the call is continuing), make sure its late callbacks can no longer emit events, and join afresh with the new connection.
  - Throw a `TransportError` other than `.authenticationFailed`, without changing anything the SDK's heal still reports through. The engine counts the attempt and retries with backoff; the heal's own `.connected` recovers the call, and its failure must still arrive as `.disconnected(reason: .networkDropped)`.

  Never reset your reporting state for a connect that then does not join (the heal's outcome would go unreported and every later attempt would fail the same way), and never return normally without a join under way: after a reconnect attempt returns, the engine waits for `.connected` or `.disconnected` only for `joinTimeout` (30 seconds by default), then counts the attempt as failed and calls `connect(_:)` again for the next one. Both bundled adapters throw while their SDK is still healing (see [section 11](#11-what-the-server-side-must-do)), because leaving and rejoining discards the SDK's own recovery and shows the agent a departure.

  Not every session that is still up is healing. When the engine calls `connect(_:)` on a session that joined but never reported `.connected` (the previous attempt's join deadline ran out, or a hold paused that attempt and the resume started another), it has given up on that join, usually in favour of fresh credentials for another room. Refusing then fails every remaining attempt (and, on a backend that starts an agent per credential request, strands one each time); take that session over instead. The Daily adapter does.

**Events.**

| Event | Engine reaction |
|---|---|
| `.connecting` | None (already reflected). |
| `.connected` | `connecting -> connected`, or `reconnecting -> connected`. Ignored in other states, so a duplicate is harmless. |
| `.reconnecting` | While connected, show `reconnecting(attempt: 0)` without spending a retry. If neither `.connected` nor `.disconnected` follows within 30 seconds, the engine starts its own reconnect as for a drop. |
| `.disconnected(reason: .requestedByUser)` | Ignored: the engine's own teardown caused it. |
| `.disconnected(reason: .botLeft)` | The agent hung up: `ended(.completed)`, or `ended(.noAnswer)` if the call never connected. |
| `.disconnected(reason: .networkDropped)` or `.unknown` | Never connected: `failed(.transportError)`. Connected or reconnecting: schedule the next reconnect attempt. |
| `.disconnected(reason: .authFailed)` | `failed(.badToken)`, in any state. |
| `.error(.authenticationFailed)` | While connecting or reconnecting: `failed(.badToken)`. Otherwise logged. |
| `.error(_)` | While connecting: `failed(.transportError)`. Otherwise logged; a mid-call error does not end the call. |
| `.botStartedSpeaking`, `.botStoppedSpeaking` | Update `isBotSpeaking`. |
| `.audioDevicesChanged` | Refresh `audioDevices` and `selectedAudioDeviceID`, and apply the hands-free default if not yet applied, once CallKit has activated the session (before that, ignored: the activation refreshes them). |
| `.userStartedSpeaking`, `.userStoppedSpeaking`, `.remoteAudioLevel` | Not exposed to hosts in this version. |

"Bot left" versus "network dropped" is the decision that matters most. Report `.botLeft` only when the agent has deliberately left a call that was established (the call then ends normally). Report `.networkDropped` when the connection was lost (the engine reconnects). Report `.requestedByUser` for a disconnect that follows your own `disconnect()`. Mixing them up either turns a recoverable drop in a tunnel into a dead call, or keeps redialing an agent that hung up.

**Errors.** Map SDK errors to `TransportError` inside the adapter so no SDK type leaks out. How the engine reads them:

- `TransportError.authenticationFailed` thrown from your `connect`, or from the target's `connect` closure, becomes `failed(.badToken)`, on the first connection or on a reconnect attempt. Any other error on the first connection becomes `failed(.transportError)`.
- During a reconnect attempt, any other error counts as a failed attempt and schedules the next one, until the budget is spent and the call fails with `.lostConnection`.
- `.connectionFailed` and `.underlying` are only distinguished in logs.

**Audio device ids.** The hands-free default and `AudioRouteKind(deviceID:)` classify routes by keywords in `AudioDeviceInfo.id`: `speaker` (without `bluetooth`), `bluetooth`, `earpiece` or `receiver`, `wired` or `headphone`. Use ids containing these, or the engine cannot tell a speaker from a headset.

**Concurrency.** The protocol is not actor-isolated, but the engine calls it from the main actor and `CallTarget.makeTransport` runs on the main actor. Both adapters and `FakeTransport` are `@MainActor` classes; that is the simplest shape, and an `actor` works too. Its two synchronous requirements, `events` and `canConnectWhileRinging`, are nonisolated, so such a type declares them `nonisolated` (`nonisolated let events`, and `nonisolated var canConnectWhileRinging: Bool { true }` if you override the default); the async requirements can stay isolated. Both shapes compile without warnings in the Swift 6 language mode: the package's own `ConduitCallEngineSwift6Tests` target builds one of each, with a delegate, in that mode.

```swift
import ConduitCallEngine

@MainActor
final class MyTransport: CallTransport {
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    private var isAttached = false

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
    }

    // Only if your connect(_:) leaves the audio session alone until the attach
    // (see the table above); otherwise leave it out and get the default, false.
    nonisolated var canConnectWhileRinging: Bool { false }

    func connect(_ connection: CallConnection) async throws {
        // Join connection.url with connection.token, starting audio only if isAttached.
        // Yield .connected once the agent is present and ready.
    }

    func disconnect() async {
        // Send your end-call signal, then leave. Report .requestedByUser, not .networkDropped.
    }

    func setMicEnabled(_ enabled: Bool) async {}

    func availableAudioDevices() async -> [AudioDeviceInfo] { [] }
    func selectedAudioDevice() async -> AudioDeviceInfo? { nil }
    func setAudioDevice(_ id: String) async {}

    func attachAudioSession() async {
        isAttached = true
        // Let your audio engine run on the session CallKit activated.
    }

    func detachAudioSession() async {
        isAttached = false
        // Stop audio I/O.
    }

    func send(_ signal: CallSignal) async -> CallSignalDelivery {
        // Publish signal.rawValue to the agent; .sent once it left, .failed if it could not.
        .unsupported
    }
}
```

## 11. What the server side must do

The engine joins whatever room `connect` returns. Your server must put an agent there and behave as each adapter expects.

### When your agent should start speaking

**One rule: greet when `call-connected` arrives, not when the session connects.** It applies to a client that says it sends `call-connected`; for any other client, greet as you always have, when the client is ready.

The message is an RTVI client message, in the same envelope as `end-call`:

```json
{"id": "<8 characters>", "label": "rtvi-ai", "type": "client-message", "data": {"t": "call-connected"}}
```

On Daily and SmallWebRTC a Pipecat bot sees it in the RTVI processor's client-message event (`message.type == "call-connected"`); on LiveKit, parse it from the transport's raw data-received event, as `end-call`.

It means the user is on the line and can hear you. The engine sends it on every call, placed or answered, pre-connected or not, once all of these hold, whichever comes last: the call is connected (your agent is there and, on a call the user placed, the host's `minimumOutgoingConnectingDuration` has passed), iOS has activated the call's audio, the call is not on hold, and the app is not withholding the user's microphone while it plays its own "connected" sound. The user's microphone has been opened by then. A muted user, or one in push-to-talk mode, is on the line too: being muted does not delay it. Before it, the device can already be in the room and hear you (while the app plays its ringback, or, for a ring prepared at `"media"`, before the user has answered), which is why a greeting on the device's join or on client-ready comes too early.

It is a statement of state, not an event to count. It is sent again on every new connection after a reconnect (the session behind it may be a new one) and again when it could not leave the device, and it is combined with `call-held` and `call-resumed` like this: the user is on the line once you have had `call-connected`, and away while the latest of `call-held`, `call-resumed` and `call-connected` is `call-held` (`call-connected` is never sent while the call is held). Speak only while the user is on the line. Greet at the first `call-connected` of a call; a later one is the same call coming back, not a new one. A call that connects while it is on hold gets `call-held`, then, at the resume, `call-resumed` and `call-connected`.

**How your server knows the client sends it.** A host lists the signals its calls carry as `call_signals`, the raw values of `CallSignal.allCases` (`["call-connected", "call-held", "call-resumed"]`), in the JSON body of every credential request its `CallTarget.connect` makes, and with its VoIP push registration, next to `push_features` ([section 7](#7-delivering-the-voip-token-to-your-server)). Wait for `call-connected` only when the request your agent was started for lists it, or, for an agent started before the device makes any request (a ring with inline credentials), when the device's registration lists it. A request or registration without it (an older app, a third-party client, a direct room with no credential request) promised nothing: greet when the client is ready, exactly as before. A host whose transport does not deliver signals (its `send(_:)` returns `.unsupported`) must not list them.

**The fallback.** A listed signal can still be lost, so do not wait for it forever. Once your agent knows the user answered (from the start for an agent started on an ordinary credential request; for a ring, at the `answered` receipt, or when the device joins a ring it joins only after the answer) and the device is in the room, whichever is later, greet anyway if `call-connected` has not come within a grace period, and treat a `call-connected` that comes later as the next connection's. Make the grace longer than the client's own sequence after it joins: the rest of the host's `minimumOutgoingConnectingDuration` on a call the user placed, its connected sound (bounded by `micWithholdTimeout`, 5 seconds by default), and a margin for iOS activating the audio. Ten seconds covers a host on the engine's defaults with a minimum of a few seconds; the push contract's floor for a ring is 5. Do not greet on the `answered` receipt itself: it is sent at the answer, before the audio is up. Do not let the fallback release or greet while the call is held: the engine sends `call-held` as soon as the device is in the room, also while the call still shows connecting, and a greeting then plays into a call the user cannot hear (on Daily the device has even unsubscribed from your audio), or is dropped by your own output gate while staying in your conversation as if it had been said. Stop the wait on `call-held`, start it again in full on `call-resumed` (after a resume the app runs its sequence again: the rest of the outgoing minimum and its connected sound), and if your agent is already on the line but has not greeted, greet at the resume.

### Getting your agent there before the user answers

For a call your server places, "ready when the user picks up" depends mostly on how long your agent takes to start, not on the phone. In one device ring (Daily, `"media"`, inline credentials) the push went out at once and the phone had joined the room 0.3 seconds later, but the agent only joined at 6.7 seconds (2 to 5 seconds in other rings that day); the user answered at 2 seconds, so the answered call waited 4.6 seconds for the agent. So:

- **Start your agent when you send the push, not when the phone asks for credentials after the answer.** Better still, start it first and send the push once it is in the room, bounding that wait (a few seconds) so a slow agent never holds the ring back. A ring the user answers within a second or two then has the agent waiting.
- **Ask for pre-connect on every ring**, to devices that list `preconnect` in their capabilities: `"media"` when your agent waits for `call-connected` (and the device lists `call-connected` in its `call_signals`), `"credentials"` otherwise ([PushContract.md](PushContract.md#pre-connect)). A device without the capability gets a plain ring, which works as before.
- **Hand the phone the room your agent is in.** With inline credentials the push carries it; otherwise your credential endpoint gets the ring's `call_id` with the request made during the ring (`ConnectRequest.callID`, with `.ringing(joinsBeforeAnswer:)`), so it can return the room it already started an agent in.

What the user experiences, with Conduit as the host (another host's sounds are its own, see [Which call a cue is for](#which-call)):

| Case | What happens |
|---|---|
| **Ready at the answer**: `"media"`, a transport that can join while ringing, and the agent in the room before the user answers. | The call is connected the moment the user picks up. iOS activates the audio a fraction of a second later; the engine then sends `call-connected` (with a host that plays nothing at that point, as Conduit does), and your agent greets the user who is already listening. |
| **Answered before the agent was there**: `"media"`, the device joined, the agent not yet in the room. | The call shows connecting from the answer and becomes connected the moment the agent is there (no outgoing minimum applies to an answered call). Conduit plays no ringback; if it is still connecting a second after the answer it says "Connecting" once, and "Connected" when it connects, then `call-connected` reaches your agent. Every second your agent takes to start is a second of this. |
| **Credentials only during the ring**: `"credentials"`, or `"media"` lowered to it (a transport that cannot join while ringing, or a host that allows less). | Your credential code runs during the ring; the device joins at the answer, so the call is connecting for the join plus the agent's readiness, a second or two if the agent is already in the room, longer if it is only started then. Same sounds as the row above. |
| **Pre-connect failed** (credentials rejected, the room unreachable, a drop, the agent not in the room within `joinTimeout` of the device's join, or the agent leaving before it was there). | During the ring the phone keeps ringing and nothing changes for the user; an answer connects as without pre-connect, with an `.answered` credential request. After the answer, the call stays connecting and makes that `.answered` request once; your endpoint must then return a room with an agent in it. |

**An agent that never arrives fails the call.** After the device's join, the agent has `joinTimeout` (30 seconds by default) to be there. On a ring prepared at `"media"` and answered, that bound counts from the join made during the ring; when it runs out, the call makes its one `.answered` request and joins again, and if that agent is not there within another `joinTimeout`, the call fails as `.agentUnreachable` and the user hears the call end. Without pre-connect, the call fails `joinTimeout` after the join it made at the answer.

### Daily (`PipecatDailyTransport`)

- **Joining.** The Pipecat iOS client joins `connection.url` (a Daily room URL) with `connection.token` (a Daily meeting token).
- **Readiness.** The call becomes `.connected` when the Pipecat client reaches its ready state or the bot reports ready, so the room needs a bot that speaks RTVI and sends bot-ready. A Pipecat pipeline with an RTVI processor does this. For a join made while the call rings it is the bot being in the room instead (below). With no bot, the call stays in `.connecting` until `joinTimeout` fails it as `.agentUnreachable`.
- **End-call signal.** On a deliberate hangup the client sends an RTVI client message of type `end-call` as a Daily app message to everyone in the call, waits 200 ms for it to flush, then leaves. A Pipecat server sees it in the RTVI processor's client-message event. It is sent once the call is joined, whether or not the bot has reported ready; a client that never joined sends nothing.
- **Call-control signals.** `send(_:)` sends each `CallSignal` in the same envelope, with the signal's raw value as `t` (see [Call-control signals](#call-control-signals)), once the call is joined, through the Daily call client's app-message send (the call Pipecat's transport makes, in the form that reports Daily's result), and returns `.sent` once Daily has sent it. Before the join, after `disconnect()`, or when Daily refuses it, it returns `.failed` and logs why, and the engine sends the call's state again.
- **Hold.** While the engine has the transport detached, the client is unsubscribed from every remote participant's microphone track, so the agent is not heard even if it keeps speaking; the next attach subscribes again, and returns once Daily has the subscription (within 2 seconds), so the `call-resumed` the engine sends after it reaches an agent the user can hear. A held call that reconnects joins with the agent unsubscribed.
- **Hold before the agent is ready.** A call held while it is still connecting cannot become ready until the resume: Pipecat's Daily transport sends RTVI client-ready only once the agent's microphone track is playable, which needs it subscribed, and a Pipecat bot sends bot-ready only in reply. That suits an agent that greets on client-ready: it greets when the user is back. The engine does not count the hold against `joinTimeout`, so the call connects after the resume instead of failing as `.agentUnreachable` during the user's phone call.
- **Connecting while ringing.** Supported (`canConnectWhileRinging` is `true`), so a ring can be prepared at the `media` tier. The ring's join (`connectWhileRinging(_:)`) unsubscribes from the agent's audio before it joins, so nothing of the agent can play during the ring, and joins with the mic off, as every join does. The first `attachAudioSession()`, after the answer once iOS activates the call's audio, subscribes again and returns once Daily has the subscription (within 2 seconds), so the `call-connected` the engine sends next reaches an agent the user can hear. Pipecat's client sends client-ready only for playable audio, so the bot cannot report ready while it is unsubscribed: for that join, and any other made before the first attach, the bot being in the room counts as ready. A ring answered with the bot in the room is connected at the answer; one answered before the bot arrives connects the moment it does. Every other join (an outgoing call, an answer that joins after the ring, a reconnect) keeps Daily's default subscriptions and waits for bot-ready, as before. What was observed on one phone (iPhone 17, iOS 27.0, phone locked, app not running): joined unsubscribed, a 20-second ring had no audio activity, and at the answer iOS activated the audio, the adapter subscribed, the agent played cleanly and the route settled within about 0.3 seconds; the same with the app launched cold by the push and an answer 0.7 seconds after the agent was ready. Joined with Daily's default subscriptions instead, no agent audio was heard for the whole call and the route flipped between speaker and earpiece four times in 2.5 seconds; staging the subscription instead of unsubscribing showed no advantage. Your bot must wait for `call-connected` before speaking ([For any transport](#for-any-transport), pre-connect).
- **Agent hangup.** When the bot leaves the room, the call ends as `.completed`.
- **Teardown.** After the end-call signal and the leave, `disconnect()` releases the Pipecat client, which is what frees Pipecat's Daily transport and Daily's call client. A `PipecatDailyTransport` can still be connected again after `disconnect()`; it builds a new client for that.
- **Drops.** When the client's transport disconnects without a hangup, the engine reconnects.
- **Short interruptions.** Daily heals short outages inside its SDK without changing the Pipecat transport state, so the client reports nothing about them. The adapter infers them from the device's network path (`NWPathMonitor`) instead, while the call is connected: when the path stops being satisfied the call shows `reconnecting(attempt: 0)`, and when it is satisfied again the call returns to `.connected` at once, without spending a retry. If Daily gives up during the interruption and disconnects, the engine's reconnect takes over from `reconnecting(attempt: 0)` and the path coming back no longer reports `.connected` for that attempt. If the path is still down after 30 seconds and Daily has not disconnected, the engine starts its own reconnect attempts while Daily is still healing. Those attempts do not rejoin: Pipecat refuses to connect a client that is still in the call, and leaving it would discard Daily's own recovery and show the agent a departure. Each such attempt fails and spends a retry, and the path coming back still reports `.connected`, which recovers the call (if the path is already back when an attempt runs, the attempt reports `.connected` itself). If Daily disconnects in the meantime, that is reported as a drop and the next attempt joins afresh; if the path stays down past the retry budget, the call fails as `.lostConnection`. This reflects the device's network path, not Daily's media state, so it catches losing the network (airplane mode, leaving Wi-Fi with no cellular, a tunnel where the radio drops) but not a path that stays up while packets stop (a captive or dead Wi-Fi, very weak signal), and `.connected` can be announced a moment before Daily's audio has resumed. A change of network that keeps the path satisfied, such as Wi-Fi to cellular, is not reported.
- **A join whose bot never got ready.** When the engine connects again on a client that joined but whose bot never reported ready (a reconnect attempt's `joinTimeout` ran out, or a hold paused the attempt and the resume started another), the adapter takes the session over: it leaves the room without the end-call signal (the call goes on, possibly in the same room, so the agent sees the device leave and come back rather than a hangup), releases that client, and joins the new credentials with a new one. The agent of the abandoned room, if one turns up, is left to its own grace window. Only a call Daily is healing (connected, with the network path down) is refused, as above.
- **Errors.** The adapter maps every connect error to `TransportError.connectionFailed`, so Daily never reports bad credentials itself. Throw `TransportError.authenticationFailed` from your `connect` closure when your own credential endpoint returns 401 or 403.

### LiveKit (`LiveKitTransport`)

- **Joining.** `connection.url` is the LiveKit server URL (`wss://...`) and `connection.token` an access token with a join grant for the room.
- **Readiness.** The call becomes `.connected` once the room is connected **and** at least one remote participant is present. Any remote participant counts as the agent, so dispatch the agent to the room when you mint the token. With no agent, the call stays in `.connecting` until `joinTimeout` fails it as `.agentUnreachable`.
- **End-call signal.** On a deliberate hangup, unless the room is already disconnected or disconnecting, the client publishes this JSON on the room's data channel, then disconnects. A join still in flight (the host called `disconnect()` right after starting a connect, or a ring ended while the device was joining) is given time to finish first, and a reconnecting room gets the signal once LiveKit's data channel is back; `disconnect()` waits at most 2 seconds for all of this before it leaves anyway. A join that had not finished by then leaves the room, with the signal, as soon as it completes: LiveKit ignores a disconnect while it is still setting a connect up, so without that the device would stay in the room with the agent and nobody to leave it.

  ```json
  {"id": "<8 characters>", "label": "rtvi-ai", "type": "client-message", "data": {"t": "end-call"}}
  ```

  The message is published reliably (LiveKit retransmits it instead of dropping it under backpressure). If your agent runs on Pipecat, note that Pipecat's LiveKit transport has not been delivering client data messages to its RTVI processor, so parse this from the transport's raw data-received event.
- **Call-control signals.** `send(_:)` publishes each `CallSignal` in the same envelope, reliably, with the signal's raw value as `t` (see [Call-control signals](#call-control-signals)), under the same rules and the same 2-second bound as the end-call signal, and returns `.sent` once LiveKit took it on the reliable data channel. A room that is disconnected or disconnecting drops it, and that, a failed publish, or the bound running out return `.failed`, after which the engine sends the call's state again. Parse it from the same raw data event.
- **Hold.** While the engine has the transport detached, LiveKit's audio engine is disabled, so nothing plays and nothing is captured; the room, and the agent's subscription, stay up, and the next attach starts the engine again.
- **Connecting while ringing.** Supported (`canConnectWhileRinging` is `true`): joining the room configures no audio session and starts no audio. The agent's audio is subscribed but not played, and the mic is not published, until the engine attaches after CallKit activates the session. `send(_:)` reaches the agent as soon as the room is connected. Observed on one phone (iPhone 17, iOS 27.0, phone locked, app not running): the phone joined during the ring with no audio activity, the agent was ready 1.8 seconds after the push, the user answered at 2.4 seconds and the call was connected at that instant, iOS activated the audio 0.2 seconds later, and nothing was heard from the app before the answer.
- **Agent hangup.** When the last remote participant leaves a connected call, the call ends as `.completed`, including when it left during an outage LiveKit then recovered from. If another remote participant remains, the call continues. An agent that was in the room the device joined (it arrives with LiveKit's join response) and leaves before the room is connected is reported the same way: a pre-connected ring then drops its preparation, and a call the user placed ends as `.noAnswer` instead of waiting out `joinTimeout`.
- **Drops.** A room disconnect without a hangup triggers the engine's reconnect. LiveKit's own reconnects show as `reconnecting(attempt: 0)` and recover without spending a retry. A reconnect LiveKit reports as complete counts as recovered only if the room is connected and a remote participant is present, the same rule as the first connect. A reconnect LiveKit gives up on is reported as a network drop, so the engine's own reconnect runs and, if the outage lasts, the call fails as `.lostConnection`. If LiveKit rejoins the room and no remote participant is there, the agent left while the device was offline, and the call ends as `.completed`, as it does when the agent leaves a connected call; the engine does not redial. If LiveKit's own reconnect has not finished after 30 seconds, the engine starts its own reconnect attempts; while LiveKit is still reconnecting the room, those attempts do not rejoin (rejoining the same room mid-reconnect can leave the call reconnecting with nothing left to report it) and each fails and spends a retry, so LiveKit's reconnect, which LiveKit bounds by its own attempt count, still decides: its completion recovers the call, and giving up is reported as a drop, after which the next attempt joins afresh with the target's fresh credentials. If the room has already healed with the agent present when an attempt runs, the attempt reports `.connected` itself.
- **LiveKit 2.18.0 or later.** The package requires it. From that version every reconnect LiveKit gives up on ends with the room disconnected, which is how the adapter tells a failed reconnect from a successful one; earlier versions could report one as complete with the room still marked connected (client-sdk-swift PR #1144).
- **One join at a time.** LiveKit's `Room` cannot run two connects at once (each one's cleanup fails the other). A `connect(_:)` that arrives while an earlier join is still in flight (a hold and resume during a reconnect attempt's join make the engine start the attempt again at once) cancels that join, waits for its cleanup, and then joins.
- **Errors.** A connect error becomes `.authenticationFailed` (`.badToken`, which ends the call at once, also during a reconnect) only when LiveKit's validation request was answered 401 or 403, or LiveKit reports insufficient permissions. After a failed join, LiveKit asks the server's validation endpoint why; a token the server rejects (expired, wrong key, no grant for the room) is answered 401 or 403. Every other error, including a validation request that could not be made because the device is offline, becomes `.connectionFailed`, which a reconnect retries. LiveKit's own reconnects skip that validation, so an expired token there shows up as a drop, and the engine's next attempt fetches fresh credentials from your `connect` closure.

### Call-control signals

The engine tells the agent when the user is on the line, and when the user's side holds and resumes the call, through `CallTransport.send(_:)`. A transport carries each `CallSignal` as an RTVI client message, the same envelope as the end-call signal, with the signal's raw value as `t`:

```json
{"id": "<8 characters>", "label": "rtvi-ai", "type": "client-message", "data": {"t": "call-held"}}
```

| `t` | Meaning | What the agent should do |
|---|---|---|
| `call-held` | The user's side put the call on hold. The user cannot hear the agent and their mic is closed. | Stop speaking (interrupt any response in progress), take no turns, and keep the session. If the user's media disappears while held, wait much longer than the usual drop grace window (the hold can last as long as the user's phone call) before giving up. |
| `call-resumed` | The call is back. | Resume normally. |
| `call-connected` | The user is on the line: the call is connected, CallKit has activated its audio, it is not held, and the app is not withholding the mic. On every call. | Start speaking (greet), once; see [When your agent should start speaking](#when-your-agent-should-start-speaking). |

Signals are best effort and can repeat: `call-connected` is sent again after every reconnect, `call-held` after every reconnect of a held call, and `call-resumed` after a reconnect that follows a resume the agent may have missed. A signal the device could not send is sent again, as the call's current state, a few times over about a minute and on the next connection, so an agent that closed its audio on `call-held` converges on the resume even if one message was lost. Treat each as the current state, not a toggle, and ignore names you do not know. Both bundled adapters deliver them: on Daily through the RTVI processor's client-message event (`data.t`), on LiveKit through the raw data-received event, exactly as the end-call signal. A transport that does not implement `send(_:)` delivers nothing; the call works the same, and the agent simply hears silence while the call is held.

### For any transport

- **Honor the end-call signal.** A dropped connection and a hangup look the same from the server unless the client says which it is. Because the engine reconnects after drops, your agent should hold the room for a grace window when the user's media disappears. When the end-call signal arrives, tear down immediately instead. If you ignore it, every hangup keeps your agent in the room (and billing) for the full grace window, and nothing on the device will tell you.
- **Size the grace window to the engine's backoff.** The engine waits 1, 2, 4, 8, 16 and 30 seconds before its six attempts, a little over a minute in total plus connection time. When the transport first reports that it is healing itself, the engine waits up to 30 seconds for it before that backoff starts, so the device can still be trying for about a minute and a half after its media stopped. A shorter window cuts off drops the device would have recovered from. A held call does not reconnect until it is resumed, so after `call-held` (see [Call-control signals](#call-control-signals)) use a much longer window.
- **Reconnects call your credential code again.** Each attempt re-runs the target's `connect`. Your endpoint may return the same room (the agent is still waiting there) or a fresh room with a newly dispatched agent; either works, as long as an agent is present when the device arrives. Inline credentials from a push are reused if your `connect` closure keeps returning them, so they must stay valid for the length of the call.
- **The signal is best-effort.** The engine's teardown calls `disconnect()` for every ending (user hangup, agent hangup, failure, and a pre-connected ring that ends unanswered), and the adapters send the signal only while the connection is up. A connection that died never sends it, which is exactly when the grace window should apply.
- **Pre-connect.** If your server sends `preconnect`, its agent may see the device join while the phone rings and must wait for `call-connected` before speaking; leaving the room before the answer withdraws the ring. The obligations are in [PushContract.md](PushContract.md#pre-connect).

## 12. Simulator and unit testing

CallKit and PushKit do not work in the iOS Simulator, and both WebRTC SDKs abort when they start audio there (an uncatchable abort in the voice-processing audio unit, after signaling appears to succeed). Never construct `PipecatDailyTransport` or `LiveKitTransport` in a simulator build.

`ConduitCallEngineTesting` provides:

- `CallEngine.simulated(configuration:system:now:sleep:)`: an engine over a `SimulatedCallSystem` instead of CallKit, PushKit, the audio-interruption source and receipts. `system` defaults to nil, which gives the engine a fresh system of its own; pass one you keep when you want to drive the engine.
- `SimulatedCallSystem`: stands in for those services, lets you drive them, and exposes what the engine reported.
- `FakeTransport`: a `CallTransport` that records what the engine did and emits events you give it.

**In the app.** Choose the engine and transport by build environment:

```swift
#if targetEnvironment(simulator)
let engine = CallEngine.simulated()
#else
let engine = CallEngine()
#endif
```

and in `makeTransport`, return a `FakeTransport(reportsConnectedAfter: .seconds(1))` in the simulator, as `Example/` does, so a call reaches the connected state by itself a second after it connects. A plain `FakeTransport()` reports `.connected` only when you emit it.

**In unit tests.** `SimulatedCallSystem` drives the system side. Every step is deterministic: a test never needs to sleep or poll. Each driver either returns once the engine has applied it (`answerIncomingCall()`, `activateAudioSession()`, `setHeldFromSystem(_:onHold:)`) or takes effect at once in the engine's state and is followed, where the test checks the transport, by `awaitPendingWork()`.

| Member | Does |
|---|---|
| `deliverPush(_:completion:)` | PushKit delivers a VoIP push. Requires `engine.startPushRegistration()`. |
| `deliverVoIPPushToken(_:)`, `invalidateVoIPPushToken()`, `voipPushToken` | PushKit issues or invalidates a token; the token it holds. |
| `answerIncomingCall() async` | The user answers; returns once the connect attempt has run. |
| `endCallFromSystem(_:)` | The user ends or declines from the system UI. |
| `setMutedFromSystem(_:muted:)` | The user toggles mute from the system UI. Ignored unless `callID` is the live call's. |
| `setHeldFromSystem(_:onHold:) async -> Bool` | The user or iOS holds or resumes the call (iOS does this for a phone call). Returns whether the engine performed the action, once the engine has applied it to the transport (mic, attach, the agent's signal). |
| `startOtherCall() -> UUID`, `setOtherCallHeld(_:onHold:)`, `endOtherCall(_:) async`, `otherCallIDs` | Another call on the device (a phone call) starts, is held or resumed, and ends, as CallKit's call observer reports it. Starting one changes nothing by itself; show iOS holding the engine's call for it with `setHeldFromSystem(_:onHold: true)`. `endOtherCall(_:)` returns once the engine has done what it does then: with `resumesAfterSystemHold` and no other call left, it resumes a call iOS held, which shows in `holdRequests`. As on a device, the audio is not activated by itself after that resume: call `activateAudioSession()`. |
| `resetProvider()` | CallKit resets the provider: a live call fails with `.unknown`, a ring returns to idle, and both are recorded. |
| `outgoingStartError` | While set, every outgoing start throws it, as a rejected start does; the call fails with `.unknown`. |
| `activateAudioSession() async` | CallKit activates the audio session; returns once the engine has attached the transport and applied mic state. |
| `deactivateAudioSession()` | CallKit deactivates the session. |
| `beginAudioInterruption()`, `endAudioInterruption(shouldResume:)` | Another audio session interrupts the call, and the interruption ends. |
| `deliverTransportEvent(_:)` | The live transport emits an event, delivered synchronously. Delivered only while a call has a transport (the only time a real transport's events reach the engine), including a ring's pre-connecting one; returns whether it was delivered. |
| `awaitPendingWork() async` | Waits until the engine has finished what it started by itself, and what that started: CallKit's activation, every attach, detach and mic command, every signal, route refreshes and the hands-free default, a call's teardown (`detachAudioSession()`, `disconnect()`), a ring transport's disconnect, and the unprepared connect after a failed preparation. Not a reconnect attempt, a ring's preparation, a timer, or an event emitted with `FakeTransport.emit(_:)`; a connect or attach the test holds open keeps it waiting. |
| `awaitPendingReconnect() async` | Waits for the reconnect attempt in flight (the target's `connect` and the transport's `connect(_:)`), once its backoff is over. |
| `awaitRingPreparation() async -> RingPreparationPhase` | Waits until the ringing call's preparation has done what it does by itself (the target's `connect` for the ring has returned and, at the `.media` tier, the ring transport's `connect(_:)` too), and returns `ringPreparationPhase`. Returns at once when nothing is being prepared. |
| `fireTimer(_:) -> Bool` | Runs one of the engine's timers out now, as if its wait were over: `.ringTimeout`, `.joinTimeout`, `.transportHealTimeout`, `.reconnectBackoff`, `.signalRetry`, `.micWithholdTimeout` (the bound on `setMicWithheld(true)`, running once the call is connected with its audio activated), `.minimumOutgoingConnectingDuration` (the rest of the outgoing minimum, running while a placed call whose transport is ready is held in `.connecting`; firing it reports the call connected; it never runs for an incoming call), `.activationRecovery` (the 2 seconds CallKit is given to activate a resumed call's audio; firing it makes the engine hold and resume the call through CallKit to ask again, which shows only in `holdRequests`). Returns whether it was running. The engine does exactly what it does when that wait ends. |
| `incomingReportResult` | How CallKit answers incoming reports: `.rings`, `.filteredByFocus`, `.duplicateCallID`, `.fails(_)`. Like CallKit, the simulated system also answers `.duplicateCallID` on its own for an id it holds (a call started or reported and not yet ended), which is what a cancel push for the ringing call meets. |
| `completesIncomingReportsLater`, `completeIncomingReports()` | Hold CallKit's report completions and release them. By default reports complete before the report call returns, which real CallKit never does; set this to test the device's ordering, such as an answer that arrives before CallKit accepts the report. |
| `suspendsOutgoingStarts`, `pendingOutgoingStartCount`, `releaseOutgoingStarts()` | Hold outgoing call starts, to test ending a call while it dials. |
| `startedCallIDs`, `reportedIncomingCalls`, `updatedCalls`, `ringReceipts`, `holdRequests` | What the engine reported or requested, in plain types. Each outgoing call gets a CallKit id of its own. `ReportedCall`, `RingReceipt` and `HoldRequest` have public initializers, so you can write expected values. Like CallKit, the simulated system performs each requested hold through the engine, for a call it holds that was reported as holdable. |
| `reportedSupportsHolding(_:) -> Bool?` | Whether the engine last reported a call as holdable (`CallEngineConfiguration.supportsHolding`); nil for a call it never reported. |
| `presentConnectedCall(_:secondsElapsed:botSpeaking:) -> Bool` | Puts a connected call on the engine's observed state without CallKit, a transport or any delegate callback, for screenshots of your in-call UI. Works only on the engine `CallEngine.simulated` made for this system; returns false otherwise. |

**Time.** The engine's timeouts and backoffs wait on the `sleep` given to `CallEngine.simulated`, real time by default, so in a fast test none of them runs out by itself: keep the default configuration and end the one you want with `fireTimer(_:)`. A clock you pass as `now:` makes `CallRecord.duration` deterministic. A `sleep` that returns at once also works, for instant reconnect backoff, but then every timer runs out on the engine's next suspension, every ring times out and every call waiting for its agent fails as `.agentUnreachable`, so pair it with `configuration: CallEngineConfiguration(ringTimeout: nil, joinTimeout: nil)`.

`FakeTransport` is a main-actor class. It records `connectCount` (every join, a ring's included), `ringingConnectCount` (the joins made with `connectWhileRinging(_:)`), `disconnectCount`, `lastConnection`, `isMicEnabled`, `micEnabledHistory` (every value the engine set the mic to, in order, to check it never opened), `isAudioAttached`, `sentSignals`, `audioDeviceReadCount` and `audioDeviceSelections` (the route reads and choices the engine made), and `canceledConnectCount` (connects that finished with their task cancelled); `connectError` makes the next connect throw; `suspendConnect` with `releaseConnect()` holds a connect open, and `suspendAttach` with `releaseAttach()` an attach; `signalDeliveries` are the results its next sends return (`.sent` once it is empty); `canConnectWhileRinging` (default false) is what it declares for pre-connect; `emit(_:)` sends an event through the stream (asynchronously, unlike `deliverTransportEvent`); `FakeTransport(reportsConnectedAfter:)` makes one that reports `.connected` by itself that long after each successful connect, for a simulator build.

To test pre-connect, return a target with `ringPreparation: .media` and a `FakeTransport` whose `canConnectWhileRinging` is true, and deliver a push with `"preconnect": "media"`. The engine joins the transport while it rings, with `connectWhileRinging(_:)`; `await system.awaitRingPreparation()` returns once that join has returned, with the phase (`.connecting`, and `connectCount` and `ringingConnectCount` 1); `deliverTransportEvent(_:)` during the ring goes to that transport, so `.connected` makes the phase `.ready`; `answerIncomingCall()` then connects the call at once, and after `activateAudioSession()` and `awaitPendingWork()` the transport is attached and has been sent `.connected`. Activate the session only after `answerIncomingCall()`: an activation during an unanswered ring is ignored, as one left over from an earlier call.

A test of incoming-call handling with Swift Testing:

```swift
import ConduitCallEngine
import ConduitCallEngineTesting
import Foundation
import Testing

@MainActor
final class TestHost: CallEngineDelegate {
    let targetID = UUID()
    let transport = FakeTransport()
    private(set) var records: [CallRecord] = []

    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? {
        guard call.targetID == targetID else { return nil }
        return CallTarget(
            id: targetID,
            displayName: "Assistant",
            handle: nil,
            makeTransport: { [transport] in transport },
            connect: { _ in CallConnection(url: URL(string: "https://example.invalid/room")!, token: "t") }
        )
    }

    func callEngine(_ engine: CallEngine, didFinish record: CallRecord) {
        records.append(record)
    }
}

@MainActor
@Test func answeredRingConnectsAndIsRecorded() async throws {
    let system = SimulatedCallSystem()
    let engine = CallEngine.simulated(system: system)
    let host = TestHost()
    engine.delegate = host
    engine.startPushRegistration()

    let callID = UUID()
    system.deliverPush(["target_id": host.targetID.uuidString, "call_id": callID.uuidString]) {}
    #expect(engine.state == .incomingRinging)
    #expect(system.reportedIncomingCalls.first?.displayName == "Unknown")
    #expect(system.updatedCalls.first?.displayName == "Assistant")

    await system.answerIncomingCall()
    #expect(host.transport.connectCount == 1)
    #expect(system.deliverTransportEvent(.connected))
    await system.activateAudioSession()
    #expect(host.transport.isAudioAttached)
    #expect(host.transport.isMicEnabled)
    guard case .connected = engine.state else {
        Issue.record("expected .connected, got \(engine.state)")
        return
    }

    system.endCallFromSystem(callID)
    #expect(engine.state == .ended(.completed))
    #expect(host.records.map(\.outcome) == [.completed])
}
```

A simulated engine activates the audio session only when you call `activateAudioSession()`. Until then `isAudioActivated` stays false and the engine never attaches the transport, so in an app running the simulated engine, a `FakeTransport` is never attached unless you drive activation yourself. The simulation tests the engine's logic against your host code; it cannot tell you how a real SDK behaves under CallKit, which only a device shows.

## 13. Device verification checklist

Run these on a physical iPhone with a release-like build before shipping. Keep Console open, filtered to your bundle id: the engine logs under your app's subsystem, in categories named `[Call]`, `[CallKit]`, `[Transport]`, `[Audio]` and `[Network]`. A release build logs only warnings and errors unless you lower `CallEngineLog.minimumLevel` ([Logging](#logging)); the checks below that quote info messages need it at `.info`.

Outgoing:

- [ ] First call after a fresh launch (force-quit, relaunch, call at once): two-way audio, the mic indicator appears, the agent hears you. Repeat a few times; this is where activation-order bugs show.
- [ ] A call while the app is already warm: same result.
- [ ] Lock the screen mid-call: audio continues; end from the lock screen; exactly one `CallRecord`.
- [ ] End in-app: your server logs an immediate teardown from the end-call signal, not a grace-window expiry.
- [ ] The agent hangs up: the call ends as `.completed`.
- [ ] Bad credentials: the call fails as `.badToken`, not `.transportError`.

Audio:

- [ ] With nothing connected, the call plays on the loudspeaker. With AirPods or a car connected, it stays there.
- [ ] Connect AirPods mid-call: the route list updates; the in-app picker moves audio both ways.
- [ ] LiveKit: the native call screen's route button moves audio. Daily: confirm your in-app picker works, since the native button cannot.
- [ ] Mute from the system UI and in-app: both stay in sync.
- [ ] Invoke Siri mid-call: the mic pauses and comes back afterwards.
- [ ] Have a second phone call the device's number mid-call and accept it (iOS may offer Hold & Accept, or hold the engine call by itself): the engine call is held, not ended (`isOnHold`, the agent goes quiet and, if your server logs it, receives `call-held`). Console shows `Call held by the system`, then `CXProvider didDeactivate audio session` (possibly several times) and an interruption beginning. Then have the other phone hang up, without touching the device: within a moment Console shows `The call the system held for ended; resuming` and `Call resumed`, the agent receives `call-resumed`, and two-way audio is back within about a second, with no "interrupted" state left (`isInterrupted` false, the mic open). If CallKit does not activate the audio at once, Console shows `CallKit did not activate the audio within 2 seconds of the resume; holding and resuming the call to ask again (1 of 3)`, followed by `CXProvider didActivate audio session`; audio is then back within about 2 to 3 seconds of the hang-up. No `interruption ended` line is needed for any of this. Do this on each adapter you link. Console also shows `[Audio]` `LiveKit detach: audio engine unavailable` and `LiveKit attach: audio engine available` on LiveKit, `Daily agent audio -> unsubscribed (playout stopped)` and `-> subscribed (playout restored)` on Daily.
- [ ] The same, but hang the phone call up yourself, from the device: the same as above (the engine resumes its call by itself once the phone call has ended).
- [ ] The same, but decline the phone call: the engine call is never held (no `call-held`), audio carries on, and nothing is resumed.
- [ ] During a held engine call, a second phone call (call waiting) while the first is still up: the engine call stays held until both phone calls have ended, then comes back as above.
- [ ] Daily: during the hold, have the agent keep talking (or use a test agent that plays a tone): nothing of it is heard on the phone call or on the device.
- [ ] Place a phone call from the Phone app during an engine call: the engine call is held, and comes back by itself when the phone call ends.
- [ ] Hold and resume from your own UI, if you offer it, with no other call: `call-held` on the hold; on the resume `call-resumed`, `CXProvider didActivate audio session` within about a tenth of a second, and two-way audio. Console shows no `asking again` line. A hold from your UI stays held when a phone call taken during it ends: only your resume brings the call back.
- [ ] Stay on hold longer than a minute: the engine call survives (a connection that drops during the hold reconnects after the resume).
- [ ] Hold before the agent is ready (place a call and hold it within a second or two, before the agent greets; on Daily the agent cannot get ready while held), stay held 40 seconds, resume: the call connects and the agent greets after the resume; it does not fail as `.agentUnreachable`.
- [ ] After a resume, the agent's log shows `call-resumed` once, after the device's audio is back (Daily: after `Daily agent audio is subscribed` in Console). With the network degraded at the moment of the resume, Console may show `did not leave the device; sending the call's state again`, followed within a few seconds by the signal sent.
- [ ] CarPlay, if you support driving: place, take and end calls from the car.

Network:

- [ ] Airplane mode for about ten seconds mid-call, on each adapter you link: `reconnecting(attempt: 0)` when the network goes, then `connected` when it returns, with audio back.
- [ ] Airplane mode for several minutes: the call fails as `.lostConnection` once the retries are spent.
- [ ] Daily, with a backend that answers the first reconnect request with a room whose bot never gets ready: after `joinTimeout` Console shows `Daily connect: the session's bot never got ready` and the next attempt joins the next room, and the call recovers, instead of every later attempt failing.

Incoming:

- [ ] With the app not running, ring it: the lock screen rings with the right name; answer; two-way audio.
- [ ] Ring with no `display_name`: the name corrects within a moment.
- [ ] Decline: a `.declined` record and a `declined` receipt.
- [ ] Ring during a call: the live call is unaffected; a busy record; a `busy` receipt.
- [ ] Ring with Focus on: no ring, a `.filteredByFocus` record, a `suppressed_by_focus` receipt, your missed-call notification if you post one.
- [ ] Let a ring ring out: it stops after the timeout (or the push's `ring_timeout`), a `.ringTimedOut` record, an `unanswered` receipt, and the Phone app's Recents lists it as missed.
- [ ] Ring, then send a cancel push for it while it rings: it stops, a `.canceledByCaller` record, a `canceled` receipt, the app keeps running. Send the cancel again: a brief flash that ends at once, and later pushes still arrive.
- [ ] Ring with an unknown `target_id`, and with no `target_id` at all: a brief ring that ends, and the app keeps running.
- [ ] Inline credentials and app-fetched credentials both connect.
- [ ] If you use pre-connect, see the pre-connect checks below.
- [ ] A TestFlight build ringed through the production APNs endpoint.

Pre-connect, for each transport whose `canConnectWhileRinging` you rely on, with an agent that plays audio as soon as the device joins (so anything audible during the ring is heard), and again with the app killed and the phone locked:

- [ ] Ring with `"preconnect": "media"`: during the ring nothing from the app is audible, the ringtone and vibration are unaffected, no orange microphone indicator shows, and Console shows no audio-session activation by the app before CallKit's `didActivate`. The agent logs the device joining.
- [ ] Answer: CallKit activates, two-way audio within a second, the agent receives `call-connected` after the activation and after your connected sound, the route is right (AirPods when connected, speaker otherwise), and the in-app route picker works. A sound your host plays on `.moment(.connected)` is heard in full (it comes at CallKit's activation).
- [ ] Ring with an agent that never joins the room, and answer after 10 seconds: the call stays connecting (with whatever your host plays for an answered call), and about 20 seconds later (30 from the device's join) your backend gets an ordinary answered credential request and the call connects to the agent it returns.
- [ ] Ring with an agent that is in the room before the push, and answer: the call shows connected at the answer, your host plays what it chose for a call ready at the answer (nothing, in Conduit), and the agent gets `call-connected` within about a second of the answer.
- [ ] Ring with an agent that joins a few seconds after the push, and answer at once: no ringback, the call connects the moment the agent is in the room, with no extra minimum.
- [ ] LiveKit: decline a pre-connected ring the instant it starts ringing, and end an outgoing call the instant after placing it: the agent's log shows the device leaving (with `end-call` if it had joined); the device is never left in the room.
- [ ] Decline, let it time out, and send a cancel push: the agent gets `end-call` or sees the participant leave within a second; no audio or microphone indicator remains.
- [ ] End the agent during the ring: the ring stops, a `.canceledByCaller` record, a `canceled` receipt.
- [ ] Ring for a minute, locked: the device stays in the room the whole time (no drop in the agent's log), then answer.
- [ ] Turn on airplane mode during the ring: it keeps ringing, and answering (with the network back) connects as without pre-connect.
- [ ] Compare the time from answer to the agent's first audio with and without pre-connect.

Build:

- [ ] `Scripts/check-linkage.sh <app> <daily|livekit>` passes on the device build (single-adapter apps), or, for an app linking both adapters, its output shows no `RTC*` class defined twice; either way, no `WebRTC.framework` in `Frameworks/`.
- [ ] If you link Daily: a real Daily call after every dependency change.
- [ ] The first call shows the microphone permission prompt, or you prompt earlier yourself.

## 14. Troubleshooting

**No mic on the first call after launch; later calls are fine.**
Cause: CallKit activated the audio session while the transport was still fetching credentials or joining, and something turned audio off or ignored the mic enable. The bundled adapters and the engine handle this ordering. In a custom transport, the usual culprit is `connect` resetting audio to "off" after `attachAudioSession()` already ran, or `.connected` emitted before the mic can actually be enabled.
Fix: follow the rules in [section 10](#10-writing-your-own-transport): track attachment, have `connect` apply the current state, emit `.connected` only when ready.

**The app is killed when a push arrives, or rings stop arriving altogether.**
Cause: a VoIP push was not reported to CallKit. Usually `startPushRegistration()` runs too late (in a view or after sign-in) or not at all on a background launch, or a second `PKPushRegistry` in the app handled the push. Once this has happened repeatedly, iOS stops delivering VoIP pushes to the app.
Fix: create the engine and its delegate at launch, keep them alive, call `startPushRegistration()` in `didFinishLaunchingWithOptions`, and let the engine own PushKit.

**A push during a call ends the call.**
Cause: the same: something other than the engine received the push and did not report it, so iOS terminated the app and the call with it. The engine reports and ends busy pushes without touching the live call.
Fix: as above.

**Daily calls crash a few seconds in, after adding a package.**
Cause: a second, un-prefixed WebRTC (for example `stasel/WebRTC`) next to Daily's embedded one. The crash is a failed dynamic cast inside Daily's track handling.
Fix: remove the package or use a build of it against a prefixed WebRTC. See [the WebRTC duplication rule](#the-webrtc-duplication-rule).

**Rings never ring when the user has Focus on.**
Cause: iOS applies the user's Focus settings to CallKit calls, and the app cannot override them. The engine sees the filtered report, records a missed call (`missedReason: .filteredByFocus`), returns to idle and sends `suppressed_by_focus`.
Fix: nothing in code. Post a local notification for the missed call, and tell users how to allow your calls in their Focus settings.

**The native call screen's route button shows a new route, but Daily audio does not move.**
Cause: Daily runs its own audio session management, so CallKit's route change updates the route metadata while Daily's audio keeps playing to the old device. Mirroring the system route into Daily does not fix it.
Fix: provide an in-app route picker over `engine.audioDevices` and `engine.selectAudioDevice(_:)`. On LiveKit, the native button works.

**Every hangup keeps the agent in the room for a minute.**
Cause: the server does not act on the end-call signal, so it waits out its drop grace window. On LiveKit with Pipecat, the signal does not reach the RTVI processor.
Fix: [section 11](#11-what-the-server-side-must-do). Check your server logs for an immediate teardown after a clean hangup.

**The call sits at "connecting", then fails as `.agentUnreachable`.**
Cause: no agent joined (LiveKit: no remote participant in the room; Daily: no bot sent bot-ready). The engine waits `joinTimeout` (30 seconds by default) after the transport's `connect(_:)` returns.
Fix: dispatch the agent when you mint credentials. If your agent legitimately takes longer to start, raise `joinTimeout`.

**Bad credentials show as a generic transport error.**
Cause: the Daily adapter maps every connect error to `.connectionFailed`; only `TransportError.authenticationFailed` produces `.badToken`.
Fix: throw `TransportError.authenticationFailed` from your `connect` closure when your credential endpoint rejects the request.

**Every ring fails, even for known targets.**
Cause: `targetForIncomingCall` is not implemented (the default returns nil), or the delegate was nil or not yet set when the push was handled.
Fix: implement it, and set the delegate before `startPushRegistration()`.

**The ring shows "Unknown" or an address like `...@calltarget.invalid`.**
Cause: the push carried no `display_name` or `handle`, and the target was not resolved (or has those values).
Fix: send `display_name` and `handle` in the push; set `unknownCallerName` to something better for your app.

**The app crashes in the simulator when a call connects.**
Cause: a real WebRTC transport in a simulator build.
Fix: use `FakeTransport` and `CallEngine.simulated` behind `#if targetEnvironment(simulator)`.

**App Store Connect rejects the build for a missing camera usage description.**
Cause: the WebRTC SDKs reference camera APIs.
Fix: add `NSCameraUsageDescription`, saying calls are audio only.

**Reconnects fail after a while on calls that used inline credentials.**
Cause: the target keeps returning the push's token, which expired.
Fix: issue inline tokens that outlive the call, or have `connect` fetch fresh credentials when retrying.

**Ring-status receipts never arrive.**
Cause: `status_url` is plain HTTP (blocked by App Transport Security), the bearer is missing or wrong, or the server compares `call_id` case-sensitively (the engine sends lowercase, engines before 0.2 uppercase, and your push may have used either).
Fix: use HTTPS, check `ringStatusBearerForTarget`, compare ids case-insensitively. Receipts are never retried.

**Two history rows per call.**
Cause: recording from both `didFinish` and a state transition.
Fix: record only from `didFinish`; the engine already makes the end of a call idempotent across CallKit's own callbacks.

## Known limitations

- **One call at a time.** A second call during a live one is reported and ended as busy.
- **Pre-connect has been observed on one phone only.** On an iPhone 17 with iOS 27.0, locked, with the app not running: a LiveKit ring and Daily rings (up to 20 seconds, including a cold launch by the push) joined during the ring with no audio activity, and the answered calls played the agent cleanly with the route settled within about 0.3 seconds (see each adapter's notes in [section 11](#11-what-the-server-side-must-do)). Other devices, iOS versions, routes (Bluetooth, CarPlay) and longer rings have not been tried. Outgoing calls are never prepared.
- **Call hold is verified in unit tests only.** How iOS sequences the hold action with audio-session deactivation, activation and interruptions, whether it resumes the engine call by itself when the phone call ends, and whether a hold is offered with the provider's one-call-group configuration have not been confirmed on a device; the engine is written to handle any order. Hold is not configurable beyond on or off, and calls cannot be grouped or swapped beyond what holding allows.
- **Daily's hold silencing is verified in unit tests only.** That unsubscribing silences the agent at once on a device, how quickly subscribing again brings it back, and whether Daily's audio restarts after CallKit deactivates and reactivates the session around a hold have not been confirmed on a device.
- **A cancel push for a ring the device no longer has flashes.** iOS requires every VoIP push to be reported as a call, so a cancel for an unknown or finished ring shows a brief incoming call that ends at once. Whether iOS counts a cancel CallKit refuses as a duplicate as properly reported (and keeps delivering pushes) is assumed from the PushKit rules and has not yet been confirmed on a device.
- **The native CallKit route button cannot move audio on the Daily adapter.** Use an in-app picker.
- **Daily's short interruptions are inferred from the device's network path, not Daily's media state.** A path that stays satisfied while media stops is not reported until Daily disconnects, and recovery is announced when the path returns, possibly a moment before audio does.
- **Daily never reports bad credentials itself.** Only your `connect` closure can produce `.badToken` on Daily.
- **Fixed policies.** The reconnection budget and backoff, the loudspeaker default, and the CallKit provider configuration (email handles, calls in the Phone app's Recents, no ringtone or icon customization) are not configurable.
- **No programmatic answer.** Incoming calls are answered from the system UI only.
- **Not exposed:** the remote audio level and user-speaking events.
- **An engine that has started push registration is never deallocated.** It keeps itself alive so every push is reported.
- **The delegate must be set before `startPushRegistration()`.** A push waiting at launch can be delivered as soon as the registry exists, and a push handled with no delegate fails as an unknown target.
