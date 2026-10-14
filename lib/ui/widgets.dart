import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../sip/quality.dart';
import '../sip/sip_service.dart';

String initials(String s) {
  final parts = s.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  final first = parts.first;
  if (!RegExp(r'^\p{L}', unicode: true).hasMatch(first)) {
    return first.length <= 2 ? first : first.substring(first.length - 2);
  }
  return (first.characters.first + (parts.length > 1 ? parts[1].characters.first : '')).toUpperCase();
}

/// Initials on a colour picked from the name, so a person looks the same in
/// every list; [colors] overrides it (a missed call is red).
class Avatar extends StatelessWidget {
  const Avatar(this.title, {super.key, this.size = 40, this.dot, this.colors});
  final String title;
  final double size;
  final Color? dot;
  final (Color, Color)? colors;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (bg, fg) = colors ?? t.avatars[title.codeUnits.fold<int>(0, (h, c) => (h * 31 + c) & 0x7fffffff) % t.avatars.length];
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Text(initials(title), style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: size * 0.34)),
        ),
        if (dot != null)
          PositionedDirectional(
            end: -1,
            bottom: -1,
            child: Container(
              width: size * 0.32,
              height: size * 0.32,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle, border: Border.all(color: t.bg, width: 2)),
            ),
          ),
      ]),
    );
  }
}

class Dot extends StatelessWidget {
  const Dot(this.color, {super.key, this.size = 8});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) =>
      Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

/// Rounded surface card with the E border.
class ECard extends StatelessWidget {
  const ECard({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.borderColor, this.onTap});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? borderColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: borderColor ?? t.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

/// Filter / option pill: dark when selected, outlined otherwise.
class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, required this.selected, required this.onTap, this.leading});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: selected ? t.text : t.surface,
      shape: StadiumBorder(side: BorderSide(color: selected ? t.text : t.border)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (leading != null) ...[leading!, const SizedBox(width: 7)],
            Text(label,
                style: TextStyle(
                    color: selected ? t.bg : t.text, fontSize: 13, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(4, 16, 4, 8),
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: context.t.text2)),
      );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.color, this.textColor});
  final String label;
  final VoidCallback? onPressed;
  final Color? color, textColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SizedBox(
      height: 54,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: color ?? t.accent,
          foregroundColor: textColor ?? t.onAccent,
          disabledBackgroundColor: t.surface2,
          disabledForegroundColor: t.grey,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  const SecondaryButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SizedBox(
      height: 54,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: t.surface,
          foregroundColor: t.text,
          side: BorderSide(color: t.border),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

/// Round icon button with E border (header actions, list actions).
class RoundIcon extends StatelessWidget {
  const RoundIcon({super.key, required this.icon, required this.onTap, required this.tooltip, this.size = 44, this.color, this.bg});
  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final double size;
  final Color? color, bg;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg ?? t.surface,
        shape: CircleBorder(side: bg == null ? BorderSide(color: t.border) : BorderSide.none),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: size, height: size, child: Icon(icon, size: size * 0.42, color: color ?? t.text2)),
        ),
      ),
    );
  }
}

/// The Medut mark, as on the app icon: the staff 𓌃 (md, the first sign of
/// mdwt, "speech") speaking, white on a green rounded square.
class MedutMark extends StatelessWidget {
  const MedutMark({super.key, this.size = 26});
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: t.accent, borderRadius: BorderRadius.circular(size * 0.225)),
      child: CustomPaint(painter: _MarkPainter(t.onAccent)),
    );
  }
}

/// Paths of design/icon/medut-icon.svg, on its 100-unit grid.
class _MarkPainter extends CustomPainter {
  const _MarkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..scale(size.width / 100)
      ..translate(-0.15, -1);
    Paint stroke(double w) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(34, 78)
        ..lineTo(34, 33)
        ..arcToPoint(const Offset(43, 24), radius: const Radius.circular(9))
        ..lineTo(46, 24),
      stroke(8),
    );
    canvas.drawPath(
      Path()
        ..moveTo(52, 41)
        ..arcToPoint(const Offset(52, 59), radius: const Radius.circular(13))
        ..moveTo(60, 33)
        ..arcToPoint(const Offset(60, 67), radius: const Radius.circular(24)),
      stroke(6.5),
    );
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}

// ── Status helpers ─────────────────────────────────────────────────────────

Color regColor(Tokens t, RegStatus s) => switch (s) {
      RegStatus.registered => t.success,
      RegStatus.reconnecting => t.info,
      RegStatus.registering => t.warn,
      RegStatus.failed => t.danger,
      RegStatus.off => t.grey,
    };

/// Plain-language registration state, with the SIP detail C wanted.
String regText(AccountRuntime? rt) {
  if (rt == null) return 'regOff'.tr();
  final retry = rt.retryInMs > 0 ? ' · ${'retryIn'.tr(namedArgs: {'s': '${(rt.retryInMs / 1000).round()}'})}' : '';
  return switch (rt.status) {
    RegStatus.registered => '${'regRegistered'.tr()} · ${rt.cfg.transport.toUpperCase()}',
    RegStatus.registering => 'regRegistering'.tr(),
    RegStatus.reconnecting => 'regReconnecting'.tr(),
    RegStatus.failed =>
      '${rt.sipCode == 401 || rt.sipCode == 403 ? 'wrongPassword'.tr() : 'regFailed'.tr()}${rt.sipCode > 0 ? ' (${rt.sipCode})' : ''}$retry',
    RegStatus.off => 'regOff'.tr(),
  };
}

