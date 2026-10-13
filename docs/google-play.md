# Publishing on Google Play

What has to be done once, what to build, and what to answer in each Play
Console form. The rules quoted here are as of October 2026.

## 1. Upload key

Google Play only accepts bundles signed with an upload key. Play App Signing
then re-signs the app with a key Google keeps.

- Keystore: `~/keys/medut/upload-keystore.jks`, alias `upload`, outside the
  repo.
- `android/key.properties` (git-ignored) holds its path and password:

  ```properties
  storeFile=/home/<you>/keys/medut/upload-keystore.jks
  storePassword=...
  keyAlias=upload
  keyPassword=...
  ```

- Upload certificate SHA-256:
  `23:3B:27:BC:B8:30:05:A6:45:F9:B0:65:21:B6:90:AD:8E:8A:75:A1:A2:03:21:CC:42:AD:1F:FC:A4:AA:3A:FE`

**Back up the keystore file and its password**, for example in a password
manager. If the upload key is lost, Play Console support can reset it, but
that takes days.

Without `key.properties`, release builds are signed with the debug key. That
is fine on a test phone, but Play rejects it.

## 2. Build

```bash
scripts/build-release.sh          # build/app/outputs/bundle/release/app-release.aab
scripts/build-release.sh --apk    # also one APK per ABI, for direct installs
```

- Raise `version:` in `pubspec.yaml` before every upload. The number after `+`
  is the versionCode, and Play refuses a versionCode it has seen before.
- Keep `symbols/<version>/` for every build you ship. It is the only way to
  read that build's Dart stack traces.
- An APK signed with the upload key cannot be installed over one signed with
  the debug key, or over the Play version (which Google signs). Uninstall
  first: that deletes the app's accounts and history on that phone.

## 3. Developer account

- **Personal account** (created after 13 Nov 2023): before production, run a
  *closed test* with at least **12 testers opted in for 14 days in a row**.
  Recruit a few extra: if the count drops below 12, the 14 days restart. Then
  apply for production access on the Play Console dashboard.
- **Organization account**: no testing requirement, but it needs a D-U-N-S
  number.

## 4. Create the app

- Name **Medut**, default language English (United States), *App*, *Free*.
- The package name comes from the first upload: `com.medut.generic.phone`. It
  can never change.
- Accept *Play App Signing* with a Google-generated key.

## 5. App content (Policy > App content)

### Privacy policy

URL of [`docs/privacy-policy.md`](privacy-policy.md) once it is on `main`:
`https://github.com/Ibrahimgamal99/medut-softphone/blob/main/docs/privacy-policy.md`.
Fill in the contact email at its end first. The page must be public, so it
must not be a PDF or behind a login.

### App access

*All or some functionality is restricted.* Reviewers cannot test without a
SIP account, so give them one that keeps working during the review:

> Open Medut, enter the SIP address and password below, tap *Sign in*.
> Address: `...` Password: `...`
> To test a call, dial `...` (echo test). To test an incoming call, ...

### Ads

*No, my app does not contain ads.*

### Advertising ID

*No.* The app does not declare `com.google.android.gms.permission.AD_ID`.

### Content rating

Category *Utility, Productivity, Communication, or Other*. Answer *No* to the
violence, sexuality, language, drugs and gambling questions. Answer *Yes* to
"users can interact or exchange content" (calls and SIP messages).

### Target audience

*18 and over.* The app is not designed for children, which keeps it out of
the Families policy.

### News, health, financial features, government

*No* to news and government, *None* to health and financial features.

### Data safety

| Question | Answer |
|---|---|
| Collects or shares required data types? | Yes |
| All data encrypted in transit? | **No**. UDP and TCP accounts are not encrypted, only TLS/WSS and SRTP |
| Users can request deletion? | Yes. In the app: *Delete account* and *Clear call history*. Uninstalling deletes everything else |

| Data type | Collected | Shared | Ephemeral | Required | Purpose |
|---|---|---|---|---|---|
| Personal info > User IDs (SIP address, user name) | Yes | No | No | Required | App functionality, Account management |
| Audio > Voice or sound recordings (live call audio) | Yes | No | Yes | Required | App functionality |
| Messages > Other in-app messages (SIP MESSAGE) | Yes | No | No | Optional | App functionality |

Not collected:
- **Contacts:** read on the phone only.
- **Call recordings, call history, logs:** stored on the phone. Exports only
  happen when the user taps *Share* or *Export*.
- **Camera images:** QR codes are decoded on the phone.

If a build ever ships `google-services.json` (FCM push), add
*Device or other IDs: Yes, App functionality*.

