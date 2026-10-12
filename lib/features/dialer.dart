import 'package:easy_localization/easy_localization.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/db.dart';
import '../core/providers.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../sip/sip_service.dart';
import '../ui/widgets.dart';
import 'account_edit.dart';

/// Ask for the microphone before the first call; returns false if refused.
Future<bool> ensureMic(BuildContext context) async {
  final s = await Permission.microphone.request();
  return s.isGranted;
}

Future<void> placeCall(BuildContext context, WidgetRef ref, String number, {String? accountId, String? name}) async {
  if (number.trim().isEmpty) return;
  if (!await ensureMic(context)) return;
  ref.read(sipProvider).dial(number, accountId: accountId, name: name);
}

class DialerScreen extends ConsumerStatefulWidget {
  const DialerScreen({super.key, required this.addCallMode, required this.onOpenAccounts});
  final ValueNotifier<bool> addCallMode;
  final VoidCallback onOpenAccounts;

  @override
  ConsumerState<DialerScreen> createState() => _DialerScreenState();
}

class _DialerScreenState extends ConsumerState<DialerScreen> {
  String _number = '';
  String? _accountId;
  List<CallRecord> _recent = const [];

  @override
  void initState() {
    super.initState();
    _loadRecent();
    ref.read(dbProvider).addListener(_loadRecent);
  }

  @override
  void dispose() {
    ref.read(dbProvider).removeListener(_loadRecent);
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final r = await ref.read(dbProvider).calls(limit: 200);
    if (mounted) setState(() => _recent = r);
  }

  /// Colleagues, contacts and recent numbers containing what is typed.
  List<(String, String)> _suggestions(String q) {
    if (q.length < 2) return const [];
    final out = <String, String>{};
    void add(String number, String name) {
      if (out.length < 6 && number != q && !out.containsKey(number)) out[number] = name;
    }

    for (final w in ref.read(settingsProvider).watched) {
      if (w.ext.contains(q)) add(w.ext, w.name);
    }
    for (final c in _recent) {
      if (c.number.contains(q)) add(c.number, c.name);
    }
    for (final c in ref.read(contactsProvider).contacts) {
      for (final n in c.numbers) {
        if (n.replaceAll(RegExp(r'[^\d+]'), '').contains(q)) add(n, c.name);
      }
    }
    return out.entries.map((e) => (e.key, e.value)).toList();
  }

  static const _keys = [
    ('1', ''), ('2', 'ABC'), ('3', 'DEF'), ('4', 'GHI'), ('5', 'JKL'), ('6', 'MNO'),
    ('7', 'PQRS'), ('8', 'TUV'), ('9', 'WXYZ'), ('*', ''), ('0', '+'), ('#', ''),
  ];

