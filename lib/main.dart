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
import 'desktop/call_links.dart';
import 'desktop/desktop_shell.dart';
import 'desktop/engine.dart';
import 'desktop/platform.dart';
import 'sip/sip_service.dart';

/// The pubspec version, passed in by the desktop builds (scripts/build-desktop.sh).
const _version = String.fromEnvironment('MEDUT_VERSION', defaultValue: 'dev');

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktop) initDesktopSqlite();
  await EasyLocalization.ensureInitialized();
  await initializeDateFormatting();
  await loadLanguageChoice();

  final settings = await AppSettings.load();
  final launch = LaunchRequest.parse(args);
  late final LocalDb db;
  if (isDesktop) {
    // There is no native side: the engine runs here, and the accounts are
    // read from it, so it starts before the store does.
    db = await LocalDb.open();
    await DesktopShell.instance.init(settings: settings, db: db, minimized: launch.minimized);
    DesktopEngine.appVersion = _version;
    await DesktopEngine.instance.start(db);
  }
  final store = await AccountStore.load();
  if (!isDesktop) db = await LocalDb.open();
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
  if (isDesktop) DesktopEngine.instance.nameFor = sip.nameFor;

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

  if (isDesktop) {
    // The tray and its menu need the translations, which load with the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await DesktopShell.instance.attach(sip);
      if (!launch.isEmpty) await DesktopShell.instance.handleArgs(args);
    });
  }
}
