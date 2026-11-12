# Push contract

For whoever builds the server that rings the app. It covers the APNs request, the payload the engine parses, what the user sees, and the ring-status receipts the engine sends back.

The flow: your server sends an APNs VoIP push to a device token the app gave you. The engine reports an incoming call to CallKit straight from the payload, so the phone rings on the lock screen, in the car, or wherever the user is. When the user answers, the engine joins a room, either from credentials in the push or from credentials the app fetches itself. If the push asked for receipts, the engine POSTs the ring's outcome back to you.

How the token reaches your server, and how your server knows which target ids a device accepts, is defined by the app you are working with; see [Integration Guide, section 7](IntegrationGuide.md#7-delivering-the-voip-token-to-your-server).

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
4. If the device is already in a call (ringing, dialing, connecting, connected or reconnecting), the new ring is reported and ended at once as unanswered. The live call is not touched, the engine reports a missed call to the app, and a `busy` receipt is sent. A push whose `call_id` is the call already in progress (a second delivery of the same ring) is not a new ring: it is reported, because iOS requires it, and otherwise ignored, with no missed call and no receipt.
5. If Focus or Do Not Disturb filters the ring, the phone never rings. The engine reports a missed call to the app and a `suppressed_by_focus` receipt is sent.
6. When the user answers, the engine joins the room: `room_url` and `token` from the push if both were present, otherwise whatever the app's own credential code returns. The call then behaves like an outgoing call, including reconnection.

### What the user sees when name or handle are omitted

CallKit shows `display_name` as the caller. Without it, the lock screen first shows the app's unknown-caller name and changes to the target's real name once CallKit has accepted the report and the app has resolved the target, which is usually a fraction of a second but can be visible. The handle is less visible: it appears where iOS lists the call, such as the Phone app's Recents, and it is what Siri and Contacts can match against. Echo the `display_name` and `handle` the app gave you at registration whenever you have them; do not invent your own, because the app's own values win as soon as it resolves the target.

### Inline credentials

Putting `room_url` and `token` in the push lets the device join without a round trip to your backend after answering. Two cautions:

- The push sits in APNs and on the lock screen for as long as the phone rings, so use a short-lived token scoped to one room.
- How the app reconnects after a drop is up to its `connect` code. A host that returns the push's credentials for every attempt, as the package's quick start does, reconnects with the same token, so it must stay valid for the length of the call.

## Ring-status receipts

When the push carries `status_url`, the engine reports the ring's terminal status there, once per ring:

```
POST <status_url>
Content-Type: application/json
Authorization: Bearer <bearer>          (omitted when the app supplies none)

{"call_id": "0B9F3C1E-7A2D-4E58-B6C4-91D2E0F3A7B5", "status": "answered"}
```

| `status` | Sent when |
|---|---|
| `answered` | The user answers. Sent at the moment of answering, before the transport connects, whether or not the call then connects. |
| `declined` | The user declines the ringing call. |
| `busy` | The push arrived while another call was in progress, so it was reported and ended at once. |

Every status is sent only for a target the app knows; see "No receipt" below.
| `suppressed_by_focus` | Focus or Do Not Disturb filtered the ring; the phone never rang. |

Details:

- **`call_id`** is the call's UUID in uppercase canonical form (`UUID.uuidString`), which may differ in case from what you sent. Compare case-insensitively. If the push had no valid `call_id`, it is the id the engine minted.
- **The bearer** comes from the app (`CallEngineDelegate.callEngine(_:ringStatusBearerForTarget:)`), asked for at send time. What it is, and how your server checks it, is between you and the app. When the app returns nil or an empty string, the request has no `Authorization` header.
- **Fire-and-forget.** One attempt, no retry, the response is ignored, and a failure never affects the call. Return any 2xx. Treat a missing receipt as "unknown", not as "not answered".
- **No receipt** is sent for a malformed push, a push for a target the app does not know (whatever happens to the ring: busy, Focus-filtered or declined included), a ring CallKit refused for a reason other than Focus (unless the device was busy, which still sends `busy`), or a ring torn down by a CallKit provider reset. After `answered`, nothing further is sent: the end of the conversation is not a ring status.
- **Plain HTTP** is subject to App Transport Security. Use HTTPS unless the app has an ATS exception.
- **Privacy.** Receipts tell your server whether the user is on another call or has Focus on. Do not forward them anywhere the user did not agree to.

## Guidance

- **Mint a fresh `call_id` for every ring** and keep it unique. It is the CallKit call id and the key in every receipt. A push that repeats the id of the call still ringing or in progress is treated as a second delivery of that ring and ignored, so it cannot be used to ring again.
- **Do not ring again until the previous ring has resolved** (a receipt arrived, or enough time passed that it has clearly ended). A second ring while the first is still ringing is reported and ended immediately as busy, and the user may see it flash.
- **There is no way to cancel a ring.** No payload stops a ring that is already showing, and the engine sets no timeout of its own; it rings until the user answers or declines, or iOS ends it. Do not rely on ringing for something time-critical that may be over before the user picks up.
- **Always include `display_name`** when you have it, so the ring shows the right name from the first frame.
- **Expect the token to change.** Reinstalling the app gives the device a new VoIP token, and APNs answers pushes to the old one with `410 Unregistered`. Drop tokens that return 410.
