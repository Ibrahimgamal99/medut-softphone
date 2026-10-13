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
import 'package:medut_phone/sip/sip_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDb extends Fake implements LocalDb {}

/// Answers sign-in attempts per transport instead of registering.
class _FakeSip extends SipService {
  _FakeSip(AccountStore store, AppSettings settings, this.answers)
      : super(store: store, settings: settings, db: _FakeDb());

  final Map<String, RegProbe> answers;
  final tried = <String>[];

  @override
  Future<RegProbe> tryRegister(SipAccountConfig c, {Duration timeout = const Duration(seconds: 8)}) async {
    tried.add(c.transport);
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

  Future<void> pump(WidgetTester tester, Map<String, RegProbe> answers, {Size size = const Size(360, 640)}) async {
    sip = _FakeSip(store, await AppSettings.load(), answers);
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
    await pump(tester, {});
    expect(tester.takeException(), isNull);
    expect(signInButton(tester).onPressed, isNull);
    await fill(tester, '201@pbx.example.com', 'secret');
    expect(signInButton(tester).onPressed, isNotNull);
  });

  testWidgets('an address without a server is explained, not tried', (tester) async {
    await pump(tester, {});
    await fill(tester, '201', 'secret');
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(find.text('addressInvalid'), findsOneWidget);
    expect(sip.tried, isEmpty);
  });

  testWidgets('tries TLS, then TCP, and saves the one that registers', (tester) async {
    await pump(tester, {'tcp': const RegProbe(RegStatus.registered)});
    await fill(tester, 'sip:201@pbx.example.com:5080', 'secret');
    await tester.tap(find.byType(FilledButton));
    // The "Connected" spinner runs until the app root swaps to the tabs,
    // which this harness has no root for: pump frames instead of settling.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('connectedOver'), findsOneWidget);
    expect(sip.tried, ['tls', 'tcp']);
    final a = store.accounts.single;
    expect([a.user, a.domain, a.port, a.transport, a.password], ['201', 'pbx.example.com', 5080, 'tcp', 'secret']);
    expect(a.isDefault, isTrue);
  });

  testWidgets('a wrong password stops at the first answer', (tester) async {
    await pump(tester, {'tls': const RegProbe(RegStatus.failed, sipCode: 403)});
    await fill(tester, '201@pbx.example.com', 'nope');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(sip.tried, ['tls']);
    expect(find.text('signInWrongPassword'), findsOneWidget);
    expect(store.accounts, isEmpty);
  });

  testWidgets('no answer anywhere says so and saves nothing', (tester) async {
    await pump(tester, {});
    await fill(tester, '201@pbx.example.com', 'secret');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(sip.tried, ['tls', 'tcp', 'udp']);
    expect(find.text('signInNoAnswer'), findsOneWidget);
    expect(store.accounts, isEmpty);
  });
}
