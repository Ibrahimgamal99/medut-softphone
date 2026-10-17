# Push wake-up: incoming calls on a sleeping phone

A phone that is asleep, or whose app is closed, cannot hold a SIP connection
open. With push set up, the SIP server asks Google (FCM) or Apple (APNs) to
wake Medut when a call arrives, the phone rings at once, and the server hands
the INVITE over as soon as the app has registered again. This page covers what
to set up in the app, what the server must do, and how to see it working.

```
caller ──INVITE──▶ SIP server ──push──▶ FCM / APNs ──▶ phone: Medut starts, rings,
                       │                                 re-registers
                       └── INVITE forwarded when the registration is refreshed
```

Push is per account: *Edit account → Push wake-up* (on by default; `"push":
true` in an [account JSON](account-setup.md)). The account only carries push
parameters when the phone has a token, so an app built without push simply
registers without them.

## What the app sends the server

With push on and a token in hand, every REGISTER carries the token in the
Contact URI (RFC 8599):

```
Contact: <sip:1000@192.0.2.10:5061;transport=tls;pn-provider=fcm;pn-prid=<token>;pn-param=<project ID>>
```

| Param | Android | iOS |
|---|---|---|
| `pn-provider` | `fcm` | `apns` (App Store / TestFlight), `apns-sandbox` (debug builds) |
| `pn-prid` | The FCM registration token | The PushKit VoIP token, as hex |
| `pn-param` | The Firebase **project ID**, read from `google-services.json` | Not sent. The server holds the APNs topic (see below). |

When the token changes, the app sends a REGISTER with the new one at once.
The server has to match the binding on these params, because the phone's
address changes between registrations.

## Android: Firebase Cloud Messaging

1. **Create a Firebase project** at <https://console.firebase.google.com>, or
   open the one you have. The project ID (*Project settings → General*) is
   what the app sends as `pn-param`.
2. **Add an Android app** to it with the package name
   `com.medut.generic.phone`. The SHA-1 is not needed for messaging.
3. **Download `google-services.json`** and put it at
   `android/app/google-services.json`. It is in `.gitignore`: it names your
   project and should not be committed.
4. **Build.** Nothing else changes. `android/app/build.gradle.kts` applies the
   Google services plugin only when that file exists, and `MedutApp` fetches
   the FCM token when the engine starts. Without the file the app still
   builds, and *Stay reachable* (a foreground service) keeps it registered
   instead.
5. **Give the server a way to send pushes.** In Firebase, *Project settings →
   Service accounts → Generate new private key* downloads a service-account
   JSON. The server uses it to get an OAuth token for the
   `https://www.googleapis.com/auth/firebase.messaging` scope and posts to
   `https://fcm.googleapis.com/v1/projects/<project ID>/messages:send`.

The push must be a **data-only** message with **high** priority. A
notification message would show a notification and not start the app's code,
and FCM values must be strings:

```json
{
  "message": {
    "token": "<pn-prid from the REGISTER>",
    "android": { "priority": "high" },
    "data": {
      "type": "call",
      "call_id": "a84b4c76e66710@pbx.example.com",
      "caller_uri": "sip:2001@pbx.example.com",
      "caller_name": "Reception",
      "aor": "sip:1000@pbx.example.com"
    }
  }
}
```

What happens on the phone: the process starts, the engine re-creates the
accounts and rings at once with `caller_name` / `caller_uri`, and the accounts
refresh their registration. The INVITE whose Call-ID is `call_id` takes the
ring over. An answer given before it arrives is carried out, a decline rejects
it. No INVITE within 20 s, or a push with `"type": "cancel"` and the same
`call_id`, ends the ring as a missed call.

Two Android settings matter. *Settings → Battery optimisation → Allow* keeps
Doze from cutting the network while the app registers. And FCM lowers the
priority of an app whose high-priority pushes do not lead to something the
user sees, which a ring is, so a test that sends pushes with no call behind
them should not run for long.

## iOS: APNs VoIP pushes

iOS does not keep a backgrounded app's socket alive, so without push an
iPhone rings only while the app is open. Medut uses PushKit VoIP pushes, which
iOS delivers even when the app is terminated, and reports each one to CallKit
at once, as Apple requires.

1. **App ID.** In the Apple Developer portal, the App ID
   `com.medut.generic.phone` needs the *Push Notifications* capability.
2. **Xcode.** Under *Signing & Capabilities* for the Runner target, set your
   team and add *Push Notifications*. *Background Modes* with *Voice over IP*
   and *Audio* are already in `Info.plist`, and `Runner.entitlements` has
   `aps-environment = development`; Xcode switches it to `production` when
   archiving.
