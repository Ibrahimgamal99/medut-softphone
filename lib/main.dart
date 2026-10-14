import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'core/accounts.dart';
import 'core/contacts.dart';
import 'core/db.dart';
import 'core/language.dart';
import 'core/providers.dart';
import 'core/settings.dart';
import 'sip/sip_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  await initializeDateFormatting();
  await loadLanguageChoice();

  final settings = await AppSettings.load();
  final store = await AccountStore.load();
  final db = await LocalDb.open();
  final contacts = ContactsService();
  final sip = SipService(store: store, settings: settings, db: db)
    ..tr = ((k) => k.tr())
    ..nameFor = (number) {
      for (final w in settings.watched) {
        if (w.ext == number) return w.name;
      }
      return contacts.nameFor(number);
    }
    ..contactNumbers = (() => contacts.contacts.expand((c) => c.numbers));
  // Contacts saved with an extension get presence once the address book loads.
  contacts.addListener(sip.syncPresence);

  // SIP starts before the first frame: on Android this engine also runs with
  // no UI at all (boot, push wake-up), and registering must not wait for one.
  unawaited(sip.start());
  unawaited(contacts.load());

  runApp(
    EasyLocalization(
      supportedLocales: appLocales,
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      child: ProviderScope(
        overrides: [
          settingsProvider.overrideWith((_) => settings),
          accountsProvider.overrideWith((_) => store),
          dbProvider.overrideWith((_) => db),
          contactsProvider.overrideWith((_) => contacts),
          sipProvider.overrideWith((_) => sip),
        ],
        child: const MedutPhoneApp(),
      ),
    ),
  );
}
