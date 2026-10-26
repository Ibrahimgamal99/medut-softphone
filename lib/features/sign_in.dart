import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../core/accounts.dart';
import '../core/language.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../desktop/platform.dart';
import '../sip/probe.dart';
import '../sip/sip_service.dart';
import '../ui/widgets.dart';
import 'account_edit.dart';

/// What "More options" holds. The sheet edits it and the sign-in screen
/// reads it, so both listen to the same object.
class SignInOptions extends ChangeNotifier {
  /// auto | udp | tcp | tls | wss, or ws when a QR code asked for it.
  String transport = 'auto';
  bool encrypt = false;

  /// sdes | dtls, used when [encrypt] is on.
  String enc = 'sdes';
  bool ice = false;
  final wsUrl = TextEditingController();
  final stun = TextEditingController();
  final turn = TextEditingController();
  final turnUser = TextEditingController();
  final turnPass = TextEditingController();
  final authUser = TextEditingController();
  final proxy = TextEditingController();
  final display = TextEditingController();

  // Turned on by choosing a web link rather than by hand, so leaving the web
  // link turns them off again.
  bool _autoEncrypt = false, _autoIce = false;
  String _encBeforeWeb = 'sdes';

  bool get webLink => transport == 'wss' || transport == 'ws';

  /// Call encryption is offered over TLS and web links only; in Auto it
  /// applies when the connection found is one of those.
  bool get canEncrypt => transport == 'auto' || transport == 'tls' || webLink;

  /// SRTP keys need a secure signalling path: never over plain UDP or TCP.
  static bool encryptsOver(String transport) => transport == 'tls' || transport == 'wss' || transport == 'ws';

  String get mediaEnc => encrypt ? enc : 'none';

  /// A web link is a WebRTC server: it wants DTLS media and ICE.
  void setTransport(String t) {
    final wasWeb = webLink;
    transport = t;
    if (webLink && !wasWeb) {
      _encBeforeWeb = enc;
      enc = 'dtls';
      if (!encrypt) {
        encrypt = true;
        _autoEncrypt = true;
      }
      if (!ice) {
        _iceOn();
        _autoIce = true;
      }
    } else if (!webLink && wasWeb) {
      enc = _encBeforeWeb;
      if (_autoEncrypt) encrypt = false;
      if (_autoIce) ice = false;
      _autoEncrypt = _autoIce = false;
    }
    notifyListeners();
  }

  void setEncrypt(bool on) {
    encrypt = on;
    _autoEncrypt = false;
    if (on && webLink) enc = 'dtls';
    notifyListeners();
  }

  void setEnc(String e) {
    enc = e;
    notifyListeners();
  }

  void setIce(bool on) {
    _autoIce = false;
    if (on) {
      _iceOn();
    } else {
      ice = false;
    }
    notifyListeners();
  }

  void _iceOn() {
    ice = true;
    if (stun.text.trim().isEmpty) stun.text = kDefaultStun;
  }

  /// Takes what a QR code, file or pasted text carried; [keepAuto] when it
  /// named no transport, so the connection is still found by itself.
  void fill(SipAccountConfig p, {required bool keepAuto}) {
    transport = keepAuto ? 'auto' : p.transport;
    wsUrl.text = p.serverUrl;
    encrypt = p.mediaEnc != 'none';
    enc = p.mediaEnc == 'dtls' ? 'dtls' : 'sdes';
    ice = p.ice;
    stun.text = p.stun;
    turn.text = p.turn;
    turnUser.text = p.turnUser;
    turnPass.text = p.turnPass;
    authUser.text = p.authUser;
    proxy.text = p.outboundProxy;
    display.text = p.displayName;
    _autoEncrypt = _autoIce = false;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final c in [wsUrl, stun, turn, turnUser, turnPass, authUser, proxy, display]) {
      c.dispose();
    }
    super.dispose();
  }
}

/// Pocket · Sign in: a SIP address and a password. Every way in (TLS, TCP,
/// UDP, web link) is checked at once and the first that registers is kept.
/// A QR code, a setup file or pasted text fill the form instead; "More
/// options" holds what a PBX may need, and "All technical settings" the rest.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key, this.another = false});

  /// Adding one more account (pushed from Accounts) rather than first launch.
  final bool another;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

enum _Stage { form, checking, failed, connected }

enum _Fail { noServer, noAnswer, badPassword, notFound, refused }

class _SignInScreenState extends ConsumerState<SignInScreen> {
  late final SipService _sip = ref.read(sipProvider);
  final _address = TextEditingController();
  final _pass = TextEditingController();
  final _passFocus = FocusNode();
  final _addressFocus = FocusNode();
  final _opts = SignInOptions();

  /// Your name on calls, and what to call the account, asked on the
  /// Connected step.
  final _accountName = TextEditingController();

  /// What a QR code or file carried beyond the form (TURN, TLS checks, …).
  SipAccountConfig _base = const SipAccountConfig(id: '', name: '', user: '', domain: '');
  bool _showPass = false;
  bool _saving = false;
  String? _error;
  _Stage _stage = _Stage.form;

