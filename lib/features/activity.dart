import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';

import '../sip/quality.dart';

import '../core/db.dart';
import '../core/people.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../ui/widgets.dart';
import 'chat.dart';
import 'dialer.dart';

enum _Filter { all, missed, recorded, messages }

/// Pocket · Calls: voicemail on top, then calls (missed ones from the same
/// number folded together), recordings and messages, with search.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  _Filter _filter = _Filter.all;
  bool _searching = false;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _closeSearch() => setState(() {
        _searching = false;
        _search.clear();
      });

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final db = ref.watch(dbProvider);
    final sip = ref.watch(sipProvider);
    final mwi = sip.runtimes.values.where((r) => r.mwi.newVoice > 0 || r.mwi.oldVoice > 0).toList();
    final newVm = mwi.fold<int>(0, (a, r) => a + r.mwi.newVoice);
    final oldVm = mwi.fold<int>(0, (a, r) => a + r.mwi.oldVoice);
    final urgent = mwi.fold<int>(0, (a, r) => a + r.mwi.newUrgent);
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
                        style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: -1)),
                  ),
                  RoundIcon(icon: Icons.search, size: 40, tooltip: 'search'.tr(), onTap: () => setState(() => _searching = true)),
                ]),
        ),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: _FilterTrack(value: _filter, onChanged: (f) => setState(() => _filter = f)),
      ),
      const SizedBox(height: 12),
      if ((newVm > 0 || oldVm > 0) && query.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Material(
            color: t.accentSoft,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                final rt = mwi.first;
                placeCall(context, ref, rt.cfg.voicemail, accountId: rt.cfg.id, name: 'voicemail'.tr());
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle),
                    child: Icon(Icons.play_arrow_rounded, color: t.onAccent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('newVoicemails'.tr(namedArgs: {'n': '$newVm'}),
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      Text('voicemailSub'.tr(namedArgs: {'u': '$urgent', 'o': '$oldVm'}),
                          style: TextStyle(fontSize: 12.5, color: t.text2)),
                    ]),
                  ),
                  Text('listen'.tr(), style: TextStyle(color: t.accent, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ),
        ),
      Expanded(
        child: _filter == _Filter.messages
            ? FutureBuilder<List<ChatMessage>>(
                future: db.conversations(),
                builder: (_, s) => _ConversationList(items: s.data ?? const [], query: query),
              )
            : FutureBuilder<List<CallRecord>>(
                future: db.calls(),
                builder: (_, s) {
                  var items = s.data ?? const <CallRecord>[];
                  if (_filter == _Filter.missed) items = items.where((c) => c.result == CallResult.missed).toList();
                  if (_filter == _Filter.recorded) items = items.where((c) => c.recordingPath.isNotEmpty).toList();
                  if (query.isNotEmpty) items = items.where((c) => matchesQuery(query, [c.name, c.number])).toList();
                  return _CallList(items: items, searching: query.isNotEmpty);
                },
              ),
      ),
    ]);
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

/// Consecutive missed calls from one number on one day become one row with
/// a count; anything with a recording or quality figures stays its own row.
List<(CallRecord, int)> groupMissed(List<CallRecord> items) {
  final out = <(CallRecord, int)>[];
  for (final c in items) {
    if (out.isNotEmpty) {
      final (last, n) = out.last;
      final sameDay = DateUtils.isSameDay(last.startedAt, c.startedAt);
      if (sameDay && last.number == c.number && last.result == CallResult.missed && c.result == CallResult.missed) {
        out[out.length - 1] = (last, n + 1);
        continue;
      }
    }
    out.add((c, 1));
  }
  return out;
}

class _CallList extends ConsumerWidget {
  const _CallList({required this.items, required this.searching});
  final List<CallRecord> items;
  final bool searching;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) {
      return _Empty(icon: searching ? Icons.search_off : Icons.schedule, text: (searching ? 'noMatches' : 'noActivity').tr());
    }
    final manyAccounts = ref.watch(accountsProvider).accounts.length > 1;
    final rows = <Widget>[];
    String? lastDay;
    for (final (c, count) in groupMissed(items)) {
      final day = _dayLabel(c.startedAt);
      if (day != lastDay) {
        rows.add(Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 20, 4),
          child: Text(day, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: context.t.text2)),
        ));
        lastDay = day;
      }
      rows.add(_CallRow(c, count: count, showAccount: manyAccounts));
    }
    return ListView(padding: const EdgeInsets.only(bottom: 16), children: rows);
  }
}

