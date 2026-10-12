import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MyStatus { available, silent, dnd }

/// A colleague whose presence the Team tab watches (SUBSCRIBE).
class Watched {
  const Watched({required this.name, required this.ext});
  final String name;
  final String ext;

  Map<String, dynamic> toJson() => {'name': name, 'ext': ext};
  factory Watched.fromJson(Map<String, dynamic> j) =>
      Watched(name: j['name'] as String? ?? '', ext: j['ext'] as String? ?? '');
}

/// "Numbers matching [pattern] go out through [accountId]". The pattern uses
/// X for any digit, e.g. `0XXXXXXXXXX`, or a plain prefix like `1`.
class DialRule {
  const DialRule({required this.pattern, required this.accountId});
  final String pattern;
  final String accountId;

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

  Map<String, dynamic> toJson() => {'pattern': pattern, 'accountId': accountId};
  factory DialRule.fromJson(Map<String, dynamic> j) =>
      DialRule(pattern: j['pattern'] as String? ?? '', accountId: j['accountId'] as String? ?? '');
}

class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static Future<AppSettings> load() async => AppSettings._(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  String _s(String k, String d) => _prefs.getString(k) ?? d;
  bool _b(String k, bool d) => _prefs.getBool(k) ?? d;

  Future<void> _set(String k, Object v) async {
    switch (v) {
      case final bool b:
        await _prefs.setBool(k, b);
      case final int i:
        await _prefs.setInt(k, i);
      case final String s:
        await _prefs.setString(k, s);
    }
    notifyListeners();
  }

  // Appearance
  String get themeMode => _s('theme', 'system'); // system | light | dark
  set themeMode(String v) => _set('theme', v);

  // Reachability
  bool get keepAlive => _b('keepAlive', true);
  set keepAlive(bool v) => _set('keepAlive', v);

  // Your status
  MyStatus get status => MyStatus.values.byName(_s('status', 'available'));
  set status(MyStatus v) => _set('status', v.name);

  bool get officeHours => _b('officeHours', false);
  set officeHours(bool v) => _set('officeHours', v);
  List<int> get officeDays =>
      (_s('officeDays', '7,1,2,3,4')).split(',').where((e) => e.isNotEmpty).map(int.parse).toList();
  set officeDays(List<int> v) => _set('officeDays', v.join(','));
  String get officeStart => _s('officeStart', '09:00');
  set officeStart(String v) => _set('officeStart', v);
  String get officeEnd => _s('officeEnd', '17:00');
  set officeEnd(String v) => _set('officeEnd', v);
  bool get letFavourites => _b('letFavourites', true);
  set letFavourites(bool v) => _set('letFavourites', v);
  bool get letRepeat => _b('letRepeat', true);
  set letRepeat(bool v) => _set('letRepeat', v);

  /// The status in force now: Do not disturb outside office hours when that
  /// switch is on, otherwise the one the user picked.
  MyStatus effectiveStatus([DateTime? now]) {
    if (!officeHours) return status;
    final n = now ?? DateTime.now();
    final inDay = officeDays.contains(n.weekday);
    int mins(String hhmm) {
      final p = hhmm.split(':');
      return int.parse(p[0]) * 60 + int.parse(p[1]);
    }

    final m = n.hour * 60 + n.minute;
    final inHours = m >= mins(officeStart) && m < mins(officeEnd);
    return (inDay && inHours) ? status : MyStatus.dnd;
  }

  // Ringing
  /// system (the phone's own ringtone) | classic | soft | custom
  String get ringtoneId => _s('ringtone', 'system');
  set ringtoneId(String v) => _set('ringtone', v);
  String get customRingtonePath => _s('customRingtone', '');
  set customRingtonePath(String v) => _set('customRingtone', v);
  bool get vibrate => _b('vibrate', true);
  set vibrate(bool v) => _set('vibrate', v);
  bool get ringback => _b('ringback', true);
  set ringback(bool v) => _set('ringback', v);

  // Calls
  bool get autoAnswer => _b('autoAnswer', false);
  set autoAnswer(bool v) => _set('autoAnswer', v);
  int get autoAnswerDelay => _prefs.getInt('autoAnswerDelay') ?? 3;
  set autoAnswerDelay(int v) => _set('autoAnswerDelay', v);
  bool get showCallQuality => _b('showCallQuality', true);
  set showCallQuality(bool v) => _set('showCallQuality', v);
  Set<String> get blocked => (jsonDecode(_s('blocked', '[]')) as List).cast<String>().toSet();
  set blocked(Set<String> v) => _set('blocked', jsonEncode(v.toList()));

  // Network (applies to every account)
  /// Extra STUN / TURN servers: [{url, user, pass}].
  List<Map<String, String>> get iceServers => (jsonDecode(_s('iceServers', '[]')) as List)
      .map((e) => Map<String, String>.from(e as Map))
      .toList();
  set iceServers(List<Map<String, String>> v) => _set('iceServers', jsonEncode(v));
  /// Media only through TURN (ICE relay policy): for networks that block P2P.
  bool get forceRelay => _b('forceRelay', false);
  set forceRelay(bool v) => _set('forceRelay', v);
  int get regExpires => _prefs.getInt('regExpires') ?? 300;
  set regExpires(int v) => _set('regExpires', v);
  int get keepaliveSec => _prefs.getInt('keepaliveSec') ?? 30;
  set keepaliveSec(int v) => _set('keepaliveSec', v);

  // Audio
  /// auto (the stack's adaptive defaults) | low (20–150 ms) | robust (60–500 ms)
  String get jitterMode => _s('jitterMode', 'auto');
  set jitterMode(String v) => _set('jitterMode', v);
  int get aecMode => _prefs.getInt('aecMode') ?? 2; // 0 off, 1 suppressor, 2 webrtc
  set aecMode(int v) => _set('aecMode', v);
  bool get noiseSuppression => _b('ns', true);
  set noiseSuppression(bool v) => _set('ns', v);
  bool get autoGain => _b('agc', true);
  set autoGain(bool v) => _set('agc', v);

  /// off: no Record button · manual: the button · always: every call on an
  /// account with "Record calls" on starts recording once connected.
  String get recordingMode => _s('recordingMode', 'manual');
  set recordingMode(String v) => _set('recordingMode', v);

  // Diagnostics
  bool get debugLogging => _b('debugLogging', false);
  set debugLogging(bool v) => _set('debugLogging', v);
  bool get traceSip => _b('traceSip', true);
  set traceSip(bool v) => _set('traceSip', v);

  // Team
  List<Watched> get watched => (jsonDecode(_s('watched', '[]')) as List)
      .map((e) => Watched.fromJson(e as Map<String, dynamic>))
      .toList();
  set watched(List<Watched> v) => _set('watched', jsonEncode(v.map((e) => e.toJson()).toList()));

  Set<String> get favourites => (jsonDecode(_s('favourites', '[]')) as List).cast<String>().toSet();
  set favourites(Set<String> v) => _set('favourites', jsonEncode(v.toList()));

  // Which account places a call
  List<DialRule> get dialRules => (jsonDecode(_s('dialRules', '[]')) as List)
      .map((e) => DialRule.fromJson(e as Map<String, dynamic>))
      .toList();
  set dialRules(List<DialRule> v) => _set('dialRules', jsonEncode(v.map((e) => e.toJson()).toList()));

  /// Missed calls after this count toward the Activity badge.
  DateTime get activitySeenAt =>
      DateTime.fromMillisecondsSinceEpoch(_prefs.getInt('activitySeen') ?? DateTime.now().millisecondsSinceEpoch);
  set activitySeenAt(DateTime v) => _set('activitySeen', v.millisecondsSinceEpoch);

  bool get onboarded => _b('onboarded', false);
  set onboarded(bool v) => _set('onboarded', v);
}
