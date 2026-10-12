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

  // Audio
  int get aecMode => _prefs.getInt('aecMode') ?? 2; // 0 off, 1 suppressor, 2 webrtc
  set aecMode(int v) => _set('aecMode', v);
  bool get noiseSuppression => _b('ns', true);
  set noiseSuppression(bool v) => _set('ns', v);
  bool get autoGain => _b('agc', true);
  set autoGain(bool v) => _set('agc', v);

  // Diagnostics
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
