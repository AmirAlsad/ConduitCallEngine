# Example host

The smallest complete host for the "one fixed target" case: an app with a single built-in
agent, whose own backend hands out the call credentials. It is documentation that compiles.

There are two apps, `ExampleDaily` and `ExampleLiveKit`. They share all code in `Shared/`
and differ only in `Transport.swift`, which links exactly one adapter product
(`ConduitCallEngineDaily` or `ConduitCallEngineLiveKit`). `Scripts/check-linkage.sh` builds
on that to prove an app linking one adapter does not link the other SDK.

## What it shows

- `AppDelegate` builds the `CallEngine`, is its delegate, and calls `startPushRegistration()`
  in `didFinishLaunchingWithOptions` (PushKit registration must happen at launch).
- `ExampleAgent` is the one `CallTarget`. Its `connect` closure calls `ExampleBackend`.
- `ExampleBackend` is a placeholder: it POSTs the call-control signals the app sends (`call_signals`) to a URL and decodes `{ "url": ..., "token": ... }`.
  This is where your own backend goes.
- `CallView` shows the call state with Call, Mute and End buttons bound to the engine.
- In the simulator (`#if targetEnvironment(simulator)`) the engine comes from
  `CallEngine.simulated(...)` with a `FakeTransport`, and no backend is contacted. On a
  device it is the real `CallEngine(configuration:)` with the real adapter.

## Run it

```sh
cd Example
xcodegen generate
open ConduitCallEngineExample.xcodeproj
```

The `.xcodeproj` is generated and gitignored. Pick the `ExampleDaily` or `ExampleLiveKit`
scheme. Real calls need a physical device: the simulator has no CallKit and no microphone
capture, so there it runs the simulated engine.

## Replace before using it for real

- `ExampleBackend.baseURL`: your backend. Adapt `fetchConnection()` and
  `register(voipToken:)` to its API.
- The bundle identifiers in `project.yml` (`com.example...`) and your development team.
  `aps-environment` in the entitlements is `development`; use `production` for release.
- `ExampleAgent.id` and `displayName`: your agent's identity. A VoIP push's `target_id`
  must carry this id.

## Check linkage

```sh
xcodebuild -project ConduitCallEngineExample.xcodeproj -scheme ExampleDaily \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/example-dd CODE_SIGNING_ALLOWED=NO build
../Scripts/check-linkage.sh /tmp/example-dd/Build/Products/Debug-iphoneos/ExampleDaily.app daily
```
