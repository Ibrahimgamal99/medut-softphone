import 'dart:collection';

/// The two logs Settings shows: the connection log (registration, network,
/// SDK lines) and the SIP message trace, in memory, as EngineLog.kt keeps
/// them. Each line gets a sequence number so Flutter fetches only what it has
/// not seen.
class EngineLog {
  EngineLog._();

  static final _conn = _Ring(500);
  static final _sip = _Ring(400);

  static void conn(String line) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    _conn.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)}  $line');
  }

  static void sip(String entry) => _sip.add(entry);

  static _Ring _ring(String kind) => kind == 'sip' ? _sip : _conn;

  static int seq(String kind) => _ring(kind).seq;

  /// {seq, lines, reset}: reset when the caller must drop what it has.
  static Map<String, Object?> read(String kind, int since) {
    final r = _ring(kind);
    final reset = since <= 0 || since > r.seq || r.seq - since > r.lines.length;
    return {'seq': r.seq, 'lines': reset ? r.lines.toList() : r.after(since), 'reset': reset};
  }
}

class _Ring {
  _Ring(this.max);
  final int max;
  final lines = ListQueue<String>();
  int seq = 0; // lines ever added

  void add(String line) {
    lines.addLast(line);
    seq++;
    while (lines.length > max) {
      lines.removeFirst();
    }
  }

  /// Lines after [since], or all that are left when [since] is too old.
  List<String> after(int since) {
    final missing = (seq - since).clamp(0, 1 << 30);
    final all = lines.toList();
    return missing >= all.length ? all : all.sublist(all.length - missing);
  }
}
