import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:medut/medut.dart';
import 'package:path_provider/path_provider.dart';

import '../core/accounts.dart';
import '../core/db.dart';
import '../core/settings.dart';
import 'native_bridge.dart';

enum RegStatus { off, registering, registered, reconnecting, failed }

enum Phase { incoming, outgoing, active, held }

class MwiInfo {
  const MwiInfo({this.newVoice = 0, this.oldVoice = 0, this.newUrgent = 0});
  final int newVoice, oldVoice, newUrgent;
}

/// A configured account and its live SDK object.
class AccountRuntime {
  AccountRuntime(this.cfg, this.signature);
  SipAccountConfig cfg;
  final String signature;
  Account? account;
  RegStatus status = RegStatus.registering;
  String error = '';
  int retryInMs = 0;
  int sipCode = 0;
  MwiInfo mwi = const MwiInfo();
  StreamSubscription<MedutEvent>? sub;
}

class ActiveCall {
  ActiveCall({
    required this.id,
    required this.call,
    required this.runtime,
    required this.direction,
    required this.number,
    required this.name,
    required this.phase,
  }) : createdAt = DateTime.now();

  final String id;
  final Call call;
  final AccountRuntime runtime;
  final CallDirection direction;
  String number, name;
  Phase phase;
  final DateTime createdAt;
  DateTime? answeredAt;
  bool muted = false;
  bool recording = false;
  String recordingPath = '';
  bool userDeclined = false;
  bool remoteRinging = false;
  MediaStats? stats;
  String crypto = '';

  /// Set on the consult call of an attended transfer: the held call to hand over.
  ActiveCall? transferOf;

  String get title => name.isNotEmpty ? name : number;
}

