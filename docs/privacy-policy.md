# Medut privacy policy

Effective 13 October 2026. This policy covers the Medut app for Android and
iOS (`com.medut.generic.phone`).

## In short

Medut is a softphone: it connects your phone to a SIP phone system (PBX) that
you or your organisation choose. The developer of Medut runs no servers for
the app and receives none of your data. There are no accounts with us, no ads,
no analytics and no crash reporting.

Your data stays on your phone, except what has to go to your SIP server to
make calls work, and the few network requests listed under
[Other services](#other-services).

## What the app handles, and where it goes

**SIP account details** (server address, user name, password, and optional
settings such as a TURN server). Stored on your phone. Passwords are kept in
the Android Keystore or the iOS Keychain. They are sent only to the SIP server
you entered, to sign in. When you add an account, the app first checks which
connection types the server accepts (TLS, TCP, UDP, secure WebSocket) and
sends no password until one of them answers.

**Calls and messages.** Call audio and SIP messages travel between your phone,
your SIP server and the other party, like any phone call. Whether they are
encrypted in transit depends on your account's settings: TLS and SRTP encrypt
them, UDP and TCP do not.

**Call history and message threads.** Stored in a database on your phone.
Delete call history in *Settings > Clear call history*. *Export call history
(CSV)* writes a file only when you tap it and pick where it goes.

**Call recordings.** Made only if you turn recording on (*Settings >
Recording*) or tap *Record* during a call. A notice is shown while a call is
recorded. Recordings are saved on your phone, in the folder you choose. The
app never uploads them. Recording laws differ by country: it is up to you to
tell the other person and to follow the law where you are.

**Contacts.** With your permission, the app reads your phone's address book
(read-only) to show names and let you call them. Contacts never leave your
phone.

**Microphone.** Used only during calls and, if you turn it on, to record
them.

**Camera.** Used only to scan a setup QR code when you add an account. The
image is processed on your phone and is not stored or sent anywhere.

**Logs.** The SIP log is kept on your phone. It leaves your phone only when
you tap *Share log* and pick where it goes.

**Sharing an account.** *Share as QR code* puts the account settings,
including the password, in a QR code. The app warns you before showing it.
Show it only to people you trust.

## Other services

- **Push wake-up (optional).** On iOS, and on Android builds with Firebase
  enabled, the phone gets a push token from Apple (APNs) or Google (Firebase
  Cloud Messaging). The app sends that token only to your SIP server, so the
  server can wake the app for an incoming call. Apple's and Google's privacy
  policies cover their push services.
- **STUN.** When an account uses ICE (on by default for secure WebSocket servers),
  the app asks a STUN server for your public IP address, to set up the call's
  media path. By default that is Google's public server
  (`stun.l.google.com`). You can set your own in the account's settings.
- **Fonts.** The app downloads its typefaces from Google Fonts the first time
  it runs. Google receives your IP address and the standard details of that
  request. See the [Google Fonts FAQ](https://developers.google.com/fonts/faq/privacy).

## Permissions

| Permission | Why |
|---|---|
| Microphone | Calls, and recording if you turn it on |
| Contacts | Show your contacts' names and call them |
| Camera | Scan a setup QR code |
| Notifications, full-screen alerts | Ring for incoming calls, including on the lock screen |
| Phone accounts (Android `MANAGE_OWN_CALLS`), CallKit (iOS) | Show calls in the system's calling screens |
| Nearby devices (Bluetooth) | Use Bluetooth headsets |
| Run in the background, start at boot, ignore battery optimisation | *Stay reachable* (Android): keep your SIP registration alive so calls can ring |

You can refuse or later revoke any permission in your phone's settings. The
features that need it will stop working, and the rest of the app keeps
working.

## Keeping and deleting data

Everything the app stores is on your phone, and none of it goes into a phone
backup or a transfer to a new phone. *Delete account* removes that
account's password and settings. Uninstalling the app deletes all of its data, except
recordings or exports you saved to a shared folder. Data on your SIP server is
controlled by whoever runs that server: ask them about it.

## Children

Medut is not directed at children under 13.

## Changes

If this policy changes, the new version is published at the same address with
a new effective date.

## Contact

[contact email]
