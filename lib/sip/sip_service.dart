import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/accounts.dart';
import '../core/db.dart';
import '../core/people.dart';
import '../core/settings.dart';
import 'native_bridge.dart';
import 'probe.dart';
import 'tones.dart';

enum RegStatus { off, registering, registered, reconnecting, failed }

enum Phase { incoming, outgoing, active, held }

/// Someone's SIP presence (BLF), as the native engine reports it.
enum PresenceStatus { unknown, open, closed, busy }

class MwiInfo {
  const MwiInfo({this.newVoice = 0, this.oldVoice = 0, this.newUrgent = 0});
  final int newVoice, oldVoice, newUrgent;
}

/// How a [SipService.tryRegister] attempt ended.
class RegProbe {
  const RegProbe(this.status, {this.sipCode = 0, this.error = ''});

  /// [RegStatus.registering] means no answer before the timeout.
  final RegStatus status;
  final int sipCode;
  final String error;

  bool get ok => status == RegStatus.registered;
  bool get badPassword => sipCode == 401 || sipCode == 403;
}

/// A configured account and how its registration is doing (native's view).
class AccountRuntime {
  AccountRuntime(this.cfg, this.signature);
  SipAccountConfig cfg;
  final String signature;
  RegStatus status = RegStatus.registering;
  String error = '';
  int retryInMs = 0;
  int sipCode = 0;
  MwiInfo mwi = const MwiInfo();
}

/// A call the native engine has up, as far as the Flutter tabs need it.
class ActiveCall {
  ActiveCall({
    required this.id,
    required this.runtime,
    required this.number,
    required this.name,
    required this.phase,
    this.answeredAt,
  });

  final String id;
  final AccountRuntime runtime;
  final String number, name;
  final Phase phase;
  final DateTime? answeredAt;

  String get title => name.isNotEmpty ? name : number;
}

/// Flutter's side of the phone. The native engine (PhoneEngine.kt /
/// PhoneEngine.swift) owns SIP, every call and the call screens, and runs
/// with or without this UI; this mirrors what it reports for the tabs, hands
/// it accounts and settings, and forwards what the user does here (dial,
/// message, status).
class SipService extends ChangeNotifier with WidgetsBindingObserver {
  SipService({required this.store, required this.settings, required this.db});

  final AccountStore store;
  final AppSettings settings;
  final LocalDb db;
  final _bridge = NativeBridge.instance;

  /// Wired by the app shell: translations, theme, contact names.
  String Function(String key) tr = (k) => k;
  bool Function() isDark = () => false;
  bool Function() isRtl = () => false;
  String Function(String number) nameFor = (_) => '';

  /// Every number in the phone's contacts (extensions among them get presence).
  Iterable<String> Function() contactNumbers = () => const [];

  final Map<String, AccountRuntime> runtimes = {};
  final List<ActiveCall> calls = [];
  ActiveCall? focused;
  final Map<String, PresenceStatus> presence = {};

  /// The SIP message trace and the connection log (Settings → Diagnostics).
  final List<String> sipLog = [];
  final List<String> connLog = [];
  int _sipSeq = 0, _connSeq = 0;

  final _notices = StreamController<String>.broadcast();
  Stream<String> get notices => _notices.stream;

  /// The SDK's version, '' until the engine reports it.
  String sdkVersion = '';
  bool _started = false;
  Timer? _configDebounce;
  Timer? _presenceDebounce;

  /// The extensions whose presence is followed (see [presenceTargets]).
  List<String> presenceList = const [];

  bool get started => _started;
  bool get hasCall => calls.isNotEmpty;

  // ── Start-up ──────────────────────────────────────────────────────────────

  Future<void> start() async {
    if (_started) return;
    _started = true;
    // "Available" used to mean in the queue; whoever is logged in is Ready now.
    if (settings.status == MyStatus.available && settings.queueIn.isNotEmpty) settings.status = MyStatus.ready;
    WidgetsBinding.instance.addObserver(this);
    _bridge.states.listen(_onState);
    _bridge.historyChanges.listen((_) => db.changed());
    _bridge.notices.listen(_notices.add);

    await pushConfig();
    final state = await _bridge.ready();
    if (state != null) _onState(state);
    store.addListener(syncPresence);
    settings.addListener(_onSettings);
    db.addListener(syncPresence); // a new call can bring a new extension
    syncPresence();
  }

