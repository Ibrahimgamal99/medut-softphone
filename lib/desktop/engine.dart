import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:medut/medut.dart' as sdk;
import 'package:path/path.dart' as p;

import '../core/accounts.dart';
import '../core/db.dart';
import '../sip/native_bridge.dart';
import '../sip/quality.dart';
import '../sip/sip_service.dart' show SipService;
import 'account_repo.dart';
import 'engine_config.dart';
import 'engine_log.dart';
import 'ringer.dart';

enum Phase {
  incoming,
  outgoing,
  active,
  held;

  String get wire => name;
}

/// A configured account and its live SDK object.
class AccountRuntime {
  AccountRuntime(this.cfg, this.signature);
  SipAccountConfig cfg;
  final String signature;
  sdk.Account? account;
  StreamSubscription<sdk.MedutEvent>? sub;

  /// off | registering | registered | reconnecting | failed
  String status = 'registering';
  String error = '';
  int retryInMs = 0;
  int sipCode = 0;
  int mwiNew = 0, mwiOld = 0, mwiUrgent = 0;

  /// Registered by sign-in to see whether it works, not saved yet.
  bool probe = false;
}

class ActiveCall {
  ActiveCall(this.id, this.call, this.runtime, this.incoming, this.number, this.name, this.phase);

  final String id;
  final sdk.Call call;
  AccountRuntime runtime;
  final bool incoming;
  String number, name;
  Phase phase;

  final createdAt = DateTime.now();
  DateTime? answeredAt;
  bool muted = false;
  bool recording = false;
  String recordingPath = '';
  bool userDeclined = false;
  bool remoteRinging = false;
  sdk.MediaStats? stats;
  String crypto = '';

  /// Media path health: ok | reconnecting (network change, ICE restart) | weak (media stalled).
  String link = 'ok';

  /// SIP details, read while the call is up (they are gone once it ends).
  sdk.CallInfo? info;

  /// This computer hung up / declined (vs the other side or the network).
  bool endedLocally = false;

  // Running sums for the call's average network figures (history grade).
  double rttSum = 0, jitterSum = 0, lossSum = 0;
  int samples = 0;
  Timer? autoAnswer;

  /// On the consult call of an attended transfer: the held call to hand over.
  ActiveCall? transferOf;

  /// On a call placed to follow the other side's transfer: the old leg.
  ActiveCall? replaces;

  /// A REFER was sent for this call and has not failed yet.
  bool transferring = false;

  /// Hangs our leg up if the PBX took the transfer but never ended it.
  Timer? backstop;

  /// The join was refused and the plain transfer to the same person tried instead.
  bool semiTried = false;

  /// A status feature code (DND on, queue log-in…): kept out of the history.
  bool featureCode = false;

  String get title => name.isNotEmpty ? name : number;
}

/// What the desktop shell does for the engine: the window, the tray and
/// notifications (lib/desktop/desktop_shell.dart).
class EngineHooks {
  /// A call is ringing ([on]) or no longer is: the pop-up and its notification.
  void Function(bool on) ringing = (_) {};

  /// Show the call screen (a call was placed or answered).
  void Function() showCall = () {};

  /// The main window, with a Flutter route (`chat:<peer>`, `activity`).
  void Function(String route) openRoute = (_) {};

  void Function(int count, String latest, String title) missed = (_, _, _) {};
  void Function(String peer, String who, String body) message = (_, _, _) {};

  /// The tray: how many accounts are up, and whether a call is on.
  void Function(int registered, int total, bool inCall) status = (_, _, _) {};

  /// Whether the user is looking at the main window.
  bool Function() foreground = () => true;
}

/// The desktop phone: drives Medut-SDK over dart:ffi for every account,
/// call, transfer, recording and message — PhoneEngine.kt and .swift for
/// Linux and Windows, behind the same `medut/native` surface ([handle]), so
/// SipService and the tabs work unchanged. Keep the three engines the same.
///
/// Everything runs on the UI isolate: the FFI backend delivers SDK events
/// there.
class DesktopEngine {
  DesktopEngine._();
  static final instance = DesktopEngine._();

  final hooks = EngineHooks();
  final repo = DesktopAccountRepo();
  late LocalDb _db;

  EngineConfig config = const EngineConfig({});
  sdk.Medut? _sdk;
  bool get sdkUp => _sdk != null;
  bool _started = false;

  final runtimes = <String, AccountRuntime>{};
  final calls = <ActiveCall>[];
  ActiveCall? focused;
  final presence = <String, String>{};
  List<String> _presenceTargets = const [];
  final _subscribed = <String>{};

  /// A name for [number] from the Team list or the address book ('' when none); set by main.
  String Function(String number) nameFor = (_) => '';

  /// The call screen's snapshot (CallState.kt): rebuilt on every change.
  final snapshotNotifier = ValueNotifier<Map<String, Object?>>(const {'phase': 'idle'});

  /// Feature codes waiting to be dialed: (account id, code key, code).
  final _codeQueue = <(String, String, String)>[];
  ActiveCall? _codeCall;

  /// Sign-in tries waiting for their registration to settle.
  final _probeWaiters = <String, void Function()>{};

  Timer? _statusTick;
  Timer? _applyTimer;

  // ── Start-up ──────────────────────────────────────────────────────────────

  Future<void> start(LocalDb db) async {
    if (_started) return;
    _started = true;
    _db = db;
    NativeBridge.instance.host = handle;
    await repo.load();
    try {
      final s = await sdk.Medut.start(config: _medutConfig(), libPath: libraryPath());
      _sdk = s;
      s.events.listen(_onEvent);
      // On a network change, move calls to the new path (re-INVITE) and
      // never hang up because the move failed.
      unawaited(_quiet(() => s.networkSetHandoverPolicy(true, false)));
      await _applyAudioPrefs();
    } catch (e) {
      EngineLog.conn('SDK failed to start: $e');
      debugPrint('Medut SDK failed to start: $e');
    }
    await _applyAccounts();
    _statusTick = Timer.periodic(const Duration(minutes: 1), (_) => _publishStatus()); // office hours
  }

  /// medut.so in the bundle's lib/ (Linux), medut.dll beside the .exe
  /// (Windows): where Flutter puts the medut plugin's prebuilt core.
  static String libraryPath() {
    final dir = p.dirname(Platform.resolvedExecutable);
    return Platform.isWindows ? p.join(dir, 'medut.dll') : p.join(dir, 'lib', 'medut.so');
  }

  /// Unregisters everything and stops the stack (Quit).
  Future<void> shutdown() async {
    _statusTick?.cancel();
    await DesktopRinger.stop();
    for (final c in calls.toList()) {
      await _quiet(() => c.call.hangup());
    }
    for (final id in runtimes.keys.toList()) {
      await _destroy(id);
    }
    await _quiet(() async => _sdk?.shutdown());
    _sdk = null;
  }