Why "collected": Google counts any data sent off the phone, and Medut sends
the account, call audio and messages to the SIP server the user chose. Google's
help does not cover a server the user runs, so declaring them is the safe
reading. "Not shared" relies on the exemption for transfers the user starts:
placing a call or sending a message.

### Foreground service declarations

Play asks for each type: a description, the impact if the system delays or
stops the task, and a video link (an unlisted YouTube video works).

**specialUse (Android 14+)** and **dataSync (Android 10–13)** are the same
feature, *Stay reachable*:

> **Description:** *Stay reachable* (Settings, on by default) keeps the user's
> SIP registration and its network connection open, so the user's own PBX can
> ring the phone for incoming VoIP calls. Medut works with any SIP PBX
> (Asterisk, FreeSWITCH, 3CX, Kamailio). These servers cannot send Firebase
> Cloud Messaging pushes, so a push cannot wake the app: the connection itself
> must stay open. The service shows a persistent notification, and the user
> can turn it off in Settings.
>
> **Impact if deferred or interrupted:** the SIP registration expires and the
> PBX can no longer reach the phone. Every incoming call is missed (the caller
> gets busy or voicemail) until the user opens the app again.

**phoneCall** and **microphone** (together, during calls):

> **Description:** an ongoing VoIP call, managed through Android's Telecom
> `ConnectionService` as a self-managed calling app (`MANAGE_OWN_CALLS`). The
> service starts when the user places or answers a call and stops at hang-up.
> The microphone type captures the user's voice while the call screen is in
> the background or the phone is locked.
>
> **Impact if deferred or interrupted:** the call drops, or the other person
> stops hearing the user, as soon as the user leaves the call screen or locks
> the phone.

**Video**, one recording for all four types:
1. Sign in to an account, then open *Settings*: *Stay reachable* is on and its
   notification is shown.
2. Swipe Medut away from Recents and lock the phone.
3. Call the account from another phone: Medut rings on the lock screen.
   Answer it.
4. Press Home during the call: the call notification stays and both sides
   still hear each other. Hang up from the notification.

### Full-screen intent

*Making and receiving calls.* Calling apps get `USE_FULL_SCREEN_INTENT`
granted by default. Without this declaration, Android 14+ asks the user, and
Settings shows a warning card until they allow it.

### Battery optimisation (no form, but reviewers may ask)

The app asks to ignore battery optimisation only when *Stay reachable* is on
and the app is not yet exempt, from a Settings card the user taps. If Play
asks why, answer:

> Medut is an enterprise VoIP client for the user's own SIP PBX. These servers
> cannot send FCM high-priority messages, and Doze closes the SIP connection,
> so calls are missed. This matches Android's acceptable use case *"enterprise
> VoIP apps that can't use FCM"* in Optimize for Doze and App Standby.

## 6. Store listing

- **Category:** Communication.
- **Contact email:** required, and shown publicly.
- **App icon:** [`play-store/icon-512.png`](play-store/icon-512.png)
  (512 × 512).
- **Feature graphic:** 1024 × 500, still to make.
- **Phone screenshots:** 2 to 8, still to take.
- **Short description** (80 characters max):

  > Softphone for any SIP PBX: calls, transfer, recording, chat, many accounts.

- **Full description:**

  > Medut is a softphone for your own SIP phone system: Asterisk, FreeSWITCH,
  > 3CX, Kamailio, OpenSIPS or a carrier SBC. It has no server of its own:
  > your calls and messages go only to your SIP server.
  >
  > • Sign in with a SIP address and password. TLS, TCP, UDP and secure
  >   WebSocket are tried at once, and a failed sign-in says why.
  > • Add accounts by QR code, and use as many accounts as you need, each with
  >   its live status.
  > • Answer, decline, hold, mute, speaker and Bluetooth, keypad, two calls
  >   with swap, call waiting.
  > • Blind and warm transfer.
  > • Call recording on demand or for every call. Recordings stay on your
  >   phone.
  > • SIP messages, call history with call quality, and your phone's
  >   contacts.
  > • Ringing on the lock screen, even when the app is closed.
  > • Encrypted calls with TLS and SRTP (SDES or DTLS), plus ICE and TURN.
  > • English and Arabic.
  >
  > You need an account on a SIP server. Medut does not provide phone numbers
  > or calling plans.

## 7. Release

Upload `app-release.aab` to the closed testing track, add the testers' emails
(or a Google Group), and share the opt-in link. After 14 days with at least 12
testers, apply for production access, then promote the release to
*Production*.
