import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audio_session/audio_session.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';

import '../core/contacts.dart';
import '../core/db.dart';
import '../core/people.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../sip/quality.dart';
import '../sip/sip_service.dart';
import '../ui/widgets.dart';
import 'chat.dart';
import 'dialer.dart';
import 'status.dart';

enum _Filter { all, missed, recorded, messages }

/// One person on one day: their calls and messages, newest first.
class PersonDay {
  PersonDay(this.key, this.day);

  /// The day and the number, written however the number was.
  final String key;
  final DateTime day;
  final calls = <CallRecord>[];
  final messages = <ChatMessage>[];

  String get number => calls.isNotEmpty ? calls.first.number : messages.first.peer;
  int get count => calls.length + messages.length;

  DateTime get latest {
    final c = calls.isEmpty ? null : calls.first.startedAt;
    final m = messages.isEmpty ? null : messages.first.at;
    if (c == null) return m!;
    if (m == null) return c;
    return c.isAfter(m) ? c : m;
  }

  /// Missed calls since the last call that got through: still owed a call back.
  int get openMissed => calls.takeWhile((c) => c.result == CallResult.missed).length;
}

/// Calls and messages folded into one row per person per day, the most
/// recent row first. Both lists come newest first, as the database gives them.
List<PersonDay> groupByPerson(List<CallRecord> calls, List<ChatMessage> messages) {
  final groups = <String, PersonDay>{};
  PersonDay at(DateTime t, String number) {
    final day = DateTime(t.year, t.month, t.day);
    final key = '${day.millisecondsSinceEpoch}|${numberKey(number)}';
    return groups.putIfAbsent(key, () => PersonDay(key, day));
  }

  for (final c in calls) {
    at(c.startedAt, c.number).calls.add(c);
  }
  for (final m in messages) {
    at(m.at, m.peer).messages.add(m);
  }
  for (final g in groups.values) {
    g.calls.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    g.messages.sort((a, b) => b.at.compareTo(a.at));
  }
  return groups.values.toList()..sort((a, b) => b.latest.compareTo(a.latest));
}

