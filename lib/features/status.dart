import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../sip/sip_service.dart';
import 'contacts_screen.dart' show StatusRulesScreen;
import 'status_codes.dart';

/// Your status: Ready, Silent, Do not disturb — a label, a
/// colour and an icon.
(String, Color, IconData) statusLook(Tokens t, MyStatus s) => switch (s) {
      MyStatus.available => ('statusAvailable'.tr(), t.success, Icons.check_circle),
      MyStatus.silent => ('statusSilent'.tr(), t.warn, Icons.notifications_off),
      MyStatus.dnd => ('statusDnd'.tr(), t.danger, Icons.do_not_disturb_on),
    };

/// `4:07`, or `1:02:09` past an hour.
String _elapsed(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// The status pill: icon, status, how long, and a
/// chevron; tap for the status sheet. While the default account is not
/// registered it says so instead, and a tap retries.
class StatusPill extends ConsumerStatefulWidget {
  const StatusPill({super.key, this.compact = false});

  /// For a crowded header: short label, no timer.
  final bool compact;

  @override
  ConsumerState<StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends ConsumerState<StatusPill> {
  late final Timer _tick = Timer.periodic(const Duration(seconds: 1), (_) {
    if (mounted) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    _tick;
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final settings = ref.watch(settingsProvider);
    final sip = ref.watch(sipProvider);
    final def = ref.watch(accountsProvider).defaultAccount;
    final rt = def == null ? null : sip.runtimes[def.id];
    final narrow = MediaQuery.sizeOf(context).width < 360;

    final String label;
    final Color color;
    final IconData icon;
    String time = '';
    VoidCallback onTap = () => showStatusSheet(context);
    if (rt != null && rt.status != RegStatus.registered && rt.status != RegStatus.off) {
      final failed = rt.status == RegStatus.failed;
      label = failed ? 'notConnected'.tr() : 'regReconnecting'.tr();
      color = failed ? t.danger : t.warn;
      icon = failed ? Icons.error_outline : Icons.sync;
      onTap = () => sip.retryNow(def!.id);
    } else {
      final s = settings.effectiveStatus();
      final look = statusLook(t, s);
      label = widget.compact && s == MyStatus.dnd ? 'statusDndShort'.tr() : look.$1;
      color = look.$2;
      icon = look.$3;
      final since = settings.statusSince;
      if (!widget.compact && since.millisecondsSinceEpoch > 0 && s == settings.status) {
        time = _elapsed(DateTime.now().difference(since));
      }
    }

    return Semantics(
      button: true,
      label: 'yourStatus'.tr(),
      child: Material(
        color: color.withValues(alpha: 0.13),
        shape: StadiumBorder(side: BorderSide(color: color.withValues(alpha: 0.34))),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            height: 34,
            padding: const EdgeInsetsDirectional.only(start: 10, end: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.compact ? 84 : (narrow ? 96 : 132)),
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.3, color: color)),
              ),
              if (time.isNotEmpty) ...[
                const SizedBox(width: 7),
                Text(time,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: t.text.withValues(alpha: 0.75))),
              ],
              Icon(Icons.keyboard_arrow_down, size: 18, color: color),
            ]),
          ),
        ),
      ),
    );
  }
}

Future<void> showStatusSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _StatusSheet(),
    );

/// The status sheet: whether the softphone is registered, then Ready,
/// Silent and Do not disturb; each dials its feature codes on the PBX.
class _StatusSheet extends ConsumerWidget {
  const _StatusSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final settings = ref.watch(settingsProvider);
    final sip = ref.watch(sipProvider);
    final def = ref.watch(accountsProvider).defaultAccount;
    final registered = def != null && sip.runtimes[def.id]?.status == RegStatus.registered;
    final current = settings.status;
    final nav = Navigator.of(context);

    Widget option(MyStatus s, String help) {
      final (label, color, icon) = statusLook(t, s);
      final on = current == s;
      return ListTile(
        leading: Icon(icon, color: color),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(help, style: TextStyle(fontSize: 12.5, color: t.text2)),
        trailing: on ? Icon(Icons.check, color: color) : null,
        selected: on,
        selectedTileColor: color.withValues(alpha: 0.08),
        onTap: () {
          nav.pop();
          sip.setMyStatus(s);
        },
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ListTile(
            leading: Icon(registered ? Icons.cloud_done_outlined : Icons.cloud_off, color: registered ? t.success : t.danger),
            title: Text('softphone'.tr(), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(
              [if (def != null) def.label, registered ? 'registered'.tr() : 'notRegistered'.tr()].join(' · '),
              style: TextStyle(fontSize: 12.5, color: registered ? t.success : t.danger),
            ),
          ),
          Divider(height: 1, color: t.border),
          option(MyStatus.available, 'helpAvailable'.tr()),
          option(MyStatus.silent, 'helpSilent'.tr()),
          option(MyStatus.dnd, 'helpDnd'.tr()),
          Divider(height: 1, color: t.border),
          ListTile(
            leading: Icon(Icons.schedule, color: t.text2),
            title: Text('statusRules'.tr()),
            trailing: Icon(Icons.chevron_right, color: t.text2),
            onTap: () {
              nav.pop();
              nav.push(MaterialPageRoute(builder: (_) => const StatusRulesScreen()));
            },
          ),
          ListTile(
            leading: Icon(Icons.dialpad, color: t.text2),
            title: Text('statusCodes'.tr()),
            subtitle: Text('statusCodesSub'.tr(), style: TextStyle(fontSize: 12.5, color: t.text2)),
            trailing: Icon(Icons.chevron_right, color: t.text2),
            onTap: () {
              nav.pop();
              nav.push(MaterialPageRoute(builder: (_) => const StatusCodesScreen()));
            },
          ),
        ]),
      ),
    );
  }
}
