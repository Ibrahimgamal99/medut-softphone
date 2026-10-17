import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens: the app palette, in light and dark.
@immutable
class Tokens extends ThemeExtension<Tokens> {
  const Tokens({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.border,
    required this.text,
    required this.text2,
    required this.accent,
    required this.accentText,
    required this.accentSoft,
    required this.onAccent,
    required this.success,
    required this.successSoft,
    required this.onSuccess,
    required this.danger,
    required this.dangerSoft,
    required this.missed,
    required this.warn,
    required this.warnSoft,
    required this.info,
    required this.purple,
    required this.purpleSoft,
    required this.grey,
    required this.nav,
    required this.avatars,
    required this.dark,
  });

  final Color bg, surface, surface2, border, text, text2;
  /// [accent] fills buttons and focus rings; [accentText] is the same cyan as
  /// text or an icon, darkened on light so small text stays readable.
  final Color accent, accentText, accentSoft, onAccent;
  final Color success, successSoft, onSuccess;
  final Color danger, dangerSoft, missed, warn, warnSoft, info;
  final Color purple, purpleSoft, grey, nav;

  /// (background, initials) pairs; a person keeps the same one everywhere.
  final List<(Color, Color)> avatars;
  final bool dark;

  /// Medut brand: cool neutrals, one cyan for the brand, green only for "call".
  static const light = Tokens(
    bg: Color(0xFFF6F7F8),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFECEEF1),
    border: Color(0xFFDFE2E6),
    text: Color(0xFF111418),
    text2: Color(0xFF454D56),
    accent: Color(0xFF0F8EB8),
    accentText: Color(0xFF0B6886),
    accentSoft: Color(0xFFDCEEF5),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF16A34A),
    successSoft: Color(0xFFDCF5E4),
    onSuccess: Color(0xFFFFFFFF),
    danger: Color(0xFFDC2626),
    dangerSoft: Color(0xFFFCE4E4),
    missed: Color(0xFFDC2626),
    warn: Color(0xFFD97706),
    warnSoft: Color(0xFFFDEFD8),
    info: Color(0xFF2563EB),
    purple: Color(0xFF9333EA),
    purpleSoft: Color(0xFFEFE4FB),
    grey: Color(0xFF9097A1),
    nav: Color(0xFFF6F7F8),
    avatars: [
      (Color(0xFFD6ECF4), Color(0xFF0B6886)),
      (Color(0xFFEFE4FB), Color(0xFF7E22CE)),
      (Color(0xFFFBE8D7), Color(0xFF9A4A12)),
      (Color(0xFFDBEAFE), Color(0xFF1D4ED8)),
    ],
    dark: false,
  );

  static const darkTokens = Tokens(
    bg: Color(0xFF0C0E10),
    surface: Color(0xFF131619),
    surface2: Color(0xFF1B1F24),
    border: Color(0xFF262B31),
    text: Color(0xFFECEFF2),
    text2: Color(0xFFA6AEB7),
    accent: Color(0xFF0F8EB8),
    accentText: Color(0xFF11A4D4),
    accentSoft: Color(0x2611A4D4),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF22C55E),
    successSoft: Color(0x2422C55E),
    onSuccess: Color(0xFF052E16),
    danger: Color(0xFFEF4444),
    dangerSoft: Color(0x26EF4444),
    missed: Color(0xFFEF4444),
    warn: Color(0xFFF59E0B),
    warnSoft: Color(0x24F59E0B),
    info: Color(0xFF3B82F6),
    purple: Color(0xFFA855F7),
    purpleSoft: Color(0x29A855F7),
    grey: Color(0xFF6F7781),
    nav: Color(0xFF0C0E10),
    avatars: [
      (Color(0xFF084E65), Color(0xFF9BDCF2)),
      (Color(0xFF2E1A4A), Color(0xFFC4A2FA)),
      (Color(0xFF38261A), Color(0xFFF4B27A)),
      (Color(0xFF162A3D), Color(0xFF8EC0F2)),
    ],
    dark: true,
  );

  @override
  Tokens copyWith() => this;

  @override
  Tokens lerp(ThemeExtension<Tokens>? other, double t) =>
      (other is Tokens && t >= 0.5) ? other : this;
}

extension TokensX on BuildContext {
  Tokens get t => Theme.of(this).extension<Tokens>()!;
}

/// IBM Plex Mono: numbers, and SIP / RTP details (URIs, codecs, MOS).
TextStyle mono(BuildContext context, {double size = 11, Color? color, FontWeight? weight}) =>
    GoogleFonts.ibmPlexMono(fontSize: size, color: color ?? context.t.text2, fontWeight: weight);

ThemeData buildTheme(Tokens tk, {required String language}) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: tk.dark ? Brightness.dark : Brightness.light,
    scaffoldBackgroundColor: tk.bg,
    colorScheme: ColorScheme(
      brightness: tk.dark ? Brightness.dark : Brightness.light,
      primary: tk.accent,
      onPrimary: tk.onAccent,
      secondary: tk.success,
      onSecondary: tk.onSuccess,
      error: tk.danger,
      onError: Colors.white,
      surface: tk.surface,
      onSurface: tk.text,
    ),
    dividerColor: tk.border,
    extensions: [tk],
  );
  // IBM Plex Sans has no Arabic letters; Plex Sans Arabic covers Arabic and
  // Persian. Chinese uses the system font.
  final family = switch (language) {
    'ar' || 'fa' => GoogleFonts.ibmPlexSansArabic().fontFamily,
    _ => GoogleFonts.ibmPlexSans().fontFamily,
  };
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: family, bodyColor: tk.text, displayColor: tk.text),
    appBarTheme: AppBarTheme(
      backgroundColor: tk.bg,
      foregroundColor: tk.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    // Fields are white pills with the label inside, as on the sign-in screen.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: tk.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide(color: tk.border)),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide(color: tk.border)),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide(color: tk.accent, width: 1.5)),
      errorBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide(color: tk.danger)),
      focusedErrorBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide(color: tk.danger, width: 1.5)),
      labelStyle: TextStyle(color: tk.text2),
      floatingLabelStyle: TextStyle(color: tk.text2, fontWeight: FontWeight.w600),
      hintStyle: TextStyle(color: tk.grey),
      helperStyle: TextStyle(color: tk.grey, fontSize: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tk.accent,
        foregroundColor: tk.onAccent,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(foregroundColor: tk.text, side: BorderSide(color: tk.border), shape: const StadiumBorder()),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: tk.accentText, textStyle: const TextStyle(fontWeight: FontWeight.w600)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tk.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: tk.text,
      contentTextStyle: TextStyle(color: tk.bg),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tk.bg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? tk.accent : tk.surface2),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
  );
}