class _CallRow extends ConsumerWidget {
  const _CallRow(this.c, {required this.count, required this.showAccount});
  final CallRecord c;
  final int count;
  final bool showAccount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final missed = c.result == CallResult.missed;
    final recorded = c.recordingPath.isNotEmpty;
    final level = callQualityLevel(mos: c.mos, rttMs: c.rttMs, jitterMs: c.jitterMs, lossPct: c.lossPct);
    final poor = c.hasQos && level <= 2;
    final icon = switch (c.result) {
      CallResult.missed => Icons.call_missed,
      CallResult.failed => Icons.error_outline,
      _ => c.direction == CallDirection.incoming ? Icons.call_received : Icons.call_made,
    };
    final what = switch (c.result) {
      CallResult.missed => count > 1 ? 'missedCount'.plural(count) : 'missed'.tr(),
      CallResult.declined => 'declined'.tr(),
      CallResult.failed => 'failed'.tr(),
      _ => c.durationSec > 0 ? _duration(c.durationSec) : (c.direction == CallDirection.incoming ? 'incoming'.tr() : 'outgoing'.tr()),
    };
    final sub = TextStyle(fontSize: 12.5, color: missed ? t.missed : t.text2);
    final warn = TextStyle(fontSize: 12.5, color: t.warn, fontWeight: FontWeight.w600);

    return InkWell(
      onTap: () => _showDetail(context, ref, c),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 8, 8),
        child: Row(children: [
          Avatar(c.title, size: 44, colors: missed ? (t.dangerSoft, t.missed) : null),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: missed ? t.missed : t.text)),
              const SizedBox(height: 1),
              Text.rich(
                TextSpan(style: sub, children: [
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(end: 4),
                      child: Icon(icon, size: 13, color: sub.color),
                    ),
                  ),
                  TextSpan(text: what),
                  if (recorded)
                    TextSpan(
                      text: ' · ${'recorded'.tr()}${c.recordingSec != null ? ' ${_duration(c.recordingSec!)}' : ''}',
                      style: warn,
                    ),
                  if (poor) TextSpan(text: ' · ${'poorLine'.tr()}', style: warn),
                  if (showAccount) TextSpan(text: ' · ${c.accountName}'),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(DateFormat.Hm().format(c.startedAt), style: TextStyle(fontSize: 12, color: t.grey)),
            if (c.hasQos) ...[
              const SizedBox(height: 6),
              QualityBars(mos: c.mos, rttMs: c.rttMs, jitterMs: c.jitterMs, lossPct: c.lossPct, barWidth: 3),
            ],
          ]),
          recorded
              ? IconButton(
                  tooltip: 'play'.tr(),
                  icon: Icon(Icons.play_circle_fill, color: t.warn, size: 30),
                  onPressed: () => _showDetail(context, ref, c, play: true),
                )
              : IconButton(
                  tooltip: 'call'.tr(),
                  icon: Icon(Icons.call_outlined, color: t.accent, size: 22),
                  onPressed: () => placeCall(context, ref, c.number, accountId: c.accountId, name: c.name),
                ),
        ]),
      ),
    );
  }
}