/// Drives Medut-SDK: accounts, registration, calls, presence, MWI, messages.
/// The single source of truth for call state; the native call screens only
/// render the snapshots this pushes.
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

  Medut? _sdk;
  final Map<String, AccountRuntime> runtimes = {};
  final List<ActiveCall> calls = [];
  ActiveCall? focused;
  final Map<String, PresenceStatus> presence = {};
  final List<String> sipLog = [];
  final _notices = StreamController<String>.broadcast();
  Stream<String> get notices => _notices.stream;

  String? _pushToken;
  PushProvider _pushProvider = PushProvider.none;
  bool _foreground = true;
  bool _started = false;
  String _route = 'earpiece';
  bool _bluetooth = false;
  Timer? _statusTimer;
  Timer? _applyDebounce;
  final Set<String> _subscribed = {};

  bool get started => _started;
  bool get hasCall => calls.isNotEmpty;
  Medut? get sdk => _sdk;

  // ── Start-up ──────────────────────────────────────────────────────────────

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);

    _bridge.actions.listen(_onAction);
    _bridge.callkitAudio.listen((on) => _sdk?.notifyCallKitAudioActive(on));
    _bridge.voipPushes.listen((_) => _reRegisterAll());
    _bridge.pushTokens.listen((t) => _setPushToken(t?['token'] as String?, _provider(t?['provider'] as String?)));
    _bridge.audioRoutes.listen((r) {
      _route = r['route'] as String? ?? _route;
      _bluetooth = r['bluetooth'] == true;
      _push();
    });
    await _bridge.ready();

    await _initPush();

    var sdk = await Medut.start(
      config: _medutConfig(),
      // iOS: CallKit owns the audio session; we forward its activation.
      manageAudioSession: !Platform.isIOS,
    );
    if (sdk.reattached) {
      // Only after a Dart hot restart in development: start clean.
      sdk.shutdown();
      sdk = await Medut.start(config: _medutConfig(), manageAudioSession: !Platform.isIOS, reattachIfRunning: false);
    }
    _sdk = sdk;
    sdk.events.listen(_onGlobalEvent);
    MedutPlatform.onAudioRoutesChanged = _refreshRoutes;

    await applyAccounts();
    store.addListener(_scheduleApply);
    settings.addListener(_onSettings);
    _statusTimer = Timer.periodic(const Duration(minutes: 1), (_) => _publishStatus());
    _syncKeepAlive();
    _push();
  }

  MedutConfig _medutConfig() => MedutConfig(
        userAgent: 'Medut/0.1 (${Platform.operatingSystem})',
        statsIntervalMs: 3000,
        mosAlertThreshold: 3.5,
        traceSip: settings.traceSip,
        aecMode: AecMode.values[settings.aecMode.clamp(0, 2)],
        noiseSuppression: settings.noiseSuppression,
        autoGainControl: settings.autoGain,
        platformAudioActivate: !Platform.isIOS,
      );

  PushProvider _provider(String? p) => switch (p) {
        'apns' => PushProvider.apns,
        'apnsSandbox' => PushProvider.apnsSandbox,
        'fcm' => PushProvider.fcm,
        _ => PushProvider.none,
      };

  Future<void> _initPush() async {
    if (Platform.isIOS) {
      final t = await _bridge.pushToken();
      if (t != null) {
        _pushToken = t['token'] as String?;
        _pushProvider = _provider(t['provider'] as String?);
      }
      return;
    }
    // Android FCM. Without google-services.json Firebase is not configured:
    // skip it, the keep-alive service keeps the app reachable.
    try {
      await Firebase.initializeApp();
      final fm = FirebaseMessaging.instance;
      _pushToken = await fm.getToken().timeout(const Duration(seconds: 4));
      _pushProvider = _pushToken == null ? PushProvider.none : PushProvider.fcm;
      fm.onTokenRefresh.listen((t) => _setPushToken(t, PushProvider.fcm));
    } catch (_) {
      _pushToken = null;
    }
  }

  void _setPushToken(String? token, PushProvider provider) {
    if (token == _pushToken) return;
    final hadProvider = _pushProvider != PushProvider.none;
    _pushToken = token;
    _pushProvider = token == null ? PushProvider.none : provider;
    for (final rt in runtimes.values) {
      if (!rt.cfg.push) continue;
      if (hadProvider && token != null) {
        rt.account?.setPushToken(token);
      } else {
        _recreate(rt.cfg);
      }
    }
  }

  void _reRegisterAll() {
    for (final rt in runtimes.values) {
      rt.account?.register();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _publishStatus();
  }

  void _onSettings() {
    _syncKeepAlive();
    _publishStatus();
    final sdk = _sdk;
    if (sdk != null) {
      sdk.setAecMode(AecMode.values[settings.aecMode.clamp(0, 2)]);
      sdk.setNs(settings.noiseSuppression);
      sdk.setAgc(settings.autoGain);
    }
    _syncSubscriptions();
    _push();
  }

  // ── Accounts ──────────────────────────────────────────────────────────────

  void _scheduleApply() {
    _applyDebounce?.cancel();
    _applyDebounce = Timer(const Duration(milliseconds: 300), applyAccounts);
  }

  String _signature(SipAccountConfig c) =>
      '${c.toJson()}|${c.password}|${c.turnPass}|${c.push ? _pushProvider.name : ''}';

  Future<void> applyAccounts() async {
    if (_sdk == null) return;
    final wanted = {for (final c in store.accounts.where((a) => a.enabled)) c.id: c};
    for (final id in runtimes.keys.toList()) {
      if (!wanted.containsKey(id) && !calls.any((c) => c.runtime.cfg.id == id)) _destroy(id);
    }
    for (final c in wanted.values) {
      final rt = runtimes[c.id];
      if (rt == null || rt.signature != _signature(c)) {
        _recreate(c);
      } else {
        rt.cfg = c;
      }
    }
    _syncKeepAlive();
    notifyListeners();
  }

  void _destroy(String id) {
    final rt = runtimes.remove(id);
    if (rt == null) return;
    rt.sub?.cancel();
    try {
      rt.account?.unregister();
      rt.account?.destroy();
    } catch (_) {}
    _subscribed.removeWhere((k) => k.startsWith('$id|'));
  }

  void _recreate(SipAccountConfig c) {
    if (calls.any((x) => x.runtime.cfg.id == c.id)) return; // never under a live call
    _destroy(c.id);
    final sdk = _sdk;
    if (sdk == null) return;
    final rt = AccountRuntime(c, _signature(c));
    runtimes[c.id] = rt;
    String? opt(String s) => s.trim().isEmpty ? null : s.trim();
    try {
      final usePush = c.push && _pushToken != null;
      final acct = sdk.createAccount(
        c.aor,
        c.password,
        config: AccountConfig(
          transport: Transport.values.byName(c.transport),
          serverUrl: (c.transport == 'ws' || c.transport == 'wss') ? opt(c.serverUrl) : null,
          authUser: opt(c.authUser),
          displayName: opt(c.displayName),
          outboundProxy: opt(c.outboundProxy),
          mediaEnc: switch (c.mediaEnc) {
            'sdes' => MediaEncryption.sdes,
            'dtls' => MediaEncryption.dtlsSrtp,
            _ => MediaEncryption.none,
          },
          iceEnabled: c.ice,
          stunServer: opt(c.stun),
          turnServer: opt(c.turn),
          turnUser: opt(c.turnUser),
          turnPass: opt(c.turnPass),
          verifyTls: c.verifyTls,
          pushProvider: usePush ? _pushProvider : PushProvider.none,
          pushToken: usePush ? _pushToken : null,
          audioCodecs: c.codecs,
          dtmfMode: switch (c.dtmf) {
            'info' => DtmfMode.sipInfo,
            'auto' => DtmfMode.auto,
            _ => DtmfMode.rfc4733,
          },
        ),
      );
      rt.account = acct;
      rt.sub = acct.events.listen((e) => _onAccountEvent(rt, e));
      acct.register();
    } catch (e) {
      rt.status = RegStatus.failed;
      rt.error = e.toString();
    }
  }

  AccountRuntime? runtimeFor(Account? a) {
    if (a == null) return null;
    for (final rt in runtimes.values) {
      if (identical(rt.account, a)) return rt;
    }
    return null;
  }

  void retryNow(String id) => runtimes[id]?.account?.retryNow();

  void _onAccountEvent(AccountRuntime rt, MedutEvent e) {
    switch (e) {
      case RegStateEvent():
        rt.status = switch (e.state) {
          RegState.registered => RegStatus.registered,
          RegState.registering => RegStatus.registering,
          RegState.reconnecting => RegStatus.reconnecting,
          RegState.failed => RegStatus.failed,
          _ => RegStatus.off,
        };
        rt.error = e.errorStr ?? '';
        rt.retryInMs = e.retryDelayMs;
        final code = RegExp(r'\b([3-6]\d\d)\b').firstMatch(rt.error)?.group(1);
        rt.sipCode = int.tryParse(code ?? '') ?? 0;
        if (rt.status == RegStatus.registered) {
          _publishStatusFor(rt);
          _syncSubscriptions();
        }
        _syncKeepAlive();
        notifyListeners();
      case MwiEvent():
        rt.mwi = MwiInfo(newVoice: e.newVoice, oldVoice: e.oldVoice, newUrgent: e.newUrgent);
        notifyListeners();
      case MessageEvent():
        final peer = userPart(e.fromUri);
        db.addMessage(ChatMessage(accountId: rt.cfg.id, peer: peer, body: e.body, outgoing: false, at: DateTime.now()));
        if (!_foreground) {
          _bridge.missedCall(name: nameFor(peer), number: '$peer: ${e.body}', title: tr('newMessage'));
        }
        notifyListeners();
      case PresenceStateEvent():
        presence[userPart(e.targetUri)] = e.status;
        notifyListeners();
      default:
        break;
    }
  }

  // ── Presence ──────────────────────────────────────────────────────────────

  void _publishStatus() {
    for (final rt in runtimes.values) {
      if (rt.status == RegStatus.registered) _publishStatusFor(rt);
    }
  }

  void _publishStatusFor(AccountRuntime rt) {
    final s = settings.effectiveStatus();
    rt.account?.publishPresence(s == MyStatus.dnd ? PresenceStatus.closed : PresenceStatus.open);
  }

  void _syncSubscriptions() {
    final def = store.defaultAccount;
    final rt = def == null ? null : runtimes[def.id];
    if (rt == null || rt.status != RegStatus.registered) return;
    final want = {for (final w in settings.watched) '${rt.cfg.id}|${w.ext}'};
    for (final key in _subscribed.difference(want).toList()) {
      final ext = key.split('|').last;
      runtimes[key.split('|').first]?.account?.unsubscribePresence(uriFor(rt.cfg, ext));
      _subscribed.remove(key);
    }
    for (final key in want.difference(_subscribed)) {
      rt.account?.subscribePresence(uriFor(rt.cfg, key.split('|').last));
      _subscribed.add(key);
    }
  }

  // ── Keep-alive (Android foreground service) ───────────────────────────────

  void _syncKeepAlive() {
    final enabled = settings.keepAlive && store.accounts.any((a) => a.enabled);
    final up = runtimes.values.where((r) => r.status == RegStatus.registered).length;
    _bridge.keepAlive(
      enabled: enabled,
      title: tr('appName'),
      text: up == 0 ? tr('keepAliveConnecting') : tr('keepAliveOn').replaceAll('{n}', '$up'),
    );
  }

  // ── Global events: calls, stats, transfer, trace ──────────────────────────

  ActiveCall? _find(Call c) {
    for (final a in calls) {
      if (identical(a.call, c)) return a;
    }
    return null;
  }

  ActiveCall? _byId(String id) {
    for (final a in calls) {
      if (a.id == id) return a;
    }
    return null;
  }

  void _onGlobalEvent(MedutEvent e) {
    switch (e) {
      case IncomingCallEvent():
        _onIncoming(e);
      case CallStateEvent():
        _onCallState(e);
      case MediaStatsEvent():
        final ac = _find(e.call);
        if (ac != null) {
          ac.stats = e.stats;
          _push();
        }
      case SdpNegotiationEvent():
        final ac = _find(e.call);
        if (ac != null) ac.crypto = e.negotiatedCrypto ?? '';
      case TransferRequestEvent():
        // The other side (or the PBX) moves us to another party: follow it.
        final old = _find(e.call);
        final next = e.call.transferAccept();
        if (next != null && old != null) {
          final ac = ActiveCall(
            id: _callId(next),
            call: next,
            runtime: old.runtime,
            direction: CallDirection.outgoing,
            number: userPart(e.referToUri),
            name: nameFor(userPart(e.referToUri)),
            phase: Phase.outgoing,
          );
          calls.add(ac);
          focused = ac;
          _push();
        }
      case TransferFailedEvent():
        final ac = _find(e.call);
        if (ac != null && ac.phase == Phase.held) _resume(ac);
        _notices.add('${tr('transferFailed')}: ${e.reason}');
      case SipTraceEvent():
        sipLog.add('${e.direction == MediaDirection.tx ? '→' : '←'} ${e.transport} ${e.remoteAddr}\n${e.rawMessage}');
        if (sipLog.length > 400) sipLog.removeRange(0, sipLog.length - 400);
      default:
        break;
    }
  }

  String _callId(Call c) {
    final id = c.info()?.callId ?? '';
    return id.isNotEmpty ? id : DateTime.now().microsecondsSinceEpoch.toString();
  }

  Future<void> _onIncoming(IncomingCallEvent e) async {
    final rt = runtimeFor(e.call.account);
    if (rt == null) {
      e.call.reject(statusCode: 480, reason: 'Temporarily Unavailable');
      return;
    }
    final number = userPart(e.fromUri);
    final shown = (e.displayName ?? '').trim();
    final name = nameFor(number).isNotEmpty ? nameFor(number) : (shown == number ? '' : shown);

    if (calls.length >= 2) {
      e.call.reject(statusCode: 486, reason: 'Busy Here');
      return;
    }
    if (settings.effectiveStatus() == MyStatus.dnd) {
      final fav = settings.letFavourites && settings.favourites.contains(number);
      final repeat = settings.letRepeat && await db.calledRecently(number);
      if (!fav && !repeat) {
        e.call.reject(statusCode: 486, reason: 'Busy Here');
        await db.addCall(CallRecord(
          accountId: rt.cfg.id,
          accountName: rt.cfg.label,
          number: number,
          name: name,
          direction: CallDirection.incoming,
          result: CallResult.missed,
          startedAt: DateTime.now(),
        ));
        return;
      }
    }

    final ac = ActiveCall(
      id: _callId(e.call),
      call: e.call,
      runtime: rt,
      direction: CallDirection.incoming,
      number: number,
      name: name,
      phase: Phase.incoming,
    );
    calls.add(ac);
    // A second call while talking is "call waiting": the live one stays in front.
    focused ??= ac;
    _push();
    notifyListeners();
    if (Platform.isAndroid && _foreground && focused == ac) _bridge.openCallScreen();
  }

  void _onCallState(CallStateEvent e) {
    final ac = _find(e.call);
    if (ac == null) return;
    switch (e.state) {
      case CallState.ringing:
        ac.remoteRinging = true;
      case CallState.established:
        final first = ac.answeredAt == null;
        ac.answeredAt ??= DateTime.now();
        ac.phase = Phase.active;
        if (first && settings.recordingMode == 'always' && ac.runtime.cfg.recordCalls && !ac.recording) {
          toggleRecord(ac);
        }
      case CallState.held:
        ac.phase = Phase.held;
      case CallState.ended:
      case CallState.cancelled:
      case CallState.failed:
        _finish(ac, failed: e.state == CallState.failed, reason: e.reason);
        return;
      default:
        break;
    }
    _push();
    notifyListeners();
  }

  Future<void> _finish(ActiveCall ac, {bool failed = false, String? reason}) async {
    calls.remove(ac);
    if (ac.recording) {
      try {
        ac.call.recordStop();
      } catch (_) {}
    }
    for (final c in calls) {
      if (c.transferOf == ac) c.transferOf = null;
    }
    if (focused == ac) focused = calls.isEmpty ? null : calls.first;

    final answered = ac.answeredAt != null;
    final result = ac.direction == CallDirection.incoming
        ? (answered ? CallResult.answered : (ac.userDeclined ? CallResult.declined : CallResult.missed))
        : (failed && !answered ? CallResult.failed : CallResult.answered);
    final s = ac.stats;
    await db.addCall(CallRecord(
      accountId: ac.runtime.cfg.id,
      accountName: ac.runtime.cfg.label,
      number: ac.number,
      name: ac.name,
      direction: ac.direction,
      result: result,
      startedAt: ac.createdAt,
      durationSec: answered ? DateTime.now().difference(ac.answeredAt!).inSeconds : 0,
      mos: s?.mosLqAvg ?? s?.mosLq,
      codec: s?.codec ?? '',
      transport: ac.runtime.cfg.transport.toUpperCase(),
      recordingPath: ac.recordingPath,
    ));
    if (result == CallResult.missed && !_foreground) {
      _bridge.missedCall(name: ac.name, number: ac.number, title: tr('missedCall'));
    }
    if (failed && reason != null && reason.isNotEmpty && _foreground) _notices.add(reason);
    _push();
    notifyListeners();
  }

  // ── Actions from the native screens / CallKit / notifications ────────────

  Future<void> _onAction(NativeAction a) async {
    final ac = _byId(a.callId) ?? focused;
    switch (a.action) {
      case 'answer':
        if (ac != null) await answer(ac);
      case 'decline':
        if (ac != null) decline(ac, code: 603);
      case 'busy':
        if (ac != null) decline(ac, code: 486);
      case 'hangup':
        if (ac != null) hangup(ac);
      case 'mute':
      case 'unmute':
        if (ac != null) setMute(ac, a.action == 'mute');
      case 'hold':
        if (ac != null) hold(ac);
      case 'unhold':
        if (ac != null) _resume(ac);
      case 'route':
        await setRoute(a.args['route'] as String? ?? 'earpiece');
      case 'record':
        if (ac != null) await toggleRecord(ac);
      case 'dtmf':
        ac?.call.sendDtmf(a.args['digit'] as String? ?? '');
      case 'swap':
        swap();
      case 'answerWaiting':
        final waiting = calls.where((c) => c.phase == Phase.incoming).firstOrNull;
        if (waiting != null) await answer(waiting);
      case 'completeTransfer':
        completeTransfer();
    }
  }

  Future<void> answer(ActiveCall ac) async {
    if (ac.phase != Phase.incoming) return;
    for (final other in calls) {
      if (other != ac && other.phase == Phase.active) hold(other);
    }
    focused = ac;
    await ac.call.answer();
    _push();
    notifyListeners();
  }

  void decline(ActiveCall ac, {int code = 603}) {
    ac.userDeclined = true;
    ac.call.reject(statusCode: code, reason: code == 486 ? 'Busy Here' : 'Decline');
  }

  void hangup(ActiveCall ac) {
    if (ac.phase == Phase.incoming) {
      decline(ac);
    } else {
      ac.call.hangup();
    }
  }

  void setMute(ActiveCall ac, bool on) {
    ac.call.mute(on: on);
    ac.muted = on;
    _push();
    notifyListeners();
  }

  void hold(ActiveCall ac) {
    if (ac.phase != Phase.active) return;
    ac.call.hold();
    ac.phase = Phase.held;
    _push();
    notifyListeners();
  }

  void _resume(ActiveCall ac) {
    for (final other in calls) {
      if (other != ac && other.phase == Phase.active) hold(other);
    }
    ac.call.resume();
    ac.phase = Phase.active;
    focused = ac;
    _push();
    notifyListeners();
  }

  void swap() {
    final other = calls.where((c) => c != focused && c.phase != Phase.incoming).firstOrNull;
    if (other != null) _resume(other);
  }

  Future<void> setRoute(String route) async {
    _route = route;
    if (!await _bridge.setRoute(route)) {
      if (route == 'speaker' || route == 'earpiece') {
        await _sdk?.setSpeakerphone(route == 'speaker');
      } else {
        final routes = await MedutPlatform.listAudioRoutes();
        final bt = routes.where((r) => r.kind == AudioRouteKind.bluetooth).firstOrNull;
        if (bt != null) await MedutPlatform.setAudioRoute(bt.id);
      }
    }
    _push();
  }

  Future<void> _refreshRoutes() async {
    final routes = await MedutPlatform.listAudioRoutes();
    _bluetooth = routes.any((r) => r.kind == AudioRouteKind.bluetooth);
    final active = routes.where((r) => r.isActive).firstOrNull;
    if (active != null) {
      _route = switch (active.kind) {
        AudioRouteKind.speaker => 'speaker',
        AudioRouteKind.bluetooth => 'bluetooth',
        AudioRouteKind.wired => 'wired',
        _ => 'earpiece',
      };
    }
    _push();
  }

  Future<void> toggleRecord(ActiveCall ac) async {
    if (!ac.recording && settings.recordingMode == 'off') return;
    if (ac.recording) {
      ac.call.recordStop();
      ac.recording = false;
    } else {
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/recordings');
      await dir.create(recursive: true);
      final safe = ac.number.replaceAll(RegExp(r'[^\w+]'), '_');
      ac.recordingPath = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$safe.wav';
      ac.recording = ac.call.recordStart(ac.recordingPath) == 0;
    }
    _push();
    notifyListeners();
  }

  // ── Placing calls and transfers ───────────────────────────────────────────

  /// Turns what was typed into an AOR for [cfg]: a SIP address is used as
  /// is; anything else is a number or extension on that account's domain.
  static String uriFor(SipAccountConfig cfg, String input) {
    var s = input.trim().replaceFirst(RegExp(r'^sips?:'), '');
    if (s.contains('@')) return s;
    s = s.replaceAll(RegExp(r'[\s\-().]'), '');
    return cfg.port > 0 ? '$s@${cfg.domain}:${cfg.port}' : '$s@${cfg.domain}';
  }

  static String userPart(String uri) {
    var s = uri.replaceFirst(RegExp(r'^.*<'), '').replaceFirst(RegExp(r'>.*$'), '');
    s = s.replaceFirst(RegExp(r'^sips?:'), '');
    final at = s.indexOf('@');
    return at > 0 ? s.substring(0, at) : s;
  }

  /// Which account places a call to [number]: the one asked for, else the
  /// first matching dial rule, else the default.
  AccountRuntime? accountFor(String number, {String? accountId}) {
    if (accountId != null && runtimes[accountId] != null) return runtimes[accountId];
    for (final r in settings.dialRules) {
      if (r.matches(number) && runtimes[r.accountId] != null) return runtimes[r.accountId];
    }
    final def = store.defaultAccount;
    return def == null ? null : runtimes[def.id];
  }

  /// Places a call. An active call is put on hold first ("Add call").
  ActiveCall? dial(String input, {String? accountId, String? name}) {
    final rt = accountFor(input, accountId: accountId);
    final acct = rt?.account;
    if (rt == null || acct == null) {
      _notices.add(tr('noAccount'));
      return null;
    }
    if (calls.length >= 2) {
      _notices.add(tr('twoCallsMax'));
      return null;
    }
    for (final other in calls) {
      if (other.phase == Phase.active) hold(other);
    }
    try {
      final call = acct.call(uriFor(rt.cfg, input));
      final number = userPart(input);
      final ac = ActiveCall(
        id: _callId(call),
        call: call,
        runtime: rt,
        direction: CallDirection.outgoing,
        number: number,
        name: name ?? nameFor(number),
        phase: Phase.outgoing,
      );
      calls.add(ac);
      focused = ac;
      _push();
      notifyListeners();
      if (Platform.isAndroid) _bridge.openCallScreen();
      return ac;
    } catch (e) {
      _notices.add('${tr('callFailed')}: $e');
      return null;
    }
  }

  /// "Send now": REFER the focused call to [target] and leave.
  void transferBlind(String target) {
    final ac = focused;
    if (ac == null) return;
    ac.call.transfer(uriFor(ac.runtime.cfg, target));
  }

  /// "Talk first": hold the caller, call [target]; Complete joins them.
  void transferAttended(String target) {
    final original = focused;
    if (original == null) return;
    final consult = dial(target, accountId: original.runtime.cfg.id);
    consult?.transferOf = original;
    _push();
  }

  void completeTransfer() {
    final consult = calls.where((c) => c.transferOf != null).firstOrNull;
    final original = consult?.transferOf;
    if (consult == null || original == null) return;
    original.call.attendedTransfer(consult.call);
  }

  void sendMessage(String peer, String body, {String? accountId}) {
    final rt = accountFor(peer, accountId: accountId);
    if (rt?.account == null) {
      _notices.add(tr('noAccount'));
      return;
    }
    rt!.account!.sendMessage(uriFor(rt.cfg, peer), body);
    db.addMessage(ChatMessage(accountId: rt.cfg.id, peer: userPart(peer), body: body, outgoing: true, at: DateTime.now(), read: true));
  }

  // ── Snapshot for the native screens ───────────────────────────────────────

  void _push() => _bridge.callState(snapshot());

  static const _labelKeys = [
    'incomingOn', 'incomingCall', 'answer', 'decline', 'busy', 'message', 'mute', 'unmute', 'keypad',
    'speaker', 'earpiece', 'bluetooth', 'headset', 'hold', 'resume', 'addCall', 'transfer', 'record',
    'stopRecord', 'hide', 'onHold', 'swap', 'callDetails', 'audioOutput', 'cancel', 'complete',
  ];

  Map<String, Object?> snapshot() {
    final base = <String, Object?>{
      'labels': {for (final k in _labelKeys) k: tr(k)},
      'dark': isDark(),
      'rtl': isRtl(),
    };
    final f = focused ?? (calls.isEmpty ? null : calls.first);
    if (f == null) return {...base, 'phase': 'idle'};
    final other = calls.where((c) => c != f).firstOrNull;
    final s = f.stats;
    final mos = s?.mosLq ?? 0;
    String fmt(double v, [int d = 0]) => v.toStringAsFixed(d);
    Map<String, Object?>? second;
    if (other != null) {
      if (other.phase == Phase.incoming) {
        second = {'name': other.title, 'text': '${other.title} · ${tr('incomingCall')}', 'label': tr('answer'), 'action': 'answerWaiting'};
      } else if (f.transferOf == other) {
        second = {'name': other.title, 'text': '${other.title} · ${tr('onHold')}', 'label': tr('complete'), 'action': 'completeTransfer'};
      } else {
        second = {'name': other.title, 'text': '${other.title} · ${tr('onHold')}', 'label': tr('swap'), 'action': 'swap'};
      }
    }
    return {
      ...base,
      'phase': f.phase.name,
      'callId': f.id,
      'name': f.name,
      'number': f.number,
      'account': '${f.runtime.cfg.label} · ${f.runtime.cfg.user}',
      'status': switch (f.phase) {
        Phase.outgoing => f.remoteRinging ? tr('ringing') : tr('calling'),
        Phase.held => tr('onHold'),
        // Shown while recording, so it is never silent that a call is recorded.
        _ => f.recording ? tr('recordingNow') : '',
      },
      'canRecord': settings.recordingMode != 'off' || f.recording,
      'startedAt': f.answeredAt?.millisecondsSinceEpoch ?? 0,
      'outgoing': f.direction == CallDirection.outgoing,
      'muted': f.muted,
      'held': f.phase == Phase.held,
      'route': _route,
      'bluetooth': _bluetooth,
      'recording': f.recording,
      'silent': settings.effectiveStatus() == MyStatus.silent,
      'mos': s == null ? '' : 'MOS ${fmt(mos, 1)}',
      'quality': s == null ? '' : (mos >= 4.0 ? 'good' : (mos >= 3.5 ? 'fair' : 'poor')),
      'details': s == null
          ? <List<String>>[]
          : [
              ['codec', '${s.codec}/${s.codecClockRate ~/ 1000}k'],
              ['srtp', f.crypto.isEmpty ? (f.runtime.cfg.mediaEnc == 'none' ? 'off' : f.runtime.cfg.mediaEnc) : f.crypto],
              ['ice', s.iceLocalType.name],
              ['rtt', '${fmt(s.rttMs)} ms'],
              ['jitter', '${fmt(s.jitterMs)} ms'],
              ['loss', '${fmt(s.lossPct, 1)} %'],
              ['mos ↑/↓', '${fmt(s.mosLq, 1)} / ${fmt(s.mosLqRx, 1)}'],
              ['jbuf', '${s.jitterBufferMs} ms'],
            ],
      'second': second,
    };
  }

  /// Re-send the snapshot (theme or language changed).
  void refreshNative() => _push();

  @override
  void dispose() {
    _statusTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