/// Pocket · Calls: one row per person per day with their calls and messages
/// inside. Swipe right to call, left to delete; tap a call for its sheet.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  _Filter _filter = _Filter.all;
  bool _searching = false;
  final _search = TextEditingController();

  /// The row opened in place, by [PersonDay.key].
  String? _open;

  /// Calls swiped away: hidden at once, before the database reloads.
  final _deleted = <int>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _closeSearch() => setState(() {
        _searching = false;
        _search.clear();
      });

  Future<(List<CallRecord>, List<ChatMessage>)> _load(LocalDb db) async => (await db.calls(), await db.messages());

  String _title(PersonDay g, ContactsService contacts) {
    for (final c in g.calls) {
      if (c.name.isNotEmpty) return c.name;
    }
    final sip = ref.read(sipProvider).nameFor(g.number);
    if (sip.isNotEmpty) return sip;
    final contact = contacts.nameFor(g.number);
    return contact.isNotEmpty ? contact : g.number;
  }

  void _openChat(String peer, String title) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(peer: peer, title: title)));

  void _tap(PersonDay g, String title) {
    if (g.count > 1) {
      setState(() => _open = _open == g.key ? null : g.key);
    } else if (g.calls.isNotEmpty) {
      showCallSheet(context, ref, g.calls.first);
    } else {
      _openChat(g.number, title);
    }
  }

  void _delete(PersonDay g) {
    final calls = List.of(g.calls);
    final ids = [for (final c in calls) ?c.id];
    setState(() {
      _deleted.addAll(ids);
      if (_open == g.key) _open = null;
    });
    final db = ref.read(dbProvider)..deleteCalls(ids);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('callsDeleted'.plural(calls.length)),
        action: SnackBarAction(
          label: 'undo'.tr(),
          onPressed: () async {
            await db.restoreCalls(calls);
            if (mounted) setState(() => _deleted.removeAll(ids));
          },
        ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final db = ref.watch(dbProvider);
    final contacts = ref.watch(contactsProvider);
    final manyAccounts = ref.watch(accountsProvider).accounts.length > 1;
    final query = _search.text.trim();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 10, 12, 10),
        child: SizedBox(
          height: 48,
          child: _searching
              ? Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _search,
                      autofocus: true,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'searchCalls'.tr(),
                      ),
                    ),
                  ),
                  IconButton(tooltip: 'close'.tr(), icon: const Icon(Icons.close), onPressed: _closeSearch),
                ])
              : Row(children: [
                  Expanded(
                    child: Text('tabCalls'.tr(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: -1)),
                  ),
                  StatusPill(compact: MediaQuery.sizeOf(context).width < 420),
                  const SizedBox(width: 8),
                  RoundIcon(icon: Icons.search, size: 40, tooltip: 'search'.tr(), onTap: () => setState(() => _searching = true)),
                ]),
        ),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: _FilterTrack(value: _filter, onChanged: (f) => setState(() => _filter = f)),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: Stack(children: [
          FutureBuilder<(List<CallRecord>, List<ChatMessage>)>(
            future: _load(db),
            builder: (_, s) {
              final (allCalls, allMessages) = s.data ?? (const <CallRecord>[], const <ChatMessage>[]);
              var calls = allCalls.where((c) => !_deleted.contains(c.id)).toList();
              var messages = allMessages;
              switch (_filter) {
                case _Filter.all:
                  break;
                case _Filter.missed:
                  calls = calls.where((c) => c.result == CallResult.missed).toList();
                  messages = const [];
                case _Filter.recorded:
                  calls = calls.where((c) => c.recordingPath.isNotEmpty).toList();
                  messages = const [];
                case _Filter.messages:
                  calls = const [];
              }
              var groups = groupByPerson(calls, messages);
              if (query.isNotEmpty) {
                groups = groups
                    .where((g) => matchesQuery(query, [_title(g, contacts), g.number, for (final m in g.messages) m.body]))
                    .toList();
              }
              if (groups.isEmpty) {
                return _Empty(
                  icon: query.isNotEmpty
                      ? Icons.search_off
                      : (_filter == _Filter.messages ? Icons.chat_bubble_outline : Icons.schedule),
                  text: (query.isNotEmpty ? 'noMatches' : (_filter == _Filter.messages ? 'noMessages' : 'noActivity')).tr(),
                );
              }
              final rows = <Widget>[];
              DateTime? lastDay;
              for (final g in groups) {
                if (g.day != lastDay) {
                  rows.add(Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 20, 4),
                    child: Text(_dayLabel(g.day), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: t.text2)),
                  ));
                  lastDay = g.day;
                }
                rows.add(_swipeable(g, _title(g, contacts), manyAccounts));
              }
              return ListView(padding: EdgeInsets.only(bottom: _filter == _Filter.messages ? 88 : 16), children: rows);
            },
          ),
          if (_filter == _Filter.messages)
            PositionedDirectional(
              end: 16,
              bottom: 16,
              child: FloatingActionButton(
                tooltip: 'newChat'.tr(),
                backgroundColor: t.accent,
                foregroundColor: t.onAccent,
                shape: const StadiumBorder(),
                onPressed: () => _openChat('', ''),
                child: const Icon(Icons.edit_outlined),
              ),
            ),
        ]),
      ),
    ]);
  }

  /// Right (start to end) calls back and springs back; left deletes the
  /// row's calls, with Undo. A row of messages only can't be deleted here.
  Widget _swipeable(PersonDay g, String title, bool manyAccounts) {
    final t = context.t;
    final last = g.calls.isEmpty ? null : g.calls.first;
    return Dismissible(
      key: ValueKey('${g.key}|${g.calls.map((c) => c.id).join(',')}|${g.messages.length}'),
      direction: g.calls.isEmpty ? DismissDirection.startToEnd : DismissDirection.horizontal,
      background: _SwipeAction(icon: Icons.call, label: 'call'.tr(), color: t.accent, onColor: t.onAccent, end: false),
      secondaryBackground: _SwipeAction(icon: Icons.delete_outline, label: 'delete'.tr(), color: t.danger, onColor: Colors.white, end: true),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) return true;
        HapticFeedback.mediumImpact();
        placeCall(context, ref, g.number, accountId: last?.accountId, name: title == g.number ? null : title);
        return false;
      },
      onDismissed: (_) => _delete(g),
      child: _PersonRow(
        g: g,
        title: title,
        open: _open == g.key,
        showAccount: manyAccounts,
        onTap: () => _tap(g, title),
        onCall: (c, {play = false}) => showCallSheet(context, ref, c, play: play),
        onChat: () => _openChat(g.number, title),
      ),
    );
  }
}

/// All · Missed · Recorded · Messages on one pill track.
class _FilterTrack extends StatelessWidget {
  const _FilterTrack({required this.value, required this.onChanged});
  final _Filter value;
  final ValueChanged<_Filter> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: t.surface2, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final f in _Filter.values)
          Semantics(
            selected: f == value,
            button: true,
            child: GestureDetector(
              onTap: () => onChanged(f),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
                decoration: BoxDecoration(
                  color: f == value ? t.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(17),
                  boxShadow: f == value ? [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 3, offset: const Offset(0, 1))] : null,
                ),
                child: Text(
                  switch (f) {
                    _Filter.all => 'filterAll'.tr(),
                    _Filter.missed => 'filterMissed'.tr(),
                    _Filter.recorded => 'filterRecorded'.tr(),
                    _Filter.messages => 'filterMessages'.tr(),
                  },
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: f == value ? t.text : t.text2),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// What shows under a row while it is swiped: Call on the start side,
/// Delete on the end side.
class _SwipeAction extends StatelessWidget {
  const _SwipeAction({required this.icon, required this.label, required this.color, required this.onColor, required this.end});
  final IconData icon;
  final String label;
  final Color color, onColor;
  final bool end;

  @override
  Widget build(BuildContext context) => Container(
        color: color,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        alignment: end ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
        child: Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: [
          Icon(icon, color: onColor, size: 22),
          Text(label, style: TextStyle(color: onColor, fontWeight: FontWeight.w700, fontSize: 14)),
        ]),
      );
}