  void _press(String d) {
    HapticFeedback.selectionClick();
    setState(() => _number = (_number + d).length > 40 ? _number : _number + d);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isNotEmpty) setState(() => _number = text);
  }

  Future<void> _call() async {
    final sip = ref.read(sipProvider);
    if (_number.isEmpty) {
      // Empty: bring back the last number dialled, like a desk phone.
      final last = (await ref.read(dbProvider).calls(limit: 20)).where((c) => c.direction.name == 'outgoing').firstOrNull;
      if (last != null) setState(() => _number = last.number);
      return;
    }
    if (!mounted) return;
    await placeCall(context, ref, _number, accountId: _accountId);
    widget.addCallMode.value = false;
    if (sip.hasCall) setState(() => _number = '');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final sip = ref.watch(sipProvider);
    final store = ref.watch(accountsProvider);
    final settings = ref.watch(settingsProvider);
    final enabled = store.accounts.where((a) => a.enabled).toList();
    final selected = (_accountId != null ? store.byId(_accountId!) : null) ?? store.defaultAccount;
    final rt = selected == null ? null : sip.runtimes[selected.id];
    final status = settings.effectiveStatus();
    final match = _matchFor(_number);

    return Column(children: [
      // Header: your status, the account and its live state, voicemail.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(children: [
          Avatar(
            selected?.displayName.isNotEmpty == true ? selected!.displayName : (selected?.user ?? '?'),
            size: 44,
            dot: switch (status) {
              MyStatus.available => t.success,
              MyStatus.silent => t.warn,
              MyStatus.dnd => t.danger,
            },
          ),
          const SizedBox(width: 10),
          Expanded(
            child: selected == null
                ? InkWell(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountEditScreen())),
                    child: Text('noAccountsYet'.tr(), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.accent)),
                  )
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${selected.label} · ${selected.user}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    Text(regText(rt), style: mono(context, color: regColor(t, rt?.status ?? RegStatus.off))),
                  ]),
          ),
          if (rt != null)
            Stack(clipBehavior: Clip.none, children: [
              RoundIcon(
                icon: Icons.voicemail,
                tooltip: 'voicemail'.tr(),
                onTap: () => placeCall(context, ref, selected!.voicemail, accountId: selected.id, name: 'voicemail'.tr()),
              ),
              if (rt.mwi.newVoice > 0)
                PositionedDirectional(
                  top: -2,
                  end: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: t.purple, borderRadius: BorderRadius.circular(9)),
                    child: Text('${rt.mwi.newVoice}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                  ),
                ),
            ]),
        ]),
      ),
      // Account switcher (C), only when there is more than one.
      if (enabled.length > 1)
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final a in enabled)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: Pill(
                    label: a.label,
                    selected: a.id == selected?.id,
                    leading: Dot(regColor(t, sip.runtimes[a.id]?.status ?? RegStatus.off)),
                    onTap: () => setState(() => _accountId = a.id),
                  ),
                ),
            ],
          ),
        ),
      ValueListenableBuilder<bool>(
        valueListenable: widget.addCallMode,
        builder: (_, adding, _) => !adding || !sip.hasCall
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: ECard(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(children: [
                    Icon(Icons.pause_circle_outline, color: t.warn),
                    const SizedBox(width: 10),
                    Expanded(child: Text('${'addCallTitle'.tr()} · ${sip.focused?.title ?? ''} ${'onHold'.tr()}')),
                    TextButton(onPressed: () => widget.addCallMode.value = false, child: Text('cancel'.tr())),
                  ]),
                ),
              ),
      ),
      // Number + who it is.
      Expanded(
        child: GestureDetector(
          onLongPress: _paste,
          behavior: HitTestBehavior.opaque,
          child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(_number.isEmpty ? ' ' : _number,
                    textDirection: ui.TextDirection.ltr,
                    style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w600, letterSpacing: 1)),
              ),
            ),
            const SizedBox(height: 6),
            if (match == null && _suggestions(_number).isNotEmpty)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final (n, name) in _suggestions(_number))
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: Pill(
                          label: name.isEmpty ? n : '$name · $n',
                          selected: false,
                          onTap: () => setState(() => _number = n),
                        ),
                      ),
                  ],
                ),
              )
            else
            SizedBox(
              height: 34,
              child: match == null
                  ? Text('dialHint'.tr(), style: TextStyle(fontSize: 13, color: t.text2))
                  : Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                          color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(16)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (match.$2 != null) ...[Dot(match.$2!), const SizedBox(width: 8)],
                        Text(match.$1, style: TextStyle(fontSize: 13, color: t.text2)),
                      ]),
                    ),
            ),
            const SizedBox(height: 14),
          ]),
        ),
      ),
      // Keypad
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          childAspectRatio: 1.35,
          children: [
            for (final k in _keys)
              Center(
                child: _Key(
                  digit: k.$1,
                  letters: k.$2,
                  onTap: () => _press(k.$1),
                  onLongPress: k.$1 == '0' ? () => _press('+') : null,
                ),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(36, 14, 36, 14),
        child: Row(children: [
          const Expanded(child: SizedBox()),
          Semantics(
            button: true,
            label: 'call'.tr(),
            child: Material(
              color: t.success,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _call,
                child: SizedBox(width: 74, height: 74, child: Icon(Icons.call, size: 30, color: t.onSuccess)),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: _number.isEmpty
                  ? const SizedBox(width: 52)
                  : IconButton(
                      tooltip: 'delete'.tr(),
                      iconSize: 26,
                      color: t.text2,
                      onPressed: () => setState(() => _number = _number.substring(0, _number.length - 1)),
                      icon: GestureDetector(
                        onLongPress: () => setState(() => _number = ''),
                        child: const Icon(Icons.backspace_outlined),
                      ),
                    ),
            ),
          ),
        ]),
      ),
    ]);
  }

  /// Name (and presence colour) for what is typed: a watched colleague or a contact.
  (String, Color?)? _matchFor(String number) {
    if (number.length < 2) return null;
    final sip = ref.read(sipProvider);
    final t = context.t;
    for (final w in ref.read(settingsProvider).watched) {
      if (w.ext == number) {
        final p = sip.presence[w.ext];
        return ('${w.name} · ${presenceText(p).toLowerCase()}', presenceColor(t, p));
      }
    }
    final name = ref.read(contactsProvider).nameFor(number);
    return name.isEmpty ? null : (name, null);
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.digit, required this.letters, required this.onTap, this.onLongPress});
  final String digit, letters;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: digit,
      child: Material(
        color: t.surface,
        shape: CircleBorder(side: BorderSide(color: t.border)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox(
            width: 74,
            height: 74,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(digit, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500, height: 1)),
              SizedBox(
                height: 13,
                child: Text(letters, style: TextStyle(fontSize: 10, letterSpacing: 1.5, color: t.text2)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