  // The current attempt: each try registers under its own id, dropped
  // again unless it is saved.
  int _attempt = 0;
  final Set<String> _tried = {};
  final Map<String, (CheckState, String, String)> _steps = {};
  final List<String> _log = [];
  DateTime _startedAt = DateTime.now();
  Timer? _ticker;
  _Fail _fail = _Fail.noAnswer;
  int _failCode = 0;
  SipAccountConfig? _connected;

  /// What the last check found, so "All technical settings" starts from it.
  List<ProbeHit> _found = const [];

  @override
  void initState() {
    super.initState();
    _sip; // read now: dispose may need it after the root has switched away
    _address.addListener(_changed);
    _pass.addListener(_changed);
    _opts.addListener(_changed);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    for (final id in _tried) {
      _sip.cancelProbe(id);
    }
    for (final c in [_address, _pass, _accountName]) {
      c.dispose();
    }
    _passFocus.dispose();
    _addressFocus.dispose();
    _opts.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() => _error = null);
  }

  /// `201@pbx.example.com[:port]`, with or without `sip:`.
  ({String user, String domain, int port})? _parse() {
    final s = _address.text.trim().replaceFirst(RegExp(r'^sips?:', caseSensitive: false), '');
    final at = s.lastIndexOf('@');
    if (at <= 0 || at == s.length - 1) return null;
    final hp = SipAccountConfig.splitHostPort(s.substring(at + 1));
    if (hp == null || hp.host.isEmpty || hp.host.contains(' ')) return null;
    return (user: s.substring(0, at), domain: hp.host, port: hp.port);
  }

  bool get _canSubmit => _stage != _Stage.checking && _address.text.trim().isNotEmpty && _pass.text.isNotEmpty;

  /// The account to try over [transport]; [url] is a web link the check
  /// found, which also means DTLS and ICE whatever the options say. Plain
  /// UDP and TCP never carry encrypted media.
  SipAccountConfig _config(String transport, {String url = ''}) {
    final p = _parse();
    final o = _opts;
    final web = transport == 'wss' || transport == 'ws';
    final found = url.isNotEmpty;
    final ice = found || o.ice;
    final stun = o.stun.text.trim();
    return SipAccountConfig.fromJson({..._base.toJson(), 'id': SipAccountConfig.newId()},
            password: _pass.text, turnPass: ice ? o.turnPass.text : _base.turnPass)
        .copyWith(
      name: _base.name.isNotEmpty && _base.name != _base.domain ? _base.name : p?.domain ?? '',
      user: p?.user ?? '',
      domain: p?.domain ?? '',
      port: p?.port ?? 0,
      transport: transport,
      serverUrl: web ? (found ? url : o.wsUrl.text.trim()) : '',
      authUser: o.authUser.text.trim(),
      outboundProxy: o.proxy.text.trim(),
      displayName: o.display.text.trim(),
      mediaEnc: found ? 'dtls' : (SignInOptions.encryptsOver(transport) ? o.mediaEnc : 'none'),
      ice: ice,
      stun: ice ? (stun.isEmpty ? kDefaultStun : stun) : _base.stun,
      turn: ice ? o.turn.text.trim() : _base.turn,
      turnUser: ice ? o.turnUser.text.trim() : _base.turnUser,
      enabled: true,
      isDefault: ref.read(accountsProvider).accounts.isEmpty,
    );
  }

  Future<void> _signIn() async {
    final p = _parse();
    if (p == null) {
      setState(() => _error = 'addressInvalid'.tr());
      return;
    }
    if (_opts.webLink && !RegExp(r'^wss?://', caseSensitive: false).hasMatch(_opts.wsUrl.text.trim())) {
      setState(() => _error = 'webLinkNeeded'.tr());
      unawaited(_moreOptions());
      return;
    }
    FocusScope.of(context).unfocus();
    final attempt = ++_attempt;
    bool live() => mounted && attempt == _attempt;
    final logFrom = _sip.connLog.length;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    setState(() {
      _stage = _Stage.checking;
      _error = null;
      _steps.clear();
      _log.clear();
      _startedAt = DateTime.now();
    });

    var tries = <SipAccountConfig>[];
    var resolved = true;
    if (_opts.transport == 'auto') {
      final report = await _sip.probe(p.domain, port: p.port, onStep: (k, s, d, e) {
        if (live()) setState(() => _steps[k] = (s, d, e));
      });
      if (!live()) return;
      _log.addAll(report.log);
      resolved = report.resolved;
      _found = report.hits;
      tries = [for (final h in report.hits) _config(h.transport, url: h.url)];
      // Nothing answered a check: the server may sit behind SIP DNS (SRV)
      // records, which only a real sign-in follows.
      if (tries.isEmpty) tries = [for (final t in const ['tls', 'tcp', 'udp']) _config(t)];
    } else {
      tries = [_config(_opts.transport)];
    }

    RegProbe? last;
    for (final cfg in tries) {
      setState(() => _steps['register'] = (CheckState.running, cfg.transport, ''));
      _tried.add(cfg.id);
      final r = await _sip.tryRegister(cfg);
      if (!live()) {
        _sip.cancelProbe(cfg.id);
        return;
      }
      last = r;
      _log.add('REG  ${cfg.transport.toUpperCase().padRight(4)} ${_regWords(r)}');
      if (r.ok) {
        _ticker?.cancel();
        setState(() {
          _steps['register'] = (CheckState.ok, cfg.transport, '');
          _connected = cfg;
          _accountName.text = cfg.name;
          _stage = _Stage.connected;
        });
        return;
      }
      // A SIP refusal means this way works and the others would get the same answer.
      if (_refusal(r)) break;
    }
    _ticker?.cancel();
    final log = _sip.connLog;
    _log.addAll(log.skip(logFrom.clamp(0, log.length)));
    setState(() {
      _failCode = last?.sipCode ?? 0;
      _steps['register'] = (CheckState.failed, _failCode > 0 ? 'code' : 'noAnswer', _failCode > 0 ? '$_failCode' : '');
      _fail = switch (last) {
        final r? when r.badPassword => _Fail.badPassword,
        final r? when r.sipCode == 404 => _Fail.notFound,
        final r? when _refusal(r) => _Fail.refused,
        _ => resolved ? _Fail.noAnswer : _Fail.noServer,
      };
      _stage = _Stage.failed;
    });
  }

  static bool _refusal(RegProbe r) => r.sipCode >= 400 && r.sipCode != 408 && r.sipCode != 503;

  static String _regWords(RegProbe r) {
    if (r.ok) return 'registered';
    if (r.status == RegStatus.registering) return 'no answer';
    return [if (r.sipCode > 0) '${r.sipCode}', if (r.error.isNotEmpty) r.error].join(' ').ifEmpty('failed');
  }

  /// Stops a check, or leaves the Connected step without saving.
  void _cancel() {
    _attempt++;
    _ticker?.cancel();
    for (final id in _tried) {
      _sip.cancelProbe(id);
    }
    _tried.clear();
    setState(() {
      _stage = _Stage.form;
      _connected = null;
    });
  }

  Future<void> _finish() async {
    final c = _connected!;
    setState(() => _saving = true);
    final label = _accountName.text.trim();
    await ref
        .read(accountsProvider)
        .save(c.copyWith(name: label.isEmpty ? c.domain : label));
    // Ask once, at the moment it makes sense: calls need the mic, and
    // ringing in the background needs notifications. A computer does not ask.
    if (!isDesktop) await [Permission.microphone, Permission.notification].request();
    // First launch: the app root switches to the tabs by itself.
    if (mounted && widget.another) Navigator.pop(context);
  }

  // ── Other ways in ─────────────────────────────────────────────────────────

  /// A QR code, a file or pasted text: a Medut-SDK account JSON or a SIP URI.
  void _apply(String raw) {
    final p = SipAccountConfig.parseProvisioning(raw);
    if (p == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('invalidQr'.tr())));
      return;
    }
    final named = RegExp('transport', caseSensitive: false).hasMatch(raw) || p.serverUrl.isNotEmpty;
    setState(() {
      _base = p;
      _address.text = p.port > 0 ? '${p.user}@${p.domain}:${p.port}' : '${p.user}@${p.domain}';
      _pass.text = p.password;
      _opts.fill(p, keepAuto: !named);
      _stage = _Stage.form;
    });
    // Without the password: ask for it, then sign in.
    if (p.password.isEmpty) {
      _passFocus.requestFocus();
    } else {
      _signIn();
    }
  }

  Future<void> _scan() async {
    if (!(await Permission.camera.request()).isGranted || !mounted) return;
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw != null && mounted) _apply(raw);
  }

  Future<void> _import() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json', 'txt']);
    final path = r?.files.single.path;
    if (path == null || !mounted) return;
    final text = await File(path).readAsString();
    if (mounted) _apply(text);
  }

  Future<void> _paste() async {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted) return;
    if (clip.isNotEmpty && SipAccountConfig.parseProvisioning(clip) != null) {
      _apply(clip);
      return;
    }
    final raw = await showDialog<String>(context: context, builder: (_) => PasteAccountDialog(initial: clip));
    if (raw != null && raw.trim().isNotEmpty && mounted) _apply(raw);
  }

  Future<void> _setupSheet() async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          if (!isDesktop)
            ListTile(leading: const Icon(Icons.qr_code_scanner), title: Text('scanQr'.tr()), onTap: () => Navigator.pop(ctx, 'scan')),
          ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text('importFile'.tr()),
              onTap: () => Navigator.pop(ctx, 'import')),
          ListTile(leading: const Icon(Icons.content_paste), title: Text('paste'.tr()), onTap: () => Navigator.pop(ctx, 'paste')),
          const SizedBox(height: 8),
        ]),
      ),
    );
    switch (pick) {
      case 'scan':
        await _scan();
      case 'import':
        await _import();
      case 'paste':
        await _paste();
    }
  }

  Future<void> _openTechnical() async {
    final hit = _opts.transport == 'auto' ? _found.firstOrNull : null;
    final initial = hit != null
        ? _config(hit.transport, url: hit.url)
        : _config(_opts.transport == 'auto' ? 'tls' : _opts.transport);
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => AccountEditScreen(initial: initial),
    ));
    if (saved == true && mounted && widget.another) Navigator.pop(context);
  }

  /// "More options · WSS · DTLS · ICE" when anything differs from the defaults.
  String get _moreLabel => [
        'moreOptions'.tr(),
        if (_opts.transport != 'auto') _opts.transport.toUpperCase(),
        if (_opts.encrypt) _opts.enc == 'dtls' ? 'DTLS' : 'SRTP',
        if (_opts.ice) 'ICE',
      ].join(' · ');

  Future<void> _moreOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => MoreOptionsSheet(
        opts: _opts,
        onTechnical: () {
          Navigator.pop(ctx);
          _openTechnical();
        },
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _copyLog() async {
    await Clipboard.setData(ClipboardData(text: _log.join('\n')));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('logCopied'.tr())));
  }

  // ── Layout ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final form = _stage == _Stage.form;
    final busy = _stage == _Stage.checking;
    final body = switch (_stage) {
      _Stage.checking => _checkingBody(context),
      _Stage.failed => _failedBody(context),
      _ => _formBody(context),
    };
    return Scaffold(
      body: SafeArea(
        child: _Page(children: [
          if (_stage == _Stage.connected)
            ..._connectedBody(context)
          else ...[
            _header(context),
            SizedBox(height: form ? 26 : 12),
            Text(widget.another ? 'addAnotherTitle'.tr() : 'signIn'.tr(),
                style: TextStyle(fontSize: form ? 34 : 28, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.05)),
            if (form) ...[
              const SizedBox(height: 8),
              Text('signInSub'.tr(), style: TextStyle(fontSize: 14.5, color: t.text2, height: 1.4)),
            ],
            SizedBox(height: form ? 22 : 14),
            TextField(
              controller: _address,
              focusNode: _addressFocus,
              enabled: !busy,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              textDirection: ui.TextDirection.ltr,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              onSubmitted: (_) => _passFocus.requestFocus(),
              decoration: InputDecoration(
                labelText: 'sipAddress'.tr(),
                hintText: '201@pbx.example.com:port',
                floatingLabelBehavior: FloatingLabelBehavior.always,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pass,
              focusNode: _passFocus,
              enabled: !busy,
              obscureText: !_showPass,
              textInputAction: TextInputAction.done,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              onSubmitted: (_) => _canSubmit ? _signIn() : null,
              decoration: InputDecoration(
                labelText: 'password'.tr(),
                floatingLabelBehavior: FloatingLabelBehavior.always,
                suffixIcon: IconButton(
                  tooltip: _showPass ? 'hidePassword'.tr() : 'showPassword'.tr(),
                  icon: Icon(_showPass ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: t.grey),
                  onPressed: () => setState(() => _showPass = !_showPass),
                ),
              ),
            ),
            ...body,
          ],
        ]),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final t = context.t;
    return Row(children: [
      if (widget.another)
        IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.maybePop(context),
          icon: const BackButtonIcon(),
        )
      else ...[
        const MedutMark(),
        const SizedBox(width: 8),
        const Text('medut', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
      ],
      const Spacer(),
      IconButton(
        tooltip: 'language'.tr(),
        icon: Icon(Icons.language, color: t.text2),
        onPressed: () => showLanguageSheet(context),
      ),
    ]);
  }

  List<Widget> _formBody(BuildContext context) {
    final t = context.t;
    return [
      if (_error != null) _ErrorLine(_error!),
      const SizedBox(height: 18),
      PrimaryButton(label: 'signIn'.tr(), onPressed: _canSubmit ? _signIn : null),
      const SizedBox(height: 26),
      Text('setUpFrom'.tr(),
          textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.text2)),
      const SizedBox(height: 10),
      Row(children: [
        // No camera to scan with on a computer.
        if (!isDesktop) ...[
          Expanded(child: _Tile(icon: Icons.qr_code_scanner, label: 'scanQr'.tr(), onTap: _scan)),
          const SizedBox(width: 8),
        ],
        Expanded(child: _Tile(icon: Icons.description_outlined, label: 'importFile'.tr(), onTap: _import)),
        const SizedBox(width: 8),
        Expanded(child: _Tile(icon: Icons.content_paste, label: 'paste'.tr(), onTap: _paste)),
      ]),
      const Spacer(),
      const SizedBox(height: 16),
      Center(
        child: TextButton.icon(
          onPressed: _moreOptions,
          style: TextButton.styleFrom(foregroundColor: t.text2, minimumSize: const Size(0, 48)),
          icon: const Icon(Icons.tune, size: 18),
          label: Text(_moreLabel),
        ),
      ),
    ];
  }

  List<Widget> _checkingBody(BuildContext context) {
    final t = context.t;
    final p = _parse();
    final auto = _opts.transport == 'auto';
    String port(String k) => '${(p?.port ?? 0) > 0 ? p!.port : probePorts[k]}';
    return [
      const SizedBox(height: 18),
      Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(20)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text('connectingTo'.tr(namedArgs: {'server': p?.domain ?? ''}),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            Text('${DateTime.now().difference(_startedAt).inSeconds} s', style: mono(context, size: 11.5)),
          ]),
          const SizedBox(height: 8),
          if (auto)
            for (final k in const ['dns', 'tls', 'tcp', 'udp', 'wss'])
              _CheckRow(
                state: _steps[k]?.$1 ?? CheckState.running,
                label: switch (k) {
                  'dns' => switch (_steps[k]?.$1) {
                      CheckState.ok => 'stepServerFound'.tr(),
                      CheckState.failed => 'stepServerMissing'.tr(),
                      _ => 'stepFindingServer'.tr(),
                    },
                  'tls' => 'stepTls'.tr(),
                  'wss' => 'stepWss'.tr(),
                  _ => k.toUpperCase(),
                },
                port: k == 'dns' ? '' : port(k),
                result: _probeWords(k),
                monoResult: k == 'dns' || (k == 'wss' && _steps[k]?.$1 == CheckState.ok),
              ),
          if (_steps['register'] case final r?)
            _CheckRow(
              state: r.$1,
              label: 'stepSignIn'.tr(namedArgs: {'user': p?.user ?? ''}),
              result: switch (r.$1) {
                CheckState.running => 'overTransport'.tr(namedArgs: {'t': r.$2.toUpperCase()}),
                CheckState.ok => 'stepSignedIn'.tr(),
                _ => r.$2 == 'code' ? r.$3 : 'probeNoAnswer'.tr(),
              },
            ),
        ]),
      ),
      if (auto)
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 10, 8, 0),
          child: Text('checkAllAtOnce'.tr(), style: TextStyle(fontSize: 12, height: 1.4, color: t.text2)),
        ),
      const Spacer(),
      const SizedBox(height: 16),
      SecondaryButton(label: 'cancel'.tr(), onPressed: _cancel),
      const SizedBox(height: 8),
    ];
  }

  String _probeWords(String k) {
    final s = _steps[k];
    if (s == null || s.$1 == CheckState.running || s.$1 == CheckState.skipped) return '';
    if (k == 'dns') return s.$3;
    if (k == 'wss' && s.$1 == CheckState.ok) return s.$3;
    return switch (s.$2) {
      'answered' => 'probeAnswered'.tr(),
      'badCert' => 'probeBadCert'.tr(),
      'refused' => 'probeRefused'.tr(),
      'notTls' => 'probeNotTls'.tr(),
      'noSip' => 'probeNoSip'.tr(),
      _ => 'probeNoAnswer'.tr(),
    };
  }

  List<Widget> _failedBody(BuildContext context) {
    final t = context.t;
    final p = _parse();
    final server = p?.domain ?? '';
    final (title, text) = switch (_fail) {
      _Fail.noServer => ('failNoServerTitle'.tr(namedArgs: {'server': server}), 'failNoServerBody'.tr()),
      _Fail.noAnswer => (
          'failNoAnswerTitle'.tr(namedArgs: {'server': server}),
          _opts.transport == 'auto'
              ? 'failNoAnswerAll'.tr()
              : 'failNoAnswerOne'.tr(namedArgs: {'t': _opts.transport.toUpperCase()})
        ),
      _Fail.badPassword => ('signInWrongPassword'.tr(), 'failBadPasswordBody'.tr(namedArgs: {'code': '$_failCode'})),
      _Fail.notFound => (
          'failNotFoundTitle'.tr(),
          'signInNotFound'.tr(namedArgs: {'server': server, 'user': p?.user ?? ''})
        ),
      _Fail.refused => ('failRefusedTitle'.tr(), 'signInRefused'.tr(namedArgs: {'code': '$_failCode'})),
    };
    final setup = _Fix(Icons.qr_code_scanner, 'fixSetup'.tr(), 'fixSetupSub'.tr(), _setupSheet);
    final network = _Fix(Icons.wifi, 'fixNetwork'.tr(), 'fixNetworkSub'.tr(), null);
    final fixes = switch (_fail) {
      _Fail.noServer || _Fail.noAnswer => [
          if (!_opts.webLink)
            _Fix(Icons.link, 'fixWebLink'.tr(), 'fixWebLinkSub'.tr(), () {
              _opts.setTransport('wss');
              _moreOptions();
            }),
          setup,
          network,
        ],
      _Fail.badPassword => [
          _Fix(Icons.key_outlined, 'fixPassword'.tr(), 'fixPasswordSub'.tr(), () {
            setState(() => _showPass = true);
            _passFocus.requestFocus();
          }),
          _Fix(Icons.badge_outlined, 'fixLoginName'.tr(), 'loginNameSub'.tr(), _moreOptions),
        ],
      _Fail.notFound => [
          _Fix(Icons.dialpad, 'fixExtension'.tr(), 'fixExtensionSub'.tr(), _addressFocus.requestFocus),
          setup,
        ],
      _Fail.refused => [
          _Fix(Icons.tune, 'allTechnical'.tr(), 'allTechnicalSub'.tr(), _openTechnical),
          setup,
        ],
    };
    String two(int v) => v.toString().padLeft(2, '0');
    final at = '${two(_startedAt.hour)}:${two(_startedAt.minute)}:${two(_startedAt.second)}';
    return [
      const SizedBox(height: 14),
      Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          decoration: BoxDecoration(color: t.dangerSoft, borderRadius: BorderRadius.circular(18)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.error_outline, size: 20, color: t.danger),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.danger)),
                const SizedBox(height: 3),
                Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: t.text)),
              ]),
            ),
          ]),
        ),
      ),
      SectionLabel('thingsToTry'.tr()),
      Material(
        color: t.surface,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < fixes.length; i++) ...[
            if (i > 0) Divider(height: 1, color: t.border),
            ListTile(
              onTap: fixes[i].onTap,
              leading: Icon(fixes[i].icon, color: t.accentText),
              title: Text(fixes[i].title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              subtitle: Text(fixes[i].sub, style: TextStyle(fontSize: 12, color: t.text2)),
              trailing: fixes[i].onTap == null ? null : Icon(Icons.chevron_right, color: t.text2),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 4, 4, 12),
        decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('whatHappened'.tr(), style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Expanded(child: Text(at, style: mono(context, size: 11))),
            IconButton(tooltip: 'copyLog'.tr(), icon: Icon(Icons.copy, size: 18, color: t.text2), onPressed: _copyLog),
            IconButton(
              tooltip: 'shareLog'.tr(),
              icon: Icon(Icons.ios_share, size: 18, color: t.text2),
              onPressed: () => Share.share(_log.join('\n'), subject: 'Medut sign-in log'),
            ),
          ]),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 10),
            child: Text(_log.join('\n'),
                textDirection: ui.TextDirection.ltr, style: mono(context, size: 11).copyWith(height: 1.6)),
          ),
        ]),
      ),
      const Spacer(),
      const SizedBox(height: 16),
      PrimaryButton(label: 'tryAgain'.tr(), onPressed: _canSubmit ? _signIn : null),
      const SizedBox(height: 8),
    ];
  }

  List<Widget> _connectedBody(BuildContext context) {
    final t = context.t;
    final c = _connected!;
    return [
      const SizedBox(height: 24),
      Center(
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(color: t.accentSoft, shape: BoxShape.circle),
          child: Icon(Icons.check_rounded, size: 34, color: t.accentText),
        ),
      ),
      const SizedBox(height: 16),
      Text('signedInTitle'.tr(),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.8, height: 1.1)),
      const SizedBox(height: 6),
      Text('signedInSub'.tr(namedArgs: {'user': c.user, 'server': c.domain}),
          textAlign: TextAlign.center, style: TextStyle(fontSize: 14.5, color: t.text2)),
      const SizedBox(height: 22),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(20)),
        child: Column(children: [
          _Fact(Icons.link, 'connection'.tr(), 'transport_${c.transport}'.tr(), sub: c.serverUrl),
          Divider(height: 1, color: t.border),
          _Fact(Icons.lock_outline, 'callsLabel'.tr(), 'enc_${c.mediaEnc}'.tr()),
          Divider(height: 1, color: t.border),
          _Fact(Icons.graphic_eq, 'sound'.tr(), codecNames(c.codecsFrom(ref.read(settingsProvider).codecs))),
        ]),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _accountName,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          labelText: 'accountName'.tr(),
          hintText: 'accountNameHint'.tr(),
          helperText: 'accountNameHelp'.tr(),
          floatingLabelBehavior: FloatingLabelBehavior.always,
        ),
      ),
      const SizedBox(height: 22),
      Padding(
        padding: const EdgeInsetsDirectional.only(start: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('nextPermissions'.tr(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.text2)),
          const SizedBox(height: 10),
          _Perm(Icons.mic_none, 'permMic'.tr()),
          const SizedBox(height: 10),
          _Perm(Icons.notifications_none, 'permNotify'.tr()),
        ]),
      ),
      const Spacer(),
      const SizedBox(height: 16),
      PrimaryButton(label: 'continue'.tr(), onPressed: _saving ? null : _finish),
      const SizedBox(height: 4),
      TextButton(
        onPressed: _saving ? null : _cancel,
        style: TextButton.styleFrom(foregroundColor: t.text2, minimumSize: const Size(0, 48)),
        child: Text('useAnotherAccount'.tr()),
      ),
    ];
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Scrolls when the content is taller than the screen, and otherwise lets a
/// [Spacer] push the last children to the bottom.
class _Page extends StatelessWidget {
  const _Page({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 6, 22, 8),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight - 14),
            child: IntrinsicHeight(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ),
        ),
      );
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(6, 12, 6, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.error_outline, size: 18, color: t.danger),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(fontSize: 13, height: 1.35, color: t.danger))),
      ]),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: t.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 84,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 22, color: t.accentText),
            const SizedBox(height: 7),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// One line of the connection checklist.
