# ConduitCallEngine

A VoIP call engine for iOS: CallKit, PushKit, a call state machine, audio policy, and reconnection, with WebRTC transport adapters shipped as separate products.

**Work in progress: being extracted from Conduit.** The sources are placeholders for now and the API is not stable.

## Products

- `ConduitCallEngine`: the core engine. Imports no transport SDK.
- `ConduitCallEngineDaily`: Daily transport adapter (via the Pipecat iOS client).
- `ConduitCallEngineLiveKit`: LiveKit transport adapter.
- `ConduitCallEngineTesting`: fakes and simulator fallbacks.

Link only the transport product your app uses.

## Requirements

iOS 18 and Xcode 16.3 or later.

## License

MIT
