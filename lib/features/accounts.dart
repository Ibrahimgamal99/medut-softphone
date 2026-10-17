import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounts.dart';
import '../core/providers.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../sip/sip_service.dart';
import '../ui/widgets.dart';
import 'account_edit.dart';
import 'settings_screen.dart';
import 'sign_in.dart';

/// Accounts (from the avatar on the keypad): every PBX account with its live
/// registration state in plain words plus the SIP detail, and which account
/// places a call.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final store = ref.watch(accountsProvider);
    final sip = ref.watch(sipProvider);
    final accounts = store.accounts;

    void openEdit([SipAccountConfig? a]) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => a == null ? const SignInScreen(another: true) : AccountEditScreen(existing: a)));

    return Scaffold(
      appBar: AppBar(
        title: Text('tabAccounts'.tr(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
        actions: [
          IconButton(
            tooltip: 'settings'.tr(),
            icon: Icon(Icons.settings_outlined, color: t.text2),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: openEdit,
              icon: const Icon(Icons.add, size: 18),
              label: Text('add'.tr()),
            ),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        const ReachabilityBanner(),
        for (final a in accounts) ...[
          _AccountCard(cfg: a, rt: sip.runtimes[a.id], onEdit: () => openEdit(a)),
          const SizedBox(height: 10),
        ],
        if (accounts.length > 1) const _DialRulesCard(),
      ]),
    );
  }
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.cfg, required this.rt, required this.onEdit});
  final SipAccountConfig cfg;
  final AccountRuntime? rt;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final status = cfg.enabled ? (rt?.status ?? RegStatus.registering) : RegStatus.off;
    final failed = status == RegStatus.failed;
    final color = regColor(t, status);
    final enc = switch (cfg.mediaEnc) { 'sdes' => 'SDES', 'dtls' => 'DTLS-SRTP', _ => 'no SRTP' };
    final codecs = cfg
        .codecsFrom(ref.watch(settingsProvider).codecs)
        .map((c) => c == 'alaw' ? 'PCMA' : c == 'ulaw' ? 'PCMU' : 'Opus')
        .join(', ');

    return ECard(
      onTap: onEdit,
      borderColor: failed ? t.danger.withValues(alpha: 0.5) : null,
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Dot(color, size: 10),
          const SizedBox(width: 10),
          Flexible(child: Text(cfg.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          IconButton(
            tooltip: 'rename'.tr(),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.edit_outlined, size: 18, color: t.text2),
            onPressed: () => renameAccount(context, ref, cfg),
          ),
          const Spacer(),
          if (cfg.isDefault)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: t.accentSoft, borderRadius: BorderRadius.circular(6)),
              child: Text('default'.tr(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: t.accentText)),
            ),
          Switch(value: cfg.enabled, onChanged: (v) => ref.read(accountsProvider).setEnabled(cfg.id, v)),
        ]),
        Text(cfg.enabled ? regText(rt) : 'regOff'.tr(),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: status == RegStatus.off ? t.text2 : color)),
        const SizedBox(height: 4),
        Text('sip:${cfg.aor}\n${cfg.transport.toUpperCase()} · $enc · $codecs',
            style: mono(context, size: 11).copyWith(height: 1.5)),
        if (failed && rt != null) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            if (rt!.sipCode == 401 || rt!.sipCode == 403)
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: t.danger, foregroundColor: Colors.white, shape: const StadiumBorder()),
                onPressed: onEdit,
                child: Text('updatePassword'.tr()),
              ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(shape: const StadiumBorder(), side: BorderSide(color: t.border), foregroundColor: t.text),
              onPressed: () => ref.read(sipProvider).retryNow(cfg.id),
              child: Text('retryNow'.tr()),
            ),
          ]),
        ],
      ]),
    );
  }
}

class _DialRulesCard extends ConsumerWidget {
  const _DialRulesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final settings = ref.watch(settingsProvider);
    final store = ref.watch(accountsProvider);
    final rules = settings.dialRules;

    Future<void> add() async {
      final pattern = TextEditingController();
      var accountId = store.accounts.first.id;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, set) => AlertDialog(
            title: Text('addRule'.tr()),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: pattern, decoration: InputDecoration(labelText: 'pattern'.tr(), hintText: '0XXXXXXXXXX')),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: accountId,
                items: [for (final a in store.accounts) DropdownMenuItem(value: a.id, child: Text(a.label))],
                onChanged: (v) => set(() => accountId = v ?? accountId),
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('cancel'.tr())),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('add'.tr())),
            ],
          ),
        ),
      );
      if (ok == true && pattern.text.trim().isNotEmpty) {
        settings.dialRules = [...rules, DialRule(pattern: pattern.text.trim().toUpperCase(), accountId: accountId)];
      }
    }

    return ECard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('whichAccount'.tr(), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('defaultUnlessRule'.tr(), style: TextStyle(fontSize: 12, color: t.text2)),
        const SizedBox(height: 6),
        if (rules.isEmpty) Text('noRules'.tr(), style: mono(context, size: 12)),
        for (final r in rules)
          Row(children: [
            Expanded(
              child: Text('${r.pattern} → ${store.byId(r.accountId)?.label ?? '?'}', style: mono(context, size: 12, color: t.text)),
            ),
            IconButton(
              tooltip: 'delete'.tr(),
              icon: Icon(Icons.close, size: 18, color: t.text2),
              onPressed: () => settings.dialRules = rules.where((x) => x != r).toList(),
            ),
          ]),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(onPressed: add, icon: const Icon(Icons.add, size: 18), label: Text('addRule'.tr())),
        ),
      ]),
    );
  }
}

/// Gives an account a name of your own ("Office", "Sales line").
Future<void> renameAccount(BuildContext context, WidgetRef ref, SipAccountConfig cfg) async {
  final name = await showDialog<String>(context: context, builder: (_) => _RenameDialog(initial: cfg.label));
  if (name == null) return;
  await ref.read(accountsProvider).save(cfg.copyWith(name: name.trim().isEmpty ? cfg.domain : name.trim()));
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('accountName'.tr()),
        content: TextField(
          controller: _text,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(hintText: 'accountNameHint'.tr(), helperText: 'accountNameHelp'.tr()),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('cancel'.tr())),
          FilledButton(onPressed: () => Navigator.pop(context, _text.text), child: Text('save'.tr())),
        ],
      );
}
