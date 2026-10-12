# Medut Softphone

A mobile softphone for any SIP PBX — Asterisk, FreeSWITCH, Kamailio, OpenSIPS,
3CX or a carrier SBC — built on [Medut-SDK](https://github.com/Ibrahimgamal99/Medut-SDK).
Flutter for the app, native screens for ringing and calls. Android and iOS.

The app is only an interface: every feature maps to a Medut-SDK call. What the
SDK does not do (video, conference mixing, call park, visual voicemail) is not
in the app.

## Features

- Any number of SIP accounts over UDP / TCP / TLS / WS / WSS, with live
  registration state (registered, reconnecting, failed with the SIP code and
  retry countdown) and dial rules that pick the account per number.
- Add an account by QR code, by importing a Medut-SDK account JSON, or by
  typing it in; Advanced holds every SDK option (SRTP SDES / DTLS-SRTP,
  ICE / STUN / TURN, codec order, outbound proxy, auth user, DTMF mode, push).
- Calls: answer, decline (603), busy (486), hold, mute, speaker / Bluetooth,
  DTMF keypad, local WAV recording, two calls with swap, call waiting,
  blind transfer, attended transfer ("talk first" → Complete), and following a
  transfer the far end sends us (incoming REFER).
- Live call quality: MOS both ways, jitter, loss, RTT, codec, SRTP suite, ICE
  path, jitter buffer.
- Team: your status (Available / Silent / Do not disturb) published with SIP
  PUBLISH, office hours, "let through" rules; colleagues' presence via
  SUBSCRIBE; device contacts.
- Activity: calls, recordings and SIP MESSAGE chats in one list, voicemail
  count from MWI.
- Light / dark theme, English / Arabic with right-to-left layout on every
  screen, native ones included.
- SIP log viewer and export.

## Architecture

```
lib/                 Flutter UI + SipService (drives Medut-SDK over dart:ffi)
  sip/sip_service.dart   accounts, calls, presence, MWI, messages → call snapshots
  sip/native_bridge.dart the medut/native channel
  features/              dialer, activity, chat, team, accounts, settings, transfer
android/…/phone/     MedutApp (process-wide engine), CallActivity (native call UI),
                     MedutService (keep-alive FGS), Telecom ConnectionService,
                     ring notifications, boot receiver
ios/Runner/          CallKitManager (CallKit + PushKit), CallViewController
                     (native call UI), MedutBridge
```

Dart owns all call state. On every change it pushes a full snapshot over the
`medut/native` channel; the native screens only draw it and send taps back as
`callAction` messages. Labels are sent with the snapshot, so native and Flutter
share one translation table (`assets/translations/`).

### Staying reachable

**Android.** The Flutter engine is created in `MedutApp.onCreate`, not in the
activity, so SIP runs on every process start and survives the app being closed
or swiped away. With *Stay reachable* on, `MedutService` runs as a foreground
service (`specialUse` on Android 14+, `dataSync` before) and keeps the process
and the registration alive; it restarts after a reboot. During a call it holds
the process with the ongoing-call notification. Ask the user to allow ignoring
battery optimisation (the Accounts tab shows a banner) — Doze would otherwise
cut the network.

Optional FCM: drop `android/app/google-services.json` in place and the app sends
its FCM token in the REGISTER Contact (RFC 8599 `pn-provider=fcm`). A push from
the server starts the process, which registers and receives the INVITE.

**iOS.** iOS does not keep a backgrounded app's socket alive, so a closed app is
woken by a VoIP push. The app registers with PushKit and sends the token in the
REGISTER Contact (RFC 8599 `pn-provider=apns`, `pn-prid=<token>`). Every push is
reported to CallKit at once, as Apple requires; the call is bound to the SIP
INVITE when it arrives (answering or declining before it arrives is remembered).

Something on the server side must send that push. Options:
- **Kamailio / OpenSIPS:** a push module or script that reads the `pn-*`
  Contact params and calls APNs / FCM before forking the INVITE.
- **Asterisk / FreeSWITCH:** put such a proxy in front, or a small push
  gateway service.
Without one, iOS rings only while the app is open.

The push payload can carry `caller` / `caller_name` (or `from`, `display_name`)
to show the caller on the CallKit screen before the INVITE arrives.

## Build

```bash
flutter pub get
flutter analyze
flutter test
flutter run                 # Android device
flutter build apk --release # Android
```

**iOS** (on a Mac):
1. Build `Medut.xcframework` in Medut-SDK (`scripts/build-ios.sh`) — the SDK repo
   does not ship it yet. `pod install` reports it missing otherwise.
2. `cd ios && pod install`.
3. In Xcode: set the team, enable *Push Notifications* and *Background Modes*
   (Voice over IP, Audio, Remote notifications — already in `Info.plist`), and
   create a VoIP Services certificate / APNs key for `com.medut.generic.phone`.
4. `flutter run` on a real device (PushKit and CallKit need hardware).

App id on both platforms: `com.medut.generic.phone`.

## Still to verify on devices

- Swift (CallKit, PushKit, call screen) is written but has not been compiled yet:
  first Mac build.
- Android: incoming / outgoing calls, lock-screen ringing, background
  registration over hours, Bluetooth routing, Wi-Fi ↔ LTE handover.
- Release signing, launcher icons.

## License

See [LICENSE](LICENSE).
