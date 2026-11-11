# Changelog

## Unreleased

- Initial extraction of the call engine from the Conduit iOS app. `ConduitCallEngine` provides `CallEngine`, which reports calls to CallKit, receives agent-initiated calls over PushKit VoIP pushes, runs the call state machine, owns the call's audio-session policy and reconnects after drops, driven by host-supplied `CallTarget` values and reporting back through `CallEngineDelegate` and `CallRecord`. It also sends optional ring-status receipts and defines the `CallTransport` protocol.
- `ConduitCallEngineDaily` (`PipecatDailyTransport`, Daily through the Pipecat iOS client) and `ConduitCallEngineLiveKit` (`LiveKitTransport`, native LiveKit with manual audio) adapters, shipped as separate products so the core links no WebRTC SDK.
- `ConduitCallEngineTesting`: `FakeTransport`, `SimulatedCallSystem` and `CallEngine.simulated(...)` for the iOS Simulator and host unit tests.
- `PipecatDailyTransport` reports short network interruptions: while connected, losing the device's network path emits `.reconnecting` (the call shows `reconnecting(attempt: 0)`) and getting it back emits `.connected`, as LiveKit's own reconnects already did. Daily heals these inside its SDK without telling the Pipecat client, so they were silent before. The signal is the network path, not Daily's media state.
