# Medut Softphone

A mobile softphone for any SIP PBX (Asterisk, FreeSWITCH, Kamailio, OpenSIPS,
3CX or a carrier SBC), built on [Medut-SDK](https://github.com/Ibrahimgamal99/Medut-SDK).
The app is Flutter; the ringing and call screens are native. It runs on Android
and iOS.

The app is only an interface: every feature maps to a Medut-SDK call. What the
SDK does not do (video, conference mixing, call park) is not in the app.

## The name

*Medut* is the Ancient Egyptian *mdwt* (/mɛduːt/): "words, speech". The app
icon is its first hieroglyph, the staff 𓌃, with two sound waves.

## Features

**Sign-in and accounts**
- Sign in with a SIP address (`201@pbx.example.com`) and a password. TLS, TCP,
  UDP and SIP over secure WebSocket are checked at once and shown as a live
  checklist. No password is sent until one of them answers. A server that only
  speaks WSS, such as a WebRTC Asterisk, signs in by itself with DTLS and ICE.
- A failed sign-in says why, lists things to try and shows the attempt's log
  with Copy and Share.
- Scan a QR code, import a setup file or paste one. Any account can be shared
  as a QR code.
- *More options* covers the transport, encryption (SRTP SDES / DTLS-SRTP over
  TLS and WSS only), auth user, outbound proxy, ICE and TURN. *All technical
  settings* covers every SDK option, grouped into sections that show their
  values. Saving tests the connection first.
- Any number of accounts, each with its live registration state: registered,
  reconnecting, or failed with the SIP code and a retry countdown. Dial rules
  pick the account for each number. Each account can set a dial prefix,
  + replacement and custom SIP headers (e.g. `Privacy: id`).

**Calls**
- Answer, decline (603), busy (486), hold, mute, speaker / Bluetooth, DTMF
  keypad, two calls with swap, and call waiting.
- Blind transfer. Warm transfer holds the caller while you talk to the other
  person, then offers *Back to caller* or *Join & drop*. Incoming REFER is
  followed.
- The call screen's dock has Mute, Speaker, Record and Hold. *More* holds Add
  call, Keypad and Message. When recording is off, the keypad goes back into
  the dock.
- Live call quality: a three-bar pill with the grade and MOS. Tap it for MOS
  both ways, jitter, loss, round trip, codec, SRTP suite, ICE path and jitter
  buffer.
- The screen turns off at the ear while the earpiece is in use. A connected
  headset is chosen when a call connects. When a headset is present, a picker
  lists it by name.

**Ringing**
- Use the phone's ringtone, one of Medut's tones or your own file, with a
  preview in Settings. Vibrate on/off and a ringback tone while the far end
  rings.
- Android rings through Do not disturb; iOS rings through CallKit with the
  chosen tone. A single "N missed calls" notification, message notifications,
  and an ongoing-call card with Mute and Speaker.
- Auto-answer with a 0–30 s delay. Blocked numbers.

**Recording**
- Calls are saved as WAV files on the phone. Recording is Off, Manual or
  Every call, and Every call can be turned off for one account.
- Files are named like the phone's own recorder
  (`201 Sara_261013_182405.wav`) and saved to `Recordings/Medut`, inside the
  app, or in a folder you choose. A recording cut off by the far end is
  repaired so it still plays.

**Calls tab**
- Calls, recordings and SIP MESSAGE chats in one list, filtered by All,
  Missed, Recorded or Messages. Search covers names, numbers and message text.
- Repeated missed calls from one number on the same day are folded into one
  row. Recordings play from the list. History can be exported with times,
  quality and SIP details.

**Contacts and status**
- Your status is Available, Ready or Do not disturb, in a pill that shows how
  long it has been set, and it is published with SIP PUBLISH. Available:
  calls to your extension ring, but you are out of the queues. Ready: in the
  queues too. Do not disturb: DND on and out of the queues. Each account
  picks its PBX (FreePBX / Issabel, FusionPBX / FreeSWITCH, 3CX or custom), and
  changing status dials that PBX's feature codes (queue log-in / log-out,
  DND on / off) only where the state changes.
- Status rules: office hours, and who is let through on Do not disturb.
- SIP has no directory, so extensions (2–6 digits) are learned from calls and
  from phone contacts saved with one, and can also be added by hand. Presence
  (SUBSCRIBE) is followed for favourites and hand-added extensions, plus the
  30 most recent.
- Favourites, the phone's contacts A–Z, and dialer suggestions from
  extensions, contacts and history.