/// Centered icon and a line, for an empty list.
class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: t.surface2, shape: BoxShape.circle),
            child: Icon(icon, color: t.text2, size: 28),
          ),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center, style: TextStyle(color: t.text2)),
        ]),
      ),
    );
  }
}

String _dayLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  if (day == today) return 'today'.tr();
  if (day == today.subtract(const Duration(days: 1))) return 'yesterday'.tr();
  return DateFormat.yMMMd().format(d);
}

String _duration(int sec) => sec >= 3600
    ? '${sec ~/ 3600}:${(sec ~/ 60 % 60).toString().padLeft(2, '0')}:${(sec % 60).toString().padLeft(2, '0')}'
    : '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';

String _hm(DateTime d) => DateFormat.Hm().format(d);

IconData _callIcon(CallRecord c) => switch (c.result) {
      CallResult.missed => Icons.call_missed,
      CallResult.failed => Icons.error_outline,
      CallResult.declined => Icons.call_end,
      _ => c.direction == CallDirection.incoming ? Icons.call_received : Icons.call_made,
    };

/// "Incoming · 1:20", "Missed", "Couldn't connect · 503".
String _callWhat(CallRecord c) => switch (c.result) {
      CallResult.missed => 'missed'.tr(),
      CallResult.declined => 'declined'.tr(),
      CallResult.failed => ['failed'.tr(), if (c.sipCode != null) '${c.sipCode}'].join(' · '),
      _ => [
          c.direction == CallDirection.incoming ? 'incoming'.tr() : 'outgoing'.tr(),
          if (c.durationSec > 0) _duration(c.durationSec),
        ].join(' · '),
    };

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.g,
    required this.title,
    required this.open,
    required this.showAccount,
    required this.onTap,
    required this.onCall,
    required this.onChat,
  });
  final PersonDay g;
  final String title;
  final bool open, showAccount;
  final VoidCallback onTap, onChat;
  final void Function(CallRecord c, {bool play}) onCall;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final owed = g.openMissed;
    final unread = g.messages.any((m) => !m.read && !m.outgoing);
    final graded = g.calls.where((c) => c.result == CallResult.answered && c.hasQos).firstOrNull;
    final radius = BorderRadius.circular(open ? 20 : 0);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: EdgeInsets.symmetric(horizontal: open ? 10 : 0, vertical: open ? 4 : 0),
      decoration: BoxDecoration(
        color: open ? t.surface : t.bg,
        borderRadius: radius,
        boxShadow: open ? [BoxShadow(color: t.border, offset: const Offset(0, 1))] : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(open ? 10 : 20, 8, open ? 10 : 16, 8),
            child: Column(children: [
              Row(children: [
                Avatar(title, size: 44, colors: owed > 0 ? (t.dangerSoft, t.missed) : null),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: unread ? FontWeight.w800 : FontWeight.w700,
                          color: owed > 0 ? t.missed : t.text,
                        )),
                    if (!open) ...[const SizedBox(height: 4), _Strip(g)],
                    if (open && title != g.number)
                      Text(g.number, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 11.5)),
                  ]),
                ),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(_hm(g.latest), style: TextStyle(fontSize: 12, color: unread ? t.accent : t.grey)),
                  const SizedBox(height: 6),
                  if (owed > 0)
                    _Badge('$owed', t.missed)
                  else if (graded != null)
                    QualityBars(mos: graded.mos, rttMs: graded.rttMs, jitterMs: graded.jitterMs, lossPct: graded.lossPct, barWidth: 3)
                  else if (unread)
                    Dot(t.accent)
                  else
                    const SizedBox(height: 10),
                ]),
              ]),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                alignment: AlignmentDirectional.topCenter,
                child: open ? _nested(context) : const SizedBox(width: double.infinity),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _nested(BuildContext context) {
    DateTime at(Object i) => i is CallRecord ? i.startedAt : (i as ChatMessage).at;
    final items = <Object>[...g.calls, ...g.messages]..sort((a, b) => at(b).compareTo(at(a)));
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 56, top: 6),
      child: Column(children: [
        for (final i in items) i is CallRecord ? _callLine(context, i) : _messageLine(context, i as ChatMessage),
      ]),
    );
  }

  Widget _line(BuildContext context, {required VoidCallback onTap, required List<Widget> children}) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: context.t.border))),
          child: Row(children: children),
        ),
      );

  Widget _callLine(BuildContext context, CallRecord c) {
    final t = context.t;
    final missed = c.result == CallResult.missed;
    final recorded = c.recordingPath.isNotEmpty;
    return _line(context, onTap: () => onCall(c), children: [
      Icon(_callIcon(c), size: 14, color: missed ? t.missed : (c.result == CallResult.failed ? t.warn : t.text2)),
      const SizedBox(width: 8),
      SizedBox(width: 42, child: Text(_hm(c.startedAt), style: mono(context, size: 11.5))),
      Expanded(
        child: Text.rich(
          TextSpan(style: TextStyle(fontSize: 12.5, color: missed ? t.missed : t.text), children: [
            TextSpan(text: _callWhat(c)),
            if (recorded) TextSpan(text: ' · ${'recorded'.tr()}', style: TextStyle(color: t.warn, fontWeight: FontWeight.w600)),
            if (showAccount) TextSpan(text: ' · ${c.accountName}', style: TextStyle(color: t.text2)),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (c.hasQos) ...[
        const SizedBox(width: 6),
        QualityBars(mos: c.mos, rttMs: c.rttMs, jitterMs: c.jitterMs, lossPct: c.lossPct, barWidth: 3),
      ],
      if (recorded) ...[
        const SizedBox(width: 8),
        Semantics(
          button: true,
          label: 'play'.tr(),
          child: InkResponse(
            onTap: () => onCall(c, play: true),
            radius: 20,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: t.warn, shape: BoxShape.circle),
              child: Icon(Icons.play_arrow_rounded, size: 18, color: t.surface),
            ),
          ),
        ),
      ],
    ]);
  }

  Widget _messageLine(BuildContext context, ChatMessage m) {
    final t = context.t;
    final unread = !m.read && !m.outgoing;
    return _line(context, onTap: onChat, children: [
      Icon(m.outgoing ? Icons.reply : Icons.chat_bubble_outline, size: 14, color: t.text2),
      const SizedBox(width: 8),
      SizedBox(width: 42, child: Text(_hm(m.at), style: mono(context, size: 11.5))),
      Expanded(
        child: Text('“${m.body}”',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: unread ? t.text : t.text2, fontWeight: unread ? FontWeight.w600 : null)),
      ),
    ]);
  }
}

