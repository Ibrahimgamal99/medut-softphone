import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's languages, each named in itself.
const appLanguages = <(String, String)>[
  ('en', 'English'),
  ('ar', 'العربية'),
  ('de', 'Deutsch'),
  ('es', 'Español'),
  ('fa', 'فارسی'),
  ('fr', 'Français'),
  ('pt', 'Português'),
  ('tr', 'Türkçe'),
  ('zh', '中文'),
];

final appLocales = [for (final (code, _) in appLanguages) Locale(code)];

/// Languages written right to left (layout, native call screens).
bool isRtlLanguage(String code) => const {'ar', 'fa'}.contains(code);

String languageName(String code) => appLanguages.firstWhere((l) => l.$1 == code, orElse: () => appLanguages.first).$2;

/// Whether the app follows the phone's language (Automatic). easy_localization
/// keeps a picked language under 'locale'; with none saved it starts in the
/// phone's language. Loaded by [loadLanguageChoice] before the first frame.
final followsPhoneLanguage = ValueNotifier(true);

Future<void> loadLanguageChoice() async =>
    followsPhoneLanguage.value = !(await SharedPreferences.getInstance()).containsKey('locale');

/// Picks [code], or the phone's language (and keeps following it) when null.
Future<void> setAppLanguage(BuildContext context, String? code) async {
  followsPhoneLanguage.value = code == null;
  if (code != null) return context.setLocale(Locale(code));
  await _usePhoneLanguage(context);
}

/// The phone's language changed while the app ran: Automatic follows it.
Future<void> phoneLanguageChanged(BuildContext context) async {
  if (followsPhoneLanguage.value) await _usePhoneLanguage(context);
}

/// The phone's first language, as easy_localization picks it at start
/// (English when the app doesn't have it), without saving it as a choice.
Future<void> _usePhoneLanguage(BuildContext context) async {
  final phone = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
  final code = appLanguages.any((l) => l.$1 == phone) ? phone : 'en';
  if (code != context.locale.languageCode) await context.setLocale(Locale(code));
  if (context.mounted) await context.deleteSaveLocale();
}

/// The language sheet: Automatic, then every language in its own name.
Future<void> showLanguageSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheet) {
    final auto = followsPhoneLanguage.value;
    final current = Localizations.localeOf(context).languageCode;
    Widget option(String? code, String title, {String? subtitle}) {
      final on = code == null ? auto : !auto && code == current;
      return ListTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: on ? Icon(Icons.check, color: Theme.of(sheet).colorScheme.primary) : null,
        selected: on,
        onTap: () {
          Navigator.pop(sheet);
          setAppLanguage(context, code);
        },
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            option(null, 'languageAuto'.tr(), subtitle: 'languageAutoSub'.tr()),
            const Divider(height: 1),
            for (final (code, name) in appLanguages) option(code, name),
          ],
        ),
      ),
    );
  },
);
