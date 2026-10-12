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

/// Design E · Transfer: "Talk first" (attended, REFER + Replaces) or
/// "Send now" (blind REFER), to a watched colleague or any number.
class _TransferSheet extends ConsumerStatefulWidget {
  const _TransferSheet();

  @override
  ConsumerState<_TransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends ConsumerState<_TransferSheet> {
  bool _talkFirst = true;
  String _target = '';
  String _targetName = '';
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final sip = ref.watch(sipProvider);
    final call = sip.focused;
    final watched = ref.watch(settingsProvider).watched;
    final q = _input.text.trim().toLowerCase();
    final list = watched.where((w) => q.isEmpty || w.name.toLowerCase().contains(q) || w.ext.contains(q)).toList();
    final a = call?.title ?? '';
    final b = _targetName.isNotEmpty ? _targetName : (_target.isNotEmpty ? _target : 'someone'.tr());

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('transferWho'.tr(namedArgs: {'a': a}), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: t.surface2, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                for (final talk in [true, false])
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _talkFirst = talk),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _talkFirst == talk ? t.surface : Colors.transparent,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(talk ? 'talkFirst'.tr() : 'sendNow'.tr(),
                            style: TextStyle(
                                fontWeight: _talkFirst == talk ? FontWeight.w700 : FontWeight.w500,
                                color: _talkFirst == talk ? t.text : t.text2)),
                      ),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _input,
              keyboardType: TextInputType.phone,
              onChanged: (v) => setState(() {
                _target = v.trim();
                _targetName = '';
              }),
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'targetHint'.tr()),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView(shrinkWrap: true, children: [
                for (final w in list)
                  _TargetRow(
                    name: w.name,
                    ext: w.ext,
                    selected: _target == w.ext,
                    onTap: () => setState(() {
                      _target = w.ext;
                      _targetName = w.name;
                    }),
                  ),
              ]),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: t.accentSoft, borderRadius: BorderRadius.circular(14)),
              child: Text(
                (_talkFirst ? 'helpTalkFirst' : 'helpSendNow').tr(namedArgs: {'a': a, 'b': b}),
                style: TextStyle(fontSize: 13, height: 1.45, color: t.text),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: SecondaryButton(label: 'cancel'.tr(), onPressed: () => Navigator.pop(context))),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: PrimaryButton(
                  label: (_talkFirst ? 'callFirst' : 'sendTo').tr(namedArgs: {'b': b}),
                  color: t.success,
                  textColor: t.onSuccess,
                  onPressed: _target.isEmpty || call == null
                      ? null
                      : () {
                          final s = ref.read(sipProvider);
                          if (_talkFirst) {
                            s.transferAttended(_target);
                          } else {
                            s.transferBlind(_target);
                          }
                          Navigator.pop(context);
                        },
                ),
              ),
            ]),
          ]),
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
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: selected ? t.accent : t.border),
          ]),
        ),
      ),
    );
  }
}
