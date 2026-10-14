import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medut_phone/core/accounts.dart';
import 'package:medut_phone/core/db.dart';
import 'package:medut_phone/core/providers.dart';
import 'package:medut_phone/core/settings.dart';
import 'package:medut_phone/core/theme.dart';
import 'package:medut_phone/features/settings_screen.dart';
import 'package:medut_phone/features/status_codes.dart';
import 'package:medut_phone/sip/sip_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDb extends Fake implements LocalDb {}

/// Records the codes a status change dials instead of calling.
class _FakeSip extends SipService {
  _FakeSip(AccountStore store, AppSettings settings) : super(store: store, settings: settings, db: _FakeDb());
  final dialed = <String>[];

  @override
  Future<void> dialCodes(List<(String, String, String)> codes) async =>
      dialed.addAll(codes.map((c) => c.$3));
}

const _pbx = SipAccountConfig(id: 'a1', name: 'Office', user: '201', domain: 'pbx.example.com');

void main() {
  late AccountStore store;
  late AppSettings settings;
  late _FakeSip sip;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    // No native engine in tests: every call answers null.
    messenger.setMockMethodCallHandler(const MethodChannel('medut/native'), (_) async => null);
    store = await AccountStore.load();
    await store.save(_pbx);
    settings = await AppSettings.load();
    sip = _FakeSip(store, settings);
    sip.runtimes['a1'] = AccountRuntime(_pbx, '')..status = RegStatus.registered;
  });

  test('a transfer goes to a full sip: URI, never user@host alone', () {
    expect(SipService.referUri(_pbx, '202'), 'sip:202@pbx.example.com');
    expect(SipService.referUri(_pbx, 'sip:300@other.example.com'), 'sip:300@other.example.com');
    expect(SipService.referUri(_pbx, '300@other.example.com'), 'sip:300@other.example.com');
  });

  test('PBX presets fill the codes, and an account can override them', () {
    expect(_pbx.code('dndOn'), '*78');
    expect(_pbx.code('queueLogin'), '*45');
    final cx = _pbx.copyWith(pbx: '3cx');
    expect([cx.code('dndOn'), cx.code('queueLogin'), cx.code('queueLogout')], ['', '*62', '*63']);
    final own = _pbx.copyWith(codes: {'dndOn': '*90'});
    expect([own.code('dndOn'), own.code('dndOff')], ['*90', '*79']);
    final back = SipAccountConfig.fromJson(own.toJson());
    expect([back.pbx, back.code('dndOn')], ['freepbx', '*90']);
  });

  test('Ready logs in to the queue, Available logs out, Do not disturb sets DND and logs out', () async {
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));
    sip.setMyStatus(MyStatus.ready);
    await settle();
    expect(sip.dialed, ['*45'], reason: 'from Available: only the queue');
    sip.dialed.clear();

    sip.setMyStatus(MyStatus.available);
    await settle();
    expect(sip.dialed, ['*45'], reason: 'the toggle logs out again');
    sip.dialed.clear();

    sip.setMyStatus(MyStatus.dnd);
    await settle();
    expect(sip.dialed, ['*78'], reason: 'already out of the queue');
    sip.dialed.clear();

    sip.setMyStatus(MyStatus.ready);
    await settle();
    expect(sip.dialed, ['*79', '*45']);
    sip.dialed.clear();

    sip.setMyStatus(MyStatus.dnd);
    await settle();
    expect(sip.dialed, ['*78', '*45']);
    sip.dialed.clear();

    sip.setMyStatus(MyStatus.available);
    await settle();
    expect(sip.dialed, ['*79'], reason: 'leaving DND, and already out of the queue');
    expect(settings.statusSince.isAfter(DateTime(2020)), isTrue);
  });

  test('a saved Silent, which is gone, reads as Available', () async {
    SharedPreferences.setMockInitialValues({'status': 'silent'});
    expect((await AppSettings.load()).status, MyStatus.available);
  });

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith((_) => store),
        settingsProvider.overrideWith((_) => settings),
        sipProvider.overrideWith((_) => sip),
      ],
      child: MaterialApp(theme: ThemeData(useMaterial3: true, extensions: const [Tokens.light]), home: home),
    ));
    await tester.pump();
  }

  testWidgets('settings: grouped sections render', (tester) async {
    await pump(tester, const SettingsScreen());
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('statusCodes'), findsOneWidget);
    expect(find.text('REGISTERED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('status codes: picking a PBX fills its codes and saves them', (tester) async {
    await pump(tester, const StatusCodesScreen());
    expect(find.text('*78'), findsOneWidget);
    await tester.tap(find.text('FreePBX / Issabel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3CX').last);
    await tester.pumpAndSettle();
    expect(find.text('*62'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(store.byId('a1')!.pbx, '3cx');
    expect(store.byId('a1')!.code('queueLogout'), '*63');
  });
}