  // Desktop tuning: SipService._medutConfig on a wired or Wi-Fi computer.
  sdk.MedutConfig _medutConfig() => sdk.MedutConfig(
        userAgent: 'Medut/$appVersion (${Platform.operatingSystem})',
        iceGatheringTimeoutMs: 800,
        statsIntervalMs: 2000,
        mediaStallMs: 3000,
        mosAlertThreshold: 3.5,
        // DSCP EF for media, CS3 for signalling.
        dscpRtp: 46,
        dscpSip: 26,
        opus: const sdk.OpusConfig(fec: true, dtx: true),
        opusExpectedLossPct: 10,
        // Fail a dead INVITE in 10 s, not RFC 3261's 32 s.
        sipTimerBMs: 10000,
        regExpires: config.regExpires,
        keepaliveIntervalMs: config.keepaliveSec * 1000,
        logLevel: config.debugLogging ? 2 : 1,
        traceSip: config.traceSip,
        aecMode: sdk.AecMode.values[config.aecMode.clamp(0, 2)],
        noiseSuppression: config.noiseSuppression,
        autoGainControl: config.autoGain,
      );

  /// pubspec's version, set by main from the build.
  static String appVersion = '1';

  Future<void> _applyAudioPrefs() async {
    final s = _sdk;
    if (s == null) return;
    await _quiet(() async {
      await s.setAecMode(sdk.AecMode.values[config.aecMode.clamp(0, 2)]);
      await s.setNs(config.noiseSuppression);
      await s.setAgc(config.autoGain);
      await s.setJitterBufferType(sdk.JitterBufferType.adaptive);
      switch (config.jitterMode) {
        case 'low':
          await s.setJitterBuffer(20, 150);
        case 'robust':
          await s.setJitterBuffer(60, 500);
      }
    });
    await applyDevices();
  }

  /// The microphone and speaker Settings picked ('' = the system default).
  Future<void> applyDevices() async {
    final s = _sdk;
    if (s == null) return;
    await _quiet(() => s.setInputDevice(config.micDevice.isEmpty ? null : config.micDevice));
    await _quiet(() => s.setOutputDevice(config.speakerDevice.isEmpty ? null : config.speakerDevice));
  }

  Future<List<sdk.AudioDevice>> inputDevices() async =>
      await _orElse(() async => await _sdk?.listInputDevices() ?? const <sdk.AudioDevice>[], const []);

  Future<List<sdk.AudioDevice>> outputDevices() async =>
      await _orElse(() async => await _sdk?.listOutputDevices() ?? const <sdk.AudioDevice>[], const []);

  // ── The medut/native surface (NativeBridge.kt) ────────────────────────────

  Future<Object?> handle(String method, Object? raw) async {
    final args = raw is Map ? Map<String, Object?>.from(raw) : const <String, Object?>{};
    switch (method) {
      case 'ready':
      case 'state':
        return state();
      case 'getAccounts':
        return <Object?>[for (final a in repo.raw) Map<String, Object?>.from(a)];
      case 'setAccounts':
        await setAccounts([
          for (final a in args['accounts'] as List? ?? const []) Map<String, Object?>.from(a as Map),
        ]);
      case 'setConfig':
        setConfig(args);
      case 'tryRegister':
        return tryRegister(
          Map<String, Object?>.from(args['account'] as Map? ?? const {}),
          Duration(milliseconds: (args['timeoutMs'] as num? ?? 8000).toInt()),
        );
      case 'cancelProbe':
        await cancelProbe(args['id'] as String? ?? '');
      case 'retry':
        await _quiet(() async => runtimes[args['id']]?.account?.retryNow());
      case 'dial':
        await dial(args['number'] as String? ?? '', args['accountId'] as String?, args['name'] as String?);
      case 'sendMessage':
        return sendMessage(args['peer'] as String? ?? '', args['body'] as String? ?? '', args['accountId'] as String?);
      case 'queueCodes':
        queueCodes([for (final c in args['codes'] as List? ?? const []) Map<String, Object?>.from(c as Map)]);
      case 'setPresenceTargets':
        _presenceTargets = [for (final t in args['targets'] as List? ?? const []) '$t'];
        await _syncSubscriptions();
      case 'getLog':
        return EngineLog.read(args['kind'] as String? ?? 'conn', (args['since'] as num? ?? 0).toInt());
      case 'openCallScreen':
        if (calls.isNotEmpty) hooks.showCall();
      case 'missedSeen':
        break; // the tray badge follows the history
      case 'isBatteryExempt':
      case 'canUseFullScreenIntent':
        return true; // phone settings: nothing to ask on a computer
    }
    return null;
  }

  // ── Settings and accounts from Flutter ────────────────────────────────────

  void setConfig(Map<String, Object?> j) {
    config = EngineConfig(j);
    _publishStatus();
    unawaited(_applyAudioPrefs()); // the microphone and speaker too
    _scheduleApply(); // ICE servers, relay and the codec order live on the accounts
    _push();
  }

  Future<void> setAccounts(List<Map<String, Object?>> list) async {
    await repo.replace(list);
    _scheduleApply();
  }

  void _scheduleApply() {
    _applyTimer?.cancel();
    _applyTimer = Timer(const Duration(milliseconds: 300), () => unawaited(_applyAccounts()));
  }

  Future<void> _applyAccounts() async {
    if (!sdkUp) {
      pushState();
      return;
    }
    final wanted = {for (final a in repo.all.where((a) => a.enabled)) a.id: a};
    // A tried account that has been saved is an ordinary account from now on.
    for (final e in runtimes.entries) {
      if (e.value.probe && wanted.containsKey(e.key)) e.value.probe = false;
    }
    for (final id in runtimes.keys.toList()) {
      final rt = runtimes[id]!;
      if (!wanted.containsKey(id) && !rt.probe && !calls.any((c) => c.runtime.cfg.id == id)) await _destroy(id);
    }
    for (final c in wanted.values) {
      final rt = runtimes[c.id];
      if (rt == null || rt.signature != _signature(c)) {
        await _recreate(c);
      } else {
        rt.cfg = c;
      }
    }
    await _syncSubscriptions();
    pushState();
  }

  Future<void> _destroy(String id) async {
    final rt = runtimes.remove(id);
    if (rt == null) return;
    await rt.sub?.cancel();
    await _quiet(() async {
      await rt.account?.unregister();
      await rt.account?.destroy();
    });
    _subscribed.removeWhere((k) => k.startsWith('$id|'));
  }

