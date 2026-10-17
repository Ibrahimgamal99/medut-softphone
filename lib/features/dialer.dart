import 'package:easy_localization/easy_localization.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/db.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../sip/sip_service.dart';
import '../ui/widgets.dart';
import 'keypad_sheets.dart';
import 'status.dart';
import 'settings_screen.dart';
import 'sign_in.dart';

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

/// Pocket · Keypad: you, the account that places the call and your status on
/// top; the number with live matches; big round keys.
/// The keypad, opened full screen from the dial button on Calls and Contacts.
class KeypadPage extends StatelessWidget {
  const KeypadPage({super.key, required this.addCallMode});
  final ValueNotifier<bool> addCallMode;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(child: DialerScreen(addCallMode: addCallMode, onClose: () => Navigator.maybePop(context))),
      );
}

class DialerScreen extends ConsumerStatefulWidget {
  const DialerScreen({super.key, required this.addCallMode, this.onClose});
  final ValueNotifier<bool> addCallMode;

  /// Shown as a close button in place of the avatar (the keypad page).
  final VoidCallback? onClose;

  @override
  ConsumerState<DialerScreen> createState() => _DialerScreenState();
}

class _DialerScreenState extends ConsumerState<DialerScreen> {
  String _number = '';
  String? _accountId;
  List<CallRecord> _recent = const [];
  // Kept from initState: ref can't be used in dispose.
  late final LocalDb _db = ref.read(dbProvider);

  @override
  void initState() {
    super.initState();
    _loadRecent();
    _db.addListener(_loadRecent);
  }

  @override
  void dispose() {
    _db.removeListener(_loadRecent);
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final r = await _db.calls(limit: 200);
    if (mounted) setState(() => _recent = r);
  }

  // Memoized: build() re-runs for reasons unrelated to the query (status
  // ticks, presence), so only rescan when the query or the lists change.
  String? _matchSig;
  List<_Match> _matchCache = const [];

  /// Live matches while dialing: colleagues (extensions), the
  /// phone's contacts and recent numbers whose NUMBER contains the typed
  /// digits. When the list is long each source keeps a fair share.
  List<_Match> _matches(String query) {
    final digits = query.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return const [];
    final watched = ref.read(settingsProvider).watched;
    final contacts = ref.read(contactsProvider).contacts;
    final sig = '$digits|${watched.length}|${contacts.length}|${_recent.length}';
    if (sig == _matchSig) return _matchCache;

    final seen = <String>{};
    final team = <_Match>[], phone = <_Match>[], recent = <_Match>[];
    bool hit(String n) => n.replaceAll(RegExp(r'\D'), '').contains(digits);
    void add(List<_Match> l, String name, String number, _Source src) {
      final key = number.replaceAll(RegExp(r'[^\d+]'), '');
      if (key.isEmpty || l.length >= 30 || !seen.add(key)) return;
      l.add(_Match(name: name, number: number, source: src));
    }

    for (final w in watched) {
      if (hit(w.ext)) add(team, w.name, w.ext, _Source.team);
    }
    for (final c in contacts) {
      for (final n in c.numbers) {
        if (hit(n)) add(phone, c.name, n, _Source.contact);
      }
    }
    for (final c in _recent) {
      if (hit(c.number)) add(recent, c.name, c.number, _Source.recent);
    }

    const maxTotal = 40;
    final groups = [team, phone, recent].where((g) => g.isNotEmpty).toList();
    final out = <_Match>[];
    if (groups.length > 1) {
      final share = maxTotal ~/ groups.length;
      for (final g in groups) {
        out.addAll(g.take(share));
      }
    } else if (groups.isNotEmpty) {
      out.addAll(groups.first.take(maxTotal));
    }
    _matchSig = sig;
    _matchCache = out;
    return out;
  }

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

