import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';

import '../sip/quality.dart';

import '../core/db.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../ui/widgets.dart';
import 'chat.dart';
import 'dialer.dart';

enum _Filter { all, missed, recorded, messages }

/// Design E · Activity: voicemail count on top, then calls, recordings and
/// messages in one list.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final db = ref.watch(dbProvider);
    final sip = ref.watch(sipProvider);
    final mwi = sip.runtimes.values.where((r) => r.mwi.newVoice > 0 || r.mwi.oldVoice > 0).toList();
    final newVm = mwi.fold<int>(0, (a, r) => a + r.mwi.newVoice);
    final oldVm = mwi.fold<int>(0, (a, r) => a + r.mwi.oldVoice);
    final urgent = mwi.fold<int>(0, (a, r) => a + r.mwi.newUrgent);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Text('tabActivity'.tr(), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
      ),
      SizedBox(
        height: 38,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          for (final f in _Filter.values)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Pill(
                label: switch (f) {
                  _Filter.all => 'filterAll'.tr(),
                  _Filter.missed => 'filterMissed'.tr(),
                  _Filter.recorded => 'filterRecorded'.tr(),
                  _Filter.messages => 'filterMessages'.tr(),
                },
                selected: _filter == f,
                onTap: () => setState(() => _filter = f),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 10),
      if (newVm > 0 || oldVm > 0)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ECard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: t.purpleSoft, borderRadius: BorderRadius.circular(12)),
                child: Icon(Icons.voicemail, color: t.purple),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('newVoicemails'.tr(namedArgs: {'n': '$newVm'}), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  Text('voicemailSub'.tr(namedArgs: {'u': '$urgent', 'o': '$oldVm'}), style: TextStyle(fontSize: 12, color: t.text2)),
                ]),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: t.purple, foregroundColor: Colors.white, shape: const StadiumBorder()),
                onPressed: () {
                  final rt = mwi.first;
                  placeCall(context, ref, rt.cfg.voicemail, accountId: rt.cfg.id, name: 'voicemail'.tr());
                },
                child: Text('listen'.tr()),
              ),
            ]),
          ),
        ),
      Expanded(
        child: _filter == _Filter.messages
            ? FutureBuilder<List<ChatMessage>>(
                future: db.conversations(),
                builder: (_, s) => _ConversationList(items: s.data ?? const []),
              )
            : FutureBuilder<List<CallRecord>>(
                future: db.calls(),
                builder: (_, s) {
                  var items = s.data ?? const <CallRecord>[];
                  if (_filter == _Filter.missed) items = items.where((c) => c.result == CallResult.missed).toList();
                  if (_filter == _Filter.recorded) items = items.where((c) => c.recordingPath.isNotEmpty).toList();
                  return _CallList(items: items);
                },
              ),
      ),
    ]);
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

class _CallList extends ConsumerWidget {
  const _CallList({required this.items});
  final List<CallRecord> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    if (items.isEmpty) {
      return Center(child: Text('noActivity'.tr(), style: TextStyle(color: t.text2)));
    }
    final rows = <Widget>[];
    String? lastDay;
    for (final c in items) {
      final day = _dayLabel(c.startedAt);
      if (day != lastDay) {
        rows.add(SectionLabel(day));
        lastDay = day;
      }
      rows.add(_CallRow(c));
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: rows);
  }
}

class _CallRow extends ConsumerWidget {
  const _CallRow(this.c);
  final CallRecord c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final missed = c.result == CallResult.missed;
    final (icon, fg, bg) = c.recordingPath.isNotEmpty
        ? (Icons.fiber_manual_record, t.warn, t.warnSoft)
        : switch (c.result) {
            CallResult.missed => (Icons.call_missed, t.missed, t.dangerSoft),
            CallResult.failed => (Icons.error_outline, t.danger, t.dangerSoft),
            _ => c.direction == CallDirection.incoming
                ? (Icons.call_received, t.success, t.successSoft)
                : (Icons.call_made, t.text2, t.surface2),
          };
    final meta = <String>[
      switch (c.result) {
        CallResult.missed => 'missed'.tr(),
        CallResult.declined => 'declined'.tr(),
        CallResult.failed => 'failed'.tr(),
        _ => c.durationSec > 0 ? _duration(c.durationSec) : (c.direction == CallDirection.incoming ? 'incoming'.tr() : 'outgoing'.tr()),
      },
      '${'via'.tr()} ${c.accountName}',
    ].join(' · ');
    final level = callQualityLevel(mos: c.mos, rttMs: c.rttMs, jitterMs: c.jitterMs, lossPct: c.lossPct);
    final poor = c.hasQos && level <= 2;
    final tech = !c.hasQos
        ? ''
        : '${c.mos != null ? 'MOS ${c.mos!.toStringAsFixed(1)} · ' : ''}${c.codec} · ${c.transport}${poor ? ' · ${'poorLine'.tr()}' : ''}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ECard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        onTap: () => _showDetail(context, ref, c),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, size: 18, color: fg),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: missed ? t.missed : t.text)),
              Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.text2)),
              if (tech.isNotEmpty) Text(tech, style: mono(context, color: poor ? t.warn : t.text2)),
            ]),
          ),
          if (c.recordingPath.isNotEmpty)
            IconButton(
              tooltip: 'play'.tr(),
              icon: Icon(Icons.play_circle_fill, color: t.warn, size: 30),
              onPressed: () => _showDetail(context, ref, c, play: true),
            ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(DateFormat.Hm().format(c.startedAt), style: TextStyle(fontSize: 12, color: t.text2)),
            if (c.hasQos) ...[
              const SizedBox(height: 6),
              QualityBars(mos: c.mos, rttMs: c.rttMs, jitterMs: c.jitterMs, lossPct: c.lossPct, barWidth: 3),
            ],
          ]),
          const SizedBox(width: 6),
          RoundIcon(
            icon: Icons.call,
            size: 38,
            tooltip: 'call'.tr(),
            bg: t.successSoft,
            color: t.success,
            onTap: () => placeCall(context, ref, c.number, accountId: c.accountId, name: c.name),
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
  const _ConversationList({required this.items});
  final List<ChatMessage> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final contacts = ref.watch(contactsProvider);
    return Stack(children: [
      if (items.isEmpty)
        Center(child: Text('noMessages'.tr(), style: TextStyle(color: t.text2)))
      else
        ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, i) {
            final m = items[i];
            final name = ref.read(sipProvider).nameFor(m.peer);
            final title = name.isNotEmpty ? name : (contacts.nameFor(m.peer).isNotEmpty ? contacts.nameFor(m.peer) : m.peer);
            return ECard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(peer: m.peer, title: title))),
              child: Row(children: [
                Avatar(title, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: TextStyle(fontWeight: m.read || m.outgoing ? FontWeight.w600 : FontWeight.w800)),
                    Text(m.body, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: t.text2)),
                  ]),
                ),
                Text(DateFormat.Hm().format(m.at), style: TextStyle(fontSize: 12, color: t.text2)),
              ]),
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
      if (c.recordingPath.isNotEmpty) ('infoRecording'.tr(), c.recordingPath),
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
