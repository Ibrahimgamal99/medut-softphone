import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medut/medut.dart' show AudioDevice;

import '../core/providers.dart';
import '../core/theme.dart';
import '../ui/widgets.dart' show initials;
import 'desktop_shell.dart';
import 'engine.dart';

/// The call screen's colours (Ink in CallActivity.kt): a black ground in the
/// dark theme, the app's light page in the light one.
class _Ink {
  _Ink(this.dark, this.avatars);
  final bool dark;
  final List<(Color, Color)> avatars;

  Color get ground => dark ? const Color(0xFF000000) : const Color(0xFFF6F7F8);
  Color get text => dark ? const Color(0xFFECEFF2) : const Color(0xFF111418);
  Color get text2 => dark ? const Color(0xADFFFFFF) : const Color(0xFF454D56);
  Color get fill => tint(dark ? 0x1F : 0x14);
  Color get dock => tint(dark ? 0x12 : 0x0A);
  Color get pill => tint(dark ? 0x1A : 0x0F);
  Color get sheet => dark ? const Color(0xFF131619) : const Color(0xFFFFFFFF);
  Color get line => tint(0x14);
  Color get good => dark ? const Color(0xFF22C55E) : const Color(0xFF16A34A);
  Color get onGood => dark ? const Color(0xFF052E16) : const Color(0xFFFFFFFF);
  Color get fair => dark ? const Color(0xFFF59E0B) : const Color(0xFFD97706);
  Color get poor => dark ? const Color(0xFFEF4444) : const Color(0xFFDC2626);
  Color get rec => dark ? const Color(0xFFF87171) : const Color(0xFFDC2626);
  Color get end => dark ? const Color(0xFFEF4444) : const Color(0xFFDC2626);
  Color get purple => dark ? const Color(0xFFA855F7) : const Color(0xFF9333EA);
  Color get teal => dark ? const Color(0xFF14B8A6) : const Color(0xFF0F766E);

  /// White on the dark ink, black on the light page, at [alpha] (0–255).
  Color tint(int alpha) => (dark ? Colors.white : Colors.black).withAlpha(alpha);

  Color grade(int level) => switch (level) {
        4 || 3 => good,
        2 => fair,
        1 => poor,
        _ => text2,
      };

  (Color, Color) avatar(String title) =>
      avatars[title.codeUnits.fold<int>(0, (h, c) => (h * 31 + c) & 0x7fffffff) % avatars.length];
}

/// The snapshot (DesktopEngine.snapshot) with typed reads.
extension type _Snap(Map<String, Object?> m) {
  String s(String k) => m[k] as String? ?? '';
  bool b(String k) => m[k] as bool? ?? false;
  int i(String k) => (m[k] as num?)?.toInt() ?? 0;
  String get phase => s('phase');
  String get name => s('name');
  String get number => s('number');
  String get title => name.isNotEmpty ? name : number;
  Map<String, Object?>? map(String k) => m[k] is Map ? Map<String, Object?>.from(m[k] as Map) : null;
  List<List<String>> get details => [
        for (final r in m['details'] as List? ?? const []) [for (final c in r as List) '$c'],
      ];
}

/// The desktop call screen (CallActivity.kt in Flutter): ringing, the call
/// with its dock, the keypad, and the quality, More, Transfer and Audio
/// sheets. It holds no call state of its own: it renders the engine's
/// snapshot and sends every tap to [DesktopEngine.action]. [compact] is the
/// small ringing card the window becomes while a call rings in the background.
class DesktopCallView extends ConsumerStatefulWidget {
  const DesktopCallView({super.key, this.compact = false, this.embedded = false});
  final bool compact;

  /// In the wide layout's pane, beside the tabs: nothing to minimise to.
  final bool embedded;

  @override
  ConsumerState<DesktopCallView> createState() => _DesktopCallViewState();
}

class _DesktopCallViewState extends ConsumerState<DesktopCallView> {
  final _engine = DesktopEngine.instance;
  final _focus = FocusNode(debugLabel: 'call');
  late final Timer _tick = Timer.periodic(const Duration(seconds: 1), (_) {
    if (mounted) setState(() {});
  });

  /// The open sheet: quality, more, transfer, audio, or null.
  String? _sheet;
  bool _keypad = false;