  Future<void> _pickAccount(String? selectedId) async {
    if (selectedId == null) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SignInScreen(another: true)));
      return;
    }
    final id = await showAccountSheet(context, selectedId: selectedId);
    if (id != null && mounted) setState(() => _accountId = id);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final sip = ref.watch(sipProvider);
    final store = ref.watch(accountsProvider);
    final settings = ref.watch(settingsProvider);
    final selected = (_accountId != null ? store.byId(_accountId!) : null) ?? store.defaultAccount;
    final rt = selected == null ? null : sip.runtimes[selected.id];
    final reg = rt?.status ?? RegStatus.off;
    final me = selected == null ? '?' : (selected.displayName.isNotEmpty ? selected.displayName : selected.user);
    final match = _matchFor(_number);
    ref.watch(contactsProvider); // contacts join the matches once loaded
    final matches = _number.isEmpty ? const <_Match>[] : _matches(_number);

    return Column(children: [
      // You (status, accounts) · the account that places the call · your status.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Row(children: [
          if (widget.onClose != null)
            RoundIcon(icon: Icons.keyboard_arrow_down, size: 40, tooltip: 'close'.tr(), onTap: widget.onClose)
          else
            Semantics(
              button: true,
              label: 'yourStatus'.tr(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => showMeSheet(context),
                child: Avatar(me, size: 40, dot: statusColor(t, settings.effectiveStatus())),
              ),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: _AccountPill(
                label: selected?.label ?? 'noAccountsYet'.tr(),
                dot: selected == null ? null : regColor(t, reg),
                onTap: () => _pickAccount(selected?.id),
              ),
            ),
          ),
          const SizedBox(width: 8),
          StatusPill(compact: MediaQuery.sizeOf(context).width < 420),
          const SizedBox(width: 8),
        ]),
      ),
      // Said only when something is wrong: a registered account stays quiet.
      if (selected != null && reg != RegStatus.registered)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _pickAccount(selected.id),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Dot(regColor(t, reg)),
              const SizedBox(width: 7),
              Flexible(
                child: Text(regText(rt),
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: regColor(t, reg), fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ),
      // Android blocking calls from ringing (battery saver, full-screen alerts).
      const Padding(padding: EdgeInsets.fromLTRB(16, 10, 16, 0), child: ReachabilityBanner()),
      ValueListenableBuilder<bool>(
        valueListenable: widget.addCallMode,
        builder: (_, adding, _) => !adding || !sip.hasCall
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Container(
                  padding: const EdgeInsetsDirectional.fromSTEB(14, 4, 4, 4),
                  decoration: BoxDecoration(color: t.warnSoft, borderRadius: BorderRadius.circular(18)),
                  child: Row(children: [
                    Icon(Icons.pause_circle_outline, color: t.warn),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('${'addCallTitle'.tr()} · ${sip.focused?.title ?? ''} ${'onHold'.tr()}',
                          style: TextStyle(color: t.warn, fontWeight: FontWeight.w600)),
                    ),
                    TextButton(onPressed: () => widget.addCallMode.value = false, child: Text('cancel'.tr())),
                  ]),
                ),
              ),
      ),
      // Matches above the number, then the number and who it is.
      Expanded(
        child: GestureDetector(
          onLongPress: _paste,
          behavior: HitTestBehavior.opaque,
          child: Column(children: [
            Expanded(
              child: matches.isEmpty
                  ? const SizedBox.shrink()
                  : _MatchList(
                      matches: matches,
                      query: _number.replaceAll(RegExp(r'\D'), ''),
                      onFill: (n) => setState(() => _number = n),
                      onCall: (m) async {
                        await placeCall(context, ref, m.number, accountId: _accountId, name: m.name);
                        if (mounted) setState(() => _number = '');
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(_number.isEmpty ? ' ' : _number,
                    textDirection: ui.TextDirection.ltr,
                    style: mono(context, size: 36, weight: FontWeight.w500, color: t.text)),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 32,
              child: match != null
                  ? Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(color: t.accentSoft, borderRadius: BorderRadius.circular(16)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (match.$2 != null) ...[Dot(match.$2!), const SizedBox(width: 7)],
                          Flexible(
                            child: Text(match.$1,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.accentText)),
                          ),
                        ]),
                      ),
                    )
                  : (_number.isEmpty
                      ? Center(child: Text('dialHint'.tr(), style: TextStyle(fontSize: 13, color: t.text2)))
                      : const SizedBox.shrink()),
            ),
            const SizedBox(height: 10),
          ]),
        ),
      ),
      _Keypad(
        onKey: _press,
        onCall: _call,
        onBackspace: _number.isEmpty ? null : () => setState(() => _number = _number.substring(0, _number.length - 1)),
        onClear: () => setState(() => _number = ''),
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

class _AccountPill extends StatelessWidget {
  const _AccountPill({required this.label, required this.dot, required this.onTap});
  final String label;
  final Color? dot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.surface,
      shape: StadiumBorder(side: BorderSide(color: t.border)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsetsDirectional.fromSTEB(14, 0, 10, 0),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (dot != null) ...[Dot(dot!), const SizedBox(width: 8)],
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: dot == null ? t.accentText : t.text)),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 18, color: t.text2),
          ]),
        ),
      ),
    );
  }
}

/// Round keys sized to the screen (smaller phones get smaller keys rather
/// than a squeezed number area), then call and backspace.
class _Keypad extends StatelessWidget {
  const _Keypad({required this.onKey, required this.onCall, required this.onBackspace, required this.onClear});
  final ValueChanged<String> onKey;
  final VoidCallback onCall;
  final VoidCallback? onBackspace, onClear;