Future<void> _showDetail(BuildContext context, WidgetRef ref, CallRecord c, {bool play = false}) async {
  final t = context.t;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.88),
        child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Avatar(c.title, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                Text('${c.number} · ${DateFormat.yMMMd().add_Hm().format(c.startedAt)}', style: TextStyle(color: t.text2, fontSize: 13)),
              ]),
            ),
          ]),
          if (c.hasQos) ...[
            const SizedBox(height: 14),
            ECard(
              padding: const EdgeInsets.all(12),
              child: QualityMetricsRow(mos: c.mos, rttMs: c.rttMs, jitterMs: c.jitterMs, lossPct: c.lossPct),
            ),
            const SizedBox(height: 8),
            Text('${c.codec} · ${c.transport} · ${_duration(c.durationSec)}', style: mono(context, size: 12)),
          ],
          if (c.recordingPath.isNotEmpty) ...[
            const SizedBox(height: 12),
            _RecordingPlayer(path: c.recordingPath, autoplay: play),
          ],
          const SizedBox(height: 8),
          _CallInfoTable(c),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: PrimaryButton(
                label: 'call'.tr(),
                color: t.success,
                textColor: t.onSuccess,
                onPressed: () {
                  Navigator.pop(ctx);
                  placeCall(context, ref, c.number, accountId: c.accountId, name: c.name);
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SecondaryButton(
                label: 'message'.tr(),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(peer: c.number, title: c.title)));
                },
              ),
            ),
          ]),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              final s = ref.read(settingsProvider);
              s.blocked = {...s.blocked, c.number};
            },
            child: Text('blockNumber'.tr(), style: TextStyle(color: t.danger)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (c.id != null) ref.read(dbProvider).deleteCall(c.id!);
            },
            child: Text('deleteFromHistory'.tr(), style: TextStyle(color: t.danger)),
          ),
        ]),
        ),
      ),
    ),
  );
}

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
      }
      await _player.setFilePath(widget.path);
      if (!mounted) return;
      setState(() => _ready = true);
      if (widget.autoplay) await _player.play();
    } catch (_) {
      if (mounted) setState(() => _missing = true);
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

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
    return ECard(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: StreamBuilder<PlayerState>(
        stream: _player.playerStateStream,
        builder: (_, st) {
          final state = st.data;
          final playing = state?.playing ?? false;
          final done = state?.processingState == ProcessingState.completed;
          return Column(children: [
            Row(children: [
              IconButton(
                tooltip: playing ? 'pause'.tr() : 'play'.tr(),
                icon: Icon(playing && !done ? Icons.pause_circle : Icons.play_circle, color: t.warn, size: 40),
                onPressed: !_ready
                    ? null
                    : () async {
                        if (done) await _player.seek(Duration.zero);
                        playing && !done ? await _player.pause() : await _player.play();
                      },
              ),
              Expanded(
                child: StreamBuilder<Duration>(
                  stream: _player.positionStream,
                  builder: (_, p) {
                    final total = _player.duration ?? Duration.zero;
                    final max = total.inMilliseconds.toDouble();
                    final pos = (_dragging ?? (p.data ?? Duration.zero).inMilliseconds.toDouble()).clamp(0.0, max <= 0 ? 0.0 : max);
                    return Column(children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(trackHeight: 3, overlayShape: SliderComponentShape.noOverlay),
                        child: Slider(
                          value: max <= 0 ? 0 : pos,
                          max: max <= 0 ? 1 : max,
                          activeColor: t.warn,
                          inactiveColor: t.surface2,
                          onChanged: max <= 0 ? null : (v) => setState(() => _dragging = v),
                          onChangeEnd: (v) async {
                            await _player.seek(Duration(milliseconds: v.round()));
                            setState(() => _dragging = null);
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Row(children: [
                          Text(_fmt(Duration(milliseconds: pos.round())), style: mono(context)),
                          const Spacer(),
                          Text(_fmt(total), style: mono(context)),
                        ]),
                      ),
                    ]);
                  },
                ),
              ),
              IconButton(
                tooltip: 'shareRecording'.tr(),
                icon: Icon(Icons.ios_share, color: t.text2),
                onPressed: () => Share.shareXFiles([XFile(widget.path)]),
              ),
            ]),
          ]);
        },
      ),
    );
  }
}

class _ConversationList extends ConsumerWidget {
  const _ConversationList({required this.items, required this.query});
  final List<ChatMessage> items;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final contacts = ref.watch(contactsProvider);
    final sip = ref.read(sipProvider);
    String titleFor(String peer) {
      final name = sip.nameFor(peer);
      if (name.isNotEmpty) return name;
      final contact = contacts.nameFor(peer);
      return contact.isNotEmpty ? contact : peer;
    }

    final shown = query.isEmpty ? items : items.where((m) => matchesQuery(query, [m.peer, titleFor(m.peer), m.body])).toList();
    return Stack(children: [
      if (shown.isEmpty)
        _Empty(icon: query.isEmpty ? Icons.chat_bubble_outline : Icons.search_off, text: (query.isEmpty ? 'noMessages' : 'noMatches').tr())
      else
        ListView.builder(
          padding: const EdgeInsets.only(top: 4, bottom: 88),
          itemCount: shown.length,
          itemBuilder: (_, i) {
            final m = shown[i];
            final title = titleFor(m.peer);
            final unread = !m.read && !m.outgoing;
            return InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(peer: m.peer, title: title))),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(children: [
                  Avatar(title, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15.5, fontWeight: unread ? FontWeight.w800 : FontWeight.w700)),
                      Text(m.body,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: unread ? t.text : t.text2)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(DateFormat.Hm().format(m.at), style: TextStyle(fontSize: 12, color: unread ? t.accent : t.grey)),
                    if (unread) ...[const SizedBox(height: 6), Dot(t.accent)],
                  ]),
                ]),
              ),
            );
          },
        ),
      PositionedDirectional(
        end: 16,
        bottom: 16,
        child: FloatingActionButton(
          tooltip: 'newChat'.tr(),
          backgroundColor: t.accent,
          foregroundColor: t.onAccent,
          shape: const StadiumBorder(),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChatScreen(peer: '', title: ''))),
          child: const Icon(Icons.edit_outlined),
        ),
      ),
    ]);
  }
}

/// Everything stored about a call, for troubleshooting with the PBX.
class _CallInfoTable extends StatelessWidget {
  const _CallInfoTable(this.c);
  final CallRecord c;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    String time(DateTime? d) => d == null ? '—' : DateFormat.yMMMd().add_Hms().format(d);
    String n(num? v, [int digits = 0, String unit = '']) => v == null ? '—' : '${v.toStringAsFixed(digits)}$unit';
    final rows = <(String, String)>[
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
    return ECard(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(children: [
        for (final (k, v) in rows)
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
