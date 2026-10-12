import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

enum CallDirection { incoming, outgoing }

/// answered, missed (rang out unanswered), declined (by us), failed (could not be placed).
enum CallResult { answered, missed, declined, failed }

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
    this.durationSec = 0,
    this.mos,
    this.codec = '',
    this.transport = '',
    this.recordingPath = '',
  });

  final int? id;
  final String accountId, accountName, number, name;
  final CallDirection direction;
  final CallResult result;
  final DateTime startedAt;
  final int durationSec;
  final double? mos;
  final String codec, transport, recordingPath;

  String get title => name.isNotEmpty ? name : number;

  Map<String, Object?> toRow() => {
        'account_id': accountId,
        'account_name': accountName,
        'number': number,
        'name': name,
        'direction': direction.name,
        'result': result.name,
        'started_at': startedAt.millisecondsSinceEpoch,
        'duration': durationSec,
        'mos': mos,
        'codec': codec,
        'transport': transport,
        'recording': recordingPath,
      };

  factory CallRecord.fromRow(Map<String, Object?> r) => CallRecord(
        id: r['id'] as int?,
        accountId: r['account_id'] as String? ?? '',
        accountName: r['account_name'] as String? ?? '',
        number: r['number'] as String? ?? '',
        name: r['name'] as String? ?? '',
        direction: CallDirection.values.byName(r['direction'] as String? ?? 'incoming'),
        result: CallResult.values.byName(r['result'] as String? ?? 'answered'),
        startedAt: DateTime.fromMillisecondsSinceEpoch(r['started_at'] as int? ?? 0),
        durationSec: r['duration'] as int? ?? 0,
        mos: (r['mos'] as num?)?.toDouble(),
        codec: r['codec'] as String? ?? '',
        transport: r['transport'] as String? ?? '',
        recordingPath: r['recording'] as String? ?? '',
      );
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

/// Call history and SIP MESSAGE threads, on the device.
class LocalDb extends ChangeNotifier {
  LocalDb._(this._db);
  final Database _db;

  static Future<LocalDb> open() async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'medut.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE calls(
          id INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT, account_name TEXT,
          number TEXT, name TEXT, direction TEXT, result TEXT, started_at INTEGER,
          duration INTEGER, mos REAL, codec TEXT, transport TEXT, recording TEXT)''');
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

  Future<void> deleteCall(int id) async {
    await _db.delete('calls', where: 'id = ?', whereArgs: [id]);
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