  static const _keys = [
    ('1', ''), ('2', 'ABC'), ('3', 'DEF'), ('4', 'GHI'), ('5', 'JKL'), ('6', 'MNO'),
    ('7', 'PQRS'), ('8', 'TUV'), ('9', 'WXYZ'), ('*', ''), ('0', '+'), ('#', ''),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return LayoutBuilder(builder: (context, box) {
      final size = math.min((box.maxWidth - 48) / 3.76, MediaQuery.sizeOf(context).height * 0.092).clamp(54.0, 78.0);
      final gap = size * 0.38;
      Widget row(List<Widget> cells) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < cells.length; i++) ...[if (i > 0) SizedBox(width: gap), cells[i]],
          ]);
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(children: [
          for (var r = 0; r < 4; r++) ...[
            row([
              for (final k in _keys.sublist(r * 3, r * 3 + 3))
                _Key(
                  digit: k.$1,
                  letters: k.$2,
                  size: size,
                  onTap: () => onKey(k.$1),
                  onLongPress: k.$1 == '0' ? () => onKey('+') : null,
                ),
            ]),
            SizedBox(height: size * 0.17),
          ],
          row([
            SizedBox(width: size),
            Semantics(
              button: true,
              label: 'call'.tr(),
              child: Material(
                color: t.accent,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onCall,
                  child: SizedBox.square(dimension: size * 1.04, child: Icon(Icons.call, size: size * 0.4, color: t.onAccent)),
                ),
              ),
            ),
            SizedBox.square(
              dimension: size,
              child: onBackspace == null
                  ? null
                  : IconButton(
                      tooltip: 'delete'.tr(),
                      iconSize: 26,
                      color: t.text2,
                      onPressed: onBackspace,
                      icon: GestureDetector(onLongPress: onClear, child: const Icon(Icons.backspace_outlined)),
                    ),
            ),
          ]),
        ]),
      );
    });
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.digit, required this.letters, required this.size, required this.onTap, this.onLongPress});
  final String digit, letters;
  final double size;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: digit,
      child: Material(
        color: t.surface2,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox.square(
            dimension: size,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(digit, style: TextStyle(fontSize: size * 0.39, fontWeight: FontWeight.w500, height: 1)),
              SizedBox(
                height: size * 0.17,
                child: Text(letters,
                    style: TextStyle(fontSize: size * 0.125, fontWeight: FontWeight.w700, letterSpacing: 1.8, color: t.text2)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

enum _Source { team, contact, recent }

class _Match {
  const _Match({required this.name, required this.number, required this.source});
  final String name, number;
  final _Source source;
}

/// Match list: tap a row to put its number in the field, tap
/// the green handset to call it. The typed digits are highlighted.
class _MatchList extends ConsumerWidget {
  const _MatchList({required this.matches, required this.query, required this.onFill, required this.onCall});
  final List<_Match> matches;
  final String query;
  final ValueChanged<String> onFill;
  final ValueChanged<_Match> onCall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final presence = ref.watch(sipProvider).presence;
    return ListView.builder(
      reverse: true, // closest to the number = best match
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: matches.length,
      itemBuilder: (_, i) {
        final m = matches[i];
        final label = m.name.isNotEmpty ? m.name : m.number;
        final (tint, icon) = switch (m.source) {
          _Source.team => (t.accent, null),
          _Source.contact => (t.purple, null),
          _Source.recent => (t.text2, Icons.history),
        };
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onFill(m.number),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(children: [
              Stack(clipBehavior: Clip.none, children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: tint.withValues(alpha: 0.14), shape: BoxShape.circle),
                  child: icon != null
                      ? Icon(icon, size: 18, color: tint)
                      : Text(initials(label), style: TextStyle(color: tint, fontWeight: FontWeight.w700, fontSize: 13)),
                ),
                if (m.source == _Source.team)
                  PositionedDirectional(
                    end: -2,
                    bottom: -2,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: presenceColor(t, presence[m.number]),
                        shape: BoxShape.circle,
                        border: Border.all(color: t.bg, width: 2),
                      ),
                    ),
                  ),
              ]),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  if (m.name.isNotEmpty) _highlight(context, m.number),
                ]),
              ),
              IconButton(
                tooltip: 'call'.tr(),
                icon: Icon(Icons.call, size: 20, color: t.accentText),
                onPressed: () => onCall(m),
              ),
            ]),
          ),
        );
      },
    );
  }

  /// The number with the typed digits in bold.
  Widget _highlight(BuildContext context, String number) {
    final t = context.t;
    final base = mono(context, size: 12);
    final digitsOnly = number.replaceAll(RegExp(r'\D'), '');
    final start = digitsOnly.indexOf(query);
    if (query.isEmpty || start < 0) return Text(number, style: base);
    // Map digit positions back onto the formatted number.
    final spans = <TextSpan>[];
    var d = 0;
    for (final ch in number.characters) {
      final isDigit = RegExp(r'\d').hasMatch(ch);
      final on = isDigit && d >= start && d < start + query.length;
      spans.add(TextSpan(text: ch, style: on ? base.copyWith(color: t.accentText, fontWeight: FontWeight.w700) : base));
      if (isDigit) d++;
    }
    return Text.rich(TextSpan(children: spans), textDirection: ui.TextDirection.ltr);
  }
}
