# Changelog

## Unreleased

- Once `startPushRegistration()` has run, the engine keeps itself alive for the rest of the process (its PushKit registry holds it strongly). Before, a host that released the engine left PushKit's callback with nothing to report the call, and iOS terminates an app that does not report a VoIP push. (#17)

- `TransportError.authenticationFailed` during a reconnect attempt (thrown by the target's `connect` or by the transport's), and an `.error(.authenticationFailed)` event while reconnecting, now fail the call at once as `.badToken`. They were retried like any other failed attempt until the budget ran out and the call failed as `.lostConnection`. (#11)

- Audio activation is tied to the call in progress. An activation that arrives with no call in progress (from a call that ended while dialing) is ignored instead of being replayed onto the next call's transport before CallKit activates that call, and `isAudioActivated` is cleared when a call ends. Deferred work started by an activation, a deactivation, a system mute, an interruption, a route change or a device-list refresh now acts on the transport that was live when it started and stops if that call has ended, instead of looking up whichever transport is current when it runs. (#9)

- Ring-status receipts are sent only for targets the delegate resolves. A push for an unknown target that was busy, filtered by Focus, or declined before CallKit accepted it used to POST to the push-supplied `status_url` with no bearer. For a push during another call, `targetForIncomingCall` is now asked whether or not CallKit accepted the report. (#8)

- A push carrying the `call_id` of the call that is ringing or in progress is treated as a duplicate delivery: it is reported to CallKit, as PushKit requires, and otherwise ignored. It used to take the busy path, producing a missed-call record and a `busy` receipt for a call that was ringing or live. (#7)

- CallKit answer and mute actions now apply only to the call they name. An answer for a busy ring that CallKit still showed answered the ringing call, and a mute for another call's id muted the live one. (#6)

- A CallKit provider reset now ends the call the way any other failure does: a call that is dialing, connecting, connected or reconnecting moves to `.failed(.unknown)` (so a host's transition-driven cues stop) and a ringing call returns to `.idle`; both produce a `CallRecord` (`outcome: .failed`, `failureReason: .unknown`). Before, the engine went to `.idle` with no terminal transition and no record. Nothing is reported back to CallKit, which has already ended the call, and no receipt is sent. (#5)

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