Color presenceColor(Tokens t, PresenceStatus? s) => switch (s) {
      PresenceStatus.open => t.success,
      PresenceStatus.busy => t.danger,
      PresenceStatus.closed => t.purple,
      _ => t.grey,
    };

String presenceText(PresenceStatus? s) => switch (s) {
      PresenceStatus.open => 'presenceOpen'.tr(),
      PresenceStatus.busy => 'presenceBusy'.tr(),
      PresenceStatus.closed => 'presenceClosed'.tr(),
      _ => 'presenceUnknown'.tr(),
    };

/// Colour of a call quality grade (bars, word): green / amber / red / grey.
Color qualityColor(Tokens t, int level) => switch (level) {
      4 || 3 => t.success,
      2 => t.warn,
      1 => t.danger,
      _ => t.grey,
    };

/// 3-bar Voice Quality Indicator for a finished or live call.
class QualityBars extends StatelessWidget {
  const QualityBars({super.key, this.mos, this.rttMs, this.jitterMs, this.lossPct, this.barWidth = 4});
  final double? mos, rttMs, jitterMs, lossPct;
  final double barWidth;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final level = callQualityLevel(mos: mos, rttMs: rttMs, jitterMs: jitterMs, lossPct: lossPct);
    final color = qualityColor(t, level);
    final lit = level > 3 ? 3 : level;
    return Semantics(
      label: qualityWordKey(level).tr(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(3, (i) {
          return Container(
            margin: EdgeInsets.symmetric(horizontal: barWidth * 0.35),
            width: barWidth,
            height: barWidth * 1.75 + i * barWidth * 1.25,
            decoration: BoxDecoration(
              color: i < lit ? color : t.text2.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(barWidth / 2),
            ),
          );
        }),
      ),
    );
  }
}

/// Call detail row: the bars, then MOS / RTT / jitter / loss, each green when
/// it meets its target and red when it does not.
class QualityMetricsRow extends StatelessWidget {
  const QualityMetricsRow({super.key, this.mos, this.rttMs, this.jitterMs, this.lossPct});
  final double? mos, rttMs, jitterMs, lossPct;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    Widget chip(String label, String value, bool ok) => Expanded(
          child: Column(children: [
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ok ? t.success : t.danger,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: t.text2, fontSize: 11)),
          ]),
        );
    String fmt(double? v, String unit, {int digits = 0}) => v == null ? '—' : '${v.toStringAsFixed(digits)}$unit';
    return Row(children: [
      QualityBars(mos: mos, rttMs: rttMs, jitterMs: jitterMs, lossPct: lossPct),
      const SizedBox(width: 16),
      chip('MOS', mos?.toStringAsFixed(1) ?? '—', mos == null || callQualityLevel(mos: mos) >= 3),
      chip('RTT', fmt(rttMs, ' ms'), (rttMs ?? 0) < 150),
      chip('Jitter', fmt(jitterMs, ' ms'), (jitterMs ?? 0) < 20),
      chip('Loss', fmt(lossPct, '%', digits: 1), (lossPct ?? 0) < 1),
    ]);
  }
}

/// Pocket segmented choice: a tinted track, the chosen segment in the accent.
class PocketSegments extends StatelessWidget {
  const PocketSegments({super.key, required this.options, required this.labels, required this.value, required this.onChanged, this.track});
  final List<String> options, labels;
  final String value;
  final ValueChanged<String>? onChanged;

  /// The track colour; defaults to the second surface (for a sheet or card).
  final Color? track;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: track ?? t.surface2, borderRadius: BorderRadius.circular(13)),
      child: Row(children: [
        for (var i = 0; i < options.length; i++)
          Expanded(
            child: Semantics(
              selected: value == options[i],
              button: true,
              child: Material(
                color: value == options[i] ? t.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: onChanged == null ? null : () => onChanged!(options[i]),
                  child: SizedBox(
                    height: 38,
                    child: Center(
                      child: Text(labels[i],
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: value == options[i] ? t.accent : t.text2)),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

// ── Settings sections and rows ───────────────────────────────────────────────

/// A settings group: an uppercase caption over one rounded card whose rows
/// are separated by hairlines.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, this.title, required this.children});
  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (title != null)
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 20, 20, 8),
          child: Text(title!.toUpperCase(),
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: t.text2)),
        )
      else
        const SizedBox(height: 20),
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: Column(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, thickness: 1, indent: 60, color: t.border.withValues(alpha: 0.6)),
              children[i],
            ],
          ]),
        ),
      ),
    ]);
  }
}

/// A settings row: a tinted icon tile, a title and an optional subtitle, and
/// a trailing control (or a chevron when the row opens something).
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.tint,
    this.trailing,
    this.onTap,
    this.titleColor,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? tint;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final c = tint ?? t.accent;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 18, color: c),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: titleColor ?? t.text)),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: TextStyle(fontSize: 12, height: 1.35, color: t.text2)),
              ],
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!]
          else if (onTap != null)
            Icon(Icons.chevron_right, size: 20, color: t.text2.withValues(alpha: 0.6)),
        ]),
      ),
    );
  }
}

/// A small status badge (REGISTERED, ON).
class SettingsBadge extends StatelessWidget {
  const SettingsBadge(this.text, {super.key, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(text.toUpperCase(),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.3, color: color)),
      );
}
