import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medut_phone/core/accounts.dart';
import 'package:medut_phone/core/db.dart';
import 'package:medut_phone/core/providers.dart';
import 'package:medut_phone/core/settings.dart';
import 'package:medut_phone/core/theme.dart';
import 'package:medut_phone/features/account_edit.dart';
import 'package:medut_phone/features/settings_screen.dart';
import 'package:medut_phone/sip/sip_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDb extends Fake implements LocalDb {}

class _FakeSip extends SipService {
  _FakeSip(AccountStore store, AppSettings settings, this.reply) : super(store: store, settings: settings, db: _FakeDb());

  RegProbe reply;
  final tried = <SipAccountConfig>[];

  @override
  Future<RegProbe> tryRegister(SipAccountConfig c, {Duration timeout = const Duration(seconds: 8)}) async {
    tried.add(c);
    return reply;
  }
}

const _echo = SipAccountConfig(
  id: 'a1',
  name: 'pbx.example.com',
  user: '100',
  domain: 'pbx.example.com',
  password: 'pw',
  transport: 'wss',
  serverUrl: 'wss://pbx.example.com/sip-ws',
  mediaEnc: 'dtls',
  ice: true,
  stun: kDefaultStun,
);

void main() {
  late AccountStore store;
  late AppSettings settings;
  late _FakeSip sip;
  bool? popped;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    // No native engine in tests: every call answers null.
    messenger.setMockMethodCallHandler(const MethodChannel('medut/native'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/permissions/methods'), (call) async {
      if (call.method == 'requestPermissions') return {for (final p in call.arguments as List) p: 1};
      return 1;
    });
    store = await AccountStore.load();
    settings = await AppSettings.load();
    popped = null;
  });

  Future<void> open(WidgetTester tester, RegProbe reply, {SipAccountConfig? existing}) async {
    sip = _FakeSip(store, settings, reply);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith((_) => store),
        settingsProvider.overrideWith((_) => settings),
        sipProvider.overrideWith((_) => sip),
      ],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true, extensions: const [Tokens.light]),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => popped = await Navigator.of(context).push<bool>(MaterialPageRoute(
                builder: (_) => AccountEditScreen(existing: existing, initial: existing == null ? _echo : null))),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('sections show the account at a glance', (tester) async {
    await open(tester, const RegProbe(RegStatus.registered));
    expect(find.text('WSS · wss://pbx.example.com/sip-ws'), findsOneWidget);
    expect(find.text('DTLS-SRTP · sumCertChecked'), findsOneWidget);
    expect(find.text('ICE · STUN stun.l.google.com · sumNoTurn'), findsOneWidget);
    expect(find.text('Opus · PCMA · PCMU'), findsOneWidget);
    expect(find.text('notTested'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Save tests the connection first and saves when it works', (tester) async {
    await open(tester, const RegProbe(RegStatus.registered));
    await tester.tap(find.text('saveConnect'));
    await tester.pumpAndSettle();
    expect(sip.tried.single.id, 'a1');
    expect(store.accounts.single.serverUrl, 'wss://pbx.example.com/sip-ws');
    expect(popped, isTrue);
  });

  testWidgets('a failed test asks before saving', (tester) async {
    await open(tester, const RegProbe(RegStatus.failed, sipCode: 403));
    await tester.tap(find.text('saveConnect'));
    await tester.pumpAndSettle();
    expect(find.text('saveAnywayTitle'), findsOneWidget);
    await tester.tap(find.text('keepEditing'));
    await tester.pumpAndSettle();
    expect(store.accounts, isEmpty);

    // Nothing changed since the test: Save asks again without re-testing.
    await tester.tap(find.text('saveConnect'));
    await tester.pumpAndSettle();
    expect(sip.tried, hasLength(1));
    await tester.tap(find.text('saveAnyway'));
    await tester.pumpAndSettle();
    expect(store.accounts, hasLength(1));
  });

  testWidgets('an import keeps the saved account\'s PBX type and status codes', (tester) async {
    await store.save(_echo.copyWith(pbx: '3cx', codes: {'dndOn': '*11'}));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': '{"uri": "201@pbx.example.com", "transport": "tls"}'};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await open(tester, const RegProbe(RegStatus.registered), existing: store.accounts.single);

    await tester.tap(find.text('paste'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('use'));
    await tester.pumpAndSettle();
    // Status codes, opened from this screen, saves to the account meanwhile.
    await store.save(store.accounts.single.copyWith(codes: {'dndOn': '*12'}));
    await tester.tap(find.text('saveConnect'));
    await tester.pumpAndSettle();

    final a = store.accounts.single;
    expect([a.domain, a.transport], ['pbx.example.com', 'tls'], reason: 'the import was saved');
    expect([a.pbx, a.codes], ['3cx', {'dndOn': '*12'}]);
    expect(popped, isTrue);
  });

  test('User takes a whole SIP address, and its port wins over the Port field', () {
    final d = AccountDraft(const SipAccountConfig(id: 'b', name: '', user: '201', domain: 'old.example', port: 5061));
    d.user.text = 'sip:100@pbx.com:5162';
    final c = d.build('b');
    expect([c.user, c.domain, c.port, c.aor], ['100', 'pbx.com', 5162, '100@pbx.com:5162']);
    d.splitAddress();
    expect([d.user.text, d.domain.text, d.port.text], ['100', 'pbx.com', '5162']);

    d.user.text = '100@pbx.com';
    expect(d.build('b').port, 5162, reason: 'no port in the address: the Port field applies');
    d.domain.text = 'pbx.com:5070';
    d.user.text = '100';
    expect(d.build('b').port, 5070, reason: 'Server takes host:port too');
    d.user.text = '100@pbx.com:70000';
    expect(d.address.port, -1);
    d.dispose();
  });

  testWidgets('choosing a web link on the Connection page brings DTLS and ICE', (tester) async {
    await open(tester, const RegProbe(RegStatus.registered));
    final d = AccountDraft(const SipAccountConfig(id: 'b', name: '', user: '201', domain: 'pbx.example.com'));
    d.setTransport('wss');
    expect([d.choices.mediaEnc, d.choices.ice, d.stun.text], ['dtls', true, kDefaultStun]);
    d.setTransport('tls');
    expect([d.choices.mediaEnc, d.choices.ice], ['sdes', false], reason: 'what the web link chose goes with it');
    d.setTransport('udp');
    expect(d.choices.mediaEnc, 'none', reason: 'no encrypted media over plain UDP');
    d.dispose();

    await tester.tap(find.text('connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('UDP'));
    await tester.pumpAndSettle();
    expect(find.text('port'), findsOneWidget, reason: 'UDP asks for a port, not a web link');
    expect(tester.takeException(), isNull);

    // Back to the sections: over UDP the call is not encrypted, and ICE that
    // only the web link turned on is off again.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('enc_none'), findsOneWidget);
    await tester.tap(find.text('secSecurity'));
    await tester.pumpAndSettle();
    expect(find.text('encNeedsSecure'), findsOneWidget);
  });

  testWidgets('Codecs sets one order for every account; a web link still offers Opus first', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [settingsProvider.overrideWith((_) => settings)],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true, extensions: const [Tokens.light]),
        home: const CodecsScreen(),
      ),
    ));
    expect(settings.codecs, kCodecs, reason: 'G.711 first by default');
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(settings.codecs, ['ulaw', 'opus'], reason: 'A-law turned off');
    expect(_echo.codecsFrom(settings.codecs), ['opus', 'ulaw']);
    expect(tester.takeException(), isNull);
  });

  test('recordings are named like the phone recorder: who, then when', () {
    final at = DateTime(2026, 10, 13, 18, 24, 5);
    expect(SipService.recordingName('201', 'Sara', at), '201 Sara_261013_182405.wav');
    expect(SipService.recordingName('201', '201', at), '201_261013_182405.wav');
    expect(SipService.recordingName('sip:a/b', '', at), 'sip_a_b_261013_182405.wav');
    expect(SipService.recordingName('*43', '', at), '43_261013_182405.wav');
  });

  test('a recording cut off by the end of its call gets a header that matches its audio', () async {
    final dir = await Directory.systemTemp.createTemp('medut-wav');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/cut.wav');
    // What the SDK leaves: a 48 kHz mono 16-bit header saying "no data", then 1 s of audio.
    final header = BytesBuilder()
      ..add('RIFF'.codeUnits)
      ..add(_le32(36))
      ..add('WAVEfmt '.codeUnits)
      ..add(_le32(16))
      ..add([1, 0, 1, 0])
      ..add(_le32(48000))
      ..add(_le32(96000))
      ..add([2, 0, 16, 0])
      ..add('data'.codeUnits)
      ..add(_le32(0));
    await f.writeAsBytes([...header.toBytes(), ...List.filled(96000, 7)]);
    await SipService.repairWav(f.path);
    final b = await f.readAsBytes();
    int u32(int at) => b[at] | b[at + 1] << 8 | b[at + 2] << 16 | b[at + 3] << 24;
    expect([u32(4), u32(40), b.length], [36 + 96000, 96000, 44 + 96000]);
    expect(b[44], 7, reason: 'the audio is untouched');
    expect(await SipService.wavSeconds(f.path), 1);
  });
}

List<int> _le32(int v) => [v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff];
