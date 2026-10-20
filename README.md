# Medut Softphone

A softphone for any SIP PBX (Asterisk, FreeSWITCH, Kamailio, OpenSIPS, 3CX or
a carrier SBC), built on [Medut-SDK](https://github.com/Ibrahimgamal99/Medut-SDK).
The app is Flutter; on the phone the ringing and call screens are native. It
runs on Android, iOS, Linux and Windows.

The app is only an interface: every feature maps to a Medut-SDK call. What the
SDK does not do (video, conference mixing, call park) is not in the app.

## Download

**Android:** [latest release APK](https://github.com/Ibrahimgamal99/medut-softphone/releases/latest).
Open the `.apk` on the phone and allow installs from your browser or file
manager when Android asks. Each release page also lists the APK's SHA-256
checksum. Updates install over the previous version: every release is signed
with the same key.

**iOS:** not distributed yet; build from source on a Mac (see
[Build](#build)).

**Linux:** the `.rpm` (Fedora: `sudo dnf install ./medut-*.rpm`) or the
`.tar.gz`, which runs from any folder (`./medut`). The tray icon needs a
StatusNotifier host: KDE, Xfce and Cinnamon have one, GNOME needs the
AppIndicator extension. Passwords go in the desktop keyring (libsecret).

**Windows:** the `-setup.exe` installs for your user, with no administrator
rights; the `.zip` runs from any folder. Windows 10 or later.

## On the desktop

The same app, laid out for a window, with the desktop around it:

- **Layout:** a narrow window is the phone app. A wide one puts the tabs down
  the side and keeps the keypad in a pane on the right, which becomes the
  call while one is up.
- **Tray:** closing the window keeps Medut registered in the tray; Quit is in
  its menu, with Do not disturb and Hang up. The icon shows connected,
  offline, in a call and missed calls.
- **Ringing:** while you are in another window a call rings in a small card
  on top, in the corner, with Answer and Decline. Wayland does not let an app
  put itself on top, so there it also shows a notification with both buttons.
  Enter answers and Esc declines.
- **Audio:** pick the microphone and speaker in the call or in Settings ›
  This computer › Audio devices; on Linux the ring can go to another device
  (the speakers while calls use a headset).
- **Call links:** `tel:`, `sip:`, `sips:` and `callto:` links open Medut and
  dial. Settings › This computer › Call links makes Medut their app (on
  Windows you confirm it in Default apps). `medut 201` dials from a terminal;
  `medut --answer` and `medut --hangup` answer and hang up.
- **Start at login:** in the tray, ready for calls.

There is no push wake-up on the desktop: the app stays registered while it
runs.

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
  as a QR code. [docs/account-setup.md](docs/account-setup.md) gives the
  format, with examples.
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
- Settings in sections. *Advanced call settings* covers the codec order,
  echo cancellation, noise suppression, automatic gain, the jitter buffer
  (auto / low delay / robust), extra STUN / TURN servers, relay-only,
  registration expiry and keep-alive. *Help & diagnostics* has the SIP log
  viewer and export, the SIP trace, the connection log and permissions.
- One codec order for every account: G.711 A-law, G.711 µ-law, then Opus by
  default. An account on a web link (WSS) offers Opus first, as WebRTC
  servers expect.
- Light and dark themes, and English and Arabic with right-to-left layout on
  every screen, native ones included.

## Architecture

```
lib/
  sip/sip_service.dart     Flutter's side of the phone: mirrors the native
                           engine's state, hands it accounts and settings
  sip/probe.dart           finds how a server can be reached before sign-in
  sip/native_bridge.dart   the medut/native channel
  core/                    accounts, settings, call history (sqflite), people
  features/                sign-in, dialer, calls, contacts, chat, accounts,
                           status, settings
android/app/src/main/kotlin/com/medut/generic/phone/
  engine/PhoneEngine.kt    the phone: Medut-SDK (Kotlin), accounts, calls,
                           transfers, recording, history, presence, messages
  engine/                  account store, settings, history writer, quality
  call/                    CallActivity (ringing, in-call, Transfer, Add call),
                           ringer, notifications
  service/                 MedutService (keep-alive FGS), boot receiver
  push/                    FCM wake-up
ios/Runner/
  PhoneEngine.swift        the phone: MedutKit, its CallKit and PushKit wake-up
  EngineSupport.swift      account store, settings, history writer, quality
  CallViewController.swift in-call screen, Transfer, Add call
  MedutBridge.swift        the medut/native channel
lib/desktop/
  engine.dart              the phone on Linux and Windows: Medut-SDK over
                           dart:ffi, behind the same medut/native surface
  call_view.dart           the call screen (CallActivity in Flutter)
  desktop_shell.dart       window, tray, ringing card, notifications, links
linux/, windows/           runners: one instance, links handed to it
assets/translations/       nine languages (shared with the native screens)
design/                    design canvases and icon sources
docs/                      account QR / JSON format, push wake-up setup
```

The native engine owns SIP and every call. It starts with the process
(`MedutApp` on Android, `AppDelegate` on iOS), with or without the Flutter
UI: a push or a reboot registers the accounts and rings a call without
starting Flutter at all. It keeps the accounts (encrypted, passwords
included) and the settings Flutter last pushed, writes each finished call and
each SIP message into the same `medut.db` the Calls tab reads, and draws the
call screens from its own snapshots. Flutter shows the history, edits
accounts and settings, and forwards dial, message and status taps over the
`medut/native` channel. The labels Flutter pushes are kept natively, so the
two still share one translation table.

### Staying reachable

**Android.** The engine starts in `MedutApp.onCreate`, so SIP starts with the
process and survives the app being closed or swiped away. With *Stay
reachable* on, `MedutService` runs as a foreground service (`specialUse` on
Android 14+, `dataSync` before) that keeps the process and the registration
alive. It restarts after a reboot. During a call the ongoing-call notification
holds the process. Settings asks the user to allow ignoring battery
optimisation, because Doze would otherwise cut the network.

FCM is optional. If `android/app/google-services.json` is present, the engine
puts its FCM token in the REGISTER Contact (RFC 8599 `pn-provider=fcm`). A
call push from the server starts the process and rings at once, with the
caller the push names (`caller_name` / `caller_uri`), while the accounts
refresh their registration. The INVITE then takes the ring over; an answer
given before it arrives is carried out, and a decline rejects it. No INVITE
within 20 s, or a `cancel` push, ends the ring as a missed call.

**iOS.** iOS does not keep a backgrounded app's socket alive, so a closed app
is woken by a VoIP push. The engine registers with PushKit and puts the token
in the REGISTER Contact (RFC 8599 `pn-provider=apns`, `pn-prid=<token>`).
Every push is reported to CallKit at once, as Apple requires, by the SDK's
`MedutPush.wake`. The call is bound to the SIP INVITE when it arrives, and an
answer or decline given before then is carried out.

Something on the server side has to send that push:
- **Kamailio / OpenSIPS:** a push module or script that reads the `pn-*`
  Contact params and calls APNs / FCM before forking the INVITE.
- **Asterisk / FreeSWITCH:** such a proxy in front, or a small push gateway.

Without one, iOS rings only while the app is open. The push payload can carry
`caller_uri` / `caller_name` (the Medut-SDK push contract, docs/guides/push.md
in the SDK) to show the caller on the CallKit screen before the INVITE arrives.
[docs/push.md](docs/push.md) walks through the Firebase and APNs setup, the
payload, and what the server has to do.

## Build

```bash
flutter pub get
flutter analyze
flutter test
flutter run                  # on a connected Android device
flutter build apk --release  # Android
```

**Release:** `scripts/build-release.sh` builds the App Bundle signed with the
upload key from `android/key.properties`, and keeps the Dart debug info in
`symbols/<version>/`.

**GitHub Release:** bump `version:` in `pubspec.yaml`, commit, then push a
matching tag (`git tag v0.2.0 && git push origin v0.2.0`). The
`android-release` workflow builds the signed APK, checks it is not
debug-signed, and attaches it with its checksum and debug symbols to the
release for that tag. Signing comes from the repository secrets listed at the
top of `.github/workflows/android-release.yml`.

**Linux** (Fedora; Debian and Ubuntu have the same libraries under -dev names):
1. `sudo dnf install clang cmake ninja-build gtk3-devel libsecret-devel
   libayatana-appindicator-gtk3-devel rpm-build`
2. `flutter run -d linux`, or `scripts/build-desktop.sh` for the `.tar.gz`
   and `.rpm` in `dist/`.

**Windows:** `flutter build windows` (Visual Studio 2022 with C++ and ATL).
The `desktop` workflow builds it with its Inno Setup installer
(`windows/installer.iss`), and Linux too, on every push; a `v*` tag attaches
both to the release.

`medut.so` and `medut.dll` (x64 and arm64) come prebuilt with the medut
plugin at the Medut-SDK commit `pubspec.yaml` pins, and Flutter bundles the
one for the target: an SDK fix reaches the desktop once the pin moves.

**iOS** (on a Mac):
1. Build `Medut.xcframework` in Medut-SDK (`scripts/build-ios.sh`). The SDK
   repo does not ship it yet, and `pod install` reports it missing otherwise.
2. `cd ios && pod install`.
3. In Xcode, set the team, enable *Push Notifications* and *Background Modes*
   (Voice over IP, Audio and Remote notifications are already in
   `Info.plist`), and create a VoIP Services certificate or APNs key for
   `com.medut.generic.phone`.
4. `flutter run` on a real device, because PushKit and CallKit need hardware.

The app id is `com.medut.generic.phone` on every platform.

## License

See [LICENSE](LICENSE).
