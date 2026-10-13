import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../sip/sip_service.dart';
import '../ui/widgets.dart';
import 'accounts.dart';
import 'settings_screen.dart';
import 'contacts_screen.dart';

/// The two sheets of the keypad header: "you" from the avatar (status,
/// accounts, settings) and the account picker from the account pill.

Color statusColor(Tokens t, MyStatus s) => switch (s) {
      MyStatus.available => t.success,
      MyStatus.silent => t.warn,
      MyStatus.dnd => t.danger,
    };

Future<void> showMeSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => const _MeSheet(),
    );

/// Pops with the id of the account to call from.
Future<String?> showAccountSheet(BuildContext context, {String? selectedId}) => showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _AccountSheet(selectedId: selectedId),
    );

class _MeSheet extends ConsumerWidget {
  const _MeSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final settings = ref.watch(settingsProvider);
    final def = ref.watch(accountsProvider).defaultAccount;
    final name = def == null ? '' : (def.displayName.isNotEmpty ? def.displayName : def.user);
    final nav = Navigator.of(context);
    final help = switch (settings.effectiveStatus()) {
      MyStatus.available => 'helpAvailable'.tr(),
      MyStatus.silent => 'helpSilent'.tr(),
      MyStatus.dnd => 'helpDnd'.tr(),
    };

    return _SheetBody(children: [
      Row(children: [
        Avatar(name.isEmpty ? '?' : name, size: 52, dot: statusColor(t, settings.effectiveStatus())),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            if (def != null)
              Text('${def.user} · ${def.label}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text2)),
          ]),
        ),
      ]),
      const SizedBox(height: 20),
      Text('yourStatus'.tr(), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
      const SizedBox(height: 8),
      Row(children: [
        for (final s in MyStatus.values)
          Expanded(
            child: Padding(
              padding: EdgeInsetsDirectional.only(end: s == MyStatus.dnd ? 0 : 6),
              child: StatusButton(status: s, selected: settings.status == s, onTap: () => settings.status = s),
            ),
          ),
      ]),
      const SizedBox(height: 8),
      Text(help, style: TextStyle(fontSize: 12.5, color: t.text2)),
      const SizedBox(height: 18),
      _SheetTile(
        icon: Icons.schedule,
        title: 'statusRules'.tr(),
        subtitle: officeHoursText(settings),
        onTap: () {
          nav.pop();
          nav.push(MaterialPageRoute(builder: (_) => const StatusRulesScreen()));
        },
      ),
      const SizedBox(height: 8),
      _SheetTile(
        icon: Icons.dns_outlined,
        title: 'tabAccounts'.tr(),
        subtitle: 'manageAccountsSub'.tr(),
        onTap: () {
          nav.pop();
          nav.push(MaterialPageRoute(builder: (_) => const AccountsScreen()));
        },
      ),
      const SizedBox(height: 8),
      _SheetTile(
        icon: Icons.settings_outlined,
        title: 'settings'.tr(),
        onTap: () {
          nav.pop();
          nav.push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
        },
      ),
    ]);
  }
}

class _AccountSheet extends ConsumerWidget {
  const _AccountSheet({required this.selectedId});
  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final sip = ref.watch(sipProvider);
    final accounts = ref.watch(accountsProvider).accounts.where((a) => a.enabled).toList();
    final nav = Navigator.of(context);

    return _SheetBody(children: [
      Text('callFrom'.tr(), style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
      const SizedBox(height: 8),
      for (final a in accounts)
        Builder(builder: (context) {
          final rt = sip.runtimes[a.id];
          final status = rt?.status ?? RegStatus.registering;
          final selected = a.id == selectedId;
          return InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => nav.pop(a.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                Dot(regColor(t, status), size: 10),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${a.label} · ${a.user}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    Text(regText(rt), style: mono(context, size: 11.5, color: regColor(t, status))),
                  ]),
                ),
                if (status == RegStatus.failed)
                  TextButton(onPressed: () => sip.retryNow(a.id), child: Text('retryNow'.tr()))
                else if (selected)
                  Icon(Icons.check_circle, color: t.accent),
              ]),
            ),
          );
        }),
      const SizedBox(height: 12),
      _SheetTile(
        icon: Icons.dns_outlined,
        title: 'manageAccounts'.tr(),
        onTap: () {
          nav.pop();
          nav.push(MaterialPageRoute(builder: (_) => const AccountsScreen()));
        },
      ),
    ]);
  }
}

class _SheetBody extends StatelessWidget {
  const _SheetBody({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Center(
          child: Container(
            width: 38,
            height: 5,
            decoration: BoxDecoration(color: context.t.border, borderRadius: BorderRadius.circular(3)),
          ),
        ),
        const SizedBox(height: 16),
        ...children,
      ]),
    );
  }
}

class _SheetTile extends StatelessWidget {
  const _SheetTile({required this.icon, required this.title, required this.onTap, this.subtitle});
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: t.border)),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: t.text2),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: subtitle == null ? null : Text(subtitle!, style: TextStyle(fontSize: 12.5, color: t.text2)),
        trailing: Icon(Icons.chevron_right, color: t.text2),
      ),
    );
  }
}
