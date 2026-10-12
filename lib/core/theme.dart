import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design E tokens: Echo's palette, in light and dark.
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

  static const light = Tokens(
    bg: Color(0xFFF6F8FA),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFEEF1F5),
    border: Color(0xFFD8DEE6),
    text: Color(0xFF1C2128),
    text2: Color(0xFF5A6573),
    accent: Color(0xFF1F6FEB),
    accentSoft: Color(0xFFDDEBFF),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1A7F37),
    successSoft: Color(0xFFDAF5E1),
    onSuccess: Color(0xFFFFFFFF),
    danger: Color(0xFFCF222E),
    dangerSoft: Color(0xFFFFE4E6),
    missed: Color(0xFFC81E4E),
    warn: Color(0xFF9A6700),
    warnSoft: Color(0xFFFFF3D1),
    info: Color(0xFF0969DA),
    purple: Color(0xFF7C5CFF),
    purpleSoft: Color(0xFFECE8FF),
    grey: Color(0xFF8B95A3),
    nav: Color(0xFFFFFFFF),
    dark: false,
  );

  static const darkTokens = Tokens(
    bg: Color(0xFF0D1014),
    surface: Color(0xFF14181E),
    surface2: Color(0xFF1B2027),
    border: Color(0xFF2A313A),
    text: Color(0xFFE8EDF3),
    text2: Color(0xFF9AA4B2),
    accent: Color(0xFF4493F8),
    accentSoft: Color(0x294493F8),
    onAccent: Color(0xFF0D1014),
    success: Color(0xFF3FB950),
    successSoft: Color(0x243FB950),
    onSuccess: Color(0xFF0D1014),
    danger: Color(0xFFF85149),
    dangerSoft: Color(0x24FF4D6A),
    missed: Color(0xFFFF4D6A),
    warn: Color(0xFFD29922),
    warnSoft: Color(0x24D29922),
    info: Color(0xFF58A6FF),
    purple: Color(0xFFA5A5FF),
    purpleSoft: Color(0x24A5A5FF),
    grey: Color(0xFF6B7480),
    nav: Color(0xFF161A21),
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
    GoogleFonts.jetBrainsMono(fontSize: size, color: color ?? context.t.text2, fontWeight: weight);

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
  final family = arabic ? GoogleFonts.cairo().fontFamily : GoogleFonts.plusJakartaSans().fontFamily;
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: family, bodyColor: tk.text, displayColor: tk.text),
    appBarTheme: AppBarTheme(
      backgroundColor: tk.bg,
      foregroundColor: tk.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: tk.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: tk.border)),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: tk.border)),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: tk.accent, width: 2)),
      labelStyle: TextStyle(color: tk.text2),
      hintStyle: TextStyle(color: tk.text2),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: tk.text,
      contentTextStyle: TextStyle(color: tk.bg),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tk.bg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? tk.accent : tk.surface2),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
  );
}
