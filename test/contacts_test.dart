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
import 'package:medut_phone/features/contacts_screen.dart';
import 'package:medut_phone/sip/sip_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

CallRecord _call(String number, String name) => CallRecord(
      accountId: 'a1',
      accountName: 'Office PBX',
      number: number,
      name: name,
      direction: CallDirection.incoming,
      result: CallResult.answered,
      startedAt: DateTime.now(),
    );

class _FakeDb extends ChangeNotifier implements LocalDb {
  @override
  Future<List<CallRecord>> calls({int limit = 300}) async =>
      [_call('220', 'Reception'), _call('01009876543', ''), _call('214', 'Sara Adel')];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<AppSettings> pump(WidgetTester tester, {Set<String> favourites = const {}}) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    SharedPreferences.setMockInitialValues({});
    final store = await AccountStore.load();
    final settings = await AppSettings.load();
    settings.favourites = favourites;
    final db = _FakeDb();
    final sip = SipService(store: store, settings: settings, db: db)..syncPresence();
    tester.view.physicalSize = const Size(360, 640);
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
        home: const Scaffold(body: SafeArea(child: ContactsScreen())),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500)); // presence list debounce
    await tester.pumpAndSettle();
    return settings;
  }

  testWidgets('extensions from calls show up without typing any', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('onPhoneSystem'), findsOneWidget);
    expect(find.text('Reception'), findsOneWidget);
    expect(find.text('Sara Adel'), findsOneWidget);
    expect(find.text('fromCalls'), findsNWidgets(2));
    expect(find.text('01009876543'), findsNothing); // an outside number is not an extension
    expect(find.text('phoneContactsTitle'), findsOneWidget); // contacts not allowed yet
  });

  testWidgets('favourites sit on top; search narrows the list', (tester) async {
    await pump(tester, favourites: {'214'});
    expect(find.text('Sara'), findsOneWidget); // first name under the big avatar
    await tester.enterText(find.byType(TextField), 'recep');
    await tester.pumpAndSettle();
    expect(find.text('Reception'), findsOneWidget);
    expect(find.text('Sara Adel'), findsNothing);
  });
}