  Future<void> _recreate(SipAccountConfig c) async {
    if (calls.any((x) => x.runtime.cfg.id == c.id)) return; // never under a live call
    final wasProbe = runtimes[c.id]?.probe == true;
    await _destroy(c.id);
    final s = _sdk;
    if (s == null) return;
    final rt = AccountRuntime(c, _signature(c))..probe = wasProbe;
    runtimes[c.id] = rt;
    try {
      final acct = await s.createAccount(c.aor, c.password, config: _accountConfig(c));
      if (runtimes[c.id] != rt) {
        await _quiet(() => acct.destroy()); // replaced while it was being made
        return;
      }
      rt.account = acct;
      rt.sub = acct.events.listen((e) => _onAccountEvent(rt, e));
      for (final (k, v) in _headerPairs(c.headers)) {
        await acct.addHeader(k, v);
      }
      await acct.register();
    } catch (e) {
      rt
        ..status = 'failed'
        ..error = e is sdk.MedutException ? (e.message ?? e.code) : '$e';
    }
  }

  /// What the SDK account is built from: a change here re-creates it (and
  /// re-registers). Settings only the app reads are left out, so renaming an
  /// account does not drop its registration (AccountCfg.signature).
  String _signature(SipAccountConfig c) {
    final j = {...c.toJson(), 'password': c.password, 'turnPass': c.turnPass};
    for (final k in ['name', 'isDefault', 'voicemail', 'recordCalls', 'dialPrefix', 'plusReplace', 'pbx', 'codes']) {
      j.remove(k);
    }
    final ice = config.iceServers.map((s) => '${s.url}|${s.user}|${s.pass}').join(',');
    return '$j|$ice|${config.forceRelay}|${config.codecs}';
  }

  /// The app-wide codec order, except that a web link puts Opus first.
  List<String> _codecsFor(SipAccountConfig c) =>
      c.transport == 'ws' || c.transport == 'wss' ? ['opus', ...config.codecs.where((x) => x != 'opus')] : config.codecs;

  sdk.AccountConfig _accountConfig(SipAccountConfig c) {
    String? opt(String v) => v.trim().isEmpty ? null : v.trim();
    final web = c.transport == 'ws' || c.transport == 'wss';
    return sdk.AccountConfig(
      transport: switch (c.transport) {
        'tcp' => sdk.Transport.tcp,
        'tls' => sdk.Transport.tls,
        'ws' => sdk.Transport.ws,
        'wss' => sdk.Transport.wss,
        _ => sdk.Transport.udp,
      },
      serverUrl: web ? opt(c.serverUrl) : null,
      authUser: opt(c.authUser),
      displayName: opt(c.displayName),
      outboundProxy: opt(c.outboundProxy),
      mediaEnc: switch (c.mediaEnc) {
        'sdes' => sdk.MediaEncryption.sdes,
        'dtls' => sdk.MediaEncryption.dtlsSrtp,
        _ => sdk.MediaEncryption.none,
      },
      iceEnabled: c.ice,
      stunServer: opt(c.stun),
      turnServer: opt(c.turn),
      turnUser: opt(c.turnUser),
      turnPass: opt(c.turnPass),
      iceServers: config.iceServers,
      iceTransportPolicy: config.forceRelay ? sdk.IceTransportPolicy.relay : sdk.IceTransportPolicy.all,
      verifyTls: c.verifyTls,
      audioCodecs: _codecsFor(c),
      dtmfMode: switch (c.dtmf) {
        'info' => sdk.DtmfMode.sipInfo,
        'auto' => sdk.DtmfMode.auto,
        _ => sdk.DtmfMode.rfc4733,
      },
    );
  }

  /// "Name: value" lines of an account's custom headers.
  static List<(String, String)> _headerPairs(String headers) => [
        for (final line in headers.split('\n'))
          if (line.indexOf(':') case final i when i > 0) (line.substring(0, i).trim(), line.substring(i + 1).trim()),
      ];

  /// Registers [raw] without saving it, to see whether it works: sign-in tries
  /// TLS, TCP and UDP this way. A registration that succeeds keeps running,
  /// so saving the same config afterwards adopts it. Anything else is torn down.
  Future<Map<String, Object?>> tryRegister(Map<String, Object?> raw, Duration timeout) async {
    if (!sdkUp) return {'status': 'failed', 'sipCode': 0, 'error': 'SIP stack not running'};
    final c = DesktopAccountRepo.fromRaw(raw);
    _probeWaiters.remove(c.id)?.call();
    runtimes[c.id]?.probe = true;
    await _recreate(c);
    final rt = runtimes[c.id];
    if (rt == null) {
      await cancelProbe(c.id);
      return {'status': 'failed', 'sipCode': 0, 'error': ''};
    }
    rt.probe = true;
    final done = Completer<Map<String, Object?>>();
    late final Timer timer;
    void finish() {
      if (done.isCompleted) return;
      timer.cancel();
      _probeWaiters.remove(c.id);
      final status = runtimes[c.id] != rt ? 'off' : rt.status; // cancelled meanwhile
      if (status != 'registered') unawaited(cancelProbe(c.id));
      done.complete({'status': status, 'sipCode': rt.sipCode, 'error': rt.error});
    }

    timer = Timer(timeout, finish); // still trying: no answer on this transport
    _probeWaiters[c.id] = () {
      if (const {'registered', 'failed', 'reconnecting'}.contains(rt.status) || runtimes[c.id] != rt) finish();
    };
    _probeWaiters[c.id]?.call();
    return done.future;
  }

  /// Drops a tried account that was not saved (failed, or the user left).
  Future<void> cancelProbe(String id) async {
    final rt = runtimes[id];
    if (rt == null || !rt.probe || repo.byId(id) != null) return;
    await _destroy(id);
    _probeWaiters.remove(id)?.call();
    pushState();
  }

  // ── SDK events ────────────────────────────────────────────────────────────

  void _onAccountEvent(AccountRuntime rt, sdk.MedutEvent e) {
    if (runtimes[rt.cfg.id] != rt) return;
    switch (e) {
      case sdk.RegStateEvent():
        _onRegistration(rt, e);
      case sdk.MwiEvent():
        rt
          ..mwiNew = e.newVoice
          ..mwiOld = e.oldVoice
          ..mwiUrgent = e.newUrgent;
        pushState();
      case sdk.MessageEvent():
        unawaited(_onMessage(rt, e));
      case sdk.PresenceStateEvent():
        presence[userPart(e.targetUri)] = e.status.name;
        pushState();
      default:
    }
  }