**App**
- Tabs: Calls, Contacts and Settings. A dial button on Calls and Contacts
  opens the keypad.
- Settings in sections. *Advanced call settings* covers echo cancellation,
  noise suppression, automatic gain, the jitter buffer (auto / low delay /
  robust), extra STUN / TURN servers, relay-only, registration expiry and
  keep-alive. *Help & diagnostics* has the SIP log viewer and export, the SIP
  trace, the connection log and permissions.
- Light and dark themes, and English and Arabic with right-to-left layout on
  every screen, native ones included.

## Architecture

```
lib/
  sip/sip_service.dart     drives Medut-SDK over dart:ffi: accounts, calls,
                           presence, MWI, messages → call snapshots
  sip/probe.dart           finds how a server can be reached before sign-in
  sip/native_bridge.dart   the medut/native channel
  core/                    accounts, settings, call history (sqflite), people
  features/                sign-in, dialer, calls, contacts, chat, accounts,
                           status, settings, transfer
android/app/src/main/kotlin/com/medut/generic/phone/
  MedutApp                 process-wide Flutter engine
  call/                    CallActivity (native call UI), ringer, notifications
  service/                 MedutService (keep-alive FGS), boot receiver
  telecom/                 Telecom ConnectionService
ios/Runner/
  CallKitManager.swift     CallKit + PushKit
  CallViewController.swift native call UI
  MedutBridge.swift        the medut/native channel
assets/translations/       en.json, ar.json (shared with the native screens)
design/                    design canvases and icon sources
```

Dart owns all call state. On every change it pushes a full snapshot over the
`medut/native` channel. The native screens only draw the snapshot and send
taps back as `callAction` messages. Labels travel with the snapshot, so the
native and Flutter screens share one translation table.

### Staying reachable

**Android.** The Flutter engine is created in `MedutApp.onCreate`, not in the
activity, so SIP starts with the process and survives the app being closed or
swiped away. With *Stay reachable* on, `MedutService` runs as a foreground
service (`specialUse` on Android 14+, `dataSync` before) that keeps the
process and the registration alive. It restarts after a reboot. During a call
the ongoing-call notification holds the process. Settings asks the user to
allow ignoring battery optimisation, because Doze would otherwise cut the
network.

FCM is optional. If `android/app/google-services.json` is present, the app
puts its FCM token in the REGISTER Contact (RFC 8599 `pn-provider=fcm`). A push
from the server starts the process, which then registers and receives the
INVITE.

**iOS.** iOS does not keep a backgrounded app's socket alive, so a closed app
is woken by a VoIP push. The app registers with PushKit and puts the token in
the REGISTER Contact (RFC 8599 `pn-provider=apns`, `pn-prid=<token>`). Every
push is reported to CallKit at once, as Apple requires. The call is bound to
the SIP INVITE when it arrives, and an answer or decline given before then is
remembered.

Something on the server side has to send that push:
- **Kamailio / OpenSIPS:** a push module or script that reads the `pn-*`
  Contact params and calls APNs / FCM before forking the INVITE.
- **Asterisk / FreeSWITCH:** such a proxy in front, or a small push gateway.

Without one, iOS rings only while the app is open. The push payload can carry
`caller` / `caller_name` (or `from` / `display_name`) to show the caller on
the CallKit screen before the INVITE arrives.

## Build

```bash
flutter pub get
flutter analyze
flutter test
flutter run                  # on a connected Android device
flutter build apk --release  # Android
```

**Google Play:** `scripts/build-release.sh` builds the App Bundle signed with
the upload key from `android/key.properties`, and keeps the Dart debug info in
`symbols/<version>/`. [docs/google-play.md](docs/google-play.md) covers the key,
the developer account and every Play Console form. The privacy policy is
[docs/privacy-policy.md](docs/privacy-policy.md).

**iOS** (on a Mac):
1. Build `Medut.xcframework` in Medut-SDK (`scripts/build-ios.sh`). The SDK
   repo does not ship it yet, and `pod install` reports it missing otherwise.
2. `cd ios && pod install`.
3. In Xcode, set the team, enable *Push Notifications* and *Background Modes*
   (Voice over IP, Audio and Remote notifications are already in
   `Info.plist`), and create a VoIP Services certificate or APNs key for
   `com.medut.generic.phone`.
4. `flutter run` on a real device, because PushKit and CallKit need hardware.

The app id is `com.medut.generic.phone` on both platforms.

## License

See [LICENSE](LICENSE).