/// The day's calls as chips, oldest on the start side, then the latest
/// message. Whatever doesn't fit is clipped.
class _Strip extends StatelessWidget {
  const _Strip(this.g);
  final PersonDay g;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final chrono = g.calls.reversed.toList();
    final shown = chrono.length > 3 ? chrono.sublist(chrono.length - 2) : chrono;
    final hidden = chrono.length - shown.length;
    final message = g.messages.isEmpty ? null : g.messages.first;
    return SizedBox(
      height: 20,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Row(spacing: 4, children: [
          if (hidden > 0) _Chip(text: '+$hidden', fg: t.text2, bg: t.surface2),
          for (final c in shown) _callChip(t, c),
          if (message != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Container(
                height: 20,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(color: t.surface2, borderRadius: BorderRadius.circular(7)),
                child: Row(mainAxisSize: MainAxisSize.min, spacing: 3, children: [
                  Icon(Icons.chat_bubble_outline, size: 11, color: t.text2),
                  Flexible(
                    child: Text(message.body,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: t.text2, height: 1.1)),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _callChip(Tokens t, CallRecord c) {
    final recorded = c.recordingPath.isNotEmpty;
    final (text, fg, bg) = switch (c.result) {
      CallResult.missed => (_hm(c.startedAt), t.missed, t.dangerSoft),
      CallResult.failed => (c.sipCode != null ? '${c.sipCode}' : _hm(c.startedAt), t.warn, t.warnSoft),
      CallResult.declined => (_hm(c.startedAt), t.text2, t.surface2),
      _ => (
          c.durationSec > 0 ? _duration(c.durationSec) : _hm(c.startedAt),
          recorded ? t.warn : t.text2,
          recorded ? t.warnSoft : t.surface2,
        ),
    };
    return _Chip(icon: _callIcon(c), text: text, fg: fg, bg: bg);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({this.icon, required this.text, required this.fg, required this.bg});
  final IconData? icon;
  final String text;
  final Color fg, bg;

  @override
  Widget build(BuildContext context) => Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(7)),
        child: Row(mainAxisSize: MainAxisSize.min, spacing: 2, children: [
          if (icon != null) Icon(icon, size: 11, color: fg),
          Text(text, style: mono(context, size: 10.5, color: fg, weight: FontWeight.w500)),
        ]),
      );
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 18),
        height: 18,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(9)),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
      );
}

// ── One call: the sheet ───────────────────────────────────────────────────────

/// One call in a sheet: Call and Message first, then the recording, the
/// quality pill (tap for every figure), a few facts, and everything stored
/// behind Technical details.
Future<void> showCallSheet(BuildContext context, WidgetRef ref, CallRecord c, {bool play = false}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: context.t.surface,
      builder: (_) => _CallSheet(c: c, play: play, outer: context),
    );

class _CallSheet extends ConsumerStatefulWidget {
  const _CallSheet({required this.c, required this.play, required this.outer});
  final CallRecord c;
  final bool play;

  /// The screen under the sheet, for what opens after it closes.
  final BuildContext outer;

  @override
  ConsumerState<_CallSheet> createState() => _CallSheetState();
}

class _CallSheetState extends ConsumerState<_CallSheet> {
  bool _figures = false;
  bool _technical = false;

  CallRecord get c => widget.c;

  String _when(DateTime d) {
    final day = _dayLabel(d);
    return '$day ${_hm(d)}';
  }

  void _call() {
    Navigator.pop(context);
    placeCall(widget.outer, ref, c.number, accountId: c.accountId, name: c.name);
  }

  void _message() {
    Navigator.pop(context);
    Navigator.of(widget.outer).push(MaterialPageRoute(builder: (_) => ChatScreen(peer: c.number, title: c.title)));
  }

  void _block() {
    Navigator.pop(context);
    final s = ref.read(settingsProvider);
    s.blocked = {...s.blocked, c.number};
  }

  void _delete() {
    Navigator.pop(context);
    final id = c.id;
    if (id == null) return;
    final db = ref.read(dbProvider)..deleteCall(id);
    ScaffoldMessenger.of(widget.outer)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('callsDeleted'.plural(1)),
        action: SnackBarAction(label: 'undo'.tr(), onPressed: () => db.restoreCalls([c])),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final manyAccounts = ref.watch(accountsProvider).accounts.length > 1;
    final missed = c.result == CallResult.missed;
    final sub = [
      if (c.number != c.title) c.number,
      switch (c.result) {
        CallResult.missed => 'missed'.tr(),
        CallResult.declined => 'declined'.tr(),
        CallResult.failed => 'failed'.tr(),
        _ => c.direction == CallDirection.incoming ? 'incoming'.tr() : 'outgoing'.tr(),
      },
      _when(c.startedAt),
      if (manyAccounts) c.accountName,
    ].join(' · ');

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Avatar(c.title, size: 48, colors: missed ? (t.dangerSoft, t.missed) : null),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                  Text(sub, style: TextStyle(color: missed ? t.missed : t.text2, fontSize: 12.5)),
                ]),
              ),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _SheetButton(icon: Icons.call, label: 'call'.tr(), primary: true, onTap: _call)),
              const SizedBox(width: 8),
              Expanded(child: _SheetButton(icon: Icons.chat_bubble_outline, label: 'message'.tr(), onTap: _message)),
              const SizedBox(width: 8),
              Material(
                color: t.surface2,
                shape: const CircleBorder(),
                child: PopupMenuButton<int>(
                  tooltip: 'more'.tr(),
                  icon: Icon(Icons.more_horiz, color: t.text),
                  onSelected: (v) => Clipboard.setData(ClipboardData(
                    text: v == 0
                        ? c.number
                        : ['${c.title} · ${c.number}', for (final (k, val) in callInfoRows(c)) '$k: $val'].join('\n'),
                  )),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 0, child: Text('copyNumber'.tr())),
                    PopupMenuItem(value: 1, child: Text('copyCallDetails'.tr())),
                  ],
                ),
              ),
            ]),
            if (c.recordingPath.isNotEmpty) ...[
              const SizedBox(height: 12),
              _RecordingPlayer(path: c.recordingPath, autoplay: widget.play),
            ],
            if (c.hasQos) ...[
              const SizedBox(height: 12),
              _QualityRow(c, open: _figures, onTap: () => setState(() => _figures = !_figures)),
              if (_figures) ...[const SizedBox(height: 6), _QualityFigures(c)],
            ],
            const SizedBox(height: 12),
            _Facts(c),
            const SizedBox(height: 12),
            _TechnicalRow(c, open: _technical, onTap: () => setState(() => _technical = !_technical)),
            if (_technical) _CallInfoTable(c),
            const SizedBox(height: 4),
            Row(children: [
              TextButton(onPressed: _block, child: Text('blockNumber'.tr(), style: TextStyle(color: t.danger, fontWeight: FontWeight.w700))),
              const Spacer(),
              TextButton(onPressed: _delete, child: Text('delete'.tr(), style: TextStyle(color: t.danger, fontWeight: FontWeight.w700))),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({required this.icon, required this.label, required this.onTap, this.primary = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final fg = primary ? t.onAccent : t.text;
    return Material(
      color: primary ? t.accent : t.surface2,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, spacing: 7, children: [
            Icon(icon, size: 19, color: fg),
            Flexible(
              child: Text(label,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontSize: 14.5, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The 3-bar pill as a button: bars, grade word, MOS; opens every figure.
class _QualityRow extends StatelessWidget {
  const _QualityRow(this.c, {required this.open, required this.onTap});
  final CallRecord c;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final level = callQualityLevel(mos: c.mos, rttMs: c.rttMs, jitterMs: c.jitterMs, lossPct: c.lossPct);
    return Material(
      color: t.bg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(children: [
            QualityBars(mos: c.mos, rttMs: c.rttMs, jitterMs: c.jitterMs, lossPct: c.lossPct),
            const SizedBox(width: 8),
            Text(qualityWordKey(level).tr(), style: TextStyle(color: qualityColor(t, level), fontSize: 14, fontWeight: FontWeight.w700)),
            if (c.mos != null) ...[
              const SizedBox(width: 8),
              Text('MOS ${c.mos!.toStringAsFixed(1)}', style: mono(context, size: 12)),
            ],
            const Spacer(),
            Text('details'.tr(), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text2)),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 180),
              child: Icon(Icons.expand_more, size: 20, color: t.text2),
            ),
          ]),
        ),
      ),
    );
  }
}

/// MOS both ways, jitter, loss, round trip and codec; a figure that misses
/// its target is red.
class _QualityFigures extends StatelessWidget {
  const _QualityFigures(this.c);
  final CallRecord c;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    Widget mos(String label, double? v) {
      final level = callQualityLevel(mos: v);
      return _Tile(
        label: label,
        value: v == null ? '—' : v.toStringAsFixed(1),
        trailing: v == null ? null : Text(qualityWordKey(level).tr(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: qualityColor(t, level))),
      );
    }

    Widget net(String label, double? v, double target, String Function(double) fmt) =>
        _Tile(label: label, value: v == null ? '—' : fmt(v), color: v != null && v >= target ? t.danger : null);

    final tiles = [
      mos('youHeard'.tr(), c.mos),
      mos('theyHeard'.tr(), c.mosRx),
      net('qJitter'.tr(), c.jitterMs, 20, (v) => '${v.round()} ms'),
      net('qLoss'.tr(), c.lossPct, 1, (v) => '${v.toStringAsFixed(1)} %'),
      net('qRtt'.tr(), c.rttMs, 150, (v) => '${v.round()} ms'),
      _Tile(label: 'qCodec'.tr(), value: c.codec.isEmpty ? '—' : c.codec),
    ];
    return Column(spacing: 6, children: [
      for (var i = 0; i < tiles.length; i += 2)
        Row(spacing: 6, children: [Expanded(child: tiles[i]), Expanded(child: tiles[i + 1])]),
    ]);
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, this.color, this.trailing});
  final String label, value;
  final Color? color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(color: t.bg, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: t.text2)),
        const SizedBox(height: 2),
        Row(spacing: 6, children: [
          Flexible(
            child: Text(value,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 14, color: color ?? t.text, weight: FontWeight.w500)),
          ),
          ?trailing,
        ]),
      ]),
    );
  }
}

