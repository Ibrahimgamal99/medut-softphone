import 'dart:async';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounts.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../ui/widgets.dart';

/// Settings → Status codes: for each account, which PBX it is and the
/// feature codes a status change dials there (DND on / off, queue log-in /
/// log-out). Picking a PBX fills its usual codes; each stays editable.
class StatusCodesScreen extends ConsumerWidget {
  const StatusCodesScreen({super.key, this.accountId});

  /// Only this account (from its technical settings); null = all accounts.
  final String? accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final accounts = ref.watch(accountsProvider).accounts.where((a) => accountId == null || a.id == accountId).toList();
    return Scaffold(
      appBar: AppBar(title: Text('statusCodes'.tr(), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.info.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.info.withValues(alpha: 0.3)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline, size: 20, color: t.info),
              const SizedBox(width: 10),
              Expanded(child: Text('statusCodesIntro'.tr(), style: const TextStyle(fontSize: 13, height: 1.45))),
            ]),
          ),
          for (final a in accounts) _AccountCodes(key: ValueKey(a.id), account: a),
          if (accounts.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('noAccountsYet'.tr(), textAlign: TextAlign.center, style: TextStyle(color: t.text2)),
            ),
        ]),
      ),
    );
  }
}

/// `FreePBX / Issabel · DND *78 / *79 · queue *45` for an account.
String codesSummary(SipAccountConfig a) {
  String pair(String on, String off) =>
      on.isEmpty && off.isEmpty ? '—' : (on == off ? on : '${on.isEmpty ? '—' : on} / ${off.isEmpty ? '—' : off}');
  return '${pbxName(a.pbx)} · DND ${pair(a.code('dndOn'), a.code('dndOff'))}'
      ' · ${'queueShort'.tr()} ${pair(a.code('queueLogin'), a.code('queueLogout'))}';
}

/// PBX names for the presets in [kPbxPresets].
String pbxName(String pbx) => switch (pbx) {
      'freepbx' => 'FreePBX / Issabel',
      'fusionpbx' => 'FusionPBX / FreeSWITCH',
      '3cx' => '3CX',
      _ => 'pbxCustom'.tr(),
    };

class _AccountCodes extends ConsumerStatefulWidget {
  const _AccountCodes({super.key, required this.account});
  final SipAccountConfig account;

  @override
  ConsumerState<_AccountCodes> createState() => _AccountCodesState();
}

class _AccountCodesState extends ConsumerState<_AccountCodes> {
  late String _pbx = widget.account.pbx;
  late final Map<String, TextEditingController> _codes = {
    for (final k in kStatusCodeKeys) k: TextEditingController(text: widget.account.code(k)),
  };
  Timer? _save;
  late final AccountStore _store = ref.read(accountsProvider);

  @override
  void initState() {
    super.initState();
    _store; // read now: saving on dispose needs it
  }

  @override
  void dispose() {
    _save?.cancel();
    _flush();
    for (final c in _codes.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Saves a moment after the last keystroke (and on leaving). Codes are
  /// app-side only, so saving never re-registers the account.
  void _changed() {
    setState(() {});
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 600), _flush);
  }

  void _flush() {
    final store = _store;
    final a = store.byId(widget.account.id);
    if (a == null) return;
    final codes = {for (final e in _codes.entries) e.key: e.value.text.trim()};
    if (a.pbx == _pbx && kStatusCodeKeys.every((k) => a.code(k) == codes[k])) return;
    store.save(a.copyWith(pbx: _pbx, codes: codes));
  }

  void _preset(String pbx) {
    _pbx = pbx;
    for (final k in kStatusCodeKeys) {
      _codes[k]!.text = kPbxPresets[pbx]?[k] ?? '';
    }
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final toggle = _codes['queueLogin']!.text.isNotEmpty && _codes['queueLogin']!.text == _codes['queueLogout']!.text;
    Widget field(String key, String label, String help) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: TextField(
            controller: _codes[key],
            keyboardType: TextInputType.phone,
            textDirection: ui.TextDirection.ltr,
            style: mono(context, size: 15, color: t.text),
            onChanged: (_) => _changed(),
            decoration: InputDecoration(labelText: label, helperText: help, hintText: 'codeNone'.tr()),
          ),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(widget.account.label.toUpperCase()),
      Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DropdownButtonFormField<String>(
            initialValue: _pbx,
            isExpanded: true,
            decoration: InputDecoration(labelText: 'pbxType'.tr()),
            items: [
              for (final p in kPbxPresets.keys)
                DropdownMenuItem(value: p, child: Text(pbxName(p), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => v == null ? null : _preset(v),
          ),
          field('dndOn', 'code_dndOn'.tr(), 'codeDndOnHelp'.tr()),
          field('dndOff', 'code_dndOff'.tr(), 'codeDndOffHelp'.tr()),
          field('queueLogin', 'code_queueLogin'.tr(), 'codeQueueLoginHelp'.tr()),
          field('queueLogout', 'code_queueLogout'.tr(), 'codeQueueLogoutHelp'.tr()),
          if (toggle)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.sync_alt, size: 18, color: t.warn),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('codeToggleNote'.tr(namedArgs: {'code': _codes['queueLogin']!.text}),
                      style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text2)),
                ),
              ]),
            ),
        ]),
      ),
    ]);
  }
}
