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
    required this.dark,
  });

  final Color bg, surface, surface2, border, text, text2;
  final Color accent, accentSoft, onAccent;
  final Color success, successSoft, onSuccess;
  final Color danger, dangerSoft, missed, warn, warnSoft, info;
  final Color purple, purpleSoft, grey, nav;
  final bool dark;

  /// Pocket: cool neutrals, one green that is both the brand and "call".
  static const light = Tokens(
    bg: Color(0xFFF3F4F6),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFE9ECEF),
    border: Color(0xFFE0E3E8),
    text: Color(0xFF0E1116),
    text2: Color(0xFF5D6470),
    accent: Color(0xFF08805A),
    accentSoft: Color(0xFFDCF2E8),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF08805A),
    successSoft: Color(0xFFDCF2E8),
    onSuccess: Color(0xFFFFFFFF),
    danger: Color(0xFFE5383B),
    dangerSoft: Color(0xFFFDE6E6),
    missed: Color(0xFFE5383B),
    warn: Color(0xFF9A6700),
    warnSoft: Color(0xFFFDF1DC),
    info: Color(0xFF1D5C99),
    purple: Color(0xFF4B3BB0),
    purpleSoft: Color(0xFFE7E3FB),
    grey: Color(0xFF9097A1),
    nav: Color(0xFFF3F4F6),
    dark: false,
  );

  static const darkTokens = Tokens(
    bg: Color(0xFF0C0E10),
    surface: Color(0xFF16191C),
    surface2: Color(0xFF1F2327),
    border: Color(0xFF2A2F34),
    text: Color(0xFFF2F4F6),
    text2: Color(0xFFA0A8B2),
    accent: Color(0xFF3DD49A),
    accentSoft: Color(0x243DD49A),
    onAccent: Color(0xFF04271A),
    success: Color(0xFF3DD49A),
    successSoft: Color(0x243DD49A),
    onSuccess: Color(0xFF04271A),
    danger: Color(0xFFFF5A5F),
    dangerSoft: Color(0x26FF5A5F),
    missed: Color(0xFFFF5A5F),
    warn: Color(0xFFE9B04A),
    warnSoft: Color(0x24E9B04A),
    info: Color(0xFF8EC0F2),
    purple: Color(0xFFB7AEFF),
    purpleSoft: Color(0x29B7AEFF),
    grey: Color(0xFF6F7781),
    nav: Color(0xFF0C0E10),
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

/// Monospace for SIP / RTP details (URIs, codecs, MOS).
TextStyle mono(BuildContext context, {double size = 11, Color? color, FontWeight? weight}) =>
    GoogleFonts.dmMono(fontSize: size, color: color ?? context.t.text2, fontWeight: weight);

ThemeData buildTheme(Tokens tk, {required bool arabic}) {
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
  final family = arabic ? GoogleFonts.cairo().fontFamily : GoogleFonts.figtree().fontFamily;
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
      style: TextButton.styleFrom(foregroundColor: tk.accent, textStyle: const TextStyle(fontWeight: FontWeight.w600)),
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