/// Rang, talked, and who ended it (or the SIP code when it never connected).
class _Facts extends StatelessWidget {
  const _Facts(this.c);
  final CallRecord c;

  @override
  Widget build(BuildContext context) {
    final ring = c.ringSec;
    final third = c.result != CallResult.answered && c.sipCode != null
        ? _Tile(label: 'sipCodeShort'.tr(), value: '${c.sipCode}')
        : _Tile(
            label: 'infoEndedBy'.tr(),
            value: switch (c.endedBy) {
              'local' => 'you'.tr(),
              '' => '—',
              _ => 'endedThem'.tr(),
            },
          );
    return Row(spacing: 6, children: [
      Expanded(child: _Tile(label: 'rang'.tr(), value: ring <= 0 ? '—' : (ring < 60 ? '$ring s' : _duration(ring)))),
      Expanded(child: _Tile(label: 'talk'.tr(), value: c.durationSec > 0 ? _duration(c.durationSec) : '—')),
      Expanded(child: third),
    ]);
  }
}

class _TechnicalRow extends StatelessWidget {
  const _TechnicalRow(this.c, {required this.open, required this.onTap});
  final CallRecord c;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final summary = [
      c.transport,
      if (c.encryption.isNotEmpty) 'SRTP',
      c.icePath,
      if (c.callId.isNotEmpty) 'Call-ID ${c.callId.length > 8 ? '${c.callId.substring(0, 8)}…' : c.callId}',
    ].where((s) => s.isNotEmpty).join(' · ');
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(2, 12, 2, 10),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
        child: Row(children: [
          Icon(Icons.description_outlined, size: 20, color: t.grey),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('technicalDetails'.tr(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              if (summary.isNotEmpty) Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 10.5)),
            ]),
          ),
          AnimatedRotation(
            turns: open ? 0.5 : 0,
            duration: const Duration(milliseconds: 180),
            child: Icon(Icons.expand_more, size: 20, color: t.text2),
          ),
        ]),
      ),
    );
  }
}

