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

CallRecord _call(int id, String number, CallResult result, int minutesAgo, {String name = '', int sec = 0, String rec = '', double? mos, double? jitter}) =>
    CallRecord(
      id: id,
      accountId: 'a1',
      accountName: 'Office PBX',
      number: number,
      name: name,
      direction: result == CallResult.missed ? CallDirection.incoming : CallDirection.outgoing,
      result: result,
      startedAt: _now.subtract(Duration(minutes: minutesAgo)),
      durationSec: sec,
      recordingPath: rec,
      mos: mos,
      jitterMs: jitter,
    );

/// Newest first, as the database returns them.
final _history = [
  _call(1, '01009876543', CallResult.missed, 1),
  _call(2, '01009876543', CallResult.missed, 2),
  _call(3, '01009876543', CallResult.missed, 3),
  _call(4, '214', CallResult.answered, 4, name: 'Sara Adel', sec: 252, rec: '/rec/sara.wav'),
  _call(5, '0100 987 6543', CallResult.missed, 5),
  _call(6, '220', CallResult.answered, 6, name: 'Reception', sec: 65, mos: 3.2, jitter: 34),
];

final _messages = [
  ChatMessage(accountId: 'a1', peer: '214', body: 'Sent the contract', outgoing: false, at: _now.subtract(const Duration(minutes: 7))),
];

class _FakeDb extends ChangeNotifier implements LocalDb {
  final deleted = <int>[];
  final restored = <int>[];

  @override
  Future<List<CallRecord>> calls({int limit = 300}) async =>
      _history.where((c) => !deleted.contains(c.id) || restored.contains(c.id)).toList();

  @override
  Future<List<ChatMessage>> messages({int limit = 300}) async => _messages;

  @override
  Future<void> deleteCalls(List<int> ids) async {
    deleted.addAll(ids);
    notifyListeners();
  }

  @override
  Future<void> restoreCalls(List<CallRecord> calls) async {
    restored.addAll(calls.map((c) => c.id!));
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

late _FakeDb _db;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  test('one row per person per day, however the number is written, messages included', () {
    final rows = groupByPerson(_history, _messages);
    expect(rows.map((r) => (r.number, r.calls.length, r.messages.length)).toList(), [
      ('01009876543', 4, 0),
      ('214', 1, 1),
      ('220', 1, 0),
    ]);
    expect(rows.first.openMissed, 4);
    expect(rows[1].openMissed, 0);
  });

  Future<void> pump(WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    SharedPreferences.setMockInitialValues({});
    final store = await AccountStore.load();
    final settings = await AppSettings.load();
    final db = _db = _FakeDb();
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
  testWidgets('lists people, opens a row, deletes with a swipe and searches on a small phone', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Sara Adel'), findsOneWidget);
    expect(find.text('01009876543'), findsOneWidget);
    // Four missed calls, all owed: the last two as chips, the rest as +2.
    expect(find.text('4'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget);
    expect(find.byIcon(Icons.call_missed), findsNWidgets(2));
    // Sara's row carries her message.
    expect(find.text('Sent the contract'), findsOneWidget);

    // Tapping a row of several calls opens all of them in place.
    await tester.tap(find.text('01009876543'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.call_missed), findsNWidgets(4));

    // Swipe Reception to the left: gone, with Undo.
    await tester.drag(find.text('Reception'), const Offset(-320, 0));
    await tester.pumpAndSettle();
    expect(find.text('Reception'), findsNothing);
    expect(_db.deleted, [6]);
    expect(find.text('Call deleted'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Reception'), findsOneWidget);

    // A row with one call opens its sheet straight away; the quality pill
    // and Technical details each open in place.
    await tester.tap(find.text('Reception'));
    await tester.pumpAndSettle();
    expect(find.text('Fair'), findsOneWidget);
    await tester.tap(find.text('Fair'));
    await tester.pumpAndSettle();
    expect(find.text('You heard'), findsOneWidget);
    expect(find.text('34 ms'), findsOneWidget);
    await tester.tap(find.text('Technical details'));
    await tester.pumpAndSettle();
    expect(find.text('Call-ID'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(180, 20));
    await tester.pumpAndSettle();
    expect(find.text('Technical details'), findsNothing);

    // A name.
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'sara');
    await tester.pumpAndSettle();
    expect(find.text('Sara Adel'), findsOneWidget);
    expect(find.text('Reception'), findsNothing);

    // A number typed with a dash, and a word from a message.
    await tester.enterText(find.byType(TextField), '0100-987');
    await tester.pumpAndSettle();
    expect(find.text('01009876543'), findsOneWidget);
    expect(find.text('Sara Adel'), findsNothing);
    await tester.enterText(find.byType(TextField), 'contract');
    await tester.pumpAndSettle();
    expect(find.text('Sara Adel'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nobody');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches'), findsOneWidget);
  });
}
