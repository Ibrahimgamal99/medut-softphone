import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:medut_phone/core/accounts.dart';
import 'package:medut_phone/core/db.dart';
import 'package:medut_phone/core/settings.dart';
import 'package:medut_phone/sip/quality.dart';
import 'package:medut_phone/sip/sip_service.dart';

void main() {
  group('provisioning', () {
    test('reads a Medut-SDK account JSON', () {
      final a = SipAccountConfig.parseProvisioning('''
        {"uri": "100@pbx.example.com:5061", "password": "secret", "display_name": "Ext 100",
         "transport": "tls", "media_enc": "dtls_srtp", "ice_enabled": true,
         "stun_server": "stun:stun.l.google.com:19302", "audio_codecs": ["opus", "alaw"]}''')!;
      expect(a.user, '100');
      expect(a.domain, 'pbx.example.com');
      expect(a.port, 5061);
      expect(a.password, 'secret');
      expect(a.transport, 'tls');
      expect(a.mediaEnc, 'dtls');
      expect(a.ice, isTrue);
      expect(a.codecs, ['opus', 'alaw']);
    });

    test('reads a SIP URI with password and transport', () {
      final a = SipAccountConfig.parseProvisioning('sip:201:p%40ss@pbx.acme.local:5080;transport=tcp')!;
      expect(a.user, '201');
      expect(a.password, 'p@ss');
      expect(a.domain, 'pbx.acme.local');
      expect(a.port, 5080);
      expect(a.transport, 'tcp');
    });

    test('rejects anything else', () {
      expect(SipAccountConfig.parseProvisioning('hello'), isNull);
      expect(SipAccountConfig.parseProvisioning('{"uri": "nope"}'), isNull);
    });

    test('every example in docs/account-setup.md reads', () {
      final doc = File('docs/account-setup.md').readAsStringSync();
      final json = [for (final m in RegExp(r'```json\n(.*?)```', dotAll: true).allMatches(doc)) m.group(1)!];
      final uris = [
        for (final m in RegExp(r'```text\n(.*?)```', dotAll: true).allMatches(doc)) ...m.group(1)!.trim().split('\n')
      ];
      expect(json.length + uris.length, greaterThan(8));
      final read = {for (final e in [...json, ...uris]) e: SipAccountConfig.parseProvisioning(e)};
      read.forEach((e, a) => expect(a, isNotNull, reason: e));

      final web = read.values.firstWhere((a) => a!.transport == 'wss')!;
      expect(web.serverUrl, startsWith('wss://'));
      expect(web.mediaEnc, 'dtls');
      expect(web.ice, isTrue);

      // The export example is exactly what Share as QR code writes for it.
      final export = json.firstWhere((e) => e.contains('"verify_tls"'));
      expect(jsonDecode(read[export]!.toProvisioning()), jsonDecode(export));
    });
  });

  group('dial rules', () {
    test('X matches one digit and length must match', () {
      const r = DialRule(pattern: '0XXXXXXXXXX', accountId: 'a');
      expect(r.matches('01005550192'), isTrue);
      expect(r.matches('0100 555 0192'), isTrue);
      expect(r.matches('0100555019'), isFalse);
      expect(r.matches('11005550192'), isFalse);
    });

    test('a plain pattern is a prefix', () {
      const r = DialRule(pattern: '1', accountId: 'a');
      expect(r.matches('1004'), isTrue);
      expect(r.matches('2004'), isFalse);
    });
  });

  group('addresses', () {
    const cfg = SipAccountConfig(id: 'x', name: 'PBX', user: '201', domain: 'pbx.example.com');

    test('numbers go to the account domain', () {
      expect(SipService.uriFor(cfg, '204'), '204@pbx.example.com');
      expect(SipService.uriFor(cfg, '+20 100-555 0192'), '+201005550192@pbx.example.com');
      expect(SipService.uriFor(cfg.copyWith(port: 5080), '204'), '204@pbx.example.com:5080');
    });

    test('SIP addresses are kept', () {
      expect(SipService.uriFor(cfg, 'sip:bob@other.example'), 'bob@other.example');
    });

    test('user part of a From header', () {
      expect(SipService.userPart('"Sara" <sip:204@pbx.example.com>;tag=1'), '204');
      expect(SipService.userPart('sip:+201005550192@carrier.net'), '+201005550192');
    });
  });

  group('call quality grade', () {
    test('checking until a sample', () => expect(callQualityLevel(), 0));
    test('excellent needs a high MOS and clean network', () {
      expect(callQualityLevel(mos: 4.4, rttMs: 40, jitterMs: 5, lossPct: 0), 4);
      expect(callQualityLevel(rttMs: 40, jitterMs: 5, lossPct: 0), 3);
    });
    test('one missed target drops to fair, a bad one to poor', () {
      expect(callQualityLevel(mos: 4.4, rttMs: 200, jitterMs: 5, lossPct: 0), 2);
      expect(callQualityLevel(mos: 4.4, rttMs: 40, jitterMs: 5, lossPct: 3), 1);
    });
    test('MOS caps the grade', () {
      expect(callQualityLevel(mos: 3.8, rttMs: 40, jitterMs: 5, lossPct: 0), 3);
      expect(callQualityLevel(mos: 2.5), 1);
    });
  });

  group('call record', () {
    final start = DateTime(2026, 10, 12, 10, 0, 0);
    final rec = CallRecord(
      accountId: 'a', accountName: 'Office', number: '204', name: 'Sara',
      direction: CallDirection.outgoing, result: CallResult.answered,
      startedAt: start, answeredAt: start.add(const Duration(seconds: 8)),
      endedAt: start.add(const Duration(seconds: 128)), durationSec: 120,
      mos: 4.2, mosMin: 3.9, mosRx: 4.1, rttMs: 60, jitterMs: 6, lossPct: 0.2, packetsLost: 3,
      codec: 'opus', transport: 'TLS', encryption: 'AES_CM_128_HMAC_SHA1_80', icePath: 'host → host',
      remoteMedia: '10.0.0.5:4000', callId: 'abc@pbx', remoteUri: 'sip:204@pbx', localUri: 'sip:201@pbx',
      setupMs: 850, endReason: 'BYE', sipCode: 200, endedBy: 'local', recordingPath: '/rec/1.wav', recordingSec: 118,
    );

    test('every field survives the database row', () {
      final back = CallRecord.fromRow({...rec.toRow(), 'id': 1});
      expect(back.toRow(), rec.toRow());
      expect(back.ringSec, 8);
      expect(back.totalSec, 128);
    });

    test('CSV row matches the header', () => expect(rec.toCsv().length, CallRecord.csvHeader.length));
  });

  test('recording length comes from the WAV header', () async {
    // 8 kHz, 16-bit mono = 16000 bytes/s; 3 s of silence.
    final bytes = BytesBuilder()
      ..add('RIFF'.codeUnits)..add(Uint8List(4))..add('WAVEfmt '.codeUnits)
      ..add([16, 0, 0, 0, 1, 0, 1, 0, 0x40, 0x1F, 0, 0, 0x80, 0x3E, 0, 0, 2, 0, 16, 0])
      ..add('data'.codeUnits)..add(Uint8List(4))..add(Uint8List(48000));
    final f = File('${Directory.systemTemp.path}/medut_wav_test.wav')..writeAsBytesSync(bytes.toBytes());
    expect(await SipService.wavSeconds(f.path), 3);
    expect(await SipService.wavSeconds('${f.path}.missing'), isNull);
    f.deleteSync();
  });
}