class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.state, required this.label, this.port = '', this.result = '', this.monoResult = false});
  final CheckState state;
  final String label, port, result;
  final bool monoResult;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final dim = state == CheckState.failed || state == CheckState.skipped;
    final dot = switch (state) {
      CheckState.running => SizedBox(
          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: t.accentText)),
      CheckState.ok => Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(color: t.accentSoft, shape: BoxShape.circle),
          child: Icon(Icons.check_rounded, size: 14, color: t.accentText)),
      CheckState.failed => Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(color: t.surface2, shape: BoxShape.circle),
          child: Icon(Icons.close_rounded, size: 14, color: t.text2)),
      CheckState.skipped => Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(color: t.surface2, shape: BoxShape.circle),
          child: Icon(Icons.remove_rounded, size: 14, color: t.text2)),
    };
    return Container(
      constraints: const BoxConstraints(minHeight: 42),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
      child: Row(children: [
        SizedBox(width: 22, child: Center(child: dot)),
        const SizedBox(width: 11),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: label),
              if (port.isNotEmpty) TextSpan(text: '  $port', style: mono(context, size: 11.5)),
            ]),
            style: TextStyle(
                fontSize: 14, fontWeight: dim ? FontWeight.w500 : FontWeight.w600, color: dim ? t.text2 : t.text),
          ),
        ),
        // Expanded, not Flexible: a loose child beside an Expanded one keeps
        // its unused half as dead space, and a short result drifted left.
        Expanded(
          child: Text(result,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: monoResult ? mono(context, size: 11.5) : TextStyle(fontSize: 12, color: t.text2)),
        ),
      ]),
    );
  }
}

