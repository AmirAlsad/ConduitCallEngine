# Changelog

## Unreleased

### Transport adapters

- Both adapters treat a connect attempt as over once it has reported a disconnect, its connect has thrown, or the host has called `disconnect()`, and report nothing that would steer the engine after that. Previously the attempt's state was only reset when the next `connect` ran, which is after the host's credential code, so a late callback from the dropped call was judged as part of a live one: on LiveKit a late participant-left could end a reconnecting call as `.completed`, and on Daily a late bot-left could do the same, a late bot-ready could report a dead attempt as connected, and a failed reconnect attempt was counted twice (its connect threw and the Pipecat client also reported `.disconnected`). Neither adapter reports `.connected` after the host's `disconnect()` any more. ([#10](https://github.com/AmirAlsad/ConduitCallEngine/issues/10))
- `PipecatDailyTransport.disconnect()` now releases its Pipecat client after sending the end-call signal and leaving. It never did, so every Daily call left Pipecat's `DailyTransport` and its Daily `CallClient` alive for the rest of the process: the transport holds its client options, whose `transport` is the transport itself, and pipecat-client-ios-daily 1.3.0 breaks that cycle only in `release()`. A `connect` after `disconnect()` now builds a fresh client (before, it reused the old one), and a `connect` that starts while a `disconnect()` is still flushing its end-call signal gets its own client, which that disconnect does not touch.

## 0.1.1 - 2026-11-11

- Correct the stated requirement: the package needs Xcode 26 or later, not 16.3. The sources use iOS 26 SDK names and never compiled with Xcode 16. CI now builds with Xcode 26.

## 0.1.0 - 2026-11-11

- Initial extraction of the call engine from the Conduit iOS app. `ConduitCallEngine` provides `CallEngine`, which reports calls to CallKit, receives agent-initiated calls over PushKit VoIP pushes, runs the call state machine, owns the call's audio-session policy and reconnects after drops, driven by host-supplied `CallTarget` values and reporting back through `CallEngineDelegate` and `CallRecord`. It also sends optional ring-status receipts and defines the `CallTransport` protocol.
- `ConduitCallEngineDaily` (`PipecatDailyTransport`, Daily through the Pipecat iOS client) and `ConduitCallEngineLiveKit` (`LiveKitTransport`, native LiveKit with manual audio) adapters, shipped as separate products so the core links no WebRTC SDK.
- `ConduitCallEngineTesting`: `FakeTransport`, `SimulatedCallSystem` and `CallEngine.simulated(...)` for the iOS Simulator and host unit tests.
- `PipecatDailyTransport` reports short network interruptions: while connected, losing the device's network path emits `.reconnecting` (the call shows `reconnecting(attempt: 0)`) and getting it back emits `.connected`, as LiveKit's own reconnects already did. Daily heals these inside its SDK without telling the Pipecat client, so they were silent before. The signal is the network path, not Daily's media state.
- `LiveKitTransport` no longer reports a call connected after LiveKit abandons its own reconnect. A completed SDK reconnect now counts only if the room is connected and a remote participant is present; otherwise the adapter disconnects the room and reports `.disconnected(.networkDropped)`, so the engine's reconnect and retry budget apply. Previously a long outage could leave the call showing connected with no audio and no further recovery.