  /// The keypad sends DTMF, or dials a second call ("Add call").
  bool _addCall = false;
  String _typed = '';
  final _transferTo = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tick;
  }

  @override
  void dispose() {
    _tick.cancel();
    _focus.dispose();
    _transferTo.dispose();
    super.dispose();
  }

  void _act(String name, [Map<String, Object?> args = const {}]) => unawaited(_engine.action(name, args));

  void _openSheet(String? which) => setState(() => _sheet = which);

  void _openKeypad({bool addCall = false}) => setState(() {
        _sheet = null;
        _keypad = true;
        _addCall = addCall;
        _typed = '';
      });

  void _key(String d) {
    setState(() => _typed = (_typed + d).length > (_addCall ? 40 : 24) ? (_typed + d).substring(1) : _typed + d);
    if (!_addCall) _act('dtmf', {'digit': d});
  }

  /// Enter answers, Escape declines or closes what is open, digits are DTMF.
  KeyEventResult _onKey(FocusNode _, KeyEvent e, _Snap s) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (s.phase == 'incoming') {
      if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
        _act('answer');
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.escape) {
        _act('decline');
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (_sheet != null) {
        _openSheet(null);
      } else if (_keypad) {
        setState(() => _keypad = false);
      } else if (!widget.embedded) {
        DesktopShell.instance.callOpen.value = false;
      }
      return KeyEventResult.handled;
    }
    if (_sheet == 'transfer') return KeyEventResult.ignored; // typing a number
    final ch = e.character;
    if (ch != null && RegExp(r'^[0-9*#]$').hasMatch(ch)) {
      if (!_keypad) _openKeypad();
      _key(ch);
      return KeyEventResult.handled;
    }
    if (_keypad && _addCall && k == LogicalKeyboardKey.backspace && _typed.isNotEmpty) {
      setState(() => _typed = _typed.substring(0, _typed.length - 1));
      return KeyEventResult.handled;
    }
    if (_keypad && _addCall && (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) && _typed.isNotEmpty) {
      _placeAddCall();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _placeAddCall() {
    final n = _typed.trim();
    if (n.isEmpty) return;
    setState(() => _keypad = false);
    _act('addCall', {'number': n});
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, Object?>>(
      valueListenable: _engine.snapshotNotifier,
      builder: (context, raw, _) {
        final s = _Snap(raw);
        if (s.phase == 'idle' || s.phase.isEmpty) return const SizedBox.shrink();
        final ink = _Ink(Theme.of(context).brightness == Brightness.dark, context.t.avatars);
        if (s.phase == 'incoming') {
          _sheet = null;
          _keypad = false;
        }
        if (_sheet == 'quality' && s.details.isEmpty) _sheet = null;
        final body = widget.compact && s.phase == 'incoming'
            ? _ringCard(ink, s)
            : s.phase == 'incoming'
                ? _incoming(ink, s)
                : _keypad
                    ? _keypadView(ink, s)
                    : _inCall(ink, s);
        return Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: (n, e) => _onKey(n, e, s),
          child: Material(
            color: ink.ground,
            child: DefaultTextStyle.merge(
              style: TextStyle(color: ink.text),
              child: Stack(children: [
                Positioned.fill(child: SafeArea(child: body)),
                if (_sheet != null) ...[
                  Positioned.fill(
                    child: GestureDetector(onTap: () => _openSheet(null), child: const ColoredBox(color: Color(0x80000000))),
                  ),
                  Positioned(left: 0, right: 0, bottom: 0, child: _sheetPanel(ink, s)),
                ],
              ]),
            ),
          ),
        );
      },
    );
  }

  // ── Ringing ───────────────────────────────────────────────────────────────

  /// The small card: who, on which account, Decline and Answer.
  Widget _ringCard(_Ink ink, _Snap s) {
    final (bg, fg) = ink.avatar(s.title);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Row(children: [
          _disc(s.title, bg, fg, 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('↙  ${s.s('account')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: ink.text2)),
              const SizedBox(height: 2),
              Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              if (s.name.isNotEmpty) Text(s.number, style: TextStyle(fontSize: 13, color: ink.text2)),
            ]),
          ),
        ]),
        const Spacer(),
        Row(children: [
          Expanded(child: _wideButton(ink, Icons.call_end, _l('decline', 'Decline'), ink.end, Colors.white, () => _act('decline'))),
          const SizedBox(width: 10),
          Expanded(child: _wideButton(ink, Icons.call, _l('answer', 'Answer'), ink.good, ink.onGood, () => _act('answer'))),
        ]),
      ]),
    );
  }

  Widget _incoming(_Ink ink, _Snap s) {
    final (bg, fg) = ink.avatar(s.title);
    final account = s.s('account');
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 28),
          child: Column(children: [
            _pillText(ink, account.isNotEmpty ? '↙  $account' : '↙', semantics: '${_l('incomingOn', 'Incoming on')} $account'),
            const Spacer(),
            _rings(ink, s.title, bg, fg, 164),
            const SizedBox(height: 18),
            Text(s.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            if (s.name.isNotEmpty) Text(s.number, style: TextStyle(fontSize: 16, color: ink.text2)),
            const Spacer(),
            Row(children: [
              Expanded(child: _quick(ink, _l('busy', 'Busy'), () => _act('busy'))),
              const SizedBox(width: 8),
              Expanded(child: _quick(ink, _l('message', 'Message'), () => _act('reply'))),
            ]),
            const SizedBox(height: 28),
            Row(children: [
              Expanded(child: _roundCell(ink, Icons.call_end, _l('decline', 'Decline'), 72, ink.end, Colors.white, () => _act('decline'))),
              Expanded(child: _roundCell(ink, Icons.call, _l('answer', 'Answer'), 72, ink.good, ink.onGood, () => _act('answer'))),
            ]),
          ]),
        ),
      ),
    );
  }

  // ── In call ───────────────────────────────────────────────────────────────

  Widget _inCall(_Ink ink, _Snap s) {
    final (bg, fg) = ink.avatar(s.title);
    final started = s.i('startedAt');
    final held = s.b('held');
    final link = s.s('link');
    final line = s.phase == 'outgoing' || held || link != 'ok'
        ? s.s('status')
        : started <= 0 && s.name.isNotEmpty
            ? s.number
            : s.b('recording')
                ? s.s('status')
                : '';
    final second = s.map('second');
    final xfer = s.map('transfer');
    final canRecord = s.b('canRecord');
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
          child: Column(children: [
            Row(children: [
              if (widget.embedded)
                const SizedBox(width: 44)
              else
                _iconButton(ink, Icons.keyboard_arrow_down, 'Minimise', () => DesktopShell.instance.callOpen.value = false),
              Expanded(
                child: Text(s.s('account'), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: ink.text2)),
              ),
              const SizedBox(width: 44),
            ]),
            if (second != null && xfer == null)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsetsDirectional.fromSTEB(14, 5, 5, 5),
                decoration: BoxDecoration(color: ink.pill, borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                    child: Text('${second['text'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  _chip(ink, '${second['label'] ?? _l('swap', 'Swap')}', () => _act('${second['action'] ?? 'swap'}')),
                ]),
              ),
            const Spacer(),
            _rings(ink, s.title, bg, fg, 148),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 14, 8, 0),
              child: Text(s.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
            ),
            if (started > 0)
              Text(_clock(started),
                  style: TextStyle(fontSize: 17, color: ink.text2, fontFeatures: const [FontFeature.tabularFigures()])),
            if (line.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(line,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: held ? ink.purple : (link != 'ok' ? ink.fair : ink.text2))),
              ),
            if (s.s('qualityWord').isNotEmpty) ...[
              const SizedBox(height: 14),
              InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _openSheet('quality'),
                child: _qualityPill(ink, s, chevron: true),
              ),
            ],
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (s.b('encrypted')) ...[
                Icon(Icons.lock_outline, size: 14, color: ink.text2),
                const SizedBox(width: 5),
                Text(_l('encrypted', 'Encrypted'), style: TextStyle(fontSize: 12.5, color: ink.text2)),
                const SizedBox(width: 14),
              ],
              if (s.b('recording'))
                Text('● ${_l('recShort', 'Rec')}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ink.rec)),
            ]),
            if (xfer != null) _transferBar(ink, xfer),
            const Spacer(),
            Container(
              padding: const EdgeInsets.fromLTRB(6, 14, 6, 12),
              decoration: BoxDecoration(color: ink.dock, borderRadius: BorderRadius.circular(28)),
              child: Row(children: [
                Expanded(
                  child: _dockCell(ink, s.b('muted') ? Icons.mic_off : Icons.mic, _l('mute', 'Mute'), s.b('muted'),
                      () => _act(s.b('muted') ? 'unmute' : 'mute')),
                ),
                // A computer has no earpiece: this picks the microphone and speaker.
                Expanded(child: _dockCell(ink, Icons.headset_mic_outlined, _l('audioShort', 'Audio'), false, () => _openSheet('audio'))),
                Expanded(
                  child: canRecord
                      ? _dockCell(ink, Icons.fiber_manual_record, s.b('recording') ? _l('stopRecord', 'Stop rec') : _l('record', 'Record'),
                          s.b('recording'), () => _act('record'),
                          onFill: ink.end, onTint: Colors.white)
                      : _dockCell(ink, Icons.dialpad, _l('keypad', 'Keypad'), false, _openKeypad),
                ),
                Expanded(
                  child: _dockCell(ink, Icons.pause, held ? _l('resume', 'Resume') : _l('hold', 'Hold'), held,
                      () => _act(held ? 'unhold' : 'hold')),
                ),
              ]),
            ),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(child: _roundCell(ink, Icons.phone_forwarded, _l('transfer', 'Transfer'), 46, ink.fill, ink.text, () {
                _transferTo.clear();
                _openSheet('transfer');
              })),
              Semantics(
                button: true,
                label: 'Hang up',
                child: Material(
                  color: ink.end,
                  borderRadius: BorderRadius.circular(29),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(29),
                    onTap: () => _act('hangup'),
                    child: const SizedBox(width: 88, height: 60, child: Icon(Icons.call_end, color: Colors.white)),
                  ),
                ),
              ),
              Expanded(child: _roundCell(ink, Icons.more_horiz, _l('more', 'More'), 46, ink.fill, ink.text, () => _openSheet('more'))),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _transferBar(_Ink ink, Map<String, Object?> x) {
    final talking = x['phase'] == 'talking';
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(color: ink.pill, borderRadius: BorderRadius.circular(22)),
      child: Column(children: [
        Text('${x['status'] ?? ''}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 3, 4, 12),
          child: Text('${x['hint'] ?? ''}', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: ink.text2)),
        ),
        Row(children: [
          Expanded(child: _wideButton(ink, null, '${x['back'] ?? 'Back to caller'}', ink.fill, ink.text, () => _act('cancelTransfer'))),
          const SizedBox(width: 8),
          Expanded(
            child: Opacity(
              opacity: talking ? 1 : 0.45,
              child: _wideButton(ink, null, '${x['join'] ?? 'Join & drop'}', ink.teal, ink.onGood, talking ? () => _act('completeTransfer') : null),
            ),
          ),
        ]),
      ]),
    );
  }

  // ── Keypad ────────────────────────────────────────────────────────────────

  Widget _keypadView(_Ink ink, _Snap s) {
    Widget key(String d) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Material(
            color: ink.fill,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _key(d),
              child: SizedBox(
                width: 74,
                height: 74,
                child: Center(child: Text(d, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500))),
              ),
            ),
          ),
        );
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
        child: Column(children: [
          if (_addCall) _pillText(ink, '${_l('addCallTitle', 'Add call')} · ${s.title} ${_l('onHold', 'On hold')}'),
          const Spacer(),
          SizedBox(
            height: 64,
            child: Center(
              child: Text(_typed, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 34)),
            ),
          ),
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
            ['*', '0', '#'],
          ])
            Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) key(d)]),
          const SizedBox(height: 16),
          SizedBox(
            width: 340,
            child: Row(children: [
              Expanded(
                child: TextButton(
                  onPressed: () => setState(() => _keypad = false),
                  child: Text(_l('hide', 'Hide'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: ink.text2)),
                ),
              ),
              if (_addCall)
                Opacity(
                  opacity: _typed.isEmpty ? 0.45 : 1,
                  child: _round(ink, Icons.call, 74, ink.good, ink.onGood, _l('call', 'Call'), _placeAddCall),
                )
              else
                _round(ink, Icons.call_end, 74, ink.end, Colors.white, 'Hang up', () => _act('hangup')),
              Expanded(
                child: Visibility(
                  visible: _addCall && _typed.isNotEmpty,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: IconButton(
                    tooltip: 'Delete',
                    icon: Icon(Icons.backspace_outlined, color: ink.text2),
                    onPressed: () => setState(() => _typed = _typed.isEmpty ? '' : _typed.substring(0, _typed.length - 1)),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  // ── Sheets ────────────────────────────────────────────────────────────────

  Widget _sheetPanel(_Ink ink, _Snap s) {
    final content = switch (_sheet) {
      'quality' => _qualitySheet(ink, s),
      'more' => _moreSheet(ink, s),
      'transfer' => _transferSheet(ink, s),
      'audio' => _AudioSheet(ink: ink, label: _l),
      _ => const SizedBox.shrink(),
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: GestureDetector(
          onTap: () {}, // taps on the sheet don't reach the dim behind it
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
            decoration: BoxDecoration(
              color: ink.sheet,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(
                child: Container(
                  width: 38,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(color: ink.tint(0x33), borderRadius: BorderRadius.circular(3)),
                ),
              ),
              content,
            ]),
          ),
        ),
      ),
    );
  }

  Widget _qualitySheet(_Ink ink, _Snap s) {
    Widget mosBox(String label, String value) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(color: ink.tint(0x0F), borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 11.5, color: ink.text2)),
              Text(value.isEmpty ? '—' : value,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
            ]),
          ),
        );
    final rows = s.details;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(_l('callQuality', 'Call quality'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
        _qualityPill(ink, s),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        mosBox(_l('youHear', 'You hear'), s.s('mosYou')),
        const SizedBox(width: 8),
        mosBox(_l('theyHear', 'They hear'), s.s('mosThem')),
      ]),
      const SizedBox(height: 6),
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) Divider(height: 1, color: ink.line),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Expanded(child: Text(rows[i].first, style: TextStyle(fontSize: 13, color: ink.text2))),
            Text(rows[i].length > 1 ? rows[i][1] : '', style: mono(context, size: 12, color: ink.text)),
          ]),
        ),
      ],
    ]);
  }

  Widget _moreSheet(_Ink ink, _Snap s) {
    Widget row(IconData icon, String label, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(children: [
              Icon(icon, color: ink.text),
              const SizedBox(width: 16),
              Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ]),
          ),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      row(Icons.add, _l('addCall', 'Add call'), () => _openKeypad(addCall: true)),
      if (s.b('canRecord')) row(Icons.dialpad, _l('keypad', 'Keypad'), _openKeypad),
      row(Icons.chat_bubble_outline, _l('message', 'Message'), () {
        _openSheet(null);
        _act('message');
      }),
    ]);
  }

  Widget _transferSheet(_Ink ink, _Snap s) {
    final typed = _transferTo.text.trim();
    final q = typed.toLowerCase();
    final team = _engine.config.watched
        .where((w) => q.isEmpty || w.$1.toLowerCase().contains(q) || w.$2.contains(q))
        .take(6)
        .toList();
    void go(bool warm) {
      if (typed.isEmpty) return;
      _openSheet(null);
      _act(warm ? 'transferWarm' : 'transferBlind', {'target': typed});
    }

    Widget option(IconData icon, String title, String sub, VoidCallback onTap) => Opacity(
          opacity: typed.isEmpty ? 0.5 : 1,
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Material(
              color: ink.tint(0x0F),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: typed.isEmpty ? null : onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(children: [
                    CircleAvatar(radius: 20, backgroundColor: ink.good.withAlpha(0x29), child: Icon(icon, color: ink.good)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(sub, style: TextStyle(fontSize: 12.5, color: ink.text2)),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        );

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(_l('transferWho', 'Transfer {a}').replaceAll('{a}', s.title), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12),
      TextField(
        controller: _transferTo,
        autofocus: true,
        style: TextStyle(color: ink.text, fontSize: 18),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => go(false),
        decoration: InputDecoration(
          hintText: _l('transferTo', 'Transfer to (extension or number)'),
          hintStyle: TextStyle(color: ink.text2),
          filled: true,
          fillColor: ink.fill,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        ),
      ),
      const SizedBox(height: 8),
      for (final (name, ext) in team) _target(ink, name, ext, selected: typed == ext),
      option(Icons.phone_forwarded, _l('blindTransfer', 'Blind transfer'),
          _l('blindTransferSub', 'Sends the caller straight there. You leave the call now.'), () => go(false)),
      option(Icons.add, _l('warmTransfer', 'Warm transfer'),
          _l('warmTransferSub', 'The caller waits on hold while you talk to them, then you join them.'), () => go(true)),
    ]);
  }

  /// A Team member with their presence; a click fills the number in.
  Widget _target(_Ink ink, String name, String ext, {required bool selected}) {
    final presence = _engine.presence[ext];
    final (dot, word) = switch (presence) {
      'open' => (ink.good, _l('presenceOpen', 'Available')),
      'busy' => (ink.poor, _l('presenceBusy', 'On a call')),
      'closed' => (ink.purple, _l('presenceClosed', 'Offline / do not disturb')),
      _ => (ink.text2, _l('presenceUnknown', 'Unknown')),
    };
    final title = name.isEmpty ? ext : name;
    final (bg, fg) = ink.avatar(title);
    return Material(
      color: selected ? ink.good.withAlpha(0x29) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() {
          _transferTo.text = ext;
          _transferTo.selection = TextSelection.collapsed(offset: ext.length);
        }),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Stack(clipBehavior: Clip.none, children: [
              _disc(title, bg, fg, 40),
              PositionedDirectional(
                end: 0,
                bottom: 0,
                child: Container(width: 11, height: 11, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              ),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                Text('$ext · $word', style: TextStyle(fontSize: 12, color: ink.text2)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  // ── Pieces ────────────────────────────────────────────────────────────────

  /// The app's translation, or [fallback] for a key it does not have.
  static String _l(String key, String fallback) {
    final t = key.tr();
    return t == key ? fallback : t;
  }

  static String _clock(int startedMs) {
    final sec = ((DateTime.now().millisecondsSinceEpoch - startedMs) ~/ 1000).clamp(0, 1 << 30);
    String two(int v) => v.toString().padLeft(2, '0');
    return sec >= 3600 ? '${sec ~/ 3600}:${two(sec ~/ 60 % 60)}:${two(sec % 60)}' : '${two(sec ~/ 60)}:${two(sec % 60)}';
  }

  Widget _qualityPill(_Ink ink, _Snap s, {bool chevron = false}) {
    final level = s.i('qualityLevel');
    final fg = ink.grade(level);
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(11, 6, 10, 6),
      decoration: BoxDecoration(color: fg.withAlpha(0x26), borderRadius: BorderRadius.circular(18)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _Bars(level: level, lit: fg, off: ink.tint(0x40)),
        const SizedBox(width: 7),
        Text(s.s('qualityWord'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg)),
        if (s.s('mos').isNotEmpty) ...[
          const SizedBox(width: 6),
          Text(s.s('mos'), style: mono(context, size: 11.5, color: ink.text2)),
        ],
        if (chevron) Icon(Icons.chevron_right, size: 16, color: ink.text2),
      ]),
    );
  }

  Widget _disc(String title, Color bg, Color fg, double size) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Text(initials(title), style: TextStyle(color: fg, fontSize: size * 0.3, fontWeight: FontWeight.w700)),
      );

  /// The avatar disc inside two faint rings; the rings add 44 to its size.
  Widget _rings(_Ink ink, String title, Color bg, Color fg, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: ink.tint(0x08), shape: BoxShape.circle),
        padding: const EdgeInsets.all(10),
        child: Container(
          decoration: BoxDecoration(color: ink.tint(0x0D), shape: BoxShape.circle),
          padding: const EdgeInsets.all(12),
          child: _disc(title, bg, fg, size - 44),
        ),
      );

  Widget _pillText(_Ink ink, String text, {String? semantics}) => Semantics(
        label: semantics,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(color: ink.pill, borderRadius: BorderRadius.circular(16)),
          child: Text(text, style: TextStyle(fontSize: 13, color: ink.text2)),
        ),
      );

  Widget _chip(_Ink ink, String label, VoidCallback onTap) => Material(
        color: ink.tint(0x29),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
        ),
      );

  Widget _quick(_Ink ink, String label, VoidCallback onTap) => Material(
        color: ink.pill,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: SizedBox(height: 48, child: Center(child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)))),
        ),
      );

  Widget _wideButton(_Ink ink, IconData? icon, String label, Color bg, Color fg, VoidCallback? onTap) => Material(
        color: bg,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (icon != null) ...[Icon(icon, color: fg, size: 20), const SizedBox(width: 8)],
              Flexible(
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        ),
      );

  Widget _round(_Ink ink, IconData icon, double size, Color bg, Color fg, String label, VoidCallback onTap) => Semantics(
        button: true,
        label: label,
        child: Tooltip(
          message: label,
          child: Material(
            color: bg,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(width: size, height: size, child: Icon(icon, color: fg)),
            ),
          ),
        ),
      );

  /// A round button with its label under it.
  Widget _roundCell(_Ink ink, IconData icon, String label, double size, Color bg, Color fg, VoidCallback onTap) =>
      Column(mainAxisSize: MainAxisSize.min, children: [
        _round(ink, icon, size, bg, fg, label, onTap),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(label, style: TextStyle(fontSize: size > 60 ? 13 : 11.5, fontWeight: FontWeight.w600, color: ink.text2)),
        ),
      ]);

  Widget _dockCell(_Ink ink, IconData icon, String label, bool on, VoidCallback onTap, {Color? onFill, Color? onTint}) =>
      _roundCell(ink, icon, label, 54, on ? (onFill ?? ink.text) : ink.fill, on ? (onTint ?? ink.ground) : ink.text, onTap);

  Widget _iconButton(_Ink ink, IconData icon, String label, VoidCallback onTap) =>
      IconButton(tooltip: label, onPressed: onTap, icon: Icon(icon, color: ink.text2));
}