  void _onEvent(sdk.MedutEvent e) {
    switch (e) {
      case sdk.IncomingCallEvent():
        unawaited(_onIncoming(e));
      case sdk.CallStateEvent():
        unawaited(_onCallState(e));
      case sdk.MediaStatsEvent():
        final ac = _find(e.call);
        if (ac == null) return;
        ac.stats = e.stats;
        if (ac.phase == Phase.active || ac.phase == Phase.held) {
          ac
            ..rttSum += e.stats.rttMs
            ..jitterSum += e.stats.jitterMs
            ..lossSum += e.stats.lossPctRx
            ..samples += 1;
        }
        _push();
      case sdk.SdpNegotiationEvent():
        _find(e.call)?.crypto = e.negotiatedCrypto ?? '';
      case sdk.TransferRequestEvent():
        unawaited(_onTransferRequest(e));
      case sdk.TransferFailedEvent():
        _onTransferFailed(e);
      case sdk.NetworkEvent():
        EngineLog.conn('network ${e.stage.name}${e.localAddr.isNotEmpty ? ' ${e.localAddr}' : ''}');
        final ac = e.call == null ? null : _find(e.call!);
        if (ac == null) return;
        final link = switch (e.stage) {
          sdk.NetworkStage.callMigrating || sdk.NetworkStage.callDeferred || sdk.NetworkStage.callIceStale => 'reconnecting',
          sdk.NetworkStage.callMigrated || sdk.NetworkStage.callMigrateAccepted => 'ok',
          sdk.NetworkStage.callMigrationFailed || sdk.NetworkStage.callIceFailed => 'weak',
          _ => ac.link,
        };
        if (link != ac.link) {
          ac.link = link;
          _push();
        }
      case sdk.QualityAlertEvent():
        final ac = _find(e.call);
        if (ac == null || e.issue != sdk.QualityIssue.mediaStall) return;
        ac.link = e.recovering ? 'ok' : 'weak';
        _push();
      case sdk.LogEvent():
        if (config.debugLogging) EngineLog.conn(e.message.trim());
      case sdk.SipTraceEvent():
        EngineLog.sip('${e.direction == sdk.MediaDirection.tx ? '→' : '←'} ${e.transport} ${e.remoteAddr}\n${e.rawMessage}');
      default:
    }
  }

  void _onRegistration(AccountRuntime rt, sdk.RegStateEvent e) {
    final was = rt.status;
    rt.status = switch (e.state) {
      sdk.RegState.registered => 'registered',
      sdk.RegState.registering => 'registering',
      sdk.RegState.reconnecting => 'reconnecting',
      sdk.RegState.failed => 'failed',
      _ => 'off',
    };
    rt
      ..error = e.errorStr ?? ''
      ..retryInMs = e.retryDelayMs;
    EngineLog.conn('${rt.cfg.label}: ${e.state.name}'
        '${rt.error.isNotEmpty ? ' — ${rt.error}' : ''}'
        '${e.retryDelayMs > 0 ? ' (retry ${e.retryDelayMs ~/ 1000}s)' : ''}');
    rt.sipCode = int.tryParse(RegExp(r'\b([3-6]\d\d)\b').firstMatch(rt.error)?.group(1) ?? '') ?? 0;
    // Each refresh reports "registered" again: publish and subscribe only on arrival.
    if (rt.status == 'registered' && was != 'registered') {
      _publishStatusFor(rt);
      unawaited(_syncSubscriptions());
    }
    _probeWaiters[rt.cfg.id]?.call();
    pushState();
  }

  Future<void> _onMessage(AccountRuntime rt, sdk.MessageEvent e) async {
    final peer = userPart(e.fromUri);
    await _db.addMessage(ChatMessage(accountId: rt.cfg.id, peer: peer, body: e.body, outgoing: false, at: DateTime.now()));
    if (!hooks.foreground()) {
      final who = nameFor(peer);
      hooks.message(peer, who.isEmpty ? peer : who, e.body);
    }
    NativeBridge.instance.deliver('historyChanged');
  }

  // ── Presence and your status ──────────────────────────────────────────────

  void _publishStatus() {
    for (final rt in runtimes.values) {
      if (rt.status == 'registered') _publishStatusFor(rt);
    }
  }

  void _publishStatusFor(AccountRuntime rt) {
    final dnd = config.effectiveStatus() == 'dnd';
    unawaited(_quiet(() async => rt.account?.publishPresence(dnd ? sdk.PresenceStatus.closed : sdk.PresenceStatus.open)));
  }

  /// Follows the presence targets (lib/core/people.dart) on the default account.
  Future<void> _syncSubscriptions() async {
    final def = repo.defaultAccount;
    final rt = def == null ? null : runtimes[def.id];
    if (rt == null || rt.status != 'registered') return;
    final want = {for (final t in _presenceTargets) '${rt.cfg.id}|$t'};
    for (final key in _subscribed.difference(want).toList()) {
      final i = key.indexOf('|');
      final o = runtimes[key.substring(0, i)];
      if (o != null) await _quiet(() async => o.account?.unsubscribePresence(uriFor(o.cfg, key.substring(i + 1))));
      _subscribed.remove(key);
    }
    for (final key in want.difference(_subscribed)) {
      await _quiet(() async => rt.account?.subscribePresence(uriFor(rt.cfg, key.substring(key.indexOf('|') + 1))));
      _subscribed.add(key);
    }
  }

  /// Status feature codes to dial, one after the other as ordinary calls, so
  /// each PBX announcement is heard. Each entry is {accountId, key, code}.
  void queueCodes(List<Map<String, Object?>> codes) {
    for (final c in codes) {
      final id = c['accountId'] as String?;
      final code = c['code'] as String?;
      if (id == null || code == null) continue;
      _codeQueue.add((id, c['key'] as String? ?? '', code));
    }
    _publishStatus();
    unawaited(_dialNextCode());
  }

  /// Dials the next waiting feature code, once no call is up.
  Future<void> _dialNextCode() async {
    if (_codeCall != null || _codeQueue.isEmpty || calls.isNotEmpty) return;
    final (id, key, code) = _codeQueue.removeAt(0);
    EngineLog.conn('status code: $key $code');
    final ac = await dial(code, id, config.label('code_$key', key), show: false);
    if (ac == null) return _dialNextCode();
    ac.featureCode = true;
    _codeCall = ac;
    // The PBX hangs up after its announcement; if it does not, we do.
    ac.backstop = Timer(const Duration(seconds: 20), () {
      if (calls.contains(ac)) unawaited(hangup(ac));
    });
  }

  // ── Calls ─────────────────────────────────────────────────────────────────

  ActiveCall? _find(sdk.Call c) {
    for (final ac in calls) {
      if (ac.call.id == c.id) return ac;
    }
    return null;
  }