// ── Recording ────────────────────────────────────────────────────────────────

/// Loudness of a 16-bit PCM WAV file in [bars] slices, 0–1, for drawing its
/// waveform. Reads a short stretch of each slice only, so an hour-long call
/// is as quick as a short one. Empty when the file is not a WAV this reads.
List<double> wavPeaks(String path, {int bars = 56}) {
  RandomAccessFile? f;
  try {
    f = File(path).openSync();
    final len = f.lengthSync();
    final head = f.readSync(12);
    if (head.length < 12 || String.fromCharCodes(head, 0, 4) != 'RIFF' || String.fromCharCodes(head, 8, 12) != 'WAVE') {
      return const [];
    }
    var pos = 12, bits = 0, channels = 0, dataAt = -1, dataLen = 0;
    while (pos + 8 <= len) {
      f.setPositionSync(pos);
      final h = f.readSync(8);
      final size = ByteData.sublistView(h).getUint32(4, Endian.little);
      final id = String.fromCharCodes(h, 0, 4);
      if (id == 'fmt ') {
        final fmt = ByteData.sublistView(f.readSync(16));
        channels = fmt.getUint16(2, Endian.little);
        bits = fmt.getUint16(14, Endian.little);
      } else if (id == 'data') {
        dataAt = pos + 8;
        // A recording cut off by the end of its call can say 0, or too much.
        dataLen = size == 0 ? len - dataAt : math.min(size, len - dataAt);
        break;
      }
      pos += 8 + size + (size & 1);
    }
    if (bits != 16 || channels < 1 || dataAt < 0) return const [];
    final frame = 2 * channels;
    final frames = dataLen ~/ frame;
    if (frames < bars) return const [];
    final per = frames ~/ bars;
    final out = <double>[];
    for (var i = 0; i < bars; i++) {
      f.setPositionSync(dataAt + i * per * frame);
      final chunk = f.readSync(math.min(per, 4096) * frame);
      final d = ByteData.sublistView(chunk);
      var sum = 0.0;
      for (var j = 0; j + 1 < chunk.length; j += 2) {
        final v = d.getInt16(j, Endian.little) / 32768;
        sum += v * v;
      }
      out.add(chunk.length < 2 ? 0 : math.sqrt(sum / (chunk.length ~/ 2)));
    }
    final top = out.fold<double>(0, math.max);
    return top <= 0 ? List.filled(bars, 0) : [for (final v in out) math.pow(v / top, 0.7).toDouble()];
  } catch (_) {
    return const [];
  } finally {
    f?.closeSync();
  }
}

