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
11. [What the server side must do](#11-what-the-server-side-must-do)
12. [Simulator and unit testing](#12-simulator-and-unit-testing)
13. [Device verification checklist](#13-device-verification-checklist)
14. [Troubleshooting](#14-troubleshooting)
- [Known limitations](#known-limitations)

## 1. What the engine does and does not do

`CallEngine` is a `@MainActor`, `@Observable` class. You create one for the whole process, give it a delegate, and hand it a `CallTarget` for each call. It does:

- **CallKit.** Reports outgoing and incoming calls, so they get the system call screen, the lock screen, Bluetooth and CarPlay routing, the system mute and end buttons, and entries in the Phone app's Recents. It handles CallKit's answer, end, mute and reset actions.
- **PushKit.** Registers for VoIP pushes, reports every push as a call (iOS requires it), and passes you the VoIP token.
- **The call state machine.** One call at a time, with the states below, and a `CallRecord` when each call finishes.
- **Audio-session policy.** Configures the session for voice chat, lets CallKit activate it, attaches the transport only after activation, keeps the mic off until then, pauses the mic during interruptions (Siri, a phone call), and routes to the loudspeaker by default when no headset or car is connected.
- **Reconnection.** After a mid-call network drop it retries with exponential backoff (six attempts, waiting 1, 2, 4, 8, 16 and 30 seconds) while CallKit keeps showing the call, and fails with `.lostConnection` when the budget runs out.
- **Ring-status receipts.** When a push asks for them, it POSTs the ring's outcome to your server.

It does not: show any in-app UI, store anything, know what an agent or account is, fetch credentials, deliver the VoIP token to your server, or send pushes. Those are yours.

### What "connected" means

`.connected` means the transport is up **and** the agent is ready to hear the user, not merely that a WebRTC connection exists. Each adapter decides that from its SDK (Daily: the Pipecat client reaches its ready state or the bot reports ready; LiveKit: the room is connected and a remote participant is present; see [section 11](#11-what-the-server-side-must-do)). For an outgoing call, this is also the moment the engine tells CallKit the call connected, which starts the system call timer. If the agent never becomes ready, the call stays in `.connecting`; the engine has no timeout for that.

### States

```
idle -> dialing -> connecting -> connected <-> reconnecting(attempt:)
                                     |
                                     +-> ended(CallOutcome) | failed(CallFailureReason)

idle -> incomingRinging -> connecting -> ...   (after the user answers)
```

| State | Meaning | `isActive` | `isTerminal` |
|---|---|---|---|
| `.idle` | No call. | false | false |
| `.incomingRinging` | A push is ringing. CallKit's system UI is the only surface; the app shows nothing until the user answers. | false | false |
| `.dialing` | `placeCall` was called; CallKit is starting the call. | true | false |
| `.connecting` | CallKit has the call; credentials are being fetched and the transport is joining. | true | false |
| `.connected(since:)` | Transport and agent ready. `since` is the first connection time and is kept across reconnects. | true | false |
| `.reconnecting(attempt:)` | Media dropped while CallKit still shows the call. `attempt` is the engine's retry count; `0` means the transport reported a short interruption it is healing itself (LiveKit's own reconnect, or a lost network path on Daily, see [section 11](#11-what-the-server-side-must-do)) and no retry has been spent. | true | false |
| `.ended(CallOutcome)` | Finished. | true | true |
| `.failed(CallFailureReason)` | Could not be established or could not recover. | true | true |

Terminal states stay until you call `reset()` (typically when your call screen is dismissed), or until the next `placeCall` or incoming ring, which reset first. A ring that ends before the user could take it (Focus filtered it, its target is unknown, CallKit refused it, or the CallKit provider reset) goes straight back to `.idle` without a terminal state. A provider reset during a call that is dialing, connecting, connected or reconnecting fails it with `.failed(.unknown)`.

### Outcomes and failure reasons

| `CallOutcome` | When |
|---|---|
| `.completed` | The call connected, then ended by the user, the system UI, or the agent leaving. |
| `.canceled` | The user ended the call (in-app or from the system UI) after placing or answering it, before it connected. |
| `.declined` | The user declined an incoming call while it was still ringing. |
| `.noAnswer` | The agent left before the call ever connected, or the ring never reached the user (busy, Focus). |
| `.failed` | See the reason. |

A call that reaches `.ended(outcome)` is recorded with the same outcome, so a host can switch on either and show the same thing.

| `CallFailureReason` | Produced by |
|---|---|
| `.badToken` | `TransportError.authenticationFailed` thrown by the target's `connect` closure or by `transport.connect` on the first connect; a `.disconnected(reason: .authFailed)` event at any time; an `.error(.authenticationFailed)` event while connecting. |
| `.transportError` | Any other error from the first connect; any other `.error` event while connecting; a drop before the call ever connected. |
| `.lostConnection` | The reconnection budget ran out. |
| `.unknown` | CallKit refused to start an outgoing call, or reset its provider during a call. In a `CallRecord` only (the state goes from `.incomingRinging` back to `.idle`): CallKit refused to report an incoming call (other than Focus filtering) or reset its provider while it rang, or a ring arrived for a target your delegate did not resolve. |
| `.agentUnreachable` | Declared but not produced by the engine in this version. |

`CallOutcome`, `CallDirection` and `CallFailureReason` have stable string raw values and are `Codable`, so you can persist them.

### The engine's API

| Member | Purpose |
|---|---|
| `init(configuration:)` | The real engine over CallKit and PushKit. Device only. |
| `delegate` | Your `CallEngineDelegate`. **Weak**: keep the delegate alive yourself. |
| `startPushRegistration()` | Start PushKit. Call once in `application(_:didFinishLaunchingWithOptions:)`; later calls do nothing. |
| `voipPushToken` | The current VoIP token, once PushKit has issued one. |
| `placeCall(_:) async` | Start an outgoing call to a target. Ignored unless the engine is idle or terminal. Returns after the first connect attempt has run, not when the call connects. |
| `endCall() async` | End the live call. Ignored while ringing (the user declines from the system UI). |
| `markEndedByUser()` | Set `endedByUser` synchronously, so your UI can dismiss in the same transaction as the tap, before `endCall()` runs. |
| `setMuted(_:) async` | Mute or unmute; mirrored to CallKit. Unmuting turns the transport's mic on at once (see [section 4](#4-audio-session-ownership) for what is and is not gated). |
| `setPushToTalkActive(_:) async` | With push-to-talk enabled in the configuration, `true` turns the transport's mic on and `false` turns it off. Does nothing when push-to-talk is disabled. |
| `selectAudioDevice(_:) async` | Route audio to one of `audioDevices`. |
| `reset()` | Return to idle from a terminal state. |
| `state`, `activeCall`, `isMuted`, `isBotSpeaking`, `isAudioActivated`, `isInterrupted`, `audioDevices`, `selectedAudioDeviceID`, `endedByUser` | Observable state for your UI. `activeCall` carries the target id, display name and direction of the current call. |

`CallEngineConfiguration` has two settings: `unknownCallerName` (default `"Unknown"`), the name a ring shows when the push carries none, and `isPushToTalkEnabled`, a closure read at each mic decision, so a settings change mid-call takes effect on the next one.

### The delegate

Every callback is synchronous and on the main actor, made in the order the engine changes things. All have default implementations.

| Callback | When | Default |
|---|---|---|
| `callEngine(_:targetForIncomingCall:)` | Once per push (not for a duplicate of the call in progress), after the CallKit report is issued: inside the push handling for a ring, or once CallKit has answered the report for a push that arrives during another call. Return the `CallTarget`, or nil for an unknown target (the ring is then ended and recorded as failed, and the engine returns to idle). | nil, so every ring is ended. Implement it if you take incoming calls. |
| `callEngine(_:didChangeStateFrom:to:)` | On every real state change, after the engine has set the transition's other fields, so `activeCall` and the rest are consistent when you read them. Not called when the state is set to the value it already has. | nothing |
| `callEngine(_:didFinish:)` | Once per call, when it reaches its end: ended, failed, busy ring, Focus-filtered ring, a ring that could not proceed, a CallKit provider reset. Not for a malformed push. | nothing |
| `callEngine(_:ringStatusBearerForTarget:)` | When a receipt is about to be sent, only for pushes that carried `status_url` and whose target your delegate resolved. Return the bearer for the `Authorization` header, or nil for none. | nil |
| `callEngine(_:didUpdateVoIPPushToken:)` | When PushKit issues or rotates the VoIP token. | nothing |

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
2. When CallKit activates the session, the engine calls `transport.attachAudioSession()` and then `transport.setMicEnabled(_:)` (on unless the user muted or push-to-talk is enabled).
3. When CallKit deactivates it, the engine calls `transport.detachAudioSession()`.
4. At teardown it calls `detachAudioSession()`, then `disconnect()`.

**Activation and connection arrive in either order**, and the engine handles every interleaving:

- CallKit can activate before the transport exists (while the call is dialing, or before `answer` runs for an incoming call). The engine remembers the activation and calls `attachAudioSession()` as soon as it creates the transport, before fetching credentials.
- CallKit can activate while credentials are being fetched or the transport is still joining. `attachAudioSession()` runs then, but the SDK may ignore a mic enable before it has joined, so the engine sets the mic again when the transport reports `.connected`.
- After an interruption, CallKit can activate the session again. The engine re-applies mic state on both edges, so whichever arrives last wins.

How each adapter honors this:

- **LiveKit** runs in LiveKit's manual-audio mode: `LiveKitTransport` turns off LiveKit's automatic `AVAudioSession` configuration and keeps LiveKit's audio engine disabled until `attachAudioSession()`. Because CallKit then really owns the session, the native call screen's audio route button works on LiveKit calls. The setting is process-wide in the LiveKit SDK; if your app also uses LiveKit outside these calls, account for it.
- **Daily** manages `AVAudioSession` itself and has no hook to defer to CallKit. `PipecatDailyTransport` joins with the mic disabled and enables it only through `setMicEnabled`, which the engine calls only after activation. Its `attachAudioSession()` and `detachAudioSession()` do nothing. One consequence is that the native call screen's route button cannot move Daily's audio (see [troubleshooting](#14-troubleshooting)); route through `engine.selectAudioDevice(_:)` from an in-app picker instead.

**What is gated on activation, and what is not.** The engine waits for CallKit's activation before it turns the mic on by itself: on activation, when the transport reports `.connected` (first connect or reconnect), and when an interruption ends with `shouldResume`. The user's own mic controls are not gated. `setMuted(false)`, and unmuting from the system call UI, call `setMicEnabled(true)` on the transport straight away (unless push-to-talk is enabled), and `setPushToTalkActive(true)` does the same regardless of mute. None of these check `isAudioActivated` or `isInterrupted`, so an unmute or a push-to-talk press before CallKit has activated the session, or during an interruption, opens the transport's mic then. Muting, releasing push-to-talk (`setPushToTalkActive(false)`) and the start of an interruption only ever turn the mic off. If your UI offers mute or push-to-talk while a call is still dialing or connecting, or while `isInterrupted` is true, consider disabling those controls until `isAudioActivated` is true and `isInterrupted` is false.

**Hands-free default.** Once per call, after it connects and the transport's device list is available, the engine selects the loudspeaker if the transport lists no Bluetooth or wired route. A call with nothing connected therefore plays on the speaker rather than the earpiece, and a call in the car stays in the car. This is not configurable in this version; the user can change routes afterwards.

**Your own audio during a call.** Do not change the session category or call `setActive` while a call is up. If you play audio cues during a call, play them into the session as it is.

What a custom transport must do is in [section 10](#10-writing-your-own-transport).

## 5. Launch-time PushKit registration

Call `engine.startPushRegistration()` in `application(_:didFinishLaunchingWithOptions:)`, with the delegate already set.

Why there: when a ring arrives and the app is not running, iOS launches it in the background. No scene connects and no view appears, so registration in a view's `onAppear`, a scene delegate, or after sign-in never runs. PushKit delivers the push only to a registry that exists, and the engine creates it in `startPushRegistration()`.

Why it matters: iOS requires every VoIP push to report an incoming call to CallKit before the PushKit callback returns. An app that receives a VoIP push and does not report one is terminated, and if it keeps happening, iOS stops delivering VoIP pushes to the app. A push that arrives during a call and is not reported takes the live call down with the app.

The engine guarantees the report on every path. It reports first, synchronously inside the PushKit callback, under the identity in the payload, before touching its own state or calling your delegate. PushKit's completion handler is called after CallKit's completion, on every path.

| Push | What the engine does |
|---|---|
| Normal | Reports, asks your delegate for the target, rings. |
| Malformed (no valid `target_id` or `agent_id`) | Reports under a fresh id and the unknown-caller name, then ends it as failed. No state change, no delegate call, no record. |
| During another call (ringing, dialing, connecting, connected, reconnecting) | Reports, then ends it at once as unanswered; the live call is untouched. Your delegate gets a `CallRecord` with `missedReason: .busy`, and a `busy` receipt is sent if requested and your delegate resolves the target. |
| Carrying the `call_id` of the call in progress (a duplicate delivery) | Reports it and does nothing else: no end, no record, no receipt, no delegate call. |
| After a finished call that is still in a terminal state | Resets to idle and rings normally. |
| For a target your delegate does not resolve | Reports, then, once CallKit accepts the report, ends it as failed, records it (`outcome: .failed`, `failureReason: .unknown`) and returns to idle. |
| Filtered by Focus or Do Not Disturb | Records a missed call (`missedReason: .filteredByFocus`) and returns to idle. |
| Refused by CallKit for another reason | Records it as failed with `.unknown` and returns to idle. |

What your code must do to keep the guarantee:

- **Keep the engine alive for the whole process once `startPushRegistration()` has run.** The PushKit callbacks hold the engine weakly; if the engine has been deallocated when a push arrives, PushKit's completion is called without any call being reported, which is the case iOS punishes.
- **Set `delegate` before `startPushRegistration()`.** A push waiting at launch can be delivered as soon as the registry exists (on the main queue, right after the current turn). The delegate is weak and has no default target, so a push handled before it is set resolves to no target and the ring is ended as an unknown target.
- **Resolve targets from memory.** `targetForIncomingCall` runs during push handling. Look the target up synchronously; do not start network or disk work there.
- **Do not create your own `PKPushRegistry` for VoIP.** The engine owns PushKit for the app.

## 6. The push payload

The full contract for server authors is in [PushContract.md](PushContract.md). In summary:

- `target_id` (or its alias `agent_id`) identifies the target; `call_id` becomes the CallKit call id. Both are UUID strings.
- `display_name` and `handle` decide how the ring looks before your app is consulted. Without them it rings under `CallEngineConfiguration.unknownCallerName` and `CallTarget.defaultHandle(for:)` (`<id>@calltarget.invalid`).
- Once CallKit accepts the report, if the target your delegate returned has a different `displayName`, or a different handle (`handle`, or the default handle for its id when `handle` is nil), the engine updates the ring in place. Your target's values win.
- `room_url` and `token` together are inline credentials. Your delegate receives them as `IncomingCall.connection`; whether to use them is your choice. The usual pattern is a target whose `connect` closure returns the inline connection when there is one and fetches credentials otherwise, as in the README.
- `status_url` asks for ring-status receipts; the bearer comes from `ringStatusBearerForTarget`. Receipts are sent only for targets your delegate resolves, so a push for a target you do not know never makes the engine contact the URL it carries.

`IncomingCall` carries `callID`, `targetID`, the `displayName` and `handle` the ring was reported under (after fallbacks), and `connection`.

## 7. Delivering the VoIP token to your server

The engine receives the token; sending it to the server that will ring the device is your job.

**Where it arrives.** `callEngine(_:didUpdateVoIPPushToken:)` is called when PushKit issues or rotates the token. `engine.voipPushToken` returns the current one (nil until PushKit has issued it). Do not count on a callback at every launch; if your server might not have the token, read `voipPushToken` and send it.

**What to send.** Over your own authenticated API:

- the token, hex-encoded: `token.map { String(format: "%02x", $0) }.joined()`;
- the bundle id, from which the server derives the APNs topic (`<bundle id>.voip`);
- the APNs environment the build uses (sandbox for development-signed builds, production for TestFlight and the App Store), typically decided per build configuration;
- the target ids this device accepts rings for, and for each, the display name and handle your app uses, so the push can carry them and ring under the right name from the first frame.

The token belongs to the install, not to a target: every target gets the same token.

**When to send it again.**

- On every `didUpdateVoIPPushToken` callback.
- When the user signs in, or turns on incoming calls for a target.
- When a target's display name or handle changes, so the server echoes current values.
- Tell the server to forget the token when the user signs out, or turns incoming calls off. Reinstalling the app produces a new token; APNs answers pushes to the old one with 410.

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

**A transport per target.** `makeTransport` is per target, so targets can use different transports. A target on Daily returns `PipecatDailyTransport()`, one on LiveKit returns `LiveKitTransport()`. The engine calls `makeTransport` once per call, before it fetches credentials, and reuses that transport for every reconnect attempt in the call.

**Credentials per call.** `connect` runs for the first connection and again before every reconnect attempt, so it can mint fresh, short-lived credentials each time. Throw `TransportError.authenticationFailed` when your backend rejects the user's credentials (a 401 or 403) so the call fails as `.badToken`, which your UI can explain differently from a network failure.

**History.** Write history from `callEngine(_:didFinish:)`. A `CallRecord` has `targetID`, `direction`, `startedAt`, `duration` (connected seconds, 0 if it never connected), `outcome`, `failureReason` and `missedReason`. Check `targetID` against your targets: a ring for an unknown target is recorded against the pushed id, which may match nothing of yours. `missedReason` has no raw value, so map it yourself if you persist it. Record only from `didFinish`, not also from state transitions, or you will write two rows per call.

**In-call UI.** Present your call screen while `engine.state.isActive` is true. That excludes `.incomingRinging`, where CallKit's ring is the interface, and includes terminal states, so a failed call can stay on screen with its reason until the user closes it; call `reset()` on dismiss. When the user taps End, call `markEndedByUser()` and dismiss in the same transaction, then `await engine.endCall()`; `endedByUser` lets you tell a call your user ended in-app (dismiss at once) from a remote end or failure (show a result). It is set only by `markEndedByUser()` and `endCall()`: a call ended from the system UI, such as the lock screen, leaves it false. A ring that ends before the user takes it, including one for an unknown target, never makes the state active. Name the call from `activeCall?.displayName`.

**Cues from transitions.** `didChangeStateFrom:to:` is synchronous and ordered, so it is the place for spoken or audible cues and anything else that must match the state exactly. A typical outgoing call delivers `idle -> dialing`, `dialing -> connecting`, `connecting -> connected`, then `connected -> ended(.completed)`. A drop delivers `connected -> reconnecting(attempt: 1)` and, on recovery, `reconnecting -> connected`. `reconnecting(attempt: 0)` means the transport is healing itself and the engine has spent no retry: a short interruption delivers `connected -> reconnecting(attempt: 0)` and then `reconnecting -> connected`, or, if the transport gives up, `reconnecting(attempt: 0) -> reconnecting(attempt: 1)` and the engine's own retries. Both adapters report short interruptions this way. A ring that arrives while a finished call is still terminal delivers `ended -> idle -> incomingRinging`.

**Missed calls.** The engine posts no notifications. A record with a non-nil `missedReason` is a ring the user never saw: `.busy` (another call was up) or `.filteredByFocus`. Post a local notification for it if you want the user to know. Provisional notification authorization lets you deliver these quietly without an upfront permission prompt.

## 10. Writing your own transport

A transport carries audio between the device and the agent. Conform to `CallTransport`:

| Requirement | Contract |
|---|---|
| `events: AsyncStream<TransportEvent>` | The only way state leaves the transport. The engine reads it once per call, from creation until teardown. |
| `connect(_:) async throws` | Join `connection.url` with `connection.token`. Called once per attempt: first connect, then once per engine reconnect attempt, on the same instance. Throw `TransportError.authenticationFailed` for rejected credentials. |
| `disconnect() async` | Leave because the call is over. If your protocol has an explicit "end call" signal, send it here (see [section 11](#11-what-the-server-side-must-do)). |
| `setMicEnabled(_:) async` | Capture on or off. Can arrive before `connect` finishes; it must be harmless then, because the engine sets it again after `.connected`. Also used to pause the mic during interruptions. |
| `availableAudioDevices() async`, `selectedAudioDevice() async`, `setAudioDevice(_:) async` | The routes the user can pick, and switching between them, through your SDK so it does not revert the choice. |
| `attachAudioSession() async` | CallKit has activated the session: start audio I/O on it. Never activate the session or change its category yourself. Can be called before `connect`, and again after an interruption; make it idempotent. |
| `detachAudioSession() async` | CallKit deactivated the session, or the call is ending: stop audio I/O. Can be called mid-call. |

Rules that come from the device bugs this code survived:

- **`connect` must not undo an attach.** If attach can come before or during connect, track whether you are attached and have `connect` apply the current state, rather than resetting audio to "off" unconditionally. An unconditional reset after a slow credential fetch is what produced a dead mic on the first call after launch.
- **Emit `.connected` once the agent can hear the user**, not when the network connection opens. It drives the call timer, the user's "connected" cue, and the engine's mic re-apply.
- **Follow `.reconnecting` with `.connected` or `.disconnected`.** The engine shows reconnecting while your SDK heals itself and waits for one of the two; it has no timeout.

**Events.**

| Event | Engine reaction |
|---|---|
| `.connecting` | None (already reflected). |
| `.connected` | `connecting -> connected`, or `reconnecting -> connected`. Ignored in other states, so a duplicate is harmless. |
| `.reconnecting` | While connected, show `reconnecting(attempt:)` without spending a retry. |
| `.disconnected(reason: .requestedByUser)` | Ignored: the engine's own teardown caused it. |
| `.disconnected(reason: .botLeft)` | The agent hung up: `ended(.completed)`, or `ended(.noAnswer)` if the call never connected. |
| `.disconnected(reason: .networkDropped)` or `.unknown` | Never connected: `failed(.transportError)`. Connected or reconnecting: schedule the next reconnect attempt. |
| `.disconnected(reason: .authFailed)` | `failed(.badToken)`, in any state. |
| `.error(.authenticationFailed)` | While connecting: `failed(.badToken)`. Otherwise logged. |
| `.error(_)` | While connecting: `failed(.transportError)`. Otherwise logged; a mid-call error does not end the call. |
| `.botStartedSpeaking`, `.botStoppedSpeaking` | Update `isBotSpeaking`. |
| `.audioDevicesChanged` | Refresh `audioDevices` and `selectedAudioDeviceID`, and apply the hands-free default if not yet applied. |
| `.userStartedSpeaking`, `.userStoppedSpeaking`, `.remoteAudioLevel` | Not exposed to hosts in this version. |

"Bot left" versus "network dropped" is the decision that matters most. Report `.botLeft` only when the agent has deliberately left a call that was established (the call then ends normally). Report `.networkDropped` when the connection was lost (the engine reconnects). Report `.requestedByUser` for a disconnect that follows your own `disconnect()`. Mixing them up either turns a recoverable drop in a tunnel into a dead call, or keeps redialing an agent that hung up.

**Errors.** Map SDK errors to `TransportError` inside the adapter so no SDK type leaks out. How the engine reads them:

- `TransportError.authenticationFailed` thrown from your `connect`, or from the target's `connect` closure, on the first connection becomes `failed(.badToken)`. Any other error there becomes `failed(.transportError)`.
- During a reconnect attempt, any error, including `.authenticationFailed`, counts as a failed attempt and schedules the next one, until the budget is spent and the call fails with `.lostConnection`.
- `.connectionFailed`, `.timedOut`, `.botUnavailable` and `.underlying` are only distinguished in logs.

**Audio device ids.** The hands-free default and `AudioRouteKind(deviceID:)` classify routes by keywords in `AudioDeviceInfo.id`: `speaker` (without `bluetooth`), `bluetooth`, `earpiece` or `receiver`, `wired` or `headphone`. Use ids containing these, or the engine cannot tell a speaker from a headset.

**Concurrency.** The protocol is not actor-isolated, but the engine calls it from the main actor and `CallTarget.makeTransport` runs on the main actor. Both adapters are `@MainActor` classes with a `nonisolated let events`; that is the simplest shape:

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
}
```

## 11. What the server side must do

The engine joins whatever room `connect` returns. Your server must put an agent there and behave as each adapter expects.

### Daily (`PipecatDailyTransport`)

- **Joining.** The Pipecat iOS client joins `connection.url` (a Daily room URL) with `connection.token` (a Daily meeting token).
- **Readiness.** The call becomes `.connected` when the Pipecat client reaches its ready state or the bot reports ready, so the room needs a bot that speaks RTVI and sends bot-ready. A Pipecat pipeline with an RTVI processor does this. With no bot, the call stays in `.connecting`.
- **End-call signal.** On a deliberate hangup the client sends an RTVI client message of type `end-call`, waits 200 ms for it to flush, then leaves. A Pipecat server sees it in the RTVI processor's client-message event. It is only sent once the bot is ready.
- **Agent hangup.** When the bot leaves the room, the call ends as `.completed`.
- **Drops.** When the client's transport disconnects without a hangup, the engine reconnects.
- **Short interruptions.** Daily heals short outages inside its SDK without changing the Pipecat transport state, so the client reports nothing about them. The adapter infers them from the device's network path (`NWPathMonitor`) instead, while the call is connected: when the path stops being satisfied the call shows `reconnecting(attempt: 0)`, and when it is satisfied again the call returns to `.connected` at once, without spending a retry. If Daily gives up during the interruption and disconnects, the engine's reconnect takes over from `reconnecting(attempt: 0)` and the path coming back no longer reports `.connected` for that attempt. This reflects the device's network path, not Daily's media state, so it catches losing the network (airplane mode, leaving Wi-Fi with no cellular, a tunnel where the radio drops) but not a path that stays up while packets stop (a captive or dead Wi-Fi, very weak signal), and `.connected` can be announced a moment before Daily's audio has resumed. A change of network that keeps the path satisfied, such as Wi-Fi to cellular, is not reported.
- **Errors.** The adapter maps every connect error to `TransportError.connectionFailed`, so Daily never reports bad credentials itself. Throw `TransportError.authenticationFailed` from your `connect` closure when your own credential endpoint returns 401 or 403.

### LiveKit (`LiveKitTransport`)

- **Joining.** `connection.url` is the LiveKit server URL (`wss://...`) and `connection.token` an access token with a join grant for the room.
- **Readiness.** The call becomes `.connected` once the room is connected **and** at least one remote participant is present. Any remote participant counts as the agent, so dispatch the agent to the room when you mint the token. With no agent, the call stays in `.connecting`.
- **End-call signal.** On a deliberate hangup, while the room is connected, the client publishes this JSON on the room's data channel, then disconnects:

  ```json
  {"id": "<8 characters>", "label": "rtvi-ai", "type": "client-message", "data": {"t": "end-call"}}
  ```

  If your agent runs on Pipecat, note that Pipecat's LiveKit transport has not been delivering client data messages to its RTVI processor, so parse this from the transport's raw data-received event.
- **Agent hangup.** When the last remote participant leaves a connected call, the call ends as `.completed`. If another remote participant remains, the call continues.
- **Drops.** A room disconnect without a hangup triggers the engine's reconnect. LiveKit's own reconnects show as `reconnecting(attempt: 0)` and recover without spending a retry. A reconnect LiveKit reports as complete counts as recovered only if the room is connected and a remote participant is present, the same rule as the first connect. Otherwise (LiveKit can report an abandoned reconnect as complete, with the room still marked connected and no participants) the adapter disconnects the room and reports a network drop, so the engine's own reconnect runs and, if the outage lasts, the call fails as `.lostConnection`.
- **Errors.** Connect errors that LiveKit reports as insufficient permissions, or whose description mentions unauthorized, 401, permission or token, become `.authenticationFailed` (`.badToken`); others become `.connectionFailed`.

### For any transport

- **Honor the end-call signal.** A dropped connection and a hangup look the same from the server unless the client says which it is. Because the engine reconnects after drops, your agent should hold the room for a grace window when the user's media disappears. When the end-call signal arrives, tear down immediately instead. If you ignore it, every hangup keeps your agent in the room (and billing) for the full grace window, and nothing on the device will tell you.
- **Size the grace window to the engine's backoff.** The engine waits 1, 2, 4, 8, 16 and 30 seconds before its six attempts, a little over a minute in total plus connection time. A shorter window cuts off drops the device would have recovered from.
- **Reconnects call your credential code again.** Each attempt re-runs the target's `connect`. Your endpoint may return the same room (the agent is still waiting there) or a fresh room with a newly dispatched agent; either works, as long as an agent is present when the device arrives. Inline credentials from a push are reused if your `connect` closure keeps returning them, so they must stay valid for the length of the call.
- **The signal is best-effort.** The engine's teardown calls `disconnect()` for every ending (user hangup, agent hangup, failure), and the adapters send the signal only while the connection is up. A connection that died never sends it, which is exactly when the grace window should apply.

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

and in `makeTransport`, return a `FakeTransport()` in the simulator. `FakeTransport` never reports `.connected` on its own; emit it (for example after a short delay with `transport.emit(.connected)`, as `Example/` does) if you want the UI to reach the connected state.

**In unit tests.** `SimulatedCallSystem` drives the system side:

| Member | Does |
|---|---|
| `deliverPush(_:completion:)` | PushKit delivers a VoIP push. Requires `engine.startPushRegistration()`. |
| `deliverVoIPPushToken(_:)`, `voipPushToken` | PushKit issues a token; the token it holds. |
| `answerIncomingCall() async` | The user answers; returns once the connect attempt has run. |
| `endCallFromSystem(_:)` | The user ends or declines from the system UI. |
| `setMutedFromSystem(_:muted:)` | The user toggles mute from the system UI. Ignored unless `callID` is the live call's. |
| `resetProvider()` | CallKit resets the provider: a live call fails with `.unknown`, a ring returns to idle, and both are recorded. |
| `outgoingStartError` | While set, every outgoing start throws it, as a rejected start does; the call fails with `.unknown`. |
| `activateAudioSession() async` | CallKit activates the audio session; returns once the engine has attached the transport and applied mic state. |
| `deactivateAudioSession()` | CallKit deactivates the session; the engine detaches the transport on its next main-actor turn. |
| `beginAudioInterruption()`, `endAudioInterruption(shouldResume:)` | Another audio session interrupts the call, and the interruption ends. The engine reacts on its next main-actor turn. |
| `deliverTransportEvent(_:)` | The live transport emits an event, delivered synchronously. Delivered only while a call has a transport (the only time a real transport's events reach the engine); returns whether it was delivered. |
| `awaitPendingReconnect() async` | Waits for an in-flight reconnect attempt. |
| `incomingReportResult` | How CallKit answers incoming reports: `.rings`, `.filteredByFocus`, `.fails(_)`. |
| `completesIncomingReportsLater`, `completeIncomingReports()` | Hold CallKit's report completions and release them. By default reports complete before the report call returns, which real CallKit never does; set this to test the device's ordering, such as an answer that arrives before CallKit accepts the report. |
| `suspendsOutgoingStarts`, `pendingOutgoingStartCount`, `releaseOutgoingStarts()` | Hold outgoing call starts, to test ending a call while it dials. |
| `startedCallIDs`, `reportedIncomingCalls`, `updatedCalls`, `ringReceipts` | What the engine reported, in plain types. `ReportedCall` and `RingReceipt` have public initializers, so you can write expected values. |
| `presentConnectedCall(_:secondsElapsed:botSpeaking:) -> Bool` | Puts a connected call on the engine's observed state without CallKit, a transport or any delegate callback, for screenshots of your in-call UI. Works only on the engine `CallEngine.simulated` made for this system; returns false otherwise. |

`FakeTransport` records `connectCount`, `disconnectCount`, `lastConnection`, `isMicEnabled` and `isAudioAttached`; `connectError` makes the next connect throw; `suspendConnect` with `releaseConnect()` holds a connect open; `emit(_:)` sends an event through the stream (asynchronously, unlike `deliverTransportEvent`).

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
            connect: { CallConnection(url: URL(string: "https://example.invalid/room")!, token: "t") }
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

Pass `now:` and `sleep:` to `simulated` to control time: a clock you advance makes `CallRecord.duration` deterministic, and a `sleep` that returns at once makes reconnect backoff instant.

A simulated engine activates the audio session only when you call `activateAudioSession()`. Until then `isAudioActivated` stays false and the engine never attaches the transport, so in an app running the simulated engine, a `FakeTransport` is never attached unless you drive activation yourself. The simulation tests the engine's logic against your host code; it cannot tell you how a real SDK behaves under CallKit, which only a device shows.

## 13. Device verification checklist

Run these on a physical iPhone with a release-like build before shipping. Keep Console open, filtered to your bundle id: the engine logs under your app's subsystem, in categories named `[Call]`, `[CallKit]`, `[Transport]`, `[Audio]` and `[Network]`. Debug and info messages are compiled out of release builds; warnings and errors remain.

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
- [ ] Invoke Siri, or take a cellular call, mid-call: the mic pauses and comes back afterwards.
- [ ] CarPlay, if you support driving: place, take and end calls from the car.

Network:

- [ ] Airplane mode for about ten seconds mid-call, on each adapter you link: `reconnecting(attempt: 0)` when the network goes, then `connected` when it returns, with audio back.
- [ ] Airplane mode for several minutes: the call fails as `.lostConnection` once the retries are spent.

Incoming:

- [ ] With the app not running, ring it: the lock screen rings with the right name; answer; two-way audio.
- [ ] Ring with no `display_name`: the name corrects within a moment.
- [ ] Decline: a `.declined` record and a `declined` receipt.
- [ ] Ring during a call: the live call is unaffected; a busy record; a `busy` receipt.
- [ ] Ring with Focus on: no ring, a `.filteredByFocus` record, a `suppressed_by_focus` receipt, your missed-call notification if you post one.
- [ ] Ring with an unknown `target_id`, and with no `target_id` at all: a brief ring that ends, and the app keeps running.
- [ ] Inline credentials and app-fetched credentials both connect.
- [ ] A TestFlight build ringed through the production APNs endpoint.

Build:

- [ ] `Scripts/check-linkage.sh <app> <daily|livekit>` passes on the device build (single-adapter apps), or, for an app linking both adapters, its output shows no `RTC*` class defined twice; either way, no `WebRTC.framework` in `Frameworks/`.
- [ ] If you link Daily: a real Daily call after every dependency change.
- [ ] The first call shows the microphone permission prompt, or you prompt earlier yourself.

## 14. Troubleshooting

**No mic on the first call after launch; later calls are fine.**
Cause: CallKit activated the audio session while the transport was still fetching credentials or joining, and something turned audio off or ignored the mic enable. The bundled adapters and the engine handle this ordering. In a custom transport, the usual culprit is `connect` resetting audio to "off" after `attachAudioSession()` already ran, or `.connected` emitted before the mic can actually be enabled.
Fix: follow the rules in [section 10](#10-writing-your-own-transport): track attachment, have `connect` apply the current state, emit `.connected` only when ready.

**The app is killed when a push arrives, or rings stop arriving altogether.**
Cause: a VoIP push was not reported to CallKit. Usually `startPushRegistration()` runs too late (in a view or after sign-in) or not at all on a background launch, the engine was deallocated, or a second `PKPushRegistry` in the app handled the push. Once this has happened repeatedly, iOS stops delivering VoIP pushes to the app.
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

**The call sits at "connecting" and never connects.**
Cause: no agent joined (LiveKit: no remote participant in the room; Daily: no bot sent bot-ready). The engine has no timeout for this.
Fix: dispatch the agent when you mint credentials; let the user end the call meanwhile.

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
Cause: `status_url` is plain HTTP (blocked by App Transport Security), the bearer is missing or wrong, or the server compares `call_id` case-sensitively (the engine sends uppercase).
Fix: use HTTPS, check `ringStatusBearerForTarget`, compare ids case-insensitively. Receipts are never retried.

**Two history rows per call.**
Cause: recording from both `didFinish` and a state transition.
Fix: record only from `didFinish`; the engine already makes the end of a call idempotent across CallKit's own callbacks.

## Known limitations

- **One call at a time.** A second call during a live one is reported and ended as busy.
- **No call-hold handling.** CallKit's hold action is not handled, so the engine's call cannot be held. When the user places a cellular call during an engine call, iOS ends the engine's call (observed on iOS 27; the engine tears down normally and sends the end-call signal). Other audio interruptions pause the mic and resume it afterwards.
- **No timeout for an unanswered ring**, and no way for the server to cancel one. It rings until the user answers or declines, or iOS ends it.
- **No timeout while connecting.** If the agent never becomes ready, the call stays in `.connecting` until the user ends it.
- **The native CallKit route button cannot move audio on the Daily adapter.** Use an in-app picker.
- **Daily's short interruptions are inferred from the device's network path, not Daily's media state.** A path that stays satisfied while media stops is not reported until Daily disconnects, and recovery is announced when the path returns, possibly a moment before audio does.
- **Daily never reports bad credentials itself.** Only your `connect` closure can produce `.badToken` on Daily.
- **During reconnection, an authentication failure is retried** like any other failed attempt, and the call ends as `.lostConnection` rather than `.badToken`.
- **Fixed policies.** The reconnection budget and backoff, the loudspeaker default, and the CallKit provider configuration (email handles, calls in the Phone app's Recents, no ringtone or icon customization) are not configurable.
- **No programmatic answer.** Incoming calls are answered from the system UI only.
- **Not exposed:** the remote audio level, user-speaking events, and PushKit token invalidation (logged only).
- **`CallFailureReason.agentUnreachable`** exists but is never produced.
- **The user's mic controls are not gated on audio activation or interruptions.** Unmuting (in-app or from the system UI) and pressing push-to-talk enable the transport's mic immediately, even before CallKit has activated the session or while `isInterrupted` is true. See [section 4](#4-audio-session-ownership).
- **The engine must outlive push registration.** Once `startPushRegistration()` has run, the engine has to stay alive for the rest of the process; if it is deallocated, an incoming push is completed without reporting a call.
- **The delegate must be set before `startPushRegistration()`.** A push waiting at launch can be delivered as soon as the registry exists, and a push handled with no delegate fails as an unknown target.
