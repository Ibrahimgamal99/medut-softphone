import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

enum CallDirection { incoming, outgoing }

/// answered, missed (rang out unanswered), declined (by us), failed (could not be placed).
enum CallResult { answered, missed, declined, failed }

/// One call, everything known about it. Stored on the phone only.
class CallRecord {
  CallRecord({
    this.id,
    required this.accountId,
    required this.accountName,
    required this.number,
    required this.name,
    required this.direction,
    required this.result,
    required this.startedAt,
    this.answeredAt,
    this.endedAt,
    this.durationSec = 0,
    this.mos,
    this.mosMin,
    this.mosRx,
    this.rttMs,
    this.jitterMs,
    this.lossPct,
    this.packetsLost,
    this.codec = '',
    this.transport = '',
    this.encryption = '',
    this.icePath = '',
    this.remoteMedia = '',
    this.callId = '',
    this.remoteUri = '',
    this.localUri = '',
    this.setupMs,
    this.endReason = '',
    this.sipCode,
    this.endedBy = '',
    this.recordingPath = '',
    this.recordingSec,
  });

  final int? id;
  final String accountId, accountName, number, name;
  final CallDirection direction;
  final CallResult result;

  /// When it started ringing / dialling, was answered, and ended.
  final DateTime startedAt;
  final DateTime? answeredAt, endedAt;

  /// Talk time, from answer to hang-up.
  final int durationSec;

  /// MOS average and lowest (what you heard), and what the other side heard.
  final double? mos, mosMin, mosRx;

  /// Averages over the call, for the quality grade in the history.
  final double? rttMs, jitterMs, lossPct;
  final int? packetsLost;
  final String codec, transport, encryption, icePath, remoteMedia;

  // SIP
  final String callId, remoteUri, localUri;

  /// INVITE to answer (outgoing) / to ringing, as the SDK measured it.
  final int? setupMs;
  final String endReason;
  final int? sipCode;

  /// "local" when this phone hung up / declined, "remote" otherwise.
  final String endedBy;
  final String recordingPath;

  /// Length of the recording file, in seconds.
  final int? recordingSec;

  bool get hasQos => mos != null || rttMs != null || jitterMs != null || lossPct != null;
  String get title => name.isNotEmpty ? name : number;

  /// Ringing time before answer (or before giving up).
  int get ringSec => ((answeredAt ?? endedAt)?.difference(startedAt).inSeconds ?? 0).clamp(0, 1 << 30);

  /// From first ring / dial to the end.
  int get totalSec => (endedAt?.difference(startedAt).inSeconds ?? durationSec).clamp(0, 1 << 30);