List<double> _peaksOf(String path) => wavPeaks(path);

class _RecordingPlayer extends ConsumerStatefulWidget {
  const _RecordingPlayer({required this.path, this.autoplay = false});
  final String path;
  final bool autoplay;

  @override
  ConsumerState<_RecordingPlayer> createState() => _RecordingPlayerState();
}

class _RecordingPlayerState extends ConsumerState<_RecordingPlayer> {
  final _player = AudioPlayer();
  bool _missing = false;
  bool _ready = false;
  List<double> _peaks = const [];

  /// Where a finger on the waveform is, 0–1, until it lets go.
  double? _dragging;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!await File(widget.path).exists()) {
      if (mounted) setState(() => _missing = true);
      return;
    }
    try {
      // Play out loud: after a call the phone can still be routed to the
      // earpiece. Media attributes put it on the speaker (or a headset).
      // Never touch the session under a live call: it is the call's.
      if (!ref.read(sipProvider).hasCall) {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
        await session.setActive(true);
      }
      // A recording cut off by the end of its call may still say it is empty.
      await SipService.repairWav(widget.path);
      await _player.setFilePath(widget.path);
      if (!mounted) return;
      setState(() => _ready = true);
      if (widget.autoplay) _player.play();
      final peaks = await compute(_peaksOf, widget.path);
      if (mounted) setState(() => _peaks = peaks);
    } catch (_) {
      if (mounted) setState(() => _missing = true);
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    if (_missing) {
      return ECard(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(Icons.error_outline, color: t.warn),
          const SizedBox(width: 10),
          Expanded(child: Text('recordingMissing'.tr(), style: TextStyle(color: t.text2, fontSize: 13))),
        ]),
      );
    }
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 2, 8),
      decoration: BoxDecoration(color: t.warnSoft, borderRadius: BorderRadius.circular(18)),
      child: StreamBuilder<PlayerState>(
        stream: _player.playerStateStream,
        builder: (_, st) {
          final state = st.data;
          final playing = state?.playing ?? false;
          final done = state?.processingState == ProcessingState.completed;
          return Row(children: [
            Semantics(
              button: true,
              label: playing && !done ? 'pause'.tr() : 'play'.tr(),
              child: Material(
                color: _ready ? t.warn : t.warn.withValues(alpha: 0.4),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: !_ready
                      ? null
                      : () async {
                          if (done) await _player.seek(Duration.zero);
                          playing && !done ? await _player.pause() : await _player.play();
                        },
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(playing && !done ? Icons.pause_rounded : Icons.play_arrow_rounded, color: t.surface, size: 24),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StreamBuilder<Duration>(
                stream: _player.positionStream,
                builder: (_, p) {
                  final total = _player.duration ?? Duration.zero;
                  final ms = total.inMilliseconds;
                  final at = ms <= 0 ? 0.0 : ((p.data ?? Duration.zero).inMilliseconds / ms).clamp(0.0, 1.0);
                  final shown = _dragging ?? at;
                  return Row(children: [
                    Expanded(child: _Waveform(peaks: _peaks, progress: shown, onSeek: ms <= 0 ? null : _seek)),
                    const SizedBox(width: 8),
                    Text('${_fmt(Duration(milliseconds: (shown * ms).round()))} / ${_fmt(total)}', style: mono(context, size: 11)),
                  ]);
                },
              ),
            ),
            IconButton(
              tooltip: 'shareRecording'.tr(),
              icon: Icon(Icons.ios_share, color: t.text2, size: 20),
              onPressed: () => Share.shareXFiles([XFile(widget.path)]),
            ),
          ]);
        },
      ),
    );
  }

  /// [at] while the finger moves; null when it lets go, and the player jumps.
  void _seek(double at, {required bool end}) {
    if (!end) {
      setState(() => _dragging = at);
      return;
    }
    final total = _player.duration;
    if (total != null) _player.seek(total * at);
    setState(() => _dragging = null);
  }
}

