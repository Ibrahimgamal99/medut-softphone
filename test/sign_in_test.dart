import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medut_phone/core/accounts.dart';
import 'package:medut_phone/core/db.dart';
import 'package:medut_phone/core/providers.dart';
import 'package:medut_phone/core/settings.dart';
import 'package:medut_phone/core/theme.dart';
import 'package:medut_phone/features/sign_in.dart';
import 'package:medut_phone/sip/probe.dart';
import 'package:medut_phone/sip/sip_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDb extends Fake implements LocalDb {}

/// Answers the connection check and sign-in attempts instead of the network.
class _FakeSip extends SipService {
  _FakeSip(AccountStore store, AppSettings settings, this.answers, this.hits, {this.resolved = true})
      : super(store: store, settings: settings, db: _FakeDb());

  final Map<String, RegProbe> answers;
  final List<ProbeHit> hits;
  final bool resolved;
  final tried = <SipAccountConfig>[];
  final probed = <String>[];

  @override
  Future<ProbeReport> probe(String host, {int port = 0, ProbeListener? onStep}) async {
    probed.add(port > 0 ? '$host:$port' : host);
    for (final k in const ['dns', 'tls', 'tcp', 'udp', 'wss']) {
      final hit = hits.any((h) => h.transport == k);
      onStep?.call(k, k == 'dns' || hit ? CheckState.ok : CheckState.failed, hit ? 'answered' : 'noAnswer', '');
    }
    return ProbeReport(resolved: resolved, hits: hits, log: ['DNS  $host → 203.0.113.10']);
  }

  @override
  Future<RegProbe> tryRegister(SipAccountConfig c, {Duration timeout = const Duration(seconds: 8)}) async {
    tried.add(c);
    return answers[c.transport] ?? const RegProbe(RegStatus.registering);
  }
}