  void _onSettings() {
    _configDebounce?.cancel();
    _configDebounce = Timer(const Duration(milliseconds: 250), pushConfig);
    syncPresence();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshLogs());
  }

  /// Translated text the call screens and notifications show, so native and
  /// Flutter share one string table.
  static const _labelKeys = [
    'incomingOn', 'incomingCall', 'answer', 'decline', 'busy', 'message', 'mute', 'unmute', 'keypad',
    'speaker', 'earpiece', 'bluetooth', 'headset', 'hold', 'resume', 'addCall', 'transfer', 'record',
    'stopRecord', 'hide', 'onHold', 'swap', 'callDetails', 'audioOutput', 'cancel', 'complete',
    'more', 'callQuality', 'youHear', 'theyHear', 'encrypted', 'recShort', 'call',
    // Status lines and the warm-transfer bar
    'transferring', 'ringing', 'calling', 'reconnecting', 'poorConnection', 'recordingNow',
    'xferConnectedTo', 'xferCalling', 'xferHintTalking', 'xferHintCalling', 'xferJoin', 'xferBack',
    // The quality pill and sheet
    'signalExcellent', 'signalGood', 'signalFair', 'signalPoor', 'signalChecking',
    'qJitter', 'qLoss', 'qRtt', 'qCodec', 'qSrtp', 'qIce', 'qJbuf', 'connection', 'encNone',
    // Transfer and Add call pickers
    'transferWho', 'transferTo', 'blindTransfer', 'blindTransferSub', 'warmTransfer', 'warmTransferSub',
    'addCallTitle', 'presenceOpen', 'presenceBusy', 'presenceClosed', 'presenceUnknown',
    // Notifications and notices
    'appName', 'keepAliveConnecting', 'keepAliveOn', 'missedCall', 'missedCalls',
    'noAccount', 'twoCallsMax', 'callFailed', 'transferFailed',
    'code_dndOn', 'code_dndOff', 'code_queueLogin', 'code_queueLogout',
  ];

  /// What the native engine needs from Settings, kept by it across restarts
  /// so a call that rings with no Flutter up follows the same rules.
  Future<Map<String, Object?>> nativeConfig() async {
    final s = settings;
    return {
      // Before the translations have loaded, tr() hands the key back:
      // native keeps its own English until the real text arrives.
      'labels': {
        for (final k in _labelKeys)
          if (tr(k) case final t when t != k) k: t,
      },
      'dark': isDark(),
      'rtl': isRtl(),
      'codecs': s.codecs,
      'jitterMode': s.jitterMode,
      'aecMode': s.aecMode,
      'ns': s.noiseSuppression,
      'agc': s.autoGain,
      'iceServers': s.iceServers,
      'forceRelay': s.forceRelay,
      'regExpires': s.regExpires,
      'keepaliveSec': s.keepaliveSec,
      'debugLogging': s.debugLogging,
      'traceSip': s.traceSip,
      'ringtone': await _orElse(() => Tones.nativeSource(s.ringtoneId, s.customRingtonePath), 'system'),
      'vibrate': s.vibrate,
      'ringback': s.ringback,
      'autoAnswer': s.autoAnswer,
      'autoAnswerDelay': s.autoAnswerDelay,
      'showCallQuality': s.showCallQuality,
      'blocked': s.blocked.toList(),
      'keepAlive': s.keepAlive,
      'status': s.status.name,
      'officeHours': s.officeHours,
      'officeDays': s.officeDays.join(','),
      'officeStart': s.officeStart,
      'officeEnd': s.officeEnd,
      'letFavourites': s.letFavourites,
      'letRepeat': s.letRepeat,
      'favourites': s.favourites.toList(),
      'watched': [for (final w in s.watched) w.toJson()],
      'recordingMode': s.recordingMode,
      'recordingDir': await _orElse(() async => (await recordingsDir(s)).path, ''),
      'dialRules': [for (final r in s.dialRules) r.toJson()],
      'activitySeenAt': s.activitySeenAt.millisecondsSinceEpoch,
    };
  }

  Future<void> pushConfig() async => _bridge.setConfig(await nativeConfig());

  /// A file-system answer, or [fallback] where there is no file system (tests).
  static Future<T> _orElse<T>(Future<T> Function() f, T fallback) async {
    try {
      return await f();
    } catch (_) {
      return fallback;
    }
  }

  /// Re-send the settings (theme or language changed).
  void refreshNative() => unawaited(pushConfig());

  // ── Native state ──────────────────────────────────────────────────────────

  static RegStatus _reg(String? s) => switch (s) {
        'registered' => RegStatus.registered,
        'registering' => RegStatus.registering,
        'reconnecting' => RegStatus.reconnecting,
        'failed' => RegStatus.failed,
        _ => RegStatus.off,
      };

  static Phase _phase(String? s) => switch (s) {
        'incoming' => Phase.incoming,
        'outgoing' => Phase.outgoing,
        'held' => Phase.held,
        _ => Phase.active,
      };

  void _onState(Map<String, dynamic> st) {
    final accounts = Map<String, dynamic>.from(st['accounts'] as Map? ?? const {});
    runtimes.removeWhere((id, _) => !accounts.containsKey(id));
    for (final e in accounts.entries) {
      final a = Map<String, dynamic>.from(e.value as Map);
      final cfg = store.byId(e.key) ?? _probes[e.key];
      if (cfg == null) continue;
      final rt = runtimes.putIfAbsent(e.key, () => AccountRuntime(cfg, ''))..cfg = cfg;
      rt
        ..status = _reg(a['status'] as String?)
        ..error = a['error'] as String? ?? ''
        ..sipCode = (a['sipCode'] as num?)?.toInt() ?? 0
        ..retryInMs = (a['retryInMs'] as num?)?.toInt() ?? 0
        ..mwi = MwiInfo(
          newVoice: (a['mwiNew'] as num?)?.toInt() ?? 0,
          oldVoice: (a['mwiOld'] as num?)?.toInt() ?? 0,
          newUrgent: (a['mwiUrgent'] as num?)?.toInt() ?? 0,
        );
    }
    calls
      ..clear()
      ..addAll([
        for (final c in (st['calls'] as List? ?? const []).cast<Map<dynamic, dynamic>>())
          if (runtimes[c['accountId']] case final rt?)
            ActiveCall(
              id: c['id'] as String? ?? '',
              runtime: rt,
              number: c['number'] as String? ?? '',
              name: c['name'] as String? ?? '',
              phase: _phase(c['phase'] as String?),
              answeredAt: (c['answeredAt'] as num?) == null || (c['answeredAt'] as num) <= 0
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch((c['answeredAt'] as num).toInt()),
            ),
      ]);
    final f = st['focused'] as String?;
    focused = calls.where((c) => c.id == f).firstOrNull ?? calls.firstOrNull;
    presence
      ..clear()
      ..addAll({
        for (final e in Map<String, dynamic>.from(st['presence'] as Map? ?? const {}).entries)
          e.key: PresenceStatus.values.asNameMap()[e.value] ?? PresenceStatus.unknown,
      });
    sdkVersion = st['version'] as String? ?? sdkVersion;
    final connSeq = (st['connSeq'] as num?)?.toInt() ?? 0;
    final sipSeq = (st['sipSeq'] as num?)?.toInt() ?? 0;
    if (connSeq != _connSeq || sipSeq != _sipSeq) unawaited(_refreshLogs());
    notifyListeners();
  }

  /// Fetches the log lines native has added since the last fetch.
  Future<void> _refreshLogs() async {
    for (final (kind, list) in [('conn', connLog), ('sip', sipLog)]) {
      final since = kind == 'conn' ? _connSeq : _sipSeq;
      final r = await _bridge.getLog(kind, since);
      if (r == null) continue;
      if (r['reset'] == true) list.clear();
      list.addAll((r['lines'] as List? ?? const []).cast<String>());
      final seq = (r['seq'] as num?)?.toInt() ?? since;
      if (kind == 'conn') {
        _connSeq = seq;
      } else {
        _sipSeq = seq;
      }
    }
    notifyListeners();
  }

  // ── Accounts ──────────────────────────────────────────────────────────────

  /// Accounts being tried by [tryRegister]: registered but not saved yet.
  final Map<String, SipAccountConfig> _probes = {};

  /// Hands native the saved accounts again (after an edit was cancelled).
  Future<void> applyAccounts() => store.sync();

  /// Registers [c] without saving it, to see whether it works: sign-in tries
  /// TLS, TCP and UDP this way. A registration that succeeds keeps running,
  /// so saving the same config afterwards adopts it rather than registering
  /// twice. Anything else is torn down.
  Future<RegProbe> tryRegister(SipAccountConfig c, {Duration timeout = const Duration(seconds: 8)}) async {
    _probes[c.id] = c;
    final r = await _bridge.tryRegister(AccountStore.withSecrets(c), timeout.inMilliseconds);
    if (r == null) {
      _probes.remove(c.id);
      return const RegProbe(RegStatus.failed);
    }
    // "registering" when the time ran out: no answer on this transport.
    final result = RegProbe(
      _reg(r['status'] as String?),
      sipCode: (r['sipCode'] as num?)?.toInt() ?? 0,
      error: r['error'] as String? ?? '',
    );
    if (!result.ok) _probes.remove(c.id);
    await _refreshLogs();
    return result;
  }

  /// Checks how [host] can be reached (TLS, TCP, UDP, web link) without
  /// signing in: see probe.dart.
  Future<ProbeReport> probe(String host, {int port = 0, ProbeListener? onStep}) =>
      probeServer(host, port: port, onStep: onStep);

  /// Drops a tried account that was not saved (failed, or the user left).
  void cancelProbe(String id) {
    if (_probes.remove(id) == null || store.byId(id) != null) return;
    unawaited(_bridge.cancelProbe(id));
  }

  void retryNow(String id) => unawaited(_bridge.retry(id));

  // ── Presence ──────────────────────────────────────────────────────────────

  /// Recomputes [presenceList] and has native follow it on the default
  /// account: favourites, hand-added extensions, and the most recent ones
  /// from calls and contacts.
  void syncPresence() {
    _presenceDebounce?.cancel();
    _presenceDebounce = Timer(const Duration(milliseconds: 400), _syncSubscriptions);
  }

  Future<void> _syncSubscriptions() async {
    final recent = (await db.calls(limit: 300)).map((c) => c.number);
    final targets = presenceTargets(
      favourites: settings.favourites,
      watched: settings.watched.map((w) => w.ext),
      recent: recent,
      contacts: contactNumbers(),
      hidden: settings.hiddenExts,
    );
    if (!listEquals(targets, presenceList)) {
      presenceList = targets;
      notifyListeners();
    }
    await _bridge.setPresenceTargets(targets);
  }

  // ── Your status and the PBX feature codes behind it ───────────────────────

  /// Picks Available, Ready or Do not disturb, and tells each registered
  /// account's PBX with its feature codes: Available = out of the queues
  /// (calls to your extension still ring), Ready = queue log-in, Do not
  /// disturb = DND on + queue log-out; DND off is dialed when leaving Do not
  /// disturb. Native dials the codes as ordinary calls, one after the other,
  /// so the PBX's announcement is heard; a queue code is only dialed to
  /// change state (FreePBX's *45 is a toggle).
  void setMyStatus(MyStatus next) {
    final prev = settings.status;
    if (prev == next) return;
    settings.status = next;
    settings.statusSince = DateTime.now();
    final codes = <(String, String, String)>[];
    for (final rt in runtimes.values) {
      if (rt.status != RegStatus.registered || !store.accounts.any((a) => a.id == rt.cfg.id)) continue;
      final c = rt.cfg;
      final inQueue = settings.queueIn.contains(c.id);
      final fromDnd = prev == MyStatus.dnd;
      final keys = switch (next) {
        MyStatus.available => [if (fromDnd) 'dndOff', if (inQueue) 'queueLogout'],
        MyStatus.ready => [if (fromDnd) 'dndOff', if (!inQueue) 'queueLogin'],
        MyStatus.dnd => ['dndOn', if (inQueue) 'queueLogout'],
      };
      for (final k in keys) {
        final code = c.code(k);
        if (code.isEmpty) continue;
        codes.add((c.id, k, code));
        if (k == 'queueLogin') settings.setQueueIn(c.id, true);
        if (k == 'queueLogout') settings.setQueueIn(c.id, false);
      }
    }
    unawaited(pushConfig().then((_) => dialCodes(codes)));
  }

  /// Hands the feature codes to native, which dials them once no call is up.
  Future<void> dialCodes(List<(String, String, String)> codes) =>
      _bridge.queueCodes([for (final (id, key, code) in codes) {'accountId': id, 'key': key, 'code': code}]);

  // ── Calls and messages ────────────────────────────────────────────────────

  /// Places a call; native puts an active call on hold first ("Add call")
  /// and shows the call screen.
  void dial(String input, {String? accountId, String? name}) =>
      unawaited(_bridge.dial(input, accountId: accountId, name: name));

  /// Opens the native call screen for the call that is up.
  void openCallScreen() => unawaited(_bridge.openCallScreen());

  Future<void> sendMessage(String peer, String body, {String? accountId}) async {
    final error = await _bridge.sendMessage(peer, body, accountId: accountId);
    if (error != null) _notices.add(error);
  }

  /// The user looked at Activity: the missed-call notification goes away.
  void missedSeen() {
    unawaited(_bridge.missedSeen());
    _onSettings(); // activitySeenAt changed
  }

  // ── Helpers shared with the screens ───────────────────────────────────────

  /// Fixes the sizes in a WAV header written when recording started (data
  /// size 0) but never finished, so players see the audio: the SDK closes a
  /// recording without finishing it when the call ends under it.
  static Future<void> repairWav(String path) async {
    if (path.isEmpty) return;
    try {
      final f = File(path);
      if (!await f.exists()) return;
      final raf = await f.open(mode: FileMode.append); // read-write, no truncation
      try {
        final len = await raf.length();
        await raf.setPosition(0);
        final h = await raf.read(44);
        String tag(int at) => String.fromCharCodes(h.sublist(at, at + 4));
        if (h.length < 44 || tag(0) != 'RIFF' || tag(8) != 'WAVE' || tag(36) != 'data') return;
        int u32(int at) => h[at] | h[at + 1] << 8 | h[at + 2] << 16 | h[at + 3] << 24;
        final align = (h[32] | h[33] << 8).clamp(1, 64);
        final data = ((len - 44) ~/ align) * align;
        if (u32(40) == data && u32(4) == 36 + data) return;
        List<int> le(int v) => [v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff];
        await raf.setPosition(4);
        await raf.writeFrom(le(36 + data));
        await raf.setPosition(40);
        await raf.writeFrom(le(data));
      } finally {
        await raf.close();
      }
    } catch (_) {}
  }

  /// Length of a WAV file from its header (byte rate) and size; null if
  /// there is no readable file.
  static Future<int?> wavSeconds(String path) async {
    if (path.isEmpty) return null;
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final raf = await f.open();
      try {
        final header = await raf.read(44);
        if (header.length < 44) return null;
        final byteRate = header[28] | header[29] << 8 | header[30] << 16 | header[31] << 24;
        if (byteRate <= 0) return null;
        return ((await f.length()) - 44) ~/ byteRate;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// A recording's file name, the way the phone's own call recorder names
  /// them: who (number, then name when there is one) and when.
  /// `201 Sara_261013_182405.wav`. Native names them the same way.
  static String recordingName(String number, String name, DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    final when = '${two(at.year % 100)}${two(at.month)}${two(at.day)}_${two(at.hour)}${two(at.minute)}${two(at.second)}';
    final who = {number.trim(), name.trim()}.where((x) => x.isNotEmpty).join(' ');
    final safe = who.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]+'), '_').replaceAll(RegExp(r'^[_\s]+|[_\s]+$'), '');
    return '${safe.isEmpty ? 'call' : safe}_$when.wav';
  }

  /// Where recordings go (Settings → Recording → Save recordings in):
  /// shared — Android: Internal storage › Recordings › Medut, next to
  /// Download and DCIM (Music › Medut before Android 12); iOS:
  /// Documents/Recordings, seen in the Files app; private — inside the app
  /// only; custom — an Android folder of your choice. Native records there.
  static Future<Directory> recordingsDir(AppSettings settings) async {
    switch (settings.recordingDir) {
      case 'custom' when settings.recordingCustomDir.isNotEmpty:
        return Directory(settings.recordingCustomDir);
      case 'private':
        return Directory('${(await getApplicationSupportDirectory()).path}/recordings');
      default:
        if (Platform.isAndroid) return _sharedRecordings ??= _findSharedRecordings();
        return Directory('${(await getApplicationDocumentsDirectory()).path}/Recordings');
    }
  }

  static Future<Directory>? _sharedRecordings;

  static Future<Directory> _findSharedRecordings() async {
    final app = await getExternalStorageDirectory(); // …/Android/data/<id>/files
    final root = app?.path.split('/Android/').first;
    if (root != null) {
      final tries = ['$root/Recordings/Medut', '$root/Music/Medut'];
      for (final d in tries) {
        if (await canWrite(d)) return Directory(d);
      }
      // Android 10 and older write shared storage only with this permission.
      if (await Permission.storage.request().isGranted) {
        for (final d in tries) {
          if (await canWrite(d)) return Directory(d);
        }
      }
    }
    return Directory('${(app ?? await getApplicationSupportDirectory()).path}/Recordings');
  }

  /// Whether recordings can be written to [dir] as plain files (the recorder
  /// writes them natively). Since Android 11 an app may create audio files
  /// only inside the shared Recordings, Music, Download, Documents (and
  /// similar) folders, so the test file is a .wav too.
  static Future<bool> canWrite(String dir) async {
    try {
      await Directory(dir).create(recursive: true);
      final probe = File('$dir/.medut-write-test.wav');
      await probe.writeAsBytes(const []);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Turns what was typed into an AOR for [cfg]: a SIP address is used as
  /// is; anything else is a number or extension on that account's domain.
  /// The native engine dials the same way (PhoneEngine.uriFor).
  static String uriFor(SipAccountConfig cfg, String input) {
    var s = input.trim().replaceFirst(RegExp(r'^sips?:'), '');
    if (s.contains('@')) return s;
    s = s.replaceAll(RegExp(r'[\s\-().]'), '');
    if (s.startsWith('+') && cfg.plusReplace.isNotEmpty) s = cfg.plusReplace + s.substring(1);
    // The line-out prefix is for outside numbers, not extensions or codes.
    if (cfg.dialPrefix.isNotEmpty && RegExp(r'^\+?\d{7,}$').hasMatch(s)) s = cfg.dialPrefix + s;
    return cfg.port > 0 ? '$s@${cfg.domain}:${cfg.port}' : '$s@${cfg.domain}';
  }

  static String userPart(String uri) {
    var s = uri.replaceFirst(RegExp(r'^.*<'), '').replaceFirst(RegExp(r'>.*$'), '');
    s = s.replaceFirst(RegExp(r'^sips?:'), '');
    final at = s.indexOf('@');
    return at > 0 ? s.substring(0, at) : s;
  }

  /// The Refer-To of a transfer to [target]: a full `sip:` URI. baresip
  /// takes anything else for a user name, so `201@pbx` became
  /// `sip:201%40pbx@pbx` and every transfer went to a number that does not
  /// exist. (Native builds it: PhoneEngine.referUri.)
  static String referUri(SipAccountConfig cfg, String target) {
    final u = uriFor(cfg, target);
    return RegExp(r'^sips?:', caseSensitive: false).hasMatch(u) ? u : 'sip:$u';
  }

  @override
  void dispose() {
    _configDebounce?.cancel();
    _presenceDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
