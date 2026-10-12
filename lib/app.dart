import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'features/shell.dart';

class MedutPhoneApp extends ConsumerStatefulWidget {
  const MedutPhoneApp({super.key});

  @override
  ConsumerState<MedutPhoneApp> createState() => _MedutPhoneAppState();
}

class _MedutPhoneAppState extends ConsumerState<MedutPhoneApp> with WidgetsBindingObserver {
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

  bool _isDark(String mode) =>
      mode == 'dark' ||
      (mode == 'system' && SchedulerBinding.instance.platformDispatcher.platformBrightness == Brightness.dark);

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final sip = ref.read(sipProvider);
    final arabic = context.locale.languageCode == 'ar';
    final dark = _isDark(settings.themeMode);

    // The native call screens follow the app's theme and language.
    final changed = sip.isDark() != dark || sip.isRtl() != arabic;
    sip.isDark = () => _isDark(ref.read(settingsProvider).themeMode);
    sip.isRtl = () => arabic;
    if (changed) WidgetsBinding.instance.addPostFrameCallback((_) => sip.refreshNative());

    return MaterialApp(
      title: 'Medut',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Tokens.light, arabic: arabic),
      darkTheme: buildTheme(Tokens.darkTokens, arabic: arabic),
      themeMode: switch (settings.themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      locale: context.locale,
      supportedLocales: context.supportedLocales,
      localizationsDelegates: context.localizationDelegates,
      home: const HomeShell(),
    );
  }
}