class _Fix {
  const _Fix(this.icon, this.title, this.sub, this.onTap);
  final IconData icon;
  final String title, sub;
  final VoidCallback? onTap;
}

class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.label, this.value, {this.sub = ''});
  final IconData icon;
  final String label, value, sub;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(children: [
        Icon(icon, size: 18, color: t.accentText),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(fontSize: 13, color: t.text2)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(value, textAlign: TextAlign.end, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            if (sub.isNotEmpty)
              Text(sub,
                  textAlign: TextAlign.end,
                  textDirection: ui.TextDirection.ltr,
                  overflow: TextOverflow.ellipsis,
                  style: mono(context, size: 10.5)),
          ]),
        ),
      ]),
    );
  }
}

class _Perm extends StatelessWidget {
  const _Perm(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 18, color: context.t.text2),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.35))),
      ]);
}

/// Pasting account details: a `sip:` link or a Medut-SDK account JSON.
class PasteAccountDialog extends StatefulWidget {
  const PasteAccountDialog({super.key, this.initial = ''});
  final String initial;

  @override
  State<PasteAccountDialog> createState() => _PasteAccountDialogState();
}

class _PasteAccountDialogState extends State<PasteAccountDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('pasteTitle'.tr()),
        content: TextField(
          controller: _text,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          textDirection: ui.TextDirection.ltr,
          style: mono(context, size: 12, color: context.t.text),
          decoration: InputDecoration(hintText: 'pasteHint'.tr(), hintMaxLines: 3),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('cancel'.tr())),
          FilledButton(onPressed: () => Navigator.pop(context, _text.text), child: Text('use'.tr())),
        ],
      );
}