  ActiveCall? _byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final ac in calls) {
      if (ac.id == id) return ac;
    }
    return null;
  }

  AccountRuntime? _runtimeOf(sdk.Account? a) {
    if (a == null) return null;
    for (final rt in runtimes.values) {
      if (rt.account?.id == a.id) return rt;
    }
    return null;
  }

  Future<String> _callIdOf(sdk.Call c) async {
    final id = (await _orElse(() async => (await c.info())?.callId, null)) ?? '';
    return id.isNotEmpty ? id : c.id;
  }

  /// Whether an incoming call is turned away, and with which SIP code: 480
  /// for an account we no longer have, 603 for a blocked number, 486 when two
  /// calls are already up or under Do not disturb (unless a favourite or a
  /// repeat caller gets through; one turned away by Do not disturb still
  /// shows as missed). Null lets it ring.
  Future<int?> _refusal(sdk.Call call, AccountRuntime? rt, String number, String shown) async {
    if (rt == null) return 480;
    if (config.blocked.contains(number)) {
      EngineLog.conn('blocked call from $number');
      return 603;
    }
    if (calls.length >= 2) return 486;
    if (config.effectiveStatus() == 'dnd' && !await _dndLetsThrough(number)) {
      final name = _nameOr(number, shown);
      await _db.addCall(CallRecord(
        accountId: rt.cfg.id,
        accountName: rt.cfg.label,
        number: number,
        name: name,
        direction: CallDirection.incoming,
        result: CallResult.missed,
        startedAt: DateTime.now(),
      ));
      NativeBridge.instance.deliver('historyChanged');
      // Turned away, but still a call you missed: say so.
      await _notifyMissed(name.isEmpty ? number : name);
      return 486;
    }
    return null;
  }

  /// Under Do not disturb: a favourite or a repeat caller still rings.
  Future<bool> _dndLetsThrough(String number) async =>
      (config.letFavourites && config.favourites.any((f) => sameNumber(f, number))) ||
      (config.letRepeat && await _db.calledRecently(number));

  /// Our name for [number], else the caller's display name when it is more than the number.
  String _nameOr(String number, String shown) {
    final n = nameFor(number);
    if (n.isNotEmpty) return n;
    final s = shown.trim();
    return s == number ? '' : s;
  }

  Future<void> _onIncoming(sdk.IncomingCallEvent e) async {
    final call = e.call;
    final rt = _runtimeOf(call.account);
    final number = userPart(e.fromUri);
    final shown = e.displayName ?? '';
    final code = await _refusal(call, rt, number, shown);
    if (code != null) {
      await _quiet(() => call.reject(
            statusCode: code,
            reason: switch (code) { 603 => 'Decline', 480 => 'Temporarily Unavailable', _ => 'Busy Here' },
          ));
      return;
    }
    final ac = ActiveCall(await _callIdOf(call), call, rt!, true, number, _nameOr(number, shown), Phase.incoming);
    if (call.state.isTerminal) return; // the caller gave up while we looked
    calls.add(ac);
    // A second call while talking is "call waiting": the live one stays in front.
    focused ??= ac;
    _syncRinging();
    _push();
    pushState();
    _armAutoAnswer(ac);
  }

  /// Auto-answer (not over another call). It still rings, so it can be declined.
  void _armAutoAnswer(ActiveCall ac) {
    if (!config.autoAnswer || focused != ac) return;
    ac.autoAnswer = Timer(Duration(seconds: config.autoAnswerDelay), () {
      if (ac.phase == Phase.incoming && calls.contains(ac)) unawaited(answer(ac));
    });
  }

  /// The ringtone and the pop-up while any call rings; the ringback while the
  /// call in front is ringing at the far end. A ringing call over a live one
  /// (call waiting) rings too: a computer's speaker is not at the ear.
  void _syncRinging() {
    final ringing = calls.any((c) => c.phase == Phase.incoming);
    final f = focused;
    final back = !ringing && f != null && !f.incoming && f.phase == Phase.outgoing && f.remoteRinging && config.ringback;
    if (ringing) {
      if (_sound != 'ring') unawaited(DesktopRinger.ring(config.ringtone, device: config.ringDevice));
      _sound = 'ring';
    } else if (back) {
      if (_sound != 'back') unawaited(DesktopRinger.ringback(device: config.speakerDevice));
      _sound = 'back';
    } else if (_sound != null) {
      unawaited(DesktopRinger.stop());
      _sound = null;
    }
    if (ringing != _ringShown) {
      _ringShown = ringing;
      hooks.ringing(ringing);
    }
  }

  String? _sound;
  bool _ringShown = false;

  Future<void> _onCallState(sdk.CallStateEvent e) async {
    final ac = _find(e.call);
    if (ac == null) return;
    switch (e.state) {
      case sdk.CallState.ringing:
        ac.remoteRinging = true;
      case sdk.CallState.established:
        final first = ac.answeredAt == null;
        ac.info = await _orElse(() => ac.call.info(), null) ?? ac.info;
        if (first) ac.answeredAt = DateTime.now();
        ac.phase = Phase.active;
        // We followed a transfer and the new party answered: the old leg goes.
        final old = ac.replaces;
        ac.replaces = null;
        if (old != null && calls.contains(old)) await hangup(old);
        if (first && config.recordingMode == 'always' && ac.runtime.cfg.recordCalls && !ac.recording) {
          await _toggleRecord(ac);
        }
      case sdk.CallState.held:
        ac.phase = Phase.held;
      case sdk.CallState.ended || sdk.CallState.cancelled || sdk.CallState.failed:
        if (e.endedLocally) ac.endedLocally = true;
        await _finish(ac, e.state == sdk.CallState.failed, e.reason, e.state);
        return;
      default:
    }
    _syncRinging();
    _push();
    pushState();
  }

  Future<void> _finish(ActiveCall ac, bool failed, String? reason, sdk.CallState state) async {
    if (!calls.remove(ac)) return;
    ac.autoAnswer?.cancel();
    ac.backstop?.cancel();
    // Ended by the other side while recording: the SDK has already closed
    // the file but left its WAV header saying "no audio".
    if (ac.recording) {
      ac.recording = false;
      await SipService.repairWav(ac.recordingPath);
    }
    for (final c in calls) {
      if (c.transferOf == ac) c.transferOf = null;
      if (c.replaces == ac) c.replaces = null;
    }
    // The person we were consulting hung up, declined or never answered:
    // the caller waiting on hold comes back rather than being left there.
    final waiting = ac.transferOf;
    if (waiting != null && calls.contains(waiting) && !waiting.transferring && waiting.phase == Phase.held) {
      await _resume(waiting);
    }
    if (focused == ac) focused = calls.firstOrNull;
    _syncRinging();

    if (_codeCall == ac) _codeCall = null;
    // A feature code waiting for the line, or the next one in a row.
    if (calls.isEmpty && _codeQueue.isNotEmpty) {
      Timer(const Duration(milliseconds: 800), () => unawaited(_dialNextCode()));
    }
    if (ac.featureCode) {
      _push();
      pushState();
      return;
    }

    final answered = ac.answeredAt != null;
    final result = ac.incoming
        // Unanswered and ended here was declined; ended by the caller or the network, missed.
        ? (answered ? CallResult.answered : (ac.userDeclined || ac.endedLocally ? CallResult.declined : CallResult.missed))
        : (failed && !answered ? CallResult.failed : CallResult.answered);
    final s = ac.stats;
    final info = ac.info;
    final now = DateTime.now();
    final sipCode = (info != null && info.sipStatus > 0)
        ? info.sipStatus
        : int.tryParse(RegExp(r'\b([3-6]\d\d)\b').firstMatch(reason ?? '')?.group(1) ?? '');
    final cfg = ac.runtime.cfg;
    await _db.addCall(CallRecord(
      accountId: cfg.id,
      accountName: cfg.label,
      number: ac.number,
      name: ac.name,
      direction: ac.incoming ? CallDirection.incoming : CallDirection.outgoing,
      result: result,
      startedAt: ac.createdAt,
      answeredAt: ac.answeredAt,
      endedAt: now,
      durationSec: answered ? now.difference(ac.answeredAt!).inSeconds : 0,
      mos: s == null ? null : (s.mosLqAvg > 0 ? s.mosLqAvg : s.mosLq),
      mosMin: s != null && s.mosLqMin > 0 ? s.mosLqMin : null,
      mosRx: s != null && s.mosLqRx > 0 ? s.mosLqRx : null,
      packetsLost: s?.packetsLostRx,
      codec: s?.codec ?? '',
      icePath: s == null ? '' : '${s.iceLocalType.name} → ${s.iceRemoteType.name}',
      remoteMedia: s?.remoteAddr ?? '',
      encryption: ac.crypto.isNotEmpty ? ac.crypto : (cfg.mediaEnc == 'none' ? 'none' : cfg.mediaEnc),
      callId: (info?.callId.isNotEmpty ?? false) ? info!.callId : ac.id,
      remoteUri: info?.peerUri ?? '',
      localUri: info?.localUri ?? '',
      setupMs: (info?.setupDuration.inMilliseconds ?? 0) > 0 ? info!.setupDuration.inMilliseconds : null,
      endReason: (reason ?? '').isNotEmpty ? reason! : state.name,
      sipCode: sipCode,
      endedBy: ac.endedLocally || ac.userDeclined ? 'local' : 'remote',
      rttMs: ac.samples > 0 ? ac.rttSum / ac.samples : null,
      jitterMs: ac.samples > 0 ? ac.jitterSum / ac.samples : null,
      lossPct: ac.samples > 0 ? ac.lossSum / ac.samples : null,
      transport: cfg.transport.toUpperCase(),
      recordingPath: ac.recordingPath,
      recordingSec: await SipService.wavSeconds(ac.recordingPath),
    ));
    NativeBridge.instance.deliver('historyChanged');
    if (result == CallResult.missed) await _notifyMissed(ac.title);
    if (failed && (reason ?? '').isNotEmpty) _notice(reason!);
    _push();
    pushState();
  }

  Future<void> _notifyMissed(String latest) async {
    final count = await _db.missedSince(config.activitySeenAt);
    if (count <= 0) return;
    hooks.missed(
      count,
      latest,
      count > 1 ? config.label('missedCalls', '{n} missed calls', {'n': '$count'}) : config.label('missedCall', 'Missed call'),
    );
  }

  // ── Actions from the call screen, the pop-up, the tray and Flutter ────────

  Future<void> action(String name, [Map<String, Object?> args = const {}]) async {
    final ac = _byId(args['callId'] as String?) ?? focused;
    switch (name) {
      case 'answer':
        if (ac != null) await answer(ac);
      case 'decline':
        if (ac != null) await decline(ac, 603);
      case 'busy':
        if (ac != null) await decline(ac, 486);
      case 'hangup':
        if (ac != null) await hangup(ac);
      case 'mute' || 'unmute':
        if (ac != null) await _setMute(ac, name == 'mute');
      case 'toggleMute':
        if (ac != null) await _setMute(ac, !ac.muted);
      case 'hold':
        if (ac != null) await _hold(ac);
      case 'unhold':
        if (ac != null) await _resume(ac);
      case 'record':
        if (ac != null) await _toggleRecord(ac);
      case 'dtmf':
        final d = args['digit'] as String? ?? '';
        if (ac != null && d.isNotEmpty) await _quiet(() => ac.call.sendDtmf(d[0]));
      case 'swap':
        final other = calls.where((c) => c != focused && c.phase != Phase.incoming).firstOrNull;
        if (other != null) await _resume(other);
      case 'answerWaiting':
        final w = calls.where((c) => c.phase == Phase.incoming).firstOrNull;
        if (w != null) await answer(w);
      case 'completeTransfer':
        await _completeTransfer();
      case 'cancelTransfer':
        final consult = calls.where((c) => c.transferOf != null).firstOrNull;
        if (consult != null) await hangup(consult);
      case 'transferBlind':
        final target = (args['target'] as String? ?? '').trim();
        if (focused != null && target.isNotEmpty) await _refer(focused!, target);
      case 'transferWarm':
        final target = (args['target'] as String? ?? '').trim();
        final original = focused;
        if (original == null || target.isEmpty) return;
        (await dial(target, original.runtime.cfg.id, null))?.transferOf = original;
        _push();
      case 'addCall':
        final n = args['number'] as String?;
        if (n != null) await dial(n, focused?.runtime.cfg.id, null);
      case 'reply' || 'message':
        if (ac == null) return;
        if (name == 'reply') await decline(ac, 486);
        hooks.openRoute('chat:${ac.number}');
    }
  }

  Future<void> answer(ActiveCall ac) async {
    if (ac.phase != Phase.incoming) return;
    for (final other in calls.toList()) {
      if (other != ac && other.phase == Phase.active) await _hold(other);
    }
    focused = ac;
    ac.autoAnswer?.cancel();
    await _quiet(() => ac.call.answer());
    hooks.showCall();
    _push();
    pushState();
  }

  Future<void> decline(ActiveCall ac, [int code = 603]) async {
    ac.userDeclined = true;
    await _quiet(() => ac.call.reject(statusCode: code, reason: code == 486 ? 'Busy Here' : 'Decline'));
  }

  Future<void> hangup(ActiveCall ac) async {
    ac.endedLocally = true;
    // Close the recording while the call still exists: once it has ended
    // the SDK has freed it.
    if (ac.recording) {
      await _quiet(() => ac.call.recordStop());
      ac.recording = false;
    }
    if (ac.phase == Phase.incoming) {
      await decline(ac);
    } else {
      await _quiet(() => ac.call.hangup());
    }
  }

  Future<void> _setMute(ActiveCall ac, bool on) async {
    await _quiet(() => ac.call.mute(on: on));
    ac.muted = on;
    _push();
  }

  Future<void> _hold(ActiveCall ac) async {
    if (ac.phase != Phase.active) return;
    await _quiet(() => ac.call.hold());
    ac.phase = Phase.held;
    _push();
    pushState();
  }

  Future<void> _resume(ActiveCall ac) async {
    for (final other in calls.toList()) {
      if (other != ac && other.phase == Phase.active) await _hold(other);
    }
    await _quiet(() => ac.call.resume());
    ac.phase = Phase.active;
    focused = ac;
    _push();
    pushState();
  }

  Future<void> _toggleRecord(ActiveCall ac) async {
    if (!ac.recording && config.recordingMode == 'off') return;
    if (ac.recording) {
      await _quiet(() => ac.call.recordStop());
      ac.recording = false;
    } else {
      final dir = config.recordingDir.isNotEmpty ? config.recordingDir : p.join(Directory.systemTemp.path, 'medut');
      await Directory(dir).create(recursive: true);
      ac.recordingPath = p.join(dir, SipService.recordingName(ac.number, ac.name, DateTime.now()));
      try {
        await ac.call.recordStart(ac.recordingPath);
        ac.recording = true;
      } catch (e) {
        _notice('$e');
      }
    }
    _push();
  }

  // ── Placing calls and transfers ───────────────────────────────────────────

  /// Which account places a call to [number]: the one asked for, a dial rule, the default.
  AccountRuntime? _accountFor(String number, String? accountId) {
    final asked = runtimes[accountId];
    if (asked != null && !asked.probe) return asked;
    for (final r in config.dialRules) {
      final rt = runtimes[r.accountId];
      if (r.matches(number) && rt != null && !rt.probe) return rt;
    }
    final def = repo.defaultAccount;
    return def == null ? null : runtimes[def.id];
  }

  /// Places a call; an active call is put on hold first ("Add call").
  Future<ActiveCall?> dial(String input, String? accountId, String? name, {bool show = true}) async {
    final rt = _accountFor(input, accountId);
    final acct = rt?.account;
    if (rt == null || acct == null) {
      _notice(config.label('noAccount', 'Add a SIP account first'));
      return null;
    }
    if (calls.length >= 2) {
      _notice(config.label('twoCallsMax', 'You can have two calls at once'));
      return null;
    }
    for (final other in calls.toList()) {
      if (other.phase == Phase.active) await _hold(other);
    }
    try {
      final call = await acct.call(uriFor(rt.cfg, input));
      final number = userPart(input);
      final ac = ActiveCall(await _callIdOf(call), call, rt, false, number, name ?? nameFor(number), Phase.outgoing);
      calls.add(ac);
      focused = ac;
      _push();
      pushState();
      if (show) hooks.showCall();
      return ac;
    } catch (e) {
      _notice('${config.label('callFailed', "Couldn't place the call")}: ${e is sdk.MedutException ? e.message ?? e.code : e}');
      return null;
    }
  }

  /// Sends [ac]'s caller to [target] (REFER). The PBX ends our leg when it
  /// takes the call; a refusal comes back as TransferFailed and the call
  /// carries on. If neither happens, our leg is hung up after 20 s.
  Future<void> _refer(ActiveCall ac, String target) async {
    ac.transferring = true;
    try {
      await ac.call.transfer(SipService.referUri(ac.runtime.cfg, target));
    } catch (e) {
      _notice('${config.label('transferFailed', 'Transfer failed')}: $e');
    }
    _armBackstop(ac);
    _push();
  }

  void _armBackstop(ActiveCall ac) {
    ac.backstop?.cancel();
    ac.backstop = Timer(const Duration(seconds: 20), () {
      if (calls.contains(ac) && ac.transferring) unawaited(hangup(ac));
    });
  }

  /// Joins the held caller to the person consulted (REFER with Replaces).
  /// Still ringing there: the caller is sent to that number instead, since a
  /// call nobody answered cannot be replaced.
  Future<void> _completeTransfer() async {
    final consult = calls.where((c) => c.transferOf != null).firstOrNull;
    final original = consult?.transferOf;
    if (consult == null || original == null) return;
    if (consult.phase == Phase.outgoing || consult.phase == Phase.incoming) {
      consult.transferOf = null; // its end must not take the caller off hold
      await hangup(consult);
      await _refer(original, consult.number);
    } else {
      original.transferring = true;
      try {
        await original.call.attendedTransfer(consult.call);
      } catch (e) {
        _notice('${config.label('transferFailed', 'Transfer failed')}: $e');
      }
      _armBackstop(original);
      _push();
    }
  }

  Future<void> _onTransferRequest(sdk.TransferRequestEvent e) async {
    // The other side (or the PBX) moves us to another party: follow it, and
    // drop the old leg once the new one answers. The transferor waits for an
    // answer either way, so one we cannot follow is refused.
    if (e.autoFollowed) return;
    final old = _find(e.call);
    final next = old == null ? null : await _orElse(() => e.call.transferAccept(), null);
    if (old == null || next == null) {
      await _quiet(() => e.call.transferReject());
      return;
    }
    final number = userPart(e.referToUri);
    final ac = ActiveCall(await _callIdOf(next), next, old.runtime, false, number, nameFor(number), Phase.outgoing)
      ..replaces = old;
    calls.add(ac);
    focused = ac;
    _push();
    pushState();
  }

  void _onTransferFailed(sdk.TransferFailedEvent e) {
    final ac = _find(e.call);
    if (ac != null) {
      ac.backstop?.cancel();
      final consult = calls.where((c) => c.transferOf == ac).firstOrNull;
      if (consult != null && !ac.semiTried) {
        // The PBX would not join the two calls: send the caller to the same
        // person as a plain transfer instead.
        ac.semiTried = true;
        consult.transferOf = null;
        unawaited(hangup(consult).then((_) => _refer(ac, consult.number)));
        return;
      }
      ac.transferring = false;
      if (ac.phase == Phase.held) unawaited(_resume(ac));
      _push();
    }
    final why = e.reason;
    _notice(config.label('transferFailed', 'Transfer failed') + (why.isEmpty ? '' : ': $why'));
  }

  Future<String?> sendMessage(String peer, String body, String? accountId) async {
    final rt = _accountFor(peer, accountId);
    final acct = rt?.account;
    if (rt == null || acct == null) return config.label('noAccount', 'Add a SIP account first');
    try {
      await acct.sendMessage(uriFor(rt.cfg, peer), body);
      await _db.addMessage(ChatMessage(accountId: rt.cfg.id, peer: userPart(peer), body: body, outgoing: true, at: DateTime.now(), read: true));
      NativeBridge.instance.deliver('historyChanged');
      return null;
    } catch (e) {
      return e is sdk.MedutException ? (e.message ?? e.code) : '$e';
    }
  }

  // ── Names and numbers ─────────────────────────────────────────────────────

  static String userPart(String uri) => SipService.userPart(uri);
  static String uriFor(SipAccountConfig cfg, String input) => SipService.uriFor(cfg, input);

  /// The same number however it is written: the last nine digits (people.dart).
  static bool sameNumber(String a, String b) {
    String tail(String n) {
      final d = n.replaceAll(RegExp(r'\D'), '');
      return d.length > 9 ? d.substring(d.length - 9) : d;
    }

    final x = tail(a);
    return x.isNotEmpty && x == tail(b);
  }

  void _notice(String text) {
    if (text.isNotEmpty) NativeBridge.instance.deliver('notice', {'text': text});
  }

  // ── Snapshot for the call screen, state for Flutter ───────────────────────

  void _push() {
    snapshotNotifier.value = snapshot();
    _pushTray();
  }

  void _pushTray() {
    final total = runtimes.values.where((r) => !r.probe).length;
    final up = runtimes.values.where((r) => !r.probe && r.status == 'registered').length;
    hooks.status(up, total, calls.isNotEmpty);
  }

  static String _fmt(double v, [int d = 0]) => v.toStringAsFixed(d);

  /// English for the grade, until the translations arrive (Quality.wordFallback).
  static const _qualityWord = ['Checking…', 'Poor', 'Fair', 'Good', 'Excellent'];

  Map<String, Object?> snapshot() {
    final base = <String, Object?>{'dark': config.dark, 'rtl': config.rtl};
    final f = focused ?? calls.firstOrNull;
    if (f == null) return {...base, 'phase': 'idle'};
    final other = calls.where((c) => c != f).firstOrNull;
    final s = config.showCallQuality ? f.stats : null;
    var level = s == null ? 0 : callQualityLevel(mos: s.mosLq, rttMs: s.rttMs, jitterMs: s.jitterMs, lossPct: s.lossPctRx);
    if (f.link != 'ok') level = 1;
    final l = config;
    final second = other == null
        ? null
        : other.phase == Phase.incoming
            ? {'name': other.title, 'text': '↙ ${other.title}', 'label': l.label('answer', 'Answer'), 'action': 'answerWaiting'}
            : f.transferOf == other
                ? {
                    'name': other.title,
                    'text': '${other.title} · ${l.label('onHold', 'On hold')}',
                    'label': l.label('complete', 'Complete'),
                    'action': 'completeTransfer',
                  }
                : {
                    'name': other.title,
                    'text': '${other.title} · ${l.label('onHold', 'On hold')}',
                    'label': l.label('swap', 'Swap'),
                    'action': 'swap',
                  };
    // A warm transfer under way: who is being consulted and whether they answered.
    final consult = calls.where((c) => c.transferOf != null && calls.contains(c.transferOf)).firstOrNull;
    final transfer = consult == null
        ? null
        : () {
            final talking = consult.phase == Phase.active;
            return {
              'phase': talking ? 'talking' : 'calling',
              'status': talking
                  ? l.label('xferConnectedTo', 'Connected to {name}', {'name': consult.title})
                  : l.label('xferCalling', 'Calling {name}…', {'name': consult.title}),
              'hint': talking
                  ? l.label('xferHintTalking', 'Join & drop connects them and you leave the call.')
                  : l.label('xferHintCalling', "Your caller is on hold and can't hear this."),
              'join': l.label('xferJoin', 'Join & drop'),
              'back': l.label('xferBack', 'Back to caller'),
            };
          }();
    final status = f.transferring
        ? l.label('transferring', 'Transferring…')
        : switch (f.phase) {
            Phase.outgoing => f.remoteRinging ? l.label('ringing', 'Ringing') : l.label('calling', 'Calling…'),
            Phase.held => l.label('onHold', 'On hold'),
            _ => switch (f.link) {
                'reconnecting' => l.label('reconnecting', 'Reconnecting…'),
                'weak' => l.label('poorConnection', 'Poor connection'),
                // Shown while recording, so it is never silent that a call is recorded.
                _ => f.recording ? l.label('recordingNow', 'This call is being recorded') : '',
              },
          };
    final cfg = f.runtime.cfg;
    return {
      ...base,
      'transfer': transfer,
      'phase': f.phase.wire,
      'ring': f.phase == Phase.incoming,
      'callId': f.id,
      'name': f.name,
      'number': f.number,
      'account': '${cfg.label} · ${cfg.user}',
      'accountId': cfg.id,
      'status': status,
      'link': f.link,
      'canRecord': config.recordingMode != 'off' || f.recording,
      'startedAt': f.answeredAt?.millisecondsSinceEpoch ?? 0,
      'outgoing': !f.incoming,
      'muted': f.muted,
      'held': f.phase == Phase.held,
      'recording': f.recording,
      'mos': s == null ? '' : _fmt(s.mosLq, 1),
      'mosYou': s == null || s.mosLq <= 0 ? '' : _fmt(s.mosLq, 1),
      'mosThem': s == null || s.mosLqRx <= 0 ? '' : _fmt(s.mosLqRx, 1),
      'encrypted': f.crypto.isNotEmpty,
      // 3-bar grade. "Checking…" until the first sample; a link in trouble is never better than poor.
      'qualityLevel': level,
      'qualityWord': config.showCallQuality && f.phase == Phase.active ? l.label(qualityWordKey(level), _qualityWord[level.clamp(0, 4)]) : '',
      'details': s == null
          ? const <List<String>>[]
          : [
              [l.label('qJitter', 'Jitter'), '${_fmt(s.jitterMs)} ms'],
              [l.label('qLoss', 'Packet loss'), '${_fmt(s.lossPct, 1)} %'],
              [l.label('qRtt', 'Round trip'), '${_fmt(s.rttMs)} ms'],
              [l.label('qCodec', 'Codec'), '${s.codec} ${s.codecClockRate ~/ 1000} kHz'],
              [l.label('qSrtp', 'Encryption'), f.crypto.isNotEmpty ? f.crypto : l.label('encNone', 'None')],
              [l.label('qIce', 'Network path'), s.iceLocalType.name],
              [l.label('qJbuf', 'Jitter buffer'), '${s.jitterBufferMs} ms'],
              [l.label('connection', 'Connection'), '${cfg.transport.toUpperCase()} · ${cfg.domain}'],
            ],
      'second': second,
      'calls': calls.length,
    };
  }

  bool _statePosted = false;

  /// Sends Flutter what its tabs show, once per event-loop turn at most.
  void pushState() {
    _pushTray();
    if (_statePosted) return;
    _statePosted = true;
    scheduleMicrotask(() {
      _statePosted = false;
      NativeBridge.instance.deliver('state', state());
    });
  }

  Map<String, Object?> state() => {
        'accounts': {
          for (final e in runtimes.entries)
            e.key: {
              'status': e.value.status,
              'error': e.value.error,
              'sipCode': e.value.sipCode,
              'retryInMs': e.value.retryInMs,
              'mwiNew': e.value.mwiNew,
              'mwiOld': e.value.mwiOld,
              'mwiUrgent': e.value.mwiUrgent,
              'probe': e.value.probe,
            },
        },
        'calls': [
          for (final c in calls)
            {
              'id': c.id,
              'accountId': c.runtime.cfg.id,
              'number': c.number,
              'name': c.name,
              'phase': c.phase.wire,
              'answeredAt': c.answeredAt?.millisecondsSinceEpoch ?? 0,
            },
        ],
        'focused': focused?.id,
        'presence': Map<String, String>.of(presence),
        'version': _sdk?.version ?? '',
        'connSeq': EngineLog.seq('conn'),
        'sipSeq': EngineLog.seq('sip'),
      };

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Runs an SDK call whose failure only matters to the log.
  static Future<void> _quiet(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('medut: $e');
    }
  }

  static Future<T> _orElse<T>(Future<T> Function() f, T fallback) async {
    try {
      return await f();
    } catch (_) {
      return fallback;
    }
  }
}
