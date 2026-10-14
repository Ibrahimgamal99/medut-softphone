import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/language.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'features/shell.dart';
import 'features/sign_in.dart';

class MedutPhoneApp extends ConsumerStatefulWidget {
  const MedutPhoneApp({super.key});

  @override
  ConsumerState<MedutPhoneApp> createState() => _MedutPhoneAppState();
}

class _MedutPhoneAppState extends ConsumerState<MedutPhoneApp> with WidgetsBindingObserver {
  bool _sentToNative = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    setState(() {});
    ref.read(sipProvider).refreshNative();
  }

  @override
  void didChangeLocales(List<Locale>? locales) => phoneLanguageChanged(context);

  bool _isDark(String mode) =>
      mode == 'dark' ||
      (mode == 'system' && SchedulerBinding.instance.platformDispatcher.platformBrightness == Brightness.dark);

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final sip = ref.read(sipProvider);
    final language = context.locale.languageCode;
    final rtl = isRtlLanguage(language);
    final dark = _isDark(settings.themeMode);

    // The native call screens follow the app's theme and language (and get
    // the translations once they have loaded, on the first build).
    final changed = !_sentToNative || sip.isDark() != dark || sip.isRtl() != rtl;
    _sentToNative = true;
    sip.isDark = () => _isDark(ref.read(settingsProvider).themeMode);
    sip.isRtl = () => rtl;
    if (changed) WidgetsBinding.instance.addPostFrameCallback((_) => sip.refreshNative());

    return MaterialApp(
      title: 'Medut',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Tokens.light, language: language),
      darkTheme: buildTheme(Tokens.darkTokens, language: language),
      themeMode: switch (settings.themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      locale: context.locale,
      supportedLocales: context.supportedLocales,
      localizationsDelegates: context.localizationDelegates,
      home: const _Root(),
    );
  }
}

/// No account yet: Sign in. Saving one switches to the tabs, and deleting the
/// last one comes back here.
class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(accountsProvider).accounts.isEmpty ? const SignInScreen() : const HomeShell();
}