/// More options: how to connect, call encryption, ICE, and the few fields a
/// PBX may need at sign-in. Everything else is behind "All technical settings".
class MoreOptionsSheet extends StatelessWidget {
  const MoreOptionsSheet({super.key, required this.opts, required this.onTechnical});
  final SignInOptions opts;
  final VoidCallback onTechnical;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    Widget heading(String title, String sub) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(sub, style: TextStyle(fontSize: 12.5, height: 1.35, color: t.text2)),
        ]);
    Widget sw(String title, String sub, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          subtitle: Text(sub, style: TextStyle(fontSize: 12.5, color: t.text2)),
          value: value,
          onChanged: onChanged,
        );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ListenableBuilder(
        listenable: opts,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Center(
              child: Container(
                width: 38,
                height: 5,
                decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(3)),
              ),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: Text('moreOptions'.tr(),
                    style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
              ),
              TextButton(onPressed: () => Navigator.pop(context), child: Text('done'.tr())),
            ]),
            const SizedBox(height: 10),
            heading(
              'connection'.tr(),
              switch (opts.transport) {
                'auto' => 'connAutoSub'.tr(),
                'wss' || 'ws' => 'connWebSub'.tr(),
                final x => 'connFixedSub'.tr(namedArgs: {'t': x.toUpperCase()}),
              },
            ),
            const SizedBox(height: 10),
            PocketSegments(
              options: ['auto', 'udp', 'tcp', 'tls', 'wss', if (opts.transport == 'ws') 'ws'],
              labels: ['connAuto'.tr(), 'UDP', 'TCP', 'TLS', 'WSS', if (opts.transport == 'ws') 'WS'],
              value: opts.transport,
              onChanged: opts.setTransport,
            ),
            if (opts.webLink) ...[
              const SizedBox(height: 12),
              TextField(
                controller: opts.wsUrl,
                autocorrect: false,
                keyboardType: TextInputType.url,
                textDirection: ui.TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: 'webLink'.tr(),
                  hintText: 'wss://pbx.example.com:8089/ws',
                  helperText: 'webLinkHelp'.tr(),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Divider(color: t.border, height: 1),
            if (opts.canEncrypt) ...[
              sw(
                'encryptCalls'.tr(),
                !opts.encrypt
                    ? (opts.transport == 'auto' ? 'encAutoSub'.tr() : 'encryptCallsSub'.tr())
                    : opts.webLink
                        ? 'encWebSub'.tr()
                        : 'encPickSub'.tr(),
                opts.encrypt,
                opts.setEncrypt,
              ),
              if (opts.encrypt) ...[
                PocketSegments(
                  options: const ['sdes', 'dtls'],
                  labels: const ['SDES (SRTP)', 'DTLS-SRTP'],
                  value: opts.enc,
                  onChanged: opts.setEnc,
                ),
                const SizedBox(height: 12),
              ],
              Divider(color: t.border, height: 1),
            ],
            sw('iceTitle'.tr(), 'iceSub'.tr(), opts.ice, opts.setIce),
            if (opts.ice) ...[
              TextField(
                controller: opts.stun,
                autocorrect: false,
                keyboardType: TextInputType.url,
                textDirection: ui.TextDirection.ltr,
                decoration: InputDecoration(labelText: 'stunServer'.tr(), helperText: 'stunDefaultHelp'.tr()),
              ),
              const SizedBox(height: 4),
              FoldField(
                controller: opts.turn,
                title: 'turnServer'.tr(),
                empty: 'notSet'.tr(),
                hint: 'turn:turn.example.com:3478',
                help: 'turnHelp'.tr(),
                divider: false,
                extra: [
                  const SizedBox(height: 10),
                  TextField(
                    controller: opts.turnUser,
                    autocorrect: false,
                    textDirection: ui.TextDirection.ltr,
                    decoration: InputDecoration(labelText: 'turnUser'.tr()),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: opts.turnPass,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(labelText: 'turnPass'.tr()),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Divider(color: t.border, height: 1),
            FoldField(controller: opts.authUser, title: 'loginName'.tr(), empty: 'off'.tr(), help: 'loginNameSub'.tr()),
            FoldField(
              controller: opts.proxy,
              title: 'outboundProxy'.tr(),
              empty: 'none'.tr(),
              hint: 'sip:proxy.example.com;lr',
              help: 'proxySub'.tr(),
            ),
            FoldField(controller: opts.display, title: 'nameOnCalls'.tr(), empty: 'notSet'.tr(), ltr: false),
            const SizedBox(height: 18),
            Material(
              color: t.bg,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                onTap: onTechnical,
                title: Text('allTechnical'.tr(), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('allTechnicalSub'.tr(), style: mono(context, size: 11)),
                trailing: Icon(Icons.chevron_right, color: t.text2),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A row that shows a text setting's value and opens into its field.
class FoldField extends StatefulWidget {
  const FoldField({
    super.key,
    required this.controller,
    required this.title,
    required this.empty,
    this.hint,
    this.help,
    this.ltr = true,
    this.extra = const [],
    this.divider = true,
  });
  final TextEditingController controller;
  final String title, empty;
  final String? hint, help;

  /// More fields that open with this one (TURN user and password).
  final List<Widget> extra;
  final bool divider;

  /// SIP names and URIs read left to right in Arabic too.
  final bool ltr;

  @override
  State<FoldField> createState() => _FoldFieldState();
}

class _FoldFieldState extends State<FoldField> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final v = widget.controller.text.trim();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Row(children: [
            Expanded(child: Text(widget.title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600))),
            const SizedBox(width: 12),
            Expanded(
              child: Text(v.isEmpty ? widget.empty : v,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: TextStyle(fontSize: 13, color: t.text2)),
            ),
            Icon(_open ? Icons.expand_less : Icons.expand_more, size: 20, color: t.text2),
          ]),
        ),
      ),
      if (_open)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: widget.controller,
              autofocus: true,
              autocorrect: false,
              textDirection: widget.ltr ? ui.TextDirection.ltr : null,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(hintText: widget.hint, helperText: widget.help),
            ),
            ...widget.extra,
          ]),
        ),
      if (widget.divider) Divider(color: t.border, height: 1),
    ]);
  }
}
