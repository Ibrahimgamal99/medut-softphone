# Account QR codes and setup files

How to give someone a Medut account as a QR code, a file or a line of text,
and exactly how the app reads it. The parser is
`SipAccountConfig.parseProvisioning` in `lib/core/accounts.dart`, and
`test/core_test.dart` checks that every example on this page parses.

## Where the app reads them

- **Sign-in screen**, under *Or set up from what your admin sent*: *Scan QR*,
  *Import file* (`.json` or `.txt`, UTF-8) or *Paste*.
- **Edit account**: the same three, plus *JSON*, which shows the account in
  this format to read, copy or edit.

The same text works in all of them. Two forms are accepted:

1. **Account JSON**: a JSON object, the Medut-SDK account format. It can hold
   every connection setting.
2. **SIP URI**: `sip:user:password@host:port;transport=tls`. It is short
   enough to type, but it has no web link, encryption, ICE or TURN.

Anything else shows *That isn't a SIP account*.

## What happens after reading

**On the sign-in screen**, the form is filled in, then:

- If there is a password, Medut signs in at once. If not, it asks for the
  password first.
- If the text contains the word `transport` anywhere, or has a `server_url`,
  that transport is used exactly as given.
- Otherwise the transport is *Auto*. Medut checks TLS, TCP, UDP and secure
  WebSocket at once and keeps the first one that registers.
- For WebSocket, it tries the port in `uri` with `/ws`, `/sip-ws` and `/`. If
  there is no port, it tries 443 (`/ws`, `/sip-ws`, `/`), 8089 (`/ws`), 7443
  (`/`) and 8443 (`/ws`).
- When it finds a WebSocket server, it turns on DTLS-SRTP and ICE by itself.

**In Edit account**, the fields are filled in, and nothing connects until you
tap *Save*, which tests the connection first. Import keeps the account's own
DTMF mode, voicemail code, dial prefix, + replacement, custom headers, PBX
type and status codes, recording and push settings.

## JSON fields

Only `uri` is required. Unknown fields are ignored. Field names are case
sensitive.

| Field | Type | Default | What it does |
|---|---|---|---|
| `uri` | string | required | `user@host` or `user@host:port`. A `sip:` or `sips:` in front is allowed. |
| `password` | string | `""` | Leave it out to have the app ask for it. |
| `name` | string | `display_name`, then the host | Account label in the app. |
| `display_name` | string | `""` | Caller name the other side sees. |
| `transport` | string | `udp`, or *Auto* on the sign-in screen when left out | `udp`, `tcp`, `tls`, `ws` or `wss` (any case). |
| `server_url` | string | `""` | The web link. **Required** for `ws` and `wss`: `wss://host:port/path`. |
| `auth_user` | string | the user in `uri` | Authentication user, when it differs from the extension. |
| `outbound_proxy` | string | `""` | For example `sip:proxy.example.com;lr`. |
| `media_enc` | string | `none` | `sdes` (or `srtp`) or `dtls_srtp` (or `dtls`). Used only over `tls`, `ws` and `wss`; over UDP and TCP calls stay unencrypted. |
| `ice_enabled` | boolean | `false` | ICE for NAT. On the sign-in screen, ICE with no STUN server uses `stun:stun.l.google.com:19302`. |
| `stun_server` | string | `""` | `stun:host:port`. |
| `turn_server` | string | `""` | `turn:host:port`. Used only with ICE on. |
| `turn_user`, `turn_pass` | string | `""` | TURN credentials. |
| `audio_codecs` | list of strings | `["opus", "alaw", "ulaw"]` | Codec order, from `opus`, `alaw` (G.711 A-law) and `ulaw` (G.711 µ-law). `audio_codec` with a single string also works. |
| `verify_tls` | boolean | `true` | `false` accepts a self-signed server certificate. |

Things that break a JSON payload:

- **Wrong types.** Booleans must be `true` / `false` and lists must be lists.
  A string `"true"` or `"5061"` makes the whole payload invalid.
