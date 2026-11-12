# Changelog

## Unreleased

- A ring for a target the delegate does not resolve, or one CallKit refuses for a reason other than Focus, now returns from `.incomingRinging` to `.idle` instead of entering `.failed(.unknown)`, an active state that put a failure screen up for a ring the user never answered. It is still ended in CallKit and recorded (`outcome: .failed`, `failureReason: .unknown`). (#4)

- A call the remote party leaves before it connects now ends in `.ended(.noAnswer)`, matching its `CallRecord`; it was `.ended(.completed)`. An incoming call the user answers and then ends before it connects is now `.canceled` in both state and record; it was `.declined`, which is now kept for a ring the user declines. The outcome in `.ended(_)` is always the record's outcome. (#1)

## 0.1.1 - 2026-11-11

- Correct the stated requirement: the package needs Xcode 26 or later, not 16.3. The sources use iOS 26 SDK names and never compiled with Xcode 16. CI now builds with Xcode 26.

## 0.1.0 - 2026-11-11

- Initial extraction of the call engine from the Conduit iOS app. `ConduitCallEngine` provides `CallEngine`, which reports calls to CallKit, receives agent-initiated calls over PushKit VoIP pushes, runs the call state machine, owns the call's audio-session policy and reconnects after drops, driven by host-supplied `CallTarget` values and reporting back through `CallEngineDelegate` and `CallRecord`. It also sends optional ring-status receipts and defines the `CallTransport` protocol.
- `ConduitCallEngineDaily` (`PipecatDailyTransport`, Daily through the Pipecat iOS client) and `ConduitCallEngineLiveKit` (`LiveKitTransport`, native LiveKit with manual audio) adapters, shipped as separate products so the core links no WebRTC SDK.
- `ConduitCallEngineTesting`: `FakeTransport`, `SimulatedCallSystem` and `CallEngine.simulated(...)` for the iOS Simulator and host unit tests.
- `PipecatDailyTransport` reports short network interruptions: while connected, losing the device's network path emits `.reconnecting` (the call shows `reconnecting(attempt: 0)`) and getting it back emits `.connected`, as LiveKit's own reconnects already did. Daily heals these inside its SDK without telling the Pipecat client, so they were silent before. The signal is the network path, not Daily's media state.
- `LiveKitTransport` no longer reports a call connected after LiveKit abandons its own reconnect. A completed SDK reconnect now counts only if the room is connected and a remote participant is present; otherwise the adapter disconnects the room and reports `.disconnected(.networkDropped)`, so the engine's reconnect and retry budget apply. Previously a long outage could leave the call showing connected with no audio and no further recovery.