/// The recording's loudness as bars, played part solid; tap or drag to seek.
class _Waveform extends StatelessWidget {
  const _Waveform({required this.peaks, required this.progress, required this.onSeek});
  final List<double> peaks;
  final double progress;
  final void Function(double at, {required bool end})? onSeek;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final rtl = Directionality.of(context) == ui.TextDirection.rtl;
    return LayoutBuilder(builder: (context, box) {
      double at(Offset p) {
        final x = (p.dx / box.maxWidth).clamp(0.0, 1.0);
        return rtl ? 1 - x : x;
      }

      final seek = onSeek;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: seek == null ? null : (d) => seek(at(d.localPosition), end: true),
        onHorizontalDragUpdate: seek == null ? null : (d) => seek(at(d.localPosition), end: false),
        onHorizontalDragEnd: seek == null ? null : (_) => seek(progress, end: true),
        child: Transform.flip(
          flipX: rtl,
          child: CustomPaint(
            size: Size(box.maxWidth, 30),
            painter: _WavePainter(peaks, progress, t.warn, t.warn.withValues(alpha: 0.35)),
          ),
        ),
      );
    });
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.peaks, this.progress, this.played, this.rest);
  final List<double> peaks;
  final double progress;
  final Color played, rest;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 2.0;
    final n = peaks.isEmpty ? 40 : peaks.length;
    final w = math.max(1.5, (size.width - gap * (n - 1)) / n);
    final paint = Paint();
    for (var i = 0; i < n; i++) {
      final v = peaks.isEmpty ? 0.12 : peaks[i];
      final h = math.max(3.0, v * size.height);
      paint.color = (i + 0.5) / n <= progress ? played : rest;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(i * (w + gap), (size.height - h) / 2, w, h), Radius.circular(w / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter o) => o.progress != progress || o.peaks != peaks || o.played != played || o.rest != rest;
}

// ── Technical details ────────────────────────────────────────────────────────

/// Everything stored about a call, label and value, for troubleshooting
/// with the PBX.
List<(String, String)> callInfoRows(CallRecord c) {
  String time(DateTime? d) => d == null ? '—' : DateFormat.yMMMd().add_Hms().format(d);
  String n(num? v, [int digits = 0, String unit = '']) => v == null ? '—' : '${v.toStringAsFixed(digits)}$unit';
  return [
    ('infoStarted'.tr(), time(c.startedAt)),
    ('infoAnswered'.tr(), time(c.answeredAt)),
    ('infoEnded'.tr(), time(c.endedAt)),
    ('infoRing'.tr(), _duration(c.ringSec)),
    ('infoTalk'.tr(), _duration(c.durationSec)),
    ('infoTotal'.tr(), _duration(c.totalSec)),
    ('infoEndedBy'.tr(), c.endedBy == 'local' ? 'endedByMe'.tr() : (c.endedBy.isEmpty ? '—' : 'endedByThem'.tr())),
    ('infoReason'.tr(), [if (c.sipCode != null) '${c.sipCode}', if (c.endReason.isNotEmpty) c.endReason].join(' · ').ifEmpty('—')),
    ('MOS', '${n(c.mos, 2)} (${'infoMin'.tr()} ${n(c.mosMin, 2)})'),
    ('infoTheyHeard'.tr(), n(c.mosRx, 2)),
    ('RTT', n(c.rttMs, 0, ' ms')),
    ('Jitter', n(c.jitterMs, 0, ' ms')),
    ('Loss', '${n(c.lossPct, 1, ' %')} · ${c.packetsLost ?? '—'} pkts'),
    ('Codec', c.codec.ifEmpty('—')),
    ('SRTP', c.encryption.ifEmpty('—')),
    ('ICE', c.icePath.ifEmpty('—')),
    ('RTP', c.remoteMedia.ifEmpty('—')),
    ('infoTransport'.tr(), c.transport.ifEmpty('—')),
    ('infoAccount'.tr(), c.accountName),
    ('infoRemote'.tr(), c.remoteUri.ifEmpty(c.number)),
    ('infoLocal'.tr(), c.localUri.ifEmpty('—')),
    ('Call-ID', c.callId.ifEmpty('—')),
    ('infoSetup'.tr(), n(c.setupMs, 0, ' ms')),
    if (c.recordingPath.isNotEmpty)
      ('infoRecording'.tr(), '${c.recordingSec != null ? '${_duration(c.recordingSec!)} · ' : ''}${c.recordingPath}'),
  ];
}

class _CallInfoTable extends StatelessWidget {
  const _CallInfoTable(this.c);
  final CallRecord c;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ECard(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(children: [
        for (final (k, v) in callInfoRows(c))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 110, child: Text(k, style: TextStyle(fontSize: 12, color: t.text2))),
              Expanded(child: SelectableText(v, style: mono(context, size: 11, color: t.text))),
            ]),
          ),
      ]),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
