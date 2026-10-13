import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medut_phone/core/accounts.dart';
import 'package:medut_phone/core/contacts.dart';
import 'package:medut_phone/core/db.dart';
import 'package:medut_phone/core/providers.dart';
import 'package:medut_phone/core/settings.dart';
import 'package:medut_phone/core/theme.dart';
import 'package:medut_phone/features/dialer.dart';
import 'package:medut_phone/sip/sip_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An empty call history.
class _FakeDb extends ChangeNotifier implements LocalDb {
  @override
  Future<List<CallRecord>> calls({int limit = 300}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AccountStore store;
  late SipService sip;
  final account = SipAccountConfig(id: 'a1', name: 'Office PBX', user: '201', domain: 'pbx.example.com', isDefault: true);

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    SharedPreferences.setMockInitialValues({
      'accounts': '[{"id":"a1","name":"Office PBX","user":"201","domain":"pbx.example.com","isDefault":true}]',
    });
    store = await AccountStore.load();
  });

  Future<void> pump(WidgetTester tester, Size size, {RegStatus status = RegStatus.registered, VoidCallback? onClose}) async {
    final settings = await AppSettings.load();
    final db = _FakeDb();
    sip = SipService(store: store, settings: settings, db: db);
    sip.runtimes['a1'] = AccountRuntime(account, '')..status = status;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsProvider.overrideWith((_) => settings),
        accountsProvider.overrideWith((_) => store),
        dbProvider.overrideWith((_) => db),
        contactsProvider.overrideWith((_) => ContactsService()),
        sipProvider.overrideWith((_) => sip),
      ],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true, extensions: const [Tokens.light]),
        home: Scaffold(body: SafeArea(child: DialerScreen(addCallMode: ValueNotifier(false), onClose: onClose))),
      ),
    ));
    await tester.pump();
  }

  testWidgets('as a page from the dial button: close instead of the avatar, still fits 360', (tester) async {
    var closed = false;
    await pump(tester, const Size(360, 640), onClose: () => closed = true);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('close'));
    expect(closed, isTrue);
  });

  for (final size in const [Size(360, 640), Size(412, 915)]) {
    testWidgets('fits ${size.width.toInt()}×${size.height.toInt()} and types digits', (tester) async {
      await pump(tester, size);
      expect(tester.takeException(), isNull);
      expect(find.text('Office PBX'), findsOneWidget);
      for (final d in ['2', '0', '1']) {
        await tester.tap(find.text(d).first);
      }
      await tester.pump();
      expect(find.text('201'), findsOneWidget);
    });
  }

  testWidgets('a registered account says nothing about it', (tester) async {
    await pump(tester, const Size(360, 640));
    expect(find.text('regFailed'), findsNothing);
  });

  testWidgets('a failed account says why under the header', (tester) async {
    await pump(tester, const Size(360, 640), status: RegStatus.failed);
    expect(find.text('regFailed'), findsOneWidget);
  });
}