- **No `@` in `uri`.** Without it there is no account.
- **WebSocket without `server_url`.** `transport: "wss"` with no
  `server_url` stops sign-in at *Add the web link (wss://…) under More
  options*.
- **WebSocket without DTLS and ICE.** A WebRTC server needs both, so write
  them in. With a fixed transport the app does not add them by itself.

Not in this format, so set them in the app after import: voicemail code, dial
prefix, + replacement, custom SIP headers, PBX type and status codes, DTMF
mode, per-account recording, and push.

## Examples

**Minimal.** The app finds the connection by itself, which is the right
choice for most PBXs:

```json
{"uri": "201@pbx.example.com", "password": "secret"}
```

**No password.** Safe to print or post, because the app asks for the
password:

```json
{"name": "Office", "uri": "201@pbx.example.com"}
```

**TLS on 5061 with SRTP**, for Asterisk, FreeSWITCH or 3CX with TLS:

```json
{
  "name": "Office",
  "uri": "201@pbx.example.com:5061",
  "password": "secret",
  "display_name": "Sara",
  "transport": "tls",
  "media_enc": "sdes",
  "audio_codecs": ["opus", "alaw"]
}
```

**WebRTC (secure WebSocket)**, for example an Asterisk with `res_pjsip`
WebSocket on 8089:

```json
{
  "name": "Office (WebRTC)",
  "uri": "201@pbx.example.com",
  "password": "secret",
  "transport": "wss",
  "server_url": "wss://pbx.example.com:8089/ws",
  "media_enc": "dtls_srtp",
  "ice_enabled": true,
  "stun_server": "stun:stun.l.google.com:19302"
}
```

**Behind a strict NAT, with TURN:**

```json
{
  "uri": "201@pbx.example.com:5061",
  "password": "secret",
  "transport": "tls",
  "media_enc": "sdes",
  "ice_enabled": true,
  "stun_server": "stun:turn.example.com:3478",
  "turn_server": "turn:turn.example.com:3478",
  "turn_user": "medut",
  "turn_pass": "turn-secret"
}
```

**Carrier or SBC**, with a separate authentication user and an outbound
proxy:

```json
{
  "uri": "+20225550100@sip.carrier.example",
  "password": "secret",
  "auth_user": "acct-55501",
  "outbound_proxy": "sip:sbc.carrier.example;lr",
  "transport": "udp"
}
```

**A SIP URI**: `sip:USER[:PASSWORD]@HOST[:PORT][;transport=udp|tcp|tls]`.

```text
sip:201:secret@pbx.example.com
sip:201@pbx.example.com:5061;transport=tls
sip:201:p%40ss@pbx.example.com:5080;transport=tcp
```

- Percent-encode `@` and `:` in the user, and `@` in the password (`p@ss`
  becomes `p%40ss`).
- `sips:` does not choose TLS by itself: add `;transport=tls`.
- With no `;transport=`, the sign-in screen uses *Auto*.
- The account is named after the host. Other parameters are ignored.

## What the app exports

*Share as QR code* (the QR icon in Edit account) and the *JSON* view write
this format. The optional keys (`server_url`, `auth_user`,
`outbound_proxy`, `stun_server`, `turn_*`) are left out when empty. Because
`transport` is always written, a shared code always uses that exact
transport:

```json
{
  "name": "Office",
  "uri": "201@pbx.example.com:5061",
  "password": "secret",
  "display_name": "Sara",
  "transport": "tls",
  "media_enc": "sdes",
  "ice_enabled": false,
  "audio_codecs": ["opus", "alaw", "ulaw"],
  "verify_tls": true
}
```

## Making a QR code

Put the JSON or the SIP URI in the QR code as plain text. Any QR generator
works. From a terminal:

```bash
qrencode -o account.png "$(cat account.json)"
```

A code or file with a password is as sensitive as the password itself. For
codes you print or send to many people, leave the password out: Medut asks
for it.