void main() {
  late AccountStore store;
  late _FakeSip sip;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/permissions/methods'), (call) async {
      if (call.method == 'requestPermissions') return {for (final p in call.arguments as List) p: 1};
      return 1;
    });
    store = await AccountStore.load();
  });

  Future<void> pump(WidgetTester tester,
      {Map<String, RegProbe> answers = const {},
      List<ProbeHit> hits = const [],
      bool resolved = true,
      Size size = const Size(360, 640)}) async {
    sip = _FakeSip(store, await AppSettings.load(), answers, hits, resolved: resolved);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith((_) => store),
        sipProvider.overrideWith((_) => sip),
      ],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true, extensions: const [Tokens.light]),
        home: const SignInScreen(),
      ),
    ));
  }

  Future<void> fill(WidgetTester tester, String address, String password) async {
    await tester.enterText(find.byType(TextField).at(0), address);
    await tester.enterText(find.byType(TextField).at(1), password);
    await tester.pump();
  }

  FilledButton signInButton(WidgetTester tester) => tester.widget<FilledButton>(find.byType(FilledButton));

  testWidgets('fits a small phone and waits for both fields', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(signInButton(tester).onPressed, isNull);
    expect(find.text('scanQr'), findsOneWidget);
    expect(find.text('importFile'), findsOneWidget);
    expect(find.text('paste'), findsOneWidget);
    await fill(tester, '201@pbx.example.com', 'secret');
    expect(signInButton(tester).onPressed, isNotNull);
  });

  testWidgets('an address without a server is explained, not tried', (tester) async {
    await pump(tester);
    await fill(tester, '201', 'secret');
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(find.text('addressInvalid'), findsOneWidget);
    expect(sip.probed, isEmpty);
    expect(sip.tried, isEmpty);
  });

  testWidgets('signs in over the way that answered, then saves on Continue', (tester) async {
    await pump(tester, hits: const [ProbeHit('tcp')], answers: {'tcp': const RegProbe(RegStatus.registered)});
    await fill(tester, 'sip:201@pbx.example.com:5080', 'secret');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(sip.probed, ['pbx.example.com:5080']);
    expect(sip.tried.map((c) => c.transport), ['tcp']);
    expect(find.text('signedInTitle'), findsOneWidget);
    expect(find.text('transport_tcp'), findsOneWidget);
    expect(store.accounts, isEmpty, reason: 'nothing is saved before Continue');

    await tester.enterText(find.widgetWithText(TextField, 'accountName'), 'Office');
    await tester.enterText(find.widgetWithText(TextField, 'nameOnCallsOptional'), 'Sara');
    await tester.ensureVisible(find.text('continue'));
    await tester.tap(find.text('continue'));
    await tester.pumpAndSettle();
    final a = store.accounts.single;
    expect([a.user, a.domain, a.port, a.transport, a.password, a.displayName, a.name],
        ['201', 'pbx.example.com', 5080, 'tcp', 'secret', 'Sara', 'Office']);
    expect(a.id, sip.tried.single.id, reason: 'the running registration is adopted');
    expect(a.isDefault, isTrue);
  });

  testWidgets('a server that only answers a web link gets WSS, DTLS and ICE', (tester) async {
    await pump(tester,
        hits: const [ProbeHit('wss', url: 'wss://pbx.example.com/sip-ws')],
        answers: {'wss': const RegProbe(RegStatus.registered)});
    await fill(tester, '100@pbx.example.com', 'secret');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    final c = sip.tried.single;
    expect([c.transport, c.serverUrl, c.mediaEnc, c.ice, c.stun],
        ['wss', 'wss://pbx.example.com/sip-ws', 'dtls', true, kDefaultStun]);
    expect(find.text('transport_wss'), findsOneWidget);
    expect(find.text('enc_dtls'), findsOneWidget);
  });

  testWidgets('a wrong password stops at the first answer', (tester) async {
    await pump(tester,
        hits: const [ProbeHit('tls'), ProbeHit('tcp')],
        answers: {'tls': const RegProbe(RegStatus.failed, sipCode: 403)});
    await fill(tester, '201@pbx.example.com', 'nope');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(sip.tried.map((c) => c.transport), ['tls']);
    expect(find.text('signInWrongPassword'), findsOneWidget);
    expect(find.text('fixPassword'), findsOneWidget);
    expect(store.accounts, isEmpty);
  });

  testWidgets('no answer anywhere still tries a real sign-in, then shows the log', (tester) async {
    await pump(tester);
    await fill(tester, '201@pbx.example.com', 'secret');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(sip.tried.map((c) => c.transport), ['tls', 'tcp', 'udp']);
    expect(find.text('failNoAnswerTitle'), findsOneWidget);
    expect(find.text('fixWebLink'), findsOneWidget);
    expect(find.textContaining('REG  UDP'), findsOneWidget);
    expect(store.accounts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a name that does not resolve says it cannot find the server', (tester) async {
    await pump(tester, resolved: false);
    await fill(tester, '201@pbx.invalid', 'secret');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('failNoServerTitle'), findsOneWidget);
  });

  testWidgets('pasted account JSON fills the form and signs in over its web link', (tester) async {
    final json = jsonEncode({
      'uri': '100@echo.example.com',
      'password': 'pw',
      'transport': 'wss',
      'server_url': 'wss://echo.example.com/sip-ws',
      'media_enc': 'dtls_srtp',
      'ice_enabled': true,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData' ? {'text': json} : null);
    await pump(tester, answers: {'wss': const RegProbe(RegStatus.registered)});
    await tester.tap(find.text('paste'));
    await tester.pumpAndSettle();
    expect(sip.probed, isEmpty, reason: 'the JSON named its transport');
    final c = sip.tried.single;
    expect([c.user, c.domain, c.transport, c.serverUrl, c.mediaEnc, c.ice],
        ['100', 'echo.example.com', 'wss', 'wss://echo.example.com/sip-ws', 'dtls', true]);
    expect(find.text('signedInTitle'), findsOneWidget);
  });

  testWidgets('the language is picked from a globe button, not a word', (tester) async {
    await pump(tester);
    expect(find.byIcon(Icons.language), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
  });

  testWidgets('a server found over UDP gets no media encryption', (tester) async {
    await pump(tester, hits: const [ProbeHit('udp')], answers: {'udp': const RegProbe(RegStatus.registered)});
    await fill(tester, '201@pbx.example.com', 'secret');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(sip.tried.single.mediaEnc, 'none');
  });

  test('More options: plain UDP/TCP never encrypt, and leaving a web link undoes what it turned on', () {
    final o = SignInOptions();
    expect(SignInOptions.encryptsOver('udp'), isFalse);
    expect(SignInOptions.encryptsOver('tcp'), isFalse);
    expect(SignInOptions.encryptsOver('tls'), isTrue);
    o.setTransport('wss');
    expect([o.encrypt, o.ice], [true, true]);
    o.setTransport('udp');
    expect([o.encrypt, o.ice, o.canEncrypt], [false, false, false]);

    final p = SignInOptions()..setIce(true);
    p
      ..setTransport('wss')
      ..setTransport('tcp');
    expect(p.ice, isTrue, reason: 'ICE turned on by hand stays on');
  });

  test('More options: a web link brings DTLS and ICE, and ICE brings Google STUN', () {
    final o = SignInOptions();
    o.setEncrypt(true);
    expect(o.mediaEnc, 'sdes');
    o.setTransport('wss');
    expect([o.mediaEnc, o.ice, o.stun.text], ['dtls', true, kDefaultStun]);

    final p = SignInOptions()..setIce(true);
    expect(p.stun.text, kDefaultStun);
    p.stun.text = 'stun:stun.example.com';
    p
      ..setIce(false)
      ..setIce(true);
    expect(p.stun.text, 'stun:stun.example.com', reason: 'a STUN server you typed is kept');
  });
}
