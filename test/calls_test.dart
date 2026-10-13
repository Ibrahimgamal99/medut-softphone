import 'package:easy_localization/easy_localization.dart';
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
import 'package:medut_phone/features/activity.dart';
import 'package:medut_phone/sip/sip_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.now();

CallRecord _call(String number, CallResult result, int minutesAgo, {String name = '', int sec = 0, String rec = ''}) => CallRecord(
      accountId: 'a1',
      accountName: 'Office PBX',
      number: number,
      name: name,
      direction: result == CallResult.missed ? CallDirection.incoming : CallDirection.outgoing,
      result: result,
      startedAt: _now.subtract(Duration(minutes: minutesAgo)),
      durationSec: sec,
      recordingPath: rec,
    );

/// Newest first, as the database returns them.
final _history = [
  _call('01009876543', CallResult.missed, 1),
  _call('01009876543', CallResult.missed, 2),
  _call('01009876543', CallResult.missed, 3),
  _call('214', CallResult.answered, 4, name: 'Sara Adel', sec: 252, rec: '/rec/sara.wav'),
  _call('01009876543', CallResult.missed, 5),
  _call('220', CallResult.answered, 6, name: 'Reception', sec: 65),
];

class _FakeDb extends ChangeNotifier implements LocalDb {
  @override
  Future<List<CallRecord>> calls({int limit = 300}) async => _history;

  @override
  Future<List<ChatMessage>> conversations() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  test('missed calls from one number fold until something else comes between', () {
    final rows = groupMissed(_history);
    expect(rows.map((r) => (r.$1.number, r.$2)).toList(), [
      ('01009876543', 3),
      ('214', 1),
      ('01009876543', 1),
      ('220', 1),
    ]);
  });

  Future<void> pump(WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    SharedPreferences.setMockInitialValues({});
    final store = await AccountStore.load();
    final settings = await AppSettings.load();
    final db = _FakeDb();
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsProvider.overrideWith((_) => settings),
        accountsProvider.overrideWith((_) => store),
        dbProvider.overrideWith((_) => db),
        contactsProvider.overrideWith((_) => ContactsService()),
        sipProvider.overrideWith((_) => SipService(store: store, settings: settings, db: db)),
      ],
      child: EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/translations',
        startLocale: const Locale('en'),
        saveLocale: false,
        child: Builder(
          builder: (context) => MaterialApp(
            locale: context.locale,
            supportedLocales: context.supportedLocales,
            localizationsDelegates: context.localizationDelegates,
            theme: ThemeData(useMaterial3: true, extensions: const [Tokens.light]),
            home: const Scaffold(body: SafeArea(child: ActivityScreen())),
          ),
        ),
      ),
    ));
    // The translations load from the asset bundle outside the fake clock:
    // wait for the screen to appear.
    for (var i = 0; i < 50 && find.byType(ActivityScreen).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  // One widget test: easy_localization loads its strings once per test file.
  testWidgets('lists, folds and searches calls on a small phone', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Sara Adel'), findsOneWidget);
    expect(find.text('01009876543'), findsNWidgets(2));
    expect(find.textContaining('Missed · 3 calls', findRichText: true), findsOneWidget);

    // A name.
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'sara');
    await tester.pumpAndSettle();
    expect(find.text('Sara Adel'), findsOneWidget);
    expect(find.text('Reception'), findsNothing);

    // A number typed with a dash: with Sara's call filtered out, all four
    // misses sit together and fold.
    await tester.enterText(find.byType(TextField), '0100-987');
    await tester.pumpAndSettle();
    expect(find.text('01009876543'), findsOneWidget);
    expect(find.textContaining('Missed · 4 calls', findRichText: true), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nobody');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches'), findsOneWidget);
  });
}