  static int? _ms(DateTime? d) => d?.millisecondsSinceEpoch;
  static DateTime? _dt(Object? v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;

  Map<String, Object?> toRow() => {
        'account_id': accountId,
        'account_name': accountName,
        'number': number,
        'name': name,
        'direction': direction.name,
        'result': result.name,
        'started_at': startedAt.millisecondsSinceEpoch,
        'answered_at': _ms(answeredAt),
        'ended_at': _ms(endedAt),
        'duration': durationSec,
        'mos': mos,
        'mos_min': mosMin,
        'mos_rx': mosRx,
        'rtt': rttMs,
        'jitter': jitterMs,
        'loss': lossPct,
        'packets_lost': packetsLost,
        'codec': codec,
        'transport': transport,
        'encryption': encryption,
        'ice': icePath,
        'remote_media': remoteMedia,
        'call_id': callId,
        'remote_uri': remoteUri,
        'local_uri': localUri,
        'setup_ms': setupMs,
        'end_reason': endReason,
        'sip_code': sipCode,
        'ended_by': endedBy,
        'recording': recordingPath,
        'rec_seconds': recordingSec,
      };

  factory CallRecord.fromRow(Map<String, Object?> r) => CallRecord(
        id: r['id'] as int?,
        accountId: r['account_id'] as String? ?? '',
        accountName: r['account_name'] as String? ?? '',
        number: r['number'] as String? ?? '',
        name: r['name'] as String? ?? '',
        direction: CallDirection.values.byName(r['direction'] as String? ?? 'incoming'),
        result: CallResult.values.byName(r['result'] as String? ?? 'answered'),
        startedAt: _dt(r['started_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        answeredAt: _dt(r['answered_at']),
        endedAt: _dt(r['ended_at']),
        durationSec: r['duration'] as int? ?? 0,
        mos: (r['mos'] as num?)?.toDouble(),
        mosMin: (r['mos_min'] as num?)?.toDouble(),
        mosRx: (r['mos_rx'] as num?)?.toDouble(),
        rttMs: (r['rtt'] as num?)?.toDouble(),
        jitterMs: (r['jitter'] as num?)?.toDouble(),
        lossPct: (r['loss'] as num?)?.toDouble(),
        packetsLost: r['packets_lost'] as int?,
        codec: r['codec'] as String? ?? '',
        transport: r['transport'] as String? ?? '',
        encryption: r['encryption'] as String? ?? '',
        icePath: r['ice'] as String? ?? '',
        remoteMedia: r['remote_media'] as String? ?? '',
        callId: r['call_id'] as String? ?? '',
        remoteUri: r['remote_uri'] as String? ?? '',
        localUri: r['local_uri'] as String? ?? '',
        setupMs: r['setup_ms'] as int?,
        endReason: r['end_reason'] as String? ?? '',
        sipCode: r['sip_code'] as int?,
        endedBy: r['ended_by'] as String? ?? '',
        recordingPath: r['recording'] as String? ?? '',
        recordingSec: r['rec_seconds'] as int?,
      );

  static const csvHeader = [
    'started_at', 'answered_at', 'ended_at', 'direction', 'result', 'number', 'name', 'account',
    'talk_seconds', 'ring_seconds', 'total_seconds', 'mos', 'mos_min', 'mos_they_heard', 'rtt_ms',
    'jitter_ms', 'loss_pct', 'packets_lost', 'codec', 'transport', 'encryption', 'ice', 'remote_media',
    'call_id', 'remote_uri', 'local_uri', 'setup_ms', 'sip_code', 'end_reason', 'ended_by', 'recording', 'recording_seconds',
  ];

  List<Object?> toCsv() => [
        startedAt.toIso8601String(), answeredAt?.toIso8601String(), endedAt?.toIso8601String(),
        direction.name, result.name, number, name, accountName, durationSec, ringSec, totalSec,
        mos, mosMin, mosRx, rttMs, jitterMs, lossPct, packetsLost, codec, transport, encryption, icePath,
        remoteMedia, callId, remoteUri, localUri, setupMs, sipCode, endReason, endedBy, recordingPath,
        recordingSec,
      ];
}

class ChatMessage {
  ChatMessage({
    this.id,
    required this.accountId,
    required this.peer,
    required this.body,
    required this.outgoing,
    required this.at,
    this.read = false,
  });

  final int? id;
  final String accountId, peer, body;
  final bool outgoing, read;
  final DateTime at;

  Map<String, Object?> toRow() => {
        'account_id': accountId,
        'peer': peer,
        'body': body,
        'outgoing': outgoing ? 1 : 0,
        'at': at.millisecondsSinceEpoch,
        'read': read ? 1 : 0,
      };

  factory ChatMessage.fromRow(Map<String, Object?> r) => ChatMessage(
        id: r['id'] as int?,
        accountId: r['account_id'] as String? ?? '',
        peer: r['peer'] as String? ?? '',
        body: r['body'] as String? ?? '',
        outgoing: (r['outgoing'] as int? ?? 0) == 1,
        at: DateTime.fromMillisecondsSinceEpoch(r['at'] as int? ?? 0),
        read: (r['read'] as int? ?? 0) == 1,
      );
}

/// Columns added in schema v3: full call detail.
const _v3Columns = {
  'answered_at': 'INTEGER', 'ended_at': 'INTEGER', 'mos_min': 'REAL', 'mos_rx': 'REAL',
  'packets_lost': 'INTEGER', 'encryption': 'TEXT', 'ice': 'TEXT', 'remote_media': 'TEXT',
  'call_id': 'TEXT', 'remote_uri': 'TEXT', 'local_uri': 'TEXT', 'setup_ms': 'INTEGER',
  'end_reason': 'TEXT', 'sip_code': 'INTEGER', 'ended_by': 'TEXT',
};

/// Call history and SIP MESSAGE threads, on the device.
class LocalDb extends ChangeNotifier {
  LocalDb._(this._db);
  final Database _db;

  static Future<LocalDb> open() async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'medut.db'),
      version: 4,
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          for (final c in ['rtt', 'jitter', 'loss']) {
            await db.execute('ALTER TABLE calls ADD COLUMN $c REAL');
          }
        }
        if (from < 3) {
          for (final c in _v3Columns.entries) {
            await db.execute('ALTER TABLE calls ADD COLUMN ${c.key} ${c.value}');
          }
        }
        if (from < 4) await db.execute('ALTER TABLE calls ADD COLUMN rec_seconds INTEGER');
      },
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE calls(
          id INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT, account_name TEXT,
          number TEXT, name TEXT, direction TEXT, result TEXT, started_at INTEGER,
          duration INTEGER, mos REAL, rtt REAL, jitter REAL, loss REAL,
          codec TEXT, transport TEXT, recording TEXT,
          ${_v3Columns.entries.map((c) => '${c.key} ${c.value}').join(', ')}, rec_seconds INTEGER)''');
        await db.execute('''CREATE TABLE messages(
          id INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT, peer TEXT, body TEXT,
          outgoing INTEGER, at INTEGER, read INTEGER)''');
        await db.execute('CREATE INDEX calls_at ON calls(started_at DESC)');
        await db.execute('CREATE INDEX msg_peer ON messages(peer, at)');
      },
    );
    return LocalDb._(db);
  }

  Future<void> addCall(CallRecord r) async {
    await _db.insert('calls', r.toRow());
    notifyListeners();
  }

  Future<List<CallRecord>> calls({int limit = 300}) async =>
      (await _db.query('calls', orderBy: 'started_at DESC', limit: limit)).map(CallRecord.fromRow).toList();

  Future<int> missedSince(DateTime since) async {
    final r = await _db.rawQuery(
      "SELECT COUNT(*) c FROM calls WHERE result='missed' AND started_at > ?",
      [since.millisecondsSinceEpoch],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  /// Two calls from the same number within 3 minutes: "repeat caller".
  Future<bool> calledRecently(String number) async {
    final since = DateTime.now().subtract(const Duration(minutes: 3)).millisecondsSinceEpoch;
    final r = await _db.rawQuery(
      'SELECT COUNT(*) c FROM calls WHERE number = ? AND started_at > ?',
      [number, since],
    );
    return ((r.first['c'] as int?) ?? 0) > 0;
  }

  Future<void> clearCalls() async {
    await _db.delete('calls');
    notifyListeners();
  }

  Future<void> deleteCall(int id) async {
    await _db.delete('calls', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  Future<void> deleteCalls(List<int> ids) async {
    if (ids.isEmpty) return;
    await _db.delete('calls', where: 'id IN (${List.filled(ids.length, '?').join(',')})', whereArgs: ids);
    notifyListeners();
  }

  /// Puts deleted calls back as they were, ids and all (Undo).
  Future<void> restoreCalls(List<CallRecord> calls) async {
    final batch = _db.batch();
    for (final c in calls) {
      batch.insert('calls', {'id': c.id, ...c.toRow()}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    notifyListeners();
  }

  Future<void> addMessage(ChatMessage m) async {
    await _db.insert('messages', m.toRow());
    notifyListeners();
  }

  Future<List<ChatMessage>> thread(String peer) async =>
      (await _db.query('messages', where: 'peer = ?', whereArgs: [peer], orderBy: 'at ASC'))
          .map(ChatMessage.fromRow)
          .toList();

  /// Recent messages from every conversation, newest first.
  Future<List<ChatMessage>> messages({int limit = 300}) async =>
      (await _db.query('messages', orderBy: 'at DESC', limit: limit)).map(ChatMessage.fromRow).toList();

  /// The last message of each conversation, newest first.
  Future<List<ChatMessage>> conversations() async => (await _db.rawQuery('''
      SELECT m.* FROM messages m
      JOIN (SELECT peer, MAX(at) at FROM messages GROUP BY peer) l ON l.peer = m.peer AND l.at = m.at
      ORDER BY m.at DESC''')).map(ChatMessage.fromRow).toList();

  Future<void> markRead(String peer) async {
    await _db.update('messages', {'read': 1}, where: 'peer = ? AND read = 0', whereArgs: [peer]);
    notifyListeners();
  }

  Future<int> unreadCount() async {
    final r = await _db.rawQuery('SELECT COUNT(*) c FROM messages WHERE read = 0 AND outgoing = 0');
    return (r.first['c'] as int?) ?? 0;
  }
}
