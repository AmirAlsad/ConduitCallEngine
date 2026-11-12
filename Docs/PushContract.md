# Push contract

For whoever builds the server that rings the app. It covers the APNs request, the payload the engine parses, what the user sees, how to withdraw a ring, how to have the device connect while it rings, and the ring-status receipts the engine sends back.

The flow: your server sends an APNs VoIP push to a device token the app gave you. The engine reports an incoming call to CallKit straight from the payload, so the phone rings on the lock screen, in the car, or wherever the user is. When the user answers, the engine joins a room, either from credentials in the push or from credentials the app fetches itself. If the push asked for receipts, the engine POSTs the ring's outcome back to you.

How the token reaches your server, and how your server knows which target ids a device accepts, is defined by the app you are working with; see [Integration Guide, section 7](IntegrationGuide.md#7-delivering-the-voip-token-to-your-server).

## Device capabilities

Some payload features are optional and newer than others. An app sends its server the list the engine supports (`CallEngine.supportedPushFeatures`) along with the token. Use a feature only with a device that lists it:

| Feature | Lets you |
|---|---|
| `ring_timeout` | Put `ring_timeout` in a ring push to shorten how long it rings. |
| `cancel` | Send a cancel push to withdraw a ring ([Cancelling a ring](#cancelling-a-ring)). |
| `preconnect` | Put `preconnect` in a ring push so the device prepares the call while it rings ([Pre-connect](#pre-connect)). |

Ignore feature names you do not know; later engines add more. Treat a device whose app sent no list as supporting none of them: an engine from before the list existed (0.1) ignores `ring_timeout` and `preconnect`, and shows a cancel push as a brief incoming call that ends at once.

Separately, the app lists the call-control signals its calls carry, as `call_signals` (`["call-connected", "call-held", "call-resumed"]` from engine 0.2), with the token and in every credential request ([Integration Guide, "When your agent should start speaking"](IntegrationGuide.md#when-your-agent-should-start-speaking)). An agent you start for a ring before the device asks for credentials (inline credentials) waits for `call-connected` before it speaks only if the registration lists it, and otherwise greets when the client is ready, as before. Send `"preconnect": "media"` only to a device that lists both `preconnect` and `call-connected`: the device then joins before the answer, and `call-connected` is what tells your agent the user answered.

## The APNs request

Send an HTTP/2 request to APNs, authenticated with a token-based (`.p8` key) JWT or a VoIP certificate for the app's team:

```
POST /3/device/<hex VoIP token>
Host: api.push.apple.com            (api.sandbox.push.apple.com for development-signed builds)
authorization: bearer <JWT signed with your .p8 key>
apns-push-type: voip
apns-topic: <the app's bundle id>.voip
apns-priority: 10
apns-expiration: 0
content-type: application/json

<payload, below>
```

| Header | Value | Why |
|---|---|---|
| `apns-push-type` | `voip` | Delivers through PushKit, which wakes or launches the app. A regular alert push does not reach the engine. |
| `apns-topic` | `<bundle id>.voip` | The VoIP topic is the bundle id with `.voip` appended. |
| `apns-priority` | `10` | Deliver immediately. A ring that arrives late is useless. |
| `apns-expiration` | `0` (recommended) | APNs makes one delivery attempt and does not store the push. Without it, a phone that is offline when you ring can start ringing minutes later, when the call is long gone. |

The environment must match the build. A build signed with the development `aps-environment` (typically an Xcode debug build) has a sandbox token, and pushes to it go to `api.sandbox.push.apple.com`. TestFlight and App Store builds have production tokens and use `api.push.apple.com`. A token sent to the wrong environment is rejected (`BadDeviceToken`).

APNs limits a VoIP payload to 5 KB.

## The payload

All keys are at the top level of the JSON body, beside or instead of `aps`; the engine ignores `aps` and any key it does not know. Every value is a string. A value of another type (a number, an object) is treated as absent, and so is an empty string.

| Key | Required | Meaning | When absent or invalid |
|---|---|---|---|
| `target_id` | Yes (or `agent_id`) | UUID of the call target that is calling. The app resolves it to one of its own targets. | If neither `target_id` nor `agent_id` parses as a UUID, the push is malformed: the engine reports a call under a fresh id with the unknown-caller name and ends it at once. Nothing else happens. |
| `agent_id` | Alias | Accepted in place of `target_id`. | Used only when `target_id` is absent or not a valid UUID. When both are valid, `target_id` wins. |
| `call_id` | Strongly recommended | UUID for this ring. It becomes the CallKit call's id and is echoed in every receipt. | The engine mints a random UUID, so receipts carry an id your server never chose. |
| `display_name` | Recommended | The caller name the ring shows. | The ring shows the app's unknown-caller name (`"Unknown"` unless the app configures another), corrected once the app resolves the target. |
| `handle` | Optional | The CallKit handle the ring is reported under (an email-type handle). | `<target_id in lowercase>@calltarget.invalid`, corrected once the app resolves the target if the target has a different handle. |
| `room_url` | Optional, with `token` | Room to join on answer: a Daily room URL (`https://...`) or a LiveKit server URL (`wss://...`), matching the transport the app uses for this target. | No inline credentials; the app's own `connect` code runs on answer. |
| `token` | Optional, with `room_url` | Join token for `room_url`. | Inline credentials need both keys and a non-empty token. With only one of the two, both are ignored. |
| `status_url` | Optional | Where the engine POSTs the ring's outcome. See [Ring-status receipts](#ring-status-receipts). | No receipts are sent. |
| `ring_timeout` | Optional | How long the phone may ring, in whole seconds, as a string of digits (`"30"`). It can only shorten the ring: the engine uses the smaller of this and the app's own timeout (60 seconds unless the app configures another), and raises a value below 10 to 10. When the ring times out, the engine ends it and sends `unanswered`. | The app's own timeout applies, which you cannot know: see [How long a ring lasts](#how-long-a-ring-lasts). Zero, negative, fractional or non-numeric values are treated as absent. |
| `preconnect` | Optional | `"credentials"` or `"media"`: how much of the call the device may prepare while it rings; see [Pre-connect](#pre-connect). `"media"` is your promise that the agent stays silent until it receives `call-connected`. | Nothing is prepared; the device fetches credentials and joins after the answer. Any other value (including another case, such as `"Media"`) is treated as absent. |
| `action` | Optional | `"ring"` for a ring. A cancel push uses `"cancel"`; see [Cancelling a ring](#cancelling-a-ring). | A ring. Any other value makes the push malformed. |

A complete example:

```json
{
  "target_id": "6F1E0A52-3B7C-4D8E-9A41-2C5D7E9B0A13",
  "call_id": "0B9F3C1E-7A2D-4E58-B6C4-91D2E0F3A7B5",
  "display_name": "Assistant",
  "handle": "assistant@agents.example.com",
  "room_url": "wss://your-project.livekit.cloud",
  "token": "<short-lived LiveKit access token>",
  "status_url": "https://agent.example.com/rings/0B9F3C1E-7A2D-4E58-B6C4-91D2E0F3A7B5/status"
}
```

Only `target_id` is required, but the smallest useful ring is `{"target_id": "...", "call_id": "..."}`: it rings under the unknown-caller name, is corrected to the target's name a moment later, and on answer the app fetches credentials itself.

### What the device does with it

1. Reports the incoming call to CallKit immediately, inside the PushKit callback, under the push's own `display_name` and `handle` (or their fallbacks). iOS terminates any app that receives a VoIP push without reporting a call, so this happens before the app is consulted.
2. Asks the app to resolve `target_id` to one of its targets. Once CallKit accepts the report, if the target's name or handle differ from what the ring showed, the ring is updated in place.
3. If the app does not know the target, the call is ended as failed and recorded as a failed incoming call. No receipt is sent.
4. If the sender already cancelled this `call_id` (the cancel push arrived first, see [Cancelling a ring](#cancelling-a-ring)), the call is reported, as iOS requires, and ended at once. Nothing else happens: no missed call, no receipt.
5. If the device is already in a call (ringing, dialing, connecting, connected or reconnecting), the new ring is reported and ended at once as unanswered. The live call is not touched, the engine reports a missed call to the app, and a `busy` receipt is sent. A push whose `call_id` is the call already in progress (a second delivery of the same ring) is not a new ring: it is reported, because iOS requires it, and otherwise ignored, with no missed call and no receipt.
6. If Focus or Do Not Disturb filters the ring, the phone never rings. The engine reports a missed call to the app and a `suppressed_by_focus` receipt is sent.
7. If nobody answers or declines within the ring timeout (the app's, 60 seconds by default, or your shorter `ring_timeout`), the engine ends the ring as unanswered, reports a missed call to the app and sends `unanswered`. An answer the user gave before the timeout always wins, even if the call has not connected yet.
8. If the push carried `preconnect` and the app allows it for this target, the engine starts preparing the call once CallKit has accepted the report: it runs the app's credential code, and for `"media"` also joins the room, while the phone rings ([Pre-connect](#pre-connect)).
9. When the user answers, the engine joins the room (unless it already did during the ring): `room_url` and `token` from the push if both were present, otherwise whatever the app's own credential code returns. The call then behaves like an outgoing call, including reconnection.

### How long a ring lasts

With `ring_timeout`, a device that lists the `ring_timeout` feature rings for at most that long (at least 10 seconds), or less if the app's own timeout is shorter. Without it, the ring lasts the app's own timeout, which the app chooses: 60 seconds by default, but an app may configure a longer one, or none, in which case the ring lasts until the user answers or declines it or you cancel it. A device that does not list the feature (an engine from 0.1) has no ring timeout of its own. So a server that sends no `ring_timeout` must assume a ring can last indefinitely. Whenever your server needs to know when a ring is over (to end an agent it started for the ring, or to stop waiting for a receipt), send `ring_timeout` to devices that list the feature, and for the others rely on the receipts, or on your own bound after which you treat the ring as gone.

### What the user sees when name or handle are omitted

CallKit shows `display_name` as the caller. Without it, the lock screen first shows the app's unknown-caller name and changes to the target's real name once CallKit has accepted the report and the app has resolved the target, which is usually a fraction of a second but can be visible. The handle is less visible: it appears where iOS lists the call, such as the Phone app's Recents, and it is what Siri and Contacts can match against. Echo the `display_name` and `handle` the app gave you at registration whenever you have them; do not invent your own, because the app's own values win as soon as it resolves the target.

### Inline credentials

Putting `room_url` and `token` in the push lets the device join without a round trip to your backend after answering. Two cautions:

- The push sits in APNs and on the lock screen for as long as the phone rings, so use a short-lived token scoped to one room.
- How the app reconnects after a drop is up to its `connect` code. A host that returns the push's credentials for every attempt, as the package's quick start does, reconnects with the same token, so it must stay valid for the length of the call.

## Cancelling a ring

To withdraw a ring before the user answers, send a cancel push to the same token, through the same APNs request:

```json
{"action": "cancel", "call_id": "0B9F3C1E-7A2D-4E58-B6C4-91D2E0F3A7B5"}
```

| Key | Required | Meaning |
|---|---|---|
| `action` | Yes | `"cancel"`. |
| `call_id` | Yes | The `call_id` of the ring to withdraw. A cancel without a valid `call_id` is malformed. |
| `target_id`, `agent_id` | **Must be omitted** | A 0.1 engine treats any push with a valid target as a ring, so a cancel that names the target would ring on it, or be ended as busy while the ring it meant to cancel keeps ringing. Without a target, a 0.1 engine treats the cancel as malformed instead: a brief incoming call that ends at once. A newer engine ignores a target in a cancel. |
| `display_name` | Optional | The caller name iOS shows if the cancel has to appear as a call of its own (below). |

Send a cancel only to devices that list `cancel` among their capabilities ([Device capabilities](#device-capabilities)). iOS requires every VoIP push to be reported as an incoming call, a cancel included, so the engine reports it under its `call_id` first and then:

| The `call_id` names | What happens | Missed call | Receipt |
|---|---|---|---|
| The ring that is ringing, not yet answered | iOS refuses the report as a duplicate of the ringing call, so nothing new appears. The ring is ended as the caller hanging up. | Yes, `canceledByCaller` | `canceled`, to the ring's `status_url` |
| The call in progress, already answered (connecting or connected), including a ring the user answered a moment before | Nothing. The call continues. | No | None: `answered` was already sent |
| Nothing the device knows: the ring already ended, never arrived, or another call is in progress | The report rings, and the engine ends it at once. The user can see a brief flash of an incoming call; this is why Apple discourages cancel pushes. | No | None |

The engine remembers each cancelled `call_id` for 10 minutes (the most recent 32), so if APNs delivers the ring after its cancel, or delivers it again, that ring is reported and ended at once, with no missed call and no receipt.

A cancel that arrives after the user answered never ends the call; end a call in progress through your agent instead (Integration Guide, [section 11](IntegrationGuide.md#11-what-the-server-side-must-do)). Apple's guidance is not to cancel through pushes at all but over a connection the app already has; when your ring has not reached the device yet or you are unsure, prefer letting `ring_timeout` end it.

## Pre-connect

A ring push can ask the device to prepare the call while the phone rings, so the agent is ready when the user answers instead of being reached only then. Ask for it on every ring sent to a device that lists `preconnect` among its capabilities (`"media"` when your agent waits for `call-connected` and the device lists that signal, `"credentials"` otherwise), and send it to no other device: a device without the capability gets a plain ring, which works as before.

| `preconnect` | During the ring | At the answer |
|---|---|---|
| `"credentials"` | The app's credential code runs (the app's request is marked as being for a ringing call), and the device keeps the result. Nothing joins the room. | The device joins with those credentials, without a second request. |
| `"media"` | As for `"credentials"`, then the device joins the room. Its audio stays off: nothing plays, the microphone is closed, and the audio route is not touched until iOS activates the call's audio after the answer. | If the agent is already in the room, the call is connected at once. Otherwise the call is connected the moment the agent arrives. |

The device prepares only what three parties agree on, the lowest of: your `preconnect`, what the app allows for the target (the app may allow less, or nothing, per ring), and, for `"media"`, whether the app's transport can join a room while the phone rings. A transport that cannot (and any transport the app wrote without saying it can) joins only at the answer, as if you had sent `"credentials"`. Ask for no more than your agent is ready for.

Preparation starts once iOS has accepted the ring, not when the push arrives: a ring that Focus filters, or that the device is busy for, prepares nothing. A preparation that fails (credentials rejected, the room unreachable, the connection dropping, or, for `"media"`, the agent not in the room within the app's join timeout of the device joining, 30 seconds by default) never ends or changes the ring: it keeps ringing, and if the user answers, the device fetches credentials again and joins as it would without pre-connect.

The same holds when the user answers while the preparation is still under way and it then fails before the agent is there: the device makes an ordinary answer request for credentials (the app's request is then for an answered call, with the ring's `call_id`) and joins with what it returns, leaving the prepared room without `end-call`, since the fresh credentials may name the same room. So a credential request for an answered call, for a ring whose pre-connected agent is still waiting, means the device gave up on that agent: if you start a new one for the request, end the waiting one.

**Start your agent before you ring.** Pre-connect makes the device ready during the ring; whether the call is ready when the user picks up depends on your agent being in the room by then. Start the agent when you send the push, not when the device asks for credentials after the answer, and preferably send the push only once the agent is in the room, with a bound of a few seconds after which you ring anyway. Without inline credentials, return that agent's room to the credential request the device makes during the ring, which carries the ring's `call_id`. An agent that starts only at the answer leaves the user on a connecting call for as long as it takes to start; an agent that never comes fails the call as unreachable after the app's join timeout (30 seconds by default from the device's join, then once more after an ordinary answer request). What the user hears in each case is in the [Integration Guide, "Getting your agent there before the user answers"](IntegrationGuide.md#getting-your-agent-there-before-the-user-answers).

When the ring ends without an answer (declined, timed out, cancelled, or the phone's CallKit reset), the device leaves the room it joined. If its connection was up, it sends the `end-call` signal first (the same RTVI client message as a hangup), so your agent can end at once. The receipt is the ring's usual one.

### The `call-connected` signal

On every call, the ring's included, the engine tells the agent when the user is on the line, with an RTVI client message in the same envelope as `end-call`:

```json
{"id": "<8 characters>", "label": "rtvi-ai", "type": "client-message", "data": {"t": "call-connected"}}
```

For an answered ring it is sent once all of these hold, whichever comes last: the user answered, the connection to the agent is up, iOS activated the call's audio, the call is not on hold, and the app is not withholding the microphone while it plays its own "connected" sound. It is sent again after every reconnect of the call, since a new connection may reach a new agent session, and again if it could not leave the device (a few times, over about a minute). The rule for your agent, the capability that says the device sends it (`call_signals`), and the fallback for a lost one are in the [Integration Guide, "When your agent should start speaking"](IntegrationGuide.md#when-your-agent-should-start-speaking).

### What the agent must do for `"media"`

With `"media"` the device can be in the room, and your agent can hear its participant join, while the phone is still ringing. The agent must:

1. **Produce no audio until `call-connected` arrives.** Do not greet when the device joins, or on the client-ready event: the user has not answered yet. Start the greeting when the message arrives.
2. **Treat `end-call` as for any call:** end at once. Declining, a ring timeout and a cancel all send it while the device's connection is up.
3. **End by itself if nothing comes.** If no `call-connected` arrives within the ring's timeout plus 15 seconds of the agent's start, end the session: the ring is over and the device may have no connection left to tell you. Send `ring_timeout` with every `preconnect` ring, so the agent knows that timeout ([How long a ring lasts](#how-long-a-ring-lasts)).
4. **Use the receipts as a fallback, not as the signal** (inline rings need `status_url` for this). The engine sends `answered` the moment the user answers, before iOS has activated the call's audio and often before the device has (re)joined, so it always arrives before `call-connected`; a greeting released on it plays into audio that is not up yet. Wait for `call-connected`, and only if it has not come within a grace period (5 seconds or more; 10 is safer, see the Integration Guide's fallback) after both the `answered` receipt and the device being in the room, whichever is later, release the greeting then: a `call-connected` lost on the way. `declined`, `unanswered`, `canceled`, `busy` and `suppressed_by_focus` mean end the agent at once.
5. **Treat the user's first audio as a hint only.** The device never opens its microphone before the answer, so audio from the user's side also means the user answered, but it can be absent for a while (a muted user, push-to-talk).

How the agent receives the signal depends on the transport: on Daily, as an RTVI client message (a Pipecat bot's RTVI processor sees it as it sees `end-call`); on LiveKit, as a data packet on the room's data channel, which a Pipecat bot must parse from the transport's raw data-received event, as for `end-call`.

With `"credentials"` the device joins only after the answer, so the device joining already means the user answered; as on every call, the agent should still greet on `call-connected` when the device lists it.

### Withdrawing a pre-connected ring

When the device is in the room with your agent during a `"media"` ring, **the agent leaving the room is the cancel**: the engine ends the ring as the caller hanging up, reports a missed call (`canceledByCaller`) to the app and sends `canceled` to the ring's `status_url`. This needs no cancel push, so the user never sees the flash a cancel push can cause; prefer it whenever the device is connected. It applies only once the device saw the agent in the room and before the user answered. An agent that leaves before the device saw it there does not end the ring: the preparation is dropped, the phone keeps ringing, and an answer connects afresh. Once the user has answered, the agent leaving ends the call, as any agent hangup does.

## Ring-status receipts

When the push carries `status_url`, the engine reports the ring's terminal status there, once per ring:

```
POST <status_url>
Content-Type: application/json
Authorization: Bearer <bearer>          (omitted when the app supplies none)

{"call_id": "0b9f3c1e-7a2d-4e58-b6c4-91d2e0f3a7b5", "status": "answered"}
```

> **Compare `call_id` case-insensitively.** A UUID's hex digits can be written in either case, and the `call_id` in a receipt need not be spelled the way your push spelled it. A server that compared ids as plain strings has matched no receipt at all. Parse both as UUIDs, or lowercase both, before comparing. This engine sends the lowercase RFC 4122 form (`0b9f3c1e-7a2d-4e58-b6c4-91d2e0f3a7b5`); engines before 0.2 sent uppercase.

| `status` | Sent when |
|---|---|
| `answered` | The user answers. Sent at the moment of answering, before iOS activates the call's audio and before the transport connects, whether or not the call then connects. It therefore always precedes `call-connected`; it is not a signal that the user can hear the agent. |
| `declined` | The user declines the ringing call. |
| `busy` | The push arrived while another call was in progress, so it was reported and ended at once. |
| `suppressed_by_focus` | Focus or Do Not Disturb filtered the ring; the phone never rang. |
| `unanswered` | The ring timed out: nobody answered or declined it within the ring timeout. |
| `canceled` | A cancel push withdrew the ring while it was ringing, or the agent left a pre-connected ring ([Withdrawing a pre-connected ring](#withdrawing-a-pre-connected-ring)). |

Every status is sent only for a target the app knows; see "No receipt" below. **Accept statuses you do not know** (return 2xx and treat them as "ended, not answered"): later engines add statuses, and engines before 0.2 send only the first four.

Details:

- **`call_id`** is the call's UUID in lowercase canonical form, which may differ in case from what you sent: compare case-insensitively (above). If the push had no valid `call_id`, it is the id the engine minted.
- **The bearer** comes from the app (`CallEngineDelegate.callEngine(_:ringStatusBearerForTarget:)`), asked for at send time. What it is, and how your server checks it, is between you and the app. When the app returns nil or an empty string, the request has no `Authorization` header.
- **Fire-and-forget.** One attempt, no retry, the response is ignored, and a failure never affects the call. Return any 2xx. Treat a missing receipt as "unknown", not as "not answered".
- **No receipt** is sent for a malformed push, a push for a target the app does not know (whatever happens to the ring: busy, Focus-filtered, declined, timed out or cancelled included), a ring CallKit refused for a reason other than Focus (unless the device was busy, which still sends `busy`), a ring torn down by a CallKit provider reset, a cancel push itself, or a ring that arrived after its cancel. After `answered`, nothing further is sent: the end of the conversation is not a ring status.
- **Plain HTTP** is subject to App Transport Security. Use HTTPS unless the app has an ATS exception.
- **Privacy.** Receipts tell your server whether the user is on another call, has Focus on, or let the phone ring out. Do not forward them anywhere the user did not agree to.

## Guidance

- **Start the agent first, then ring, and ask for pre-connect** on every ring to a device that lists it ([Pre-connect](#pre-connect)). The phone joins within a fraction of a second; the agent's start is what the user waits for.
- **Mint a fresh `call_id` for every ring** and keep it unique. It is the CallKit call id and the key in every receipt. A push that repeats the id of the call still ringing or in progress is treated as a second delivery of that ring and ignored, so it cannot be used to ring again.
- **Do not ring again until the previous ring has resolved** (a receipt arrived, or enough time passed that it has clearly ended). A second ring while the first is still ringing is reported and ended immediately as busy, and the user may see it flash.
- **With pre-connect, withdraw a ring by ending the agent**, when the device is in the room with it ([Withdrawing a pre-connected ring](#withdrawing-a-pre-connected-ring)), rather than with a cancel push.
- **Bound the ring rather than cancel it.** A ring ends by itself after the app's ring timeout (60 seconds by default); send a shorter `ring_timeout` when the reason for the call expires sooner. To withdraw a ring that is still showing, send a cancel push, only to devices that list `cancel`, without `target_id`, and expect the flash described in [Cancelling a ring](#cancelling-a-ring) when the ring has already ended on the device. Do not send a cancel after an `answered` receipt.
- **Always include `display_name`** when you have it, so the ring shows the right name from the first frame.
- **Expect the token to change.** Reinstalling the app gives the device a new VoIP token, and APNs answers pushes to the old one with `410 Unregistered`. Drop tokens that return 410.