3. **A key for the server.** *Certificates, Identifiers & Profiles → Keys →
   +*, with *Apple Push Notifications service (APNs)* ticked, gives a `.p8`
   file, a **Key ID**, and your **Team ID** is at the top of the page. One key
   serves every app of the team and both APNs environments. A *VoIP Services*
   certificate works too, if your server only takes certificates.
4. **Run on a real device.** PushKit and CallKit do not exist in the
   simulator. The token appears in the SIP log in the first REGISTER after
   launch.

The server sends an HTTP/2 request to APNs with these headers; the topic is
the bundle ID followed by `.voip`:

| Header | Value |
|---|---|
| `apns-topic` | `com.medut.generic.phone.voip` |
| `apns-push-type` | `voip` |
| `apns-priority` | `10` |
| `apns-expiration` | `0` (deliver now or not at all) |
| `authorization` | `bearer <JWT signed with the .p8, Key ID and Team ID>` |

The body is the same keys as on Android, at the top level or under a `medut`
object:

```json
{ "caller_uri": "sip:2001@pbx.example.com", "caller_name": "Reception",
  "aor": "sip:1000@pbx.example.com", "call_id": "a84b4c76e66710@pbx.example.com" }
```

**Sandbox and production are different servers.** A debug build registers
with `pn-provider=apns-sandbox` and its token only works at
`api.sandbox.push.apple.com`; a TestFlight or App Store build registers with
`apns` and needs `api.push.apple.com`. The server must pick the host from
`pn-provider`. A mismatch fails silently: APNs accepts the push and nothing
arrives.

Because the app does not send `pn-param`, the server keeps the topic and the
key in its own configuration. Not on iOS yet, in the SDK: `call_id` matching
and `cancel` pushes. A push that no INVITE follows ends as a missed call.

## What the server must do

Any server that follows the contract works. In short:

1. Store `pn-provider`, `pn-prid` and `pn-param` with the registration, and
   match the binding on them.
2. On an INVITE for a device with push params, send a `call` push and hold
   the INVITE for about 25 to 30 s: push delivery, a cold start, TLS and the
   REGISTER all fit in that.
3. When the registration is refreshed, forward the held INVITE to the new
   contact, over the connection the REGISTER came in on for TCP and TLS.
4. When the caller gives up, or the wait times out, send a `cancel` push with
   the same `call_id`.
5. A REGISTER with a new `pn-prid` is the device's new binding.

- **OpenSIPS** has RFC 8599 built into its `registrar` module (3.4.18 or
  later, or 3.6.7 or later). **Kamailio** does it with a script around its
  push module.
- **Asterisk, FreePBX, Issabel and FreeSWITCH** do not speak RFC 8599. They
  need such a proxy in front, or a small push gateway that watches for
  INVITEs to a device with push params, sends the push, and lets the PBX
  retry the INVITE once the phone has registered.

The Medut-SDK guide `docs/guides/push.md` has the full contract and a worked
OpenSIPS configuration, including the cancel push.

## Seeing it work

- **The token reaches the server.** *Settings → Diagnostics → SIP log*: the
  REGISTER's `Contact` header carries `pn-provider`, `pn-prid` and, on
  Android, `pn-param`. If it does not: on Android the file is missing or the
  build predates it, on iOS the capability or the device, and on both the
  account's *Push wake-up* switch is off.
- **The push arrives.** *Settings → Diagnostics → Connection log* gets a line
  per push: `push call: call_id=… aor=… caller=…`, then the registration
  refresh and the INVITE.
- **A quick Android test without a PBX.** Register, note the token from the
  SIP log, swipe the app away, and post the FCM message above with an access
  token from your service account:

  ```bash
  TOKEN=$(gcloud auth application-default print-access-token)   # or any OAuth client
  curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
       -d @message.json \
       https://fcm.googleapis.com/v1/projects/<project ID>/messages:send
  ```

  The phone rings with the caller named in the push and, with no INVITE
  behind it, records a missed call after 20 s.

## Troubleshooting

| Symptom | Cause |
|---|---|
| No `pn-*` in the REGISTER | `google-services.json` missing (Android); Push Notifications capability or a simulator (iOS); *Push wake-up* off on the account |
| FCM says delivered, phone does not ring | The message was a notification message, or not high priority; or the phone has not allowed background activity for Medut |
| iOS: APNs returns 200, nothing arrives | `apns` token sent to the sandbox host or the other way round; wrong topic (must end in `.voip`); `apns-push-type` not `voip` |
| Rings, then "missed call" with no INVITE | The server did not forward the INVITE on the refreshed registration: it must match the binding on the push params, not on the address |
| Rings twice | The push's `aor` names the account differently from how it registered; the app maps it by user when only one account has that user |
