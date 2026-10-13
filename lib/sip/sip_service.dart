import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:medut/medut.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:proximity_screen_lock/proximity_screen_lock.dart';

import '../core/accounts.dart';
import '../core/db.dart';
import '../core/people.dart';
import '../core/settings.dart';
import 'native_bridge.dart';
import 'probe.dart';
import 'quality.dart';
import 'tones.dart';

enum RegStatus { off, registering, registered, reconnecting, failed }

enum Phase { incoming, outgoing, active, held }

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

  /// Media path health: ok | reconnecting (network change, ICE restart) |
  /// weak (media stalled, quality alert).
  String link = 'ok';

  /// SIP details, read while the call is up (they are gone once it ends).
  CallInfo? info;

  /// This phone hung up / declined (vs the other side or the network).
  bool endedLocally = false;

  // Running sums for the call's average network figures (history grade).
  double rttSum = 0, jitterSum = 0, lossSum = 0;
  int samples = 0;
  Timer? autoAnswer;

  /// Set on the consult call of an attended transfer: the held call to hand over.
  ActiveCall? transferOf;

  /// Set on a call placed to follow the other side's transfer (incoming
  /// REFER): the old leg, hung up once this one answers.
  ActiveCall? replaces;

  /// A REFER was sent for this call and has not failed yet.
  bool transferring = false;

  /// Hangs our leg up if the PBX took the transfer but never ended it.
  Timer? backstop;

  /// The join (REFER with Replaces) was refused and the plain transfer to
  /// the same person was tried instead.
  bool semiTried = false;

  /// A status feature code (DND on, queue log-in…): kept out of the history.
  bool featureCode = false;

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
  /// Every number in the phone's contacts (extensions among them get presence).
  Iterable<String> Function() contactNumbers = () => const [];

  Medut? _sdk;
  final Map<String, AccountRuntime> runtimes = {};
  final List<ActiveCall> calls = [];
  ActiveCall? focused;
  final Map<String, PresenceStatus> presence = {};
  final List<String> sipLog = [];

  /// Registration, network and SDK log lines for Settings → Connection log.
  final List<String> connLog = [];
  bool _proximityOn = false;
  final _notices = StreamController<String>.broadcast();
  Stream<String> get notices => _notices.stream;

  String? _pushToken;
  PushProvider _pushProvider = PushProvider.none;
  bool _foreground = true;
  bool _started = false;
  /// Audio outputs the platform offers during a call, and the active one.
  List<AudioRoute> _routes = const [];
  String _route = 'earpiece';
  String _ringtoneSource = 'system';
  Timer? _statusTimer;
  Timer? _applyDebounce;
  final Set<String> _subscribed = {};
  Timer? _presenceDebounce;

  /// The extensions whose presence is followed (see [presenceTargets]).
  List<String> presenceList = const [];
  final _ready = Completer<void>();

  /// Accounts being tried by [tryRegister]: registered but not saved yet.
  final Set<String> _probing = {};

  bool get started => _started;
  bool get hasCall => calls.isNotEmpty;
  Medut? get sdk => _sdk;

  // ── Start-up ──────────────────────────────────────────────────────────────

  Future<void> start() async {
    if (_started) return;
    _started = true;
    // "Available" used to mean in the queue; whoever is logged in is Ready now.
    if (settings.status == MyStatus.available && settings.queueIn.isNotEmpty) settings.status = MyStatus.ready;
    WidgetsBinding.instance.addObserver(this);

    _bridge.actions.listen(_onAction);
    _bridge.callkitAudio.listen((on) => _sdk?.notifyCallKitAudioActive(on));
    _bridge.voipPushes.listen((_) => _reRegisterAll());
    _bridge.pushTokens.listen((t) => _setPushToken(t?['token'] as String?, _provider(t?['provider'] as String?)));
    _bridge.audioRoutes.listen((r) {
      // Telecom moved the audio (headset plugged in, car, watch): re-read it.
      _route = r['route'] as String? ?? _route;
      unawaited(_refreshRoutes());
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
    // On a network change, move calls to the new path (re-INVITE) and never
    // hang up because the move failed.
    try {
      sdk.networkSetHandoverPolicy(true, false);
    } catch (_) {}
    sdk.events.listen(_onGlobalEvent);
    _applyAudioPrefs();
    MedutPlatform.onAudioRoutesChanged = _refreshRoutes;

    await _applyRingtone();
    await applyAccounts();
    store.addListener(_scheduleApply);
    settings.addListener(_onSettings);
    db.addListener(syncPresence); // a new call can bring a new extension
    _statusTimer = Timer.periodic(const Duration(minutes: 1), (_) => _publishStatus());
    _syncKeepAlive();
    _push();
    _ready.complete();
  }

  // Mobile tuning.
  MedutConfig _medutConfig() => MedutConfig(
        userAgent: 'Medut/0.1 (${Platform.operatingSystem})',
        iceGatheringTimeoutMs: 800,
        statsIntervalMs: 2000,
        mediaStallMs: 3000,
        mosAlertThreshold: 3.5,
        // DSCP EF for media, CS3 for signalling.
        dscpRtp: 46,
        dscpSip: 26,
        // Opus hardened for weak mobile networks.
        opus: const OpusConfig(fec: true, dtx: true),
        opusExpectedLossPct: 10,
        // Fail a dead INVITE in 10 s, not RFC 3261's 32 s.
        sipTimerBMs: 10000,
        regExpires: settings.regExpires,
        keepaliveIntervalMs: settings.keepaliveSec * 1000,
        logLevel: settings.debugLogging ? 2 : 1,
        // iOS: the app-owned VoiceProcessingIO engine arms when CallKit
        // activates the session, so media never starts before CallKit.
        appOwnedAudio: Platform.isIOS,
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
    // A copy: _recreate replaces entries in runtimes while we walk it.
    for (final rt in runtimes.values.toList()) {
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
    unawaited(_applyRingtone());
    _syncKeepAlive();
    _publishStatus();
    _applyAudioPrefs();
    _scheduleApply(); // ICE servers, relay and the codec order live on the accounts
    syncPresence();
    _push();
  }

  void _applyAudioPrefs() {
    final sdk = _sdk;
    if (sdk == null) return;
    try {
      sdk.setAecMode(AecMode.values[settings.aecMode.clamp(0, 2)]);
      sdk.setNs(settings.noiseSuppression);
      sdk.setAgc(settings.autoGain);
      sdk.setJitterBufferType(JitterBufferType.adaptive);
      switch (settings.jitterMode) {
        case 'low':
          sdk.setJitterBuffer(20, 150);
        case 'robust':
          sdk.setJitterBuffer(60, 500);
      }
    } catch (_) {}
  }

  void _log(String line) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    connLog.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)}  $line');
    if (connLog.length > 500) connLog.removeRange(0, connLog.length - 500);
  }

  // ── Your status and the PBX feature codes behind it ───────────────────────

  /// Feature codes waiting to be dialed: (account id, code key, code).
  final List<(String, String, String)> _codeQueue = [];
  ActiveCall? _codeCall;

  /// Picks Available, Ready or Do not disturb, and tells each registered
  /// account's PBX with its feature codes: Available = out of the queues
  /// (calls to your extension still ring), Ready = queue log-in, Do not
  /// disturb = DND on + queue log-out; DND off is dialed when leaving Do not
  /// disturb. The codes are dialed as ordinary calls, one after the other,
  /// so the PBX's announcement is heard; a queue code is only dialed to
  /// change state (FreePBX's *45 is a toggle).
  void setMyStatus(MyStatus next) {
    final prev = settings.status;
    if (prev == next) return;
    settings.status = next;
    settings.statusSince = DateTime.now();
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
        _codeQueue.add((c.id, k, code));
        if (k == 'queueLogin') settings.setQueueIn(c.id, true);
        if (k == 'queueLogout') settings.setQueueIn(c.id, false);
      }
    }
    _dialNextCode();
  }

  /// Dials the next waiting feature code, once no call is up.
  void _dialNextCode() {
    if (_codeCall != null || _codeQueue.isEmpty || calls.isNotEmpty) return;
    final (id, key, code) = _codeQueue.removeAt(0);
    _log('status code: $key $code');
    final ac = dial(code, accountId: id, name: tr('code_$key'));
    if (ac == null) {
      _dialNextCode();
      return;
    }
    ac.featureCode = true;
    _codeCall = ac;
    // The PBX hangs up after its announcement; if it does not, we do.
    ac.backstop = Timer(const Duration(seconds: 20), () {
      if (calls.contains(ac)) hangup(ac);
    });
  }

  // ── Accounts ──────────────────────────────────────────────────────────────

  void _scheduleApply() {
    _applyDebounce?.cancel();
    _applyDebounce = Timer(const Duration(milliseconds: 300), applyAccounts);
  }

  /// What the SDK account is built from: a change here re-creates it (and
  /// re-registers). Settings only the app reads (name, default, dial rules,
  /// voicemail, recording, status codes) are left out, so renaming an account
  /// does not drop its registration.
  String _signature(SipAccountConfig c) {
    final j = c.toJson()
      ..remove('name')
      ..remove('isDefault')
      ..remove('voicemail')
      ..remove('recordCalls')
      ..remove('dialPrefix')
      ..remove('plusReplace')
      ..remove('pbx')
      ..remove('codes');
    return '$j|${c.password}|${c.turnPass}|${c.push ? _pushProvider.name : ''}'
        '|${settings.iceServers}|${settings.forceRelay}|${settings.codecs}';
  }

  Future<void> applyAccounts() async {
    if (_sdk == null) return;
    final wanted = {for (final c in store.accounts.where((a) => a.enabled)) c.id: c};
    // A tried account that has been saved is an ordinary account from now on.
    _probing.removeWhere(wanted.containsKey);
    for (final id in runtimes.keys.toList()) {
      if (!wanted.containsKey(id) && !_probing.contains(id) && !calls.any((c) => c.runtime.cfg.id == id)) _destroy(id);
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
          iceServers: [
            for (final s in settings.iceServers)
              if ((s['url'] ?? '').isNotEmpty) IceServer(s['url']!, user: opt(s['user'] ?? ''), pass: opt(s['pass'] ?? '')),
          ],
          iceTransportPolicy: settings.forceRelay ? IceTransportPolicy.relay : IceTransportPolicy.all,
          verifyTls: c.verifyTls,
          pushProvider: usePush ? _pushProvider : PushProvider.none,
          pushToken: usePush ? _pushToken : null,
          audioCodecs: c.codecsFrom(settings.codecs),
          dtmfMode: switch (c.dtmf) {
            'info' => DtmfMode.sipInfo,
            'auto' => DtmfMode.auto,
            _ => DtmfMode.rfc4733,
          },
        ),
      );
      rt.account = acct;
      for (final line in c.headers.split('\n')) {
        final i = line.indexOf(':');
        if (i > 0) acct.addHeader(line.substring(0, i).trim(), line.substring(i + 1).trim());
      }
      rt.sub = acct.events.listen((e) => _onAccountEvent(rt, e));
      acct.register();
    } catch (e) {
      rt.status = RegStatus.failed;
      rt.error = e.toString();
    }
  }

  /// Registers [c] without saving it, to see whether it works: sign-in tries
  /// TLS, TCP and UDP this way. A registration that succeeds keeps running,
  /// so saving the same config afterwards adopts it rather than registering
  /// twice. Anything else is torn down.
  Future<RegProbe> tryRegister(SipAccountConfig c, {Duration timeout = const Duration(seconds: 8)}) async {
    try {
      await _ready.future.timeout(timeout);
    } on TimeoutException {
      return const RegProbe(RegStatus.registering);
    }
    _probing.add(c.id);
    _recreate(c);
    final rt = runtimes[c.id];
    if (rt == null) {
      cancelProbe(c.id);
      return const RegProbe(RegStatus.failed);
    }
    final settled = Completer<void>();
    void check() {
      final s = rt.status;
      if (!settled.isCompleted && (s == RegStatus.registered || s == RegStatus.failed || s == RegStatus.reconnecting)) {
        settled.complete();
      }
    }

    addListener(check);
    check();
    try {
      await settled.future.timeout(timeout);
    } on TimeoutException {
      // Still trying: no answer on this transport.
    } finally {
      removeListener(check);
    }
    if (!identical(runtimes[c.id], rt)) return const RegProbe(RegStatus.off); // cancelled meanwhile
    final result = RegProbe(rt.status, sipCode: rt.sipCode, error: rt.error);
    if (!result.ok) cancelProbe(c.id);
    return result;
  }

  /// Checks how [host] can be reached (TLS, TCP, UDP, web link) without
  /// signing in: see probe.dart.
  Future<ProbeReport> probe(String host, {int port = 0, ProbeListener? onStep}) =>
      probeServer(host, port: port, onStep: onStep);

  /// Drops a tried account that was not saved (failed, or the user left).
  void cancelProbe(String id) {
    if (!_probing.remove(id) || store.byId(id) != null) return;
    _destroy(id);
    notifyListeners();
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
        _log('${rt.cfg.label}: ${e.state.name}${rt.error.isNotEmpty ? ' — ${rt.error}' : ''}'
            '${e.retryDelayMs > 0 ? ' (retry ${e.retryDelayMs ~/ 1000}s)' : ''}');
        final code = RegExp(r'\b([3-6]\d\d)\b').firstMatch(rt.error)?.group(1);
        rt.sipCode = int.tryParse(code ?? '') ?? 0;
        if (rt.status == RegStatus.registered) {
          _publishStatusFor(rt);
          syncPresence();
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
          final who = nameFor(peer);
          _bridge.messageNotification(peer: peer, title: who.isNotEmpty ? who : peer, body: e.body);
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

  /// Recomputes [presenceList] and follows it on the default account:
  /// favourites, hand-added extensions, and the most recent ones from calls
  /// and contacts.
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
    final def = store.defaultAccount;
    final rt = def == null ? null : runtimes[def.id];
    if (rt == null || rt.status != RegStatus.registered) return;
    final want = {for (final ext in targets) '${rt.cfg.id}|$ext'};
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
          if (ac.phase == Phase.active || ac.phase == Phase.held) {
            ac.rttSum += e.stats.rttMs;
            ac.jitterSum += e.stats.jitterMs;
            ac.lossSum += e.stats.lossPctRx;
            ac.samples++;
          }
          _push();
        }
      case SdpNegotiationEvent():
        final ac = _find(e.call);
        if (ac != null) ac.crypto = e.negotiatedCrypto ?? '';
      case TransferRequestEvent():
        // The other side (or the PBX) moves us to another party: follow it,
        // and drop the old leg once the new one answers. The transferor
        // waits for an answer either way, so one we cannot follow is refused.
        if (e.autoFollowed) break;
        final old = _find(e.call);
        final next = old == null ? null : e.call.transferAccept();
        if (next == null || old == null) {
          e.call.transferReject();
          break;
        }
        final ac = ActiveCall(
          id: _callId(next),
          call: next,
          runtime: old.runtime,
          direction: CallDirection.outgoing,
          number: userPart(e.referToUri),
          name: nameFor(userPart(e.referToUri)),
          phase: Phase.outgoing,
        )..replaces = old;
        calls.add(ac);
        focused = ac;
        _push();
        notifyListeners();
      case TransferFailedEvent():
        final ac = _find(e.call);
        if (ac != null) {
          ac.backstop?.cancel();
          final consult = calls.where((c) => c.transferOf == ac).firstOrNull;
          if (consult != null && !ac.semiTried) {
            // The PBX would not join the two calls: send the caller to the
            // same person as a plain transfer instead.
            ac.semiTried = true;
            consult.transferOf = null; // its end must not take the caller off hold
            hangup(consult);
            _refer(ac, consult.number);
            break;
          }
          ac.transferring = false;
          if (ac.phase == Phase.held) _resume(ac);
          _push();
        }
        _notices.add('${tr('transferFailed')}${e.reason.isEmpty ? '' : ': ${e.reason}'}');
      case NetworkEvent():
        _log('network ${e.stage.name}${e.localAddr.isNotEmpty ? ' ${e.localAddr}' : ''}');
        final ac = e.call == null ? null : _find(e.call!);
        if (ac != null) {
          final link = switch (e.stage) {
            NetworkStage.callMigrating || NetworkStage.callDeferred || NetworkStage.callIceStale => 'reconnecting',
            NetworkStage.callMigrated || NetworkStage.callMigrateAccepted => 'ok',
            NetworkStage.callMigrationFailed || NetworkStage.callIceFailed => 'weak',
            _ => ac.link,
          };
          if (link != ac.link) {
            ac.link = link;
            _push();
          }
        }
      case QualityAlertEvent():
        final ac = _find(e.call);
        if (ac != null && e.issue == QualityIssue.mediaStall) {
          ac.link = e.recovering ? 'ok' : 'weak';
          _push();
        }
      case LogEvent():
        if (settings.debugLogging) _log(e.message.trim());
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

    if (settings.blocked.contains(number)) {
      e.call.reject(statusCode: 603, reason: 'Decline');
      _log('blocked call from $number');
      return;
    }
    if (calls.length >= 2) {
      e.call.reject(statusCode: 486, reason: 'Busy Here');
      return;
    }
    if (settings.effectiveStatus() == MyStatus.dnd) {
      final fav = settings.letFavourites && settings.favourites.any((f) => sameNumber(f, number));
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
    // Auto-answer (not over another call). It still rings, so it can be declined.
    if (settings.autoAnswer && focused == ac) {
      ac.autoAnswer = Timer(Duration(seconds: settings.autoAnswerDelay), () {
        if (ac.phase == Phase.incoming && calls.contains(ac)) answer(ac);
      });
    }
    if (Platform.isAndroid && _foreground && focused == ac) _bridge.openCallScreen();
  }

  void _onCallState(CallStateEvent e) {
    final ac = _find(e.call);
    if (ac == null) return;
    switch (e.state) {
      case CallState.ringing:
        ac.remoteRinging = true;
        if (ac.direction == CallDirection.outgoing && settings.ringback && focused == ac) {
          unawaited(Tones.startRingback());
        }
      case CallState.established:
        Tones.stopRingback();
        final first = ac.answeredAt == null;
        ac.info = ac.call.info() ?? ac.info;
        if (first) unawaited(_initCallRoute());
        ac.answeredAt ??= DateTime.now();
        ac.phase = Phase.active;
        // We followed a transfer and the new party answered: the old leg goes.
        final old = ac.replaces;
        ac.replaces = null;
        if (old != null && calls.contains(old)) hangup(old);
        if (first && settings.recordingMode == 'always' && ac.runtime.cfg.recordCalls && !ac.recording) {
          toggleRecord(ac);
        }
      case CallState.held:
        ac.phase = Phase.held;
      case CallState.ended:
      case CallState.cancelled:
      case CallState.failed:
        _finish(ac, failed: e.state == CallState.failed, reason: e.reason, state: e.state);
        return;
      default:
        break;
    }
    _push();
    notifyListeners();
  }

  Future<void> _finish(ActiveCall ac, {bool failed = false, String? reason, CallState? state}) async {
    try {
      ac.info = ac.call.info() ?? ac.info; // last chance for the final SIP status
    } catch (_) {}
    calls.remove(ac);
    ac.autoAnswer?.cancel();
    ac.backstop?.cancel();
    if (!calls.any((c) => c.phase == Phase.outgoing)) Tones.stopRingback();
    if (calls.isEmpty) {
      _routes = const [];
      _route = 'earpiece';
    }
    // Ended by the other side while recording: the SDK has already closed the
    // file (stopping it now would touch a freed call) but left its WAV header
    // saying "no audio", so it is fixed from the file's size.
    if (ac.recording) {
      ac.recording = false;
      await repairWav(ac.recordingPath);
    }
    for (final c in calls) {
      if (c.transferOf == ac) c.transferOf = null;
      if (c.replaces == ac) c.replaces = null;
    }
    // The person we were consulting hung up, declined or never answered:
    // the caller waiting on hold comes back rather than being left there.
    final waiting = ac.transferOf;
    if (waiting != null && calls.contains(waiting) && !waiting.transferring && waiting.phase == Phase.held) {
      _resume(waiting);
    }
    if (focused == ac) focused = calls.isEmpty ? null : calls.first;

    if (identical(_codeCall, ac)) _codeCall = null;
    // A feature code waiting for the line, or the next one in a row.
    if (calls.isEmpty && _codeQueue.isNotEmpty) Timer(const Duration(milliseconds: 800), _dialNextCode);
    if (ac.featureCode) {
      _push();
      notifyListeners();
      return;
    }

    final answered = ac.answeredAt != null;
    final result = ac.direction == CallDirection.incoming
        ? (answered ? CallResult.answered : (ac.userDeclined ? CallResult.declined : CallResult.missed))
        : (failed && !answered ? CallResult.failed : CallResult.answered);
    final s = ac.stats;
    final info = ac.info;
    final now = DateTime.now();
    final sipCode = (info?.sipStatus ?? 0) > 0
        ? info!.sipStatus
        : int.tryParse(RegExp(r'\b([3-6]\d\d)\b').firstMatch(reason ?? '')?.group(1) ?? '');
    final iceKind = s == null ? '' : '${s.iceLocalType.name} → ${s.iceRemoteType.name}';
    await db.addCall(CallRecord(
      accountId: ac.runtime.cfg.id,
      accountName: ac.runtime.cfg.label,
      number: ac.number,
      name: ac.name,
      direction: ac.direction,
      result: result,
      startedAt: ac.createdAt,
      answeredAt: ac.answeredAt,
      endedAt: now,
      durationSec: answered ? now.difference(ac.answeredAt!).inSeconds : 0,
      mos: s?.mosLqAvg ?? s?.mosLq,
      mosMin: s == null || s.mosLqMin <= 0 ? null : s.mosLqMin,
      mosRx: s == null || s.mosLqRx <= 0 ? null : s.mosLqRx,
      packetsLost: s?.packetsLostRx,
      encryption: ac.crypto.isNotEmpty ? ac.crypto : (ac.runtime.cfg.mediaEnc == 'none' ? 'none' : ac.runtime.cfg.mediaEnc),
      icePath: iceKind,
      remoteMedia: s?.remoteAddr ?? '',
      callId: info?.callId.isNotEmpty == true ? info!.callId : ac.id,
      remoteUri: info?.peerUri ?? '',
      localUri: info?.localUri ?? '',
      setupMs: info == null || info.setupDuration == Duration.zero ? null : info.setupDuration.inMilliseconds,
      endReason: (reason ?? '').isNotEmpty ? reason! : (state?.name ?? ''),
      sipCode: sipCode,
      endedBy: ac.endedLocally || ac.userDeclined ? 'local' : 'remote',
      rttMs: ac.samples == 0 ? null : ac.rttSum / ac.samples,
      jitterMs: ac.samples == 0 ? null : ac.jitterSum / ac.samples,
      lossPct: ac.samples == 0 ? null : ac.lossSum / ac.samples,
      codec: s?.codec ?? '',
      transport: ac.runtime.cfg.transport.toUpperCase(),
      recordingPath: ac.recordingPath,
      recordingSec: await wavSeconds(ac.recordingPath),
    ));
    if (result == CallResult.missed) await _notifyMissed(ac.title);
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
        final id = a.args['routeId'] as String?;
        if (id != null) {
          await selectRoute(id);
        } else {
          await setRoute(a.args['route'] as String? ?? 'earpiece');
        }
      case 'toggleSpeaker':
        await toggleSpeaker();
      case 'toggleMute':
        if (ac != null) setMute(ac, !ac.muted);
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
      case 'cancelTransfer':
        cancelTransfer();
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
    ac.endedLocally = true;
    // Close the recording while the call still exists: once it has ended the
    // SDK has freed it, and stopping then crashed the app.
    if (ac.recording) {
      try {
        ac.call.recordStop();
      } catch (_) {}
      ac.recording = false;
    }
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

  static String _kindName(AudioRouteKind k) => switch (k) {
        AudioRouteKind.speaker => 'speaker',
        AudioRouteKind.bluetooth => 'bluetooth',
        AudioRouteKind.wired => 'wired',
        _ => 'earpiece',
      };

  void _applyRoutes(List<AudioRoute> routes) {
    _routes = routes;
    final active = routes.where((r) => r.isActive).firstOrNull;
    if (active != null) _route = _kindName(active.kind);
  }

  Future<void> _refreshRoutes() async {
    try {
      _applyRoutes(await MedutPlatform.listAudioRoutes());
    } catch (_) {}
    _push();
  }

  /// When a call connects: a connected headset wins, otherwise the earpiece.
  Future<void> _initCallRoute() async {
    await _refreshRoutes();
    if (_routes.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _refreshRoutes();
    }
    final headset = _ofKind(AudioRouteKind.bluetooth) ?? _ofKind(AudioRouteKind.wired);
    if (headset != null && !headset.isActive) {
      await selectRoute(headset.id);
    } else if (headset == null && _route == 'speaker') {
      await setRoute('earpiece');
    }
  }

  AudioRoute? _ofKind(AudioRouteKind k) => _routes.where((r) => r.kind == k).firstOrNull;

  /// Off the loudspeaker means back to the best headset, not the earpiece:
  /// Bluetooth, then wired, then the earpiece.
  AudioRoute? _preferredNonSpeaker() =>
      _ofKind(AudioRouteKind.bluetooth) ?? _ofKind(AudioRouteKind.wired) ?? _ofKind(AudioRouteKind.earpiece);

  /// One-tap speaker button (call screen and the ongoing-call notification).
  Future<void> toggleSpeaker() async {
    final on = _route == 'speaker';
    final target = on ? _preferredNonSpeaker() : _ofKind(AudioRouteKind.speaker);
    if (target != null) return selectRoute(target.id);
    // No routes enumerated yet (call just connected): plain toggle.
    _route = on ? 'earpiece' : 'speaker';
    _push();
    try {
      await _sdk?.setSpeakerphone(!on);
    } catch (_) {}
    await _bridge.setRoute(_route);
  }

  /// Route call audio to an output picked on the call screen. Goes through
  /// the SDK, then through Telecom (Android) last, because while a Telecom
  /// call is up Telecom owns the route and would undo the SDK's change. Both
  /// get the route asked for: the list the SDK answers with is read before
  /// the switch completes and still names the old route as active, and
  /// passing that on sent Telecom back to the earpiece on every Speaker tap.
  /// The real route comes back through Telecom's and the SDK's route events.
  Future<void> selectRoute(String id) async {
    final route = _routes.where((r) => r.id == id).firstOrNull;
    final kind = route == null ? _route : _kindName(route.kind);
    _route = kind;
    _push();
    try {
      _routes = await MedutPlatform.setAudioRoute(id);
    } catch (_) {}
    await _bridge.setRoute(kind);
    _push();
  }

  /// Route by kind ("speaker", "bluetooth", …) when no id is known.
  Future<void> setRoute(String kind) async {
    final k = switch (kind) {
      'speaker' => AudioRouteKind.speaker,
      'bluetooth' => AudioRouteKind.bluetooth,
      'wired' => AudioRouteKind.wired,
      _ => AudioRouteKind.earpiece,
    };
    final r = _ofKind(k);
    if (r != null) return selectRoute(r.id);
    if (k == AudioRouteKind.speaker || k == AudioRouteKind.earpiece) {
      _route = kind;
      _push();
      try {
        await _sdk?.setSpeakerphone(k == AudioRouteKind.speaker);
      } catch (_) {}
      await _bridge.setRoute(kind);
    }
  }

  // ── Ringtone & missed-call notifications ──────────────────────────────────

  Future<void> _applyRingtone() async {
    final src = await Tones.nativeSource(settings.ringtoneId, settings.customRingtonePath);
    if (src != _ringtoneSource) {
      _ringtoneSource = src;
      _push();
    }
    // iOS: CallKit plays the ringtone itself, from a sound file it can find.
    await _bridge.setRingtone(src == 'system' ? null : src);
  }

  Future<void> _notifyMissed(String latest) async {
    final count = await db.missedSince(settings.activitySeenAt);
    if (count <= 0) return;
    await _bridge.missedCalls(
      count: count,
      latest: latest,
      title: count > 1 ? tr('missedCalls').replaceAll('{n}', '$count') : tr('missedCall'),
    );
  }

  /// The user looked at Activity: the missed-call notification goes away.
  void missedSeen() => _bridge.clearMissed();

  Future<void> toggleRecord(ActiveCall ac) async {
    if (!ac.recording && settings.recordingMode == 'off') return;
    if (ac.recording) {
      ac.call.recordStop();
      ac.recording = false;
    } else {
      final dir = await recordingsDir(settings);
      await dir.create(recursive: true);
      // The call may have ended meanwhile; a freed call must not be touched.
      if (!calls.contains(ac)) return;
      ac.recordingPath = '${dir.path}/${recordingName(ac.number, ac.name, DateTime.now())}';
      ac.recording = ac.call.recordStart(ac.recordingPath) == 0;
    }
    _push();
    notifyListeners();
  }

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
  /// `201 Sara_261013_182405.wav`.
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
  /// only; custom — an Android folder of your choice.
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

  // ── Placing calls and transfers ───────────────────────────────────────────

  /// Turns what was typed into an AOR for [cfg]: a SIP address is used as
  /// is; anything else is a number or extension on that account's domain.
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

  /// The Refer-To of a transfer to [target]: a full `sip:` URI. baresip
  /// takes anything else for a user name, so `201@pbx` became
  /// `sip:201%40pbx@pbx` and every transfer went to a number that does not
  /// exist.
  static String referUri(SipAccountConfig cfg, String target) {
    final u = uriFor(cfg, target);
    return RegExp(r'^sips?:', caseSensitive: false).hasMatch(u) ? u : 'sip:$u';
  }

  /// Sends [ac]'s caller to [target] (REFER). The PBX ends our leg when it
  /// takes the call; a refusal comes back as [TransferFailedEvent] and the
  /// call carries on. If neither happens, our leg is hung up after 20 s.
  void _refer(ActiveCall ac, String target) {
    ac.transferring = true;
    ac.call.transfer(referUri(ac.runtime.cfg, target));
    _armBackstop(ac);
    _push();
  }

  void _armBackstop(ActiveCall ac) {
    ac.backstop?.cancel();
    ac.backstop = Timer(const Duration(seconds: 20), () {
      if (calls.contains(ac) && ac.transferring) hangup(ac);
    });
  }

  /// Blind transfer: the caller goes straight to [target] and we leave.
  void transferBlind(String target) {
    final ac = focused;
    if (ac == null || target.trim().isEmpty) return;
    _refer(ac, target);
  }

  /// Warm transfer: hold the caller and call [target]; "Join & drop" joins
  /// them once [target] answers, "Back to caller" ends the consult call.
  void transferAttended(String target) {
    final original = focused;
    if (original == null) return;
    final consult = dial(target, accountId: original.runtime.cfg.id);
    consult?.transferOf = original;
    _push();
  }

  /// Joins the held caller to the person consulted (REFER with Replaces).
  /// Still ringing there: the caller is sent to that number instead and our
  /// ringing call is dropped, since a call nobody answered cannot be replaced.
  void completeTransfer() {
    final consult = calls.where((c) => c.transferOf != null).firstOrNull;
    final original = consult?.transferOf;
    if (consult == null || original == null) return;
    if (consult.phase == Phase.outgoing || consult.phase == Phase.incoming) {
      consult.transferOf = null; // its end must not take the caller off hold
      hangup(consult);
      _refer(original, consult.number);
    } else {
      original.transferring = true;
      original.call.attendedTransfer(consult.call);
      _armBackstop(original);
      _push();
    }
  }

  /// "Back to caller": ends the consult call; the caller comes off hold.
  void cancelTransfer() {
    final consult = calls.where((c) => c.transferOf != null).firstOrNull;
    if (consult != null) hangup(consult);
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

  void _push() {
    _bridge.callState(snapshot());
    // Screen off at the ear, whichever screen is showing: a live call on the
    // earpiece. Off for speaker, headsets, ringing and idle.
    final live = calls.any((c) => c.phase != Phase.incoming);
    unawaited(_setProximity(live && _route == 'earpiece'));
  }

  Future<void> _setProximity(bool on) async {
    if (_proximityOn == on) return;
    _proximityOn = on;
    try {
      if (on && !await ProximityScreenLock.isProximityLockSupported()) {
        _proximityOn = false;
        return;
      }
      await ProximityScreenLock.setActive(on);
    } catch (_) {
      _proximityOn = false;
    }
  }

  static const _labelKeys = [
    'incomingOn', 'incomingCall', 'answer', 'decline', 'busy', 'message', 'mute', 'unmute', 'keypad',
    'speaker', 'earpiece', 'bluetooth', 'headset', 'hold', 'resume', 'addCall', 'transfer', 'record',
    'stopRecord', 'hide', 'onHold', 'swap', 'callDetails', 'audioOutput', 'cancel', 'complete',
    'more', 'callQuality', 'youHear', 'theyHear', 'encrypted', 'recShort',
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
    final s = settings.showCallQuality ? f.stats : null;
    final mos = s?.mosLq ?? 0;
    String fmt(double v, [int d = 0]) => v.toStringAsFixed(d);
    var level = s == null
        ? 0
        : callQualityLevel(mos: s.mosLq, rttMs: s.rttMs, jitterMs: s.jitterMs, lossPct: s.lossPctRx);
    if (f.link != 'ok') level = 1;
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
    // A warm transfer under way: who is being consulted and whether they
    // answered ("Join & drop" needs them on the line).
    final consult = calls.where((c) => c.transferOf != null && calls.contains(c.transferOf)).firstOrNull;
    Map<String, Object?>? transfer;
    if (consult != null) {
      final talking = consult.phase == Phase.active;
      transfer = {
        'phase': talking ? 'talking' : 'calling',
        'status': tr(talking ? 'xferConnectedTo' : 'xferCalling').replaceAll('{name}', consult.title),
        'hint': tr(talking ? 'xferHintTalking' : 'xferHintCalling'),
        'join': tr('xferJoin'),
        'back': tr('xferBack'),
      };
    }
    return {
      ...base,
      'transfer': transfer,
      'phase': f.phase.name,
      'callId': f.id,
      'name': f.name,
      'number': f.number,
      'account': '${f.runtime.cfg.label} · ${f.runtime.cfg.user}',
      'status': f.transferring ? tr('transferring') : switch (f.phase) {
        Phase.outgoing => f.remoteRinging ? tr('ringing') : tr('calling'),
        Phase.held => tr('onHold'),
        _ => f.link == 'reconnecting'
            ? tr('reconnecting')
            : f.link == 'weak'
                ? tr('poorConnection')
                // Shown while recording, so it is never silent that a call is recorded.
                : (f.recording ? tr('recordingNow') : ''),
      },
      // ok | reconnecting | weak: the native screen tells a warning from the recording notice.
      'link': f.link,
      'canRecord': settings.recordingMode != 'off' || f.recording,
      'startedAt': f.answeredAt?.millisecondsSinceEpoch ?? 0,
      'outgoing': f.direction == CallDirection.outgoing,
      'muted': f.muted,
      'held': f.phase == Phase.held,
      'route': _route,
      // A picker is only worth showing when a headset is there to choose.
      'bluetooth': _routes.any((r) => r.kind == AudioRouteKind.bluetooth || r.kind == AudioRouteKind.wired),
      'routes': [
        for (final r in _routes)
          {
            'id': r.id,
            'kind': _kindName(r.kind),
            'name': r.name.isNotEmpty ? r.name : tr(_kindName(r.kind)),
          },
      ],
      'ringtone': _ringtoneSource,
      'vibrate': settings.vibrate,
      'recording': f.recording,
      'mos': s == null ? '' : fmt(mos, 1),
      // The quality sheet: each direction's MOS, then the figures behind it.
      'mosYou': s == null || s.mosLq <= 0 ? '' : fmt(s.mosLq, 1),
      'mosThem': s == null || s.mosLqRx <= 0 ? '' : fmt(s.mosLqRx, 1),
      'encrypted': f.crypto.isNotEmpty,
      // 3-bar grade. "Checking…" until the first sample, a link in
      // trouble (reconnecting, stalled media) is never better than poor.
      'qualityLevel': level,
      'qualityWord': settings.showCallQuality && f.phase == Phase.active ? tr(qualityWordKey(level)) : '',
      'quality': switch (level) { >= 3 => 'good', 2 => 'fair', 1 => 'poor', _ => '' },
      'details': s == null
          ? <List<String>>[]
          : [
              [tr('qJitter'), '${fmt(s.jitterMs)} ms'],
              [tr('qLoss'), '${fmt(s.lossPct, 1)} %'],
              [tr('qRtt'), '${fmt(s.rttMs)} ms'],
              [tr('qCodec'), '${s.codec} ${s.codecClockRate ~/ 1000} kHz'],
              [tr('qSrtp'), f.crypto.isNotEmpty ? f.crypto : tr('encNone')],
              [tr('qIce'), s.iceLocalType.name],
              [tr('qJbuf'), '${s.jitterBufferMs} ms'],
              [tr('connection'), '${f.runtime.cfg.transport.toUpperCase()} · ${f.runtime.cfg.domain}'],
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
