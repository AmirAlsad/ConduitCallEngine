# Example host

The smallest complete host for the "one fixed target" case: an app with a single built-in
agent, whose own backend hands out the call credentials. It is documentation that compiles.

There are two apps, `ExampleDaily` and `ExampleLiveKit`. They share all code in `Shared/`
and differ only in `Transport.swift`, which links exactly one adapter product
(`ConduitCallEngineDaily` or `ConduitCallEngineLiveKit`). `Scripts/check-linkage.sh` builds
on that to prove an app linking one adapter does not link the other SDK.

## What it shows

- `AppDelegate` builds the `CallEngine`, is its delegate, and calls `startPushRegistration()`
  in `didFinishLaunchingWithOptions` (PushKit registration must happen at launch). It sends
  the VoIP token it already has at launch and every token PushKit issues later, withdraws
  an invalidated one, and resolves a ring only when its `target_id` is the agent's id,
  passing the push's inline credentials (`IncomingCall.connection`) to the target.
- `ExampleAgent` is the one `CallTarget`. Its `connect` closure returns the push's inline
  credentials when a ring carried them, and otherwise calls `ExampleBackend`.
- `ExampleBackend` is a placeholder for your backend. `fetchConnection(for:)` POSTs the
  target id, the request's purpose and call id, and the call-control signals the app sends
  (`call_signals`), decodes `{ "url": ..., "token": ... }`, and throws
  `TransportError.authenticationFailed` for a 401 or 403 so the call fails as `.badToken`.
  `register(voipToken:)` sends the hex token, the bundle id, the APNs environment, the
  agent's id and name, `push_features` and `call_signals`.
- `CallView` shows the call state with Call, Mute and End buttons bound to the engine.
- In the simulator (`#if targetEnvironment(simulator)`) the engine comes from
  `CallEngine.simulated(system:)` with a `FakeTransport`, and no backend is contacted. The
  app keeps the `SimulatedCallSystem` and activates the call's audio after placing a call,
  as CallKit would on a device, so the simulated call attaches, opens its mic and
  delivers `.moment(.connected)`. On a device it is the real
  `CallEngine(configuration:)` with the real adapter.

## What it leaves out

The example is the minimum that works. A shipping host also:

- retries a token registration or withdrawal that failed (here they are only logged), and
  persists the token it registered, so it can withdraw it after a relaunch;
- registers again when the user signs in, turns incoming calls on, or renames the agent,
  and withdraws the token when the user signs out or turns incoming calls off
  (Integration Guide, section 7);
- authenticates its requests to the backend;
- decides the APNs environment from how the build is signed (here: sandbox for a debug
  build, production otherwise);
- keeps its own call history and missed-call notifications, plays its own sounds, and
  decides on pre-connect (`CallTarget.ringPreparation`, `.none` here).

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

- `ExampleBackend.baseURL`: your backend. Adapt `fetchConnection(for:)`,
  `register(voipToken:)` and `unregister(voipToken:)` to its API.
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
