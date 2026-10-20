import 'package:medut/medut.dart' show IceServer;

/// "Numbers matching [pattern] go out through [accountId]": X is any digit, else a prefix.
class DialRule {
  const DialRule(this.pattern, this.accountId);
  final String pattern, accountId;

  bool matches(String number) {
    final n = number.replaceAll(RegExp(r'[\s\-()]'), '');
    if (!pattern.contains('X')) return n.startsWith(pattern);
    if (n.length != pattern.length) return false;
    for (var i = 0; i < n.length; i++) {
      final p = pattern[i];
      if (p == 'X') {
        if (!RegExp(r'\d').hasMatch(n[i])) return false;
      } else if (p != n[i]) {
        return false;
      }
    }
    return true;
  }
}

/// The app settings the desktop engine works from, as Dart pushes them
/// (`setConfig`, SipService.nativeConfig). Keys and defaults are those of
/// EngineConfig.kt: keep the two the same.
class EngineConfig {
  const EngineConfig(this._j);
  final Map<String, Object?> _j;

  String _s(String k, String d) => _j[k] is String ? _j[k] as String : d;
  bool _b(String k, bool d) => _j[k] is bool ? _j[k] as bool : d;
  int _i(String k, int d) => _j[k] is num ? (_j[k] as num).toInt() : d;
  List<String> _strings(String k) => [for (final v in _j[k] as List? ?? const []) '$v'];

  Map<String, Object?> get _labels => Map<String, Object?>.from(_j['labels'] as Map? ?? const {});

  /// Translated text from Dart's string table, with `{name}` placeholders filled in.
  String label(String key, String fallback, [Map<String, String> args = const {}]) {
    var t = _labels[key] as String? ?? '';
    if (t.isEmpty) t = fallback;
    for (final e in args.entries) {
      t = t.replaceAll('{${e.key}}', e.value);
    }
    return t;
  }

  bool get dark => _b('dark', false);
  bool get rtl => _b('rtl', false);

  // Audio and network (every account)
  List<String> get codecs {
    final c = _strings('codecs');
    return c.isEmpty ? const ['alaw', 'ulaw', 'opus'] : c;
  }

  String get jitterMode => _s('jitterMode', 'auto');
  int get aecMode => _i('aecMode', 2);
  bool get noiseSuppression => _b('ns', true);
  bool get autoGain => _b('agc', true);
  bool get forceRelay => _b('forceRelay', false);
  int get regExpires => _i('regExpires', 300);
  int get keepaliveSec => _i('keepaliveSec', 30);
  bool get debugLogging => _b('debugLogging', false);
  bool get traceSip => _b('traceSip', true);

  List<IceServer> get iceServers => [
        for (final o in (_j['iceServers'] as List? ?? const []).whereType<Map>())
          if ('${o['url'] ?? ''}'.trim() case final url when url.isNotEmpty)
            IceServer(url, user: _opt(o['user']), pass: _opt(o['pass'])),
      ];

  static String? _opt(Object? v) {
    final s = '${v ?? ''}'.trim();
    return s.isEmpty ? null : s;
  }

  // Ringing
  /// A file path, or "system" for the desktop's default sound.
  String get ringtone => _s('ringtone', 'system');
  bool get ringback => _b('ringback', true);

  // Desktop audio devices: '' = the system default.
  String get micDevice => _s('micDevice', '');
  String get speakerDevice => _s('speakerDevice', '');
  String get ringDevice => _s('ringDevice', '');

  // Calls
  bool get autoAnswer => _b('autoAnswer', false);
  int get autoAnswerDelay => _i('autoAnswerDelay', 3);
  bool get showCallQuality => _b('showCallQuality', true);
  Set<String> get blocked => _strings('blocked').toSet();

  // Your status
  String get status => _s('status', 'available');
  bool get officeHours => _b('officeHours', false);
  List<int> get officeDays =>
      [for (final d in _s('officeDays', '7,1,2,3,4').split(',')) ?int.tryParse(d.trim())];
  String get officeStart => _s('officeStart', '09:00');
  String get officeEnd => _s('officeEnd', '17:00');
  bool get letFavourites => _b('letFavourites', true);
  bool get letRepeat => _b('letRepeat', true);
  Set<String> get favourites => _strings('favourites').toSet();

  /// Colleagues on the Team list: (name, extension).
  List<(String, String)> get watched => [
        for (final o in (_j['watched'] as List? ?? const []).whereType<Map>()) ('${o['name'] ?? ''}', '${o['ext'] ?? ''}'),
      ];

  // Recording: off | manual | always, and the folder Dart resolved.
  String get recordingMode => _s('recordingMode', 'manual');
  String get recordingDir => _s('recordingDir', '');

  List<DialRule> get dialRules => [
        for (final o in (_j['dialRules'] as List? ?? const []).whereType<Map>())
          DialRule('${o['pattern'] ?? ''}', '${o['accountId'] ?? ''}'),
      ];

  /// Missed calls after this count toward the badge and the notification.
  DateTime get activitySeenAt => DateTime.fromMillisecondsSinceEpoch(_i('activitySeenAt', DateTime.now().millisecondsSinceEpoch));

  /// The status in force now: Do not disturb outside office hours when that
  /// switch is on, otherwise the one the user picked (AppSettings.effectiveStatus).
  String effectiveStatus([DateTime? at]) {
    if (!officeHours) return status;
    final now = at ?? DateTime.now();
    int mins(String hhmm) {
      final p = hhmm.split(':');
      return (int.tryParse(p.first) ?? 0) * 60 + (p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0);
    }

    final m = now.hour * 60 + now.minute;
    final inHours = m >= mins(officeStart) && m < mins(officeEnd);
    return officeDays.contains(now.weekday) && inHours ? status : 'dnd';
  }
}