/// Microphone and speaker for calls, picked from the SDK's devices; the
/// choice is kept in Settings for the next call too.
class _AudioSheet extends ConsumerStatefulWidget {
  const _AudioSheet({required this.ink, required this.label});
  final _Ink ink;
  final String Function(String key, String fallback) label;

  @override
  ConsumerState<_AudioSheet> createState() => _AudioSheetState();
}

class _AudioSheetState extends ConsumerState<_AudioSheet> {
  List<AudioDevice> _mics = const [], _speakers = const [];

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      final mics = await DesktopEngine.instance.inputDevices();
      final speakers = await DesktopEngine.instance.outputDevices();
      if (mounted) {
        setState(() {
          _mics = mics;
          _speakers = speakers;
        });
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final ink = widget.ink;
    final s = ref.watch(settingsProvider);
    Widget group(String title, List<AudioDevice> list, String value, ValueChanged<String> pick) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(title, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: ink.text2)),
            ),
            for (final (name, label) in [('', widget.label('systemDefault', 'System default')), for (final d in list) (d.name, d.description.isEmpty ? d.name : d.description)])
              InkWell(
                borderRadius: BorderRadius.circular(12),
                // Settings hands the engine the new device (setConfig).
                onTap: () => pick(name),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                  child: Row(children: [
                    Icon(value == name ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        size: 20, color: value == name ? ink.good : ink.text2),
                    const SizedBox(width: 12),
                    Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5))),
                  ]),
                ),
              ),
          ],
        );
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.label('audioDevices', 'Audio devices'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          group(widget.label('microphone', 'Microphone'), _mics, s.micDevice, (v) => s.micDevice = v),
          group(widget.label('speakerDevice', 'Speaker'), _speakers, s.speakerDevice, (v) => s.speakerDevice = v),
        ]),
      ),
    );
  }
}

/// Three rising signal bars (QualityBars.kt): the 0–4 grade, 4 showing as 3.
class _Bars extends StatelessWidget {
  const _Bars({required this.level, required this.lit, required this.off});
  final int level;
  final Color lit, off;

  @override
  Widget build(BuildContext context) {
    final n = level.clamp(0, 3);
    return Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < 3; i++)
        Container(
          width: 4,
          height: 7 + i * 5,
          margin: EdgeInsetsDirectional.only(end: i < 2 ? 2.8 : 0),
          decoration: BoxDecoration(color: i < n ? lit : off, borderRadius: BorderRadius.circular(2)),
        ),
    ]);
  }
}
