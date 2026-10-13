import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../core/theme.dart';
import '../ui/widgets.dart';

Future<void> showTransferSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _TransferSheet(),
    );

/// Transfer: type or pick who to send the caller to, then
/// "Blind transfer" (REFER, you leave at once) or "Warm transfer" (the caller
/// waits on hold while you talk to them; Join & drop on the call screen).
class _TransferSheet extends ConsumerStatefulWidget {
  const _TransferSheet();

  @override
  ConsumerState<_TransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends ConsumerState<_TransferSheet> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _go({required bool warm}) {
    final target = _input.text.trim();
    if (target.isEmpty) return;
    final s = ref.read(sipProvider);
    if (warm) {
      s.transferAttended(target);
    } else {
      s.transferBlind(target);
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final sip = ref.watch(sipProvider);
    final call = sip.focused;
    final watched = ref.watch(settingsProvider).watched;
    final q = _input.text.trim().toLowerCase();
    final list = watched.where((w) => q.isEmpty || w.name.toLowerCase().contains(q) || w.ext.contains(q)).toList();
    final ready = _input.text.trim().isNotEmpty && call != null;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('transferWho'.tr(namedArgs: {'a': call?.title ?? ''}),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
            const SizedBox(height: 14),
            TextField(
              controller: _input,
              autofocus: true,
              keyboardType: TextInputType.phone,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'transferTo'.tr(),
                prefixIcon: const Icon(Icons.dialpad),
                floatingLabelBehavior: FloatingLabelBehavior.always,
              ),
            ),
            if (list.isNotEmpty) ...[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView(shrinkWrap: true, children: [
                  for (final w in list)
                    _TargetRow(
                      name: w.name,
                      ext: w.ext,
                      selected: _input.text.trim() == w.ext,
                      onTap: () => setState(() => _input.text = w.ext),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            _Option(
              icon: Icons.phone_forwarded,
              title: 'blindTransfer'.tr(),
              hint: 'blindTransferSub'.tr(),
              onTap: ready ? () => _go(warm: false) : null,
            ),
            const SizedBox(height: 10),
            _Option(
              icon: Icons.groups_outlined,
              title: 'warmTransfer'.tr(),
              hint: 'warmTransferSub'.tr(),
              onTap: ready ? () => _go(warm: true) : null,
            ),
          ]),
        ),
      ),
    );
  }
}

/// One way to transfer: a card with an icon, what it does, and a chevron.
class _Option extends StatelessWidget {
  const _Option({required this.icon, required this.title, required this.hint, required this.onTap});
  final IconData icon;
  final String title, hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: Material(
        color: t.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: t.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: t.accentSoft, shape: BoxShape.circle),
                child: Icon(icon, size: 20, color: t.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(hint, style: TextStyle(fontSize: 12.5, height: 1.35, color: t.text2)),
                ]),
              ),
              Icon(Icons.chevron_right, color: t.text2),
            ]),
          ),
        ),
      ),
    );
  }
}

class _TargetRow extends ConsumerWidget {
  const _TargetRow({required this.name, required this.ext, required this.selected, required this.onTap});
  final String name, ext;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final p = ref.watch(sipProvider).presence[ext];
    return Material(
      color: selected ? t.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(children: [
            Avatar(name, size: 40, dot: presenceColor(t, p)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('$ext · ${presenceText(p)}', style: TextStyle(fontSize: 12, color: t.text2)),
              ]),
            ),
            if (selected) Icon(Icons.check_circle, color: t.accent),
          ]),
        ),
      ),
    );
  }
}
