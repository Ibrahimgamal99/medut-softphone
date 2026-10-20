import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/accounts.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../desktop/platform.dart';
import '../sip/sip_service.dart';
import '../ui/widgets.dart';
import 'sign_in.dart' show PasteAccountDialog;
import 'status_codes.dart';

/// The account being edited. Every page of the technical settings edits this
/// one object, so a change on a section page shows in the summaries at once.
class AccountDraft extends ChangeNotifier {
  AccountDraft(SipAccountConfig a) : _a = a {
    for (final c in _all) {
      c.addListener(notifyListeners);
    }
  }

  SipAccountConfig _a;
  late final name = TextEditingController(text: _a.name);
  late final user = TextEditingController(text: _a.user);
  late final pass = TextEditingController(text: _a.password);
  late final domain = TextEditingController(text: _a.domain);
  late final port = TextEditingController(text: _a.port > 0 ? '${_a.port}' : '');
  late final wsUrl = TextEditingController(text: _a.serverUrl);
  late final authUser = TextEditingController(text: _a.authUser);
  late final display = TextEditingController(text: _a.displayName);
  late final proxy = TextEditingController(text: _a.outboundProxy);
  late final stun = TextEditingController(text: _a.stun);
  late final turn = TextEditingController(text: _a.turn);
  late final turnUser = TextEditingController(text: _a.turnUser);
  late final turnPass = TextEditingController(text: _a.turnPass);
  late final voicemail = TextEditingController(text: _a.voicemail);
  late final prefix = TextEditingController(text: _a.dialPrefix);
  late final plus = TextEditingController(text: _a.plusReplace);
  late final headers = TextEditingController(text: _a.headers);

  late final List<TextEditingController> _all = [
    name, user, pass, domain, port, wsUrl, authUser, display, proxy, stun, turn, turnUser, turnPass, voicemail, prefix, plus,
    headers, //
  ];

  /// The choices that are not text: transport, encryption, codecs, switches.
  SipAccountConfig get choices => _a;

  void set(SipAccountConfig Function(SipAccountConfig a) change) {
    _a = change(_a);
    notifyListeners();
  }

  // ICE turned on by choosing a web link rather than by hand, so leaving the
  // web link turns it off again.
  bool _autoIce = false;

  static bool _web(String t) => t == 'ws' || t == 'wss';

  /// Media encryption needs a secure signalling path: TLS or a web link.
  static bool canEncrypt(String transport) => transport == 'tls' || _web(transport);

  /// A web link is a WebRTC server: DTLS media and ICE. Plain UDP and TCP
  /// carry no encrypted media.
  void setTransport(String t) => set((a) {
        final web = _web(t), wasWeb = _web(a.transport);
        var ice = a.ice;
        if (web && !wasWeb && !ice) {
          if (stun.text.trim().isEmpty) stun.text = kDefaultStun;
          ice = _autoIce = true;
        } else if (!web && wasWeb && _autoIce) {
          ice = _autoIce = false;
        }
        final enc = web ? 'dtls' : (canEncrypt(t) ? (a.mediaEnc == 'dtls' && wasWeb ? 'sdes' : a.mediaEnc) : 'none');
        return a.copyWith(transport: t, mediaEnc: enc, ice: ice);
      });

  void setIce(bool on) {
    _autoIce = false;
    if (on && stun.text.trim().isEmpty) stun.text = kDefaultStun;
    set((a) => a.copyWith(ice: on));
  }

  /// What a QR code, file or JSON carried. Dialing and call settings, which
  /// those never hold, stay as they were.
  void fill(SipAccountConfig p) {
    final keep = _a;
    _a = p.copyWith(
      isDefault: keep.isDefault,
      dtmf: keep.dtmf,
      voicemail: keep.voicemail,
      recordCalls: keep.recordCalls,
      dialPrefix: keep.dialPrefix,
      plusReplace: keep.plusReplace,
      headers: keep.headers,
      push: keep.push,
    );
    name.text = p.name;
    user.text = p.user;
    pass.text = p.password;
    domain.text = p.domain;
    port.text = p.port > 0 ? '${p.port}' : '';
    wsUrl.text = p.serverUrl;
    authUser.text = p.authUser;
    display.text = p.displayName;
    proxy.text = p.outboundProxy;
    stun.text = p.stun;
    turn.text = p.turn;
    turnUser.text = p.turnUser;
    turnPass.text = p.turnPass;
    notifyListeners();
  }

  /// The account as it stands, keeping the id it was opened with.
  SipAccountConfig build(String id) {
    final d = domain.text.trim();
    final c = SipAccountConfig.fromJson({..._a.toJson(), 'id': id}, password: pass.text, turnPass: turnPass.text);
    return c.copyWith(
      mediaEnc: canEncrypt(c.transport) ? null : 'none',
      name: name.text.trim().isEmpty ? d : name.text.trim(),
      user: user.text.trim(),
      domain: d,
      port: int.tryParse(port.text.trim()) ?? 0,
      serverUrl: wsUrl.text.trim(),
      authUser: authUser.text.trim(),
      displayName: display.text.trim(),
      outboundProxy: proxy.text.trim(),
      stun: stun.text.trim(),
      turn: turn.text.trim(),
      turnUser: turnUser.text.trim(),
      voicemail: voicemail.text.trim().isEmpty ? '*97' : voicemail.text.trim(),
      dialPrefix: prefix.text.trim(),
      plusReplace: plus.text.trim(),
      headers: headers.text.trim(),
      enabled: true,
    );
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }
}

enum _Section { signIn, connection, security, network, audio, calls, dialing, extras }

/// Every Medut-SDK account option, in sections that show their values:
/// editing an account, or "All technical settings" from sign-in, which hands
/// over what was typed there as [initial]. Saving tests the connection first.
/// Pops with `true` once the account is saved.
class AccountEditScreen extends ConsumerStatefulWidget {
  const AccountEditScreen({super.key, this.existing, this.initial});
  final SipAccountConfig? existing;
  final SipAccountConfig? initial;

  @override
  ConsumerState<AccountEditScreen> createState() => _AccountEditScreenState();
}

class _AccountEditScreenState extends ConsumerState<AccountEditScreen> {
  late final SipService _sip = ref.read(sipProvider);
  late final String _id = (widget.existing ?? widget.initial)?.id ?? SipAccountConfig.newId();
  late final AccountDraft _d = AccountDraft(widget.existing ??
      widget.initial ??
      SipAccountConfig(id: _id, name: '', user: '', domain: '', isDefault: ref.read(accountsProvider).accounts.isEmpty));
  bool _testing = false;
  bool _saved = false;
  bool _tested = false;
  RegProbe? _result;
  String _resultSig = '';

  @override
  void dispose() {
    if (_tested && !_saved) {
      _sip.cancelProbe(_id);
      // A saved account that was tried with other settings goes back to its own.
      if (widget.existing != null) _sip.applyAccounts();
    }
    _d.dispose();
    super.dispose();
  }

  static String _sig(SipAccountConfig c) => '${jsonEncode(c.toJson())}|${c.password}|${c.turnPass}';

  bool get _inCall => _sip.calls.any((x) => x.runtime.cfg.id == _id);

  /// What is missing before the account can be tried, or null.
  String? _missing(SipAccountConfig c) {
    if (c.user.isEmpty || c.domain.isEmpty) return 'needUserServer'.tr();
    final web = c.transport == 'ws' || c.transport == 'wss';
    if (web && !RegExp(r'^wss?://', caseSensitive: false).hasMatch(c.serverUrl)) return 'webLinkNeeded'.tr();
    return null;
  }

  Future<bool> _test() async {
    final c = _d.build(_id);
    final why = _missing(c);
    if (why != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(why)));
      return false;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    _tested = true;
    final r = await _sip.tryRegister(c);
    if (!mounted) return false;
    setState(() {
      _testing = false;
      _result = r;
      _resultSig = _sig(c);
    });
    return true;
  }

  Future<void> _save() async {
    final c = _d.build(_id);
    final why = _missing(c);
    if (why != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(why)));
      return;
    }
    final fresh = _result != null && _resultSig == _sig(c);
    if (!_inCall && !(fresh && _result!.ok)) {
      if (!fresh && !await _test()) return;
      if (!mounted) return;
      if (!_result!.ok) {
        final anyway = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('saveAnywayTitle'.tr()),
            content: Text('${_resultText(_result!)}\n\n${'saveAnywayBody'.tr()}'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('keepEditing'.tr())),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('saveAnyway'.tr())),
            ],
          ),
        );
        if (anyway != true) return;
      }
    }
    if (!mounted) return;
    _saved = true;
    // PBX type and status codes belong to the saved account (Status codes
    // edits it directly): the draft's copy may be stale, and an import resets it.
    final store = ref.read(accountsProvider);
    final saved = store.byId(_id);
    await store.save(saved == null ? c : c.copyWith(pbx: saved.pbx, codes: saved.codes));
    // Ask once, at the moment it makes sense: calls need the mic, and ringing
    // in the background needs notifications. A computer does not ask.
    if (!isDesktop) await [Permission.microphone, Permission.notification].request();
    if (mounted) Navigator.pop(context, true);
  }

  static String _resultText(RegProbe r) {
    if (r.ok) return 'statusConnected'.tr();
    if (r.badPassword) return 'signInWrongPassword'.tr();
    if (r.sipCode >= 400) return 'signInRefused'.tr(namedArgs: {'code': '${r.sipCode}'});
    if (r.status == RegStatus.registering) return 'testNoAnswer'.tr();
    return r.error.isNotEmpty ? r.error : 'testFailed'.tr();
  }

  // ── Filling from a code, a file or text ───────────────────────────────────

  void _fillFrom(String raw) {
    final p = SipAccountConfig.parseProvisioning(raw);
    if (p == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('invalidQr'.tr())));
      return;
    }
    _d.fill(p);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('imported'.tr())));
  }

  Future<void> _scan() async {
    if (!(await Permission.camera.request()).isGranted || !mounted) return;
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw != null && mounted) _fillFrom(raw);
  }

  Future<void> _import() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json', 'txt']);
    final path = r?.files.single.path;
    if (path == null || !mounted) return;
    final text = await File(path).readAsString(encoding: utf8);
    if (mounted) _fillFrom(text);
  }

  Future<void> _paste() async {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted) return;
    final raw = await showDialog<String>(context: context, builder: (_) => PasteAccountDialog(initial: clip));
    if (raw != null && raw.trim().isNotEmpty && mounted) _fillFrom(raw);
  }

  /// The account as Medut-SDK account JSON, to read, copy or edit.
  Future<void> _json() async {
    final pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(_d.build(_id).toProvisioning()));
    final raw = await showDialog<String>(context: context, builder: (_) => _JsonDialog(initial: pretty));
    if (raw != null && mounted) _fillFrom(raw);
  }

  /// Show the account as a provisioning QR, to set up another phone.
  Future<void> _shareQr() async {
    final t = context.t;
    final data = _d.build(_id).toProvisioning();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('shareAccount'.tr()),
        content: SizedBox(
          width: 260,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(data: data, size: 240),
            ),
            const SizedBox(height: 10),
            Text('shareAccountWarn'.tr(), style: TextStyle(fontSize: 12, color: t.danger)),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text('close'.tr()))],
      ),
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('deleteAccount'.tr()),
        content: Text('deleteConfirm'.tr()),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('cancel'.tr())),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.t.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('delete'.tr()),
          ),
        ],
      ),
    );
    if (ok == true) {
      _saved = true;
      await ref.read(accountsProvider).remove(_id);
      if (mounted) Navigator.pop(context);
    }
  }

  void _open(_Section s) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _SectionPage(
            draft: _d,
            section: s,
            recordingAlways: ref.read(settingsProvider).recordingMode == 'always',
            codecOrder: ref.read(settingsProvider).codecs),
      ));

  // ── Layout ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'technicalSettings'.tr() : 'editAccount'.tr(),
            style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (widget.existing != null)
            IconButton(tooltip: 'shareAccount'.tr(), icon: const Icon(Icons.qr_code_2), onPressed: _shareQr),
          if (widget.existing != null)
            IconButton(tooltip: 'deleteAccount'.tr(), icon: Icon(Icons.delete_outline, color: t.danger), onPressed: _delete),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([_d, _sip]),
          builder: (context, _) {
            final c = _d.build(_id);
            return Column(children: [
              Expanded(
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
                  _head(context, c),
                  const SizedBox(height: 12),
                  Row(children: [
                    if (!isDesktop) ...[
                      Expanded(child: _Chip(icon: Icons.qr_code_scanner, label: 'scanQr'.tr(), onTap: _scan)),
                      const SizedBox(width: 8),
                    ],
                    Expanded(child: _Chip(icon: Icons.description_outlined, label: 'importFile'.tr(), onTap: _import)),
                    const SizedBox(width: 8),
                    Expanded(child: _Chip(icon: Icons.content_paste, label: 'paste'.tr(), onTap: _paste)),
                    const SizedBox(width: 8),
                    Expanded(child: _Chip(icon: Icons.data_object, label: 'JSON', onTap: _json)),
                  ]),
                  const SizedBox(height: 14),
                  Material(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(20),
                    clipBehavior: Clip.antiAlias,
                    child: Column(children: [
                      for (final s in _Section.values) ...[
                        if (s.index > 0) Divider(height: 1, color: t.border, indent: 60),
                        ListTile(
                          onTap: () => _open(s),
                          leading: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(color: t.surface2, borderRadius: BorderRadius.circular(10)),
                            child: Icon(_icon(s), size: 18, color: t.text),
                          ),
                          title: Text(_title(s), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                          subtitle: Text(_summary(s, c, ref.watch(settingsProvider).codecs),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textDirection: ui.TextDirection.ltr,
                              style: mono(context, size: 11)),
                          trailing: Icon(Icons.chevron_right, color: t.text2),
                        ),
                      ],
                    ]),
                  ),
                  // Feature codes are kept per saved account (Settings → Status codes).
                  if (widget.existing != null) ...[
                    const SizedBox(height: 12),
                    Material(
                      color: t.surface,
                      borderRadius: BorderRadius.circular(20),
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => StatusCodesScreen(accountId: _id))),
                        leading: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(color: t.surface2, borderRadius: BorderRadius.circular(10)),
                          child: Icon(Icons.dialpad, size: 18, color: t.text),
                        ),
                        title: Text('statusCodes'.tr(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        subtitle: Text(codesSummary(ref.watch(accountsProvider).byId(_id) ?? c),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textDirection: ui.TextDirection.ltr,
                            style: mono(context, size: 11)),
                        trailing: Icon(Icons.chevron_right, color: t.text2),
                      ),
                    ),
                  ],
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: SizedBox(
                  width: double.infinity,
                  child: PrimaryButton(label: 'saveConnect'.tr(), onPressed: _testing ? null : _save),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                child: Text(_inCall ? 'saveInCall'.tr() : 'testBeforeSave'.tr(),
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: t.text2)),
              ),
            ]);
          },
        ),
      ),
    );
  }

  /// The account, how it is doing, and the Test button.
  Widget _head(BuildContext context, SipAccountConfig c) {
    final t = context.t;
    final live = _sip.runtimes[_id];
    final (Color dot, String status) = switch (_result) {
      _ when _testing => (t.warn, 'testing'.tr()),
      final r? when r.ok => (t.success, 'statusConnected'.tr()),
      final r? => (t.danger, _resultText(r)),
      _ when widget.existing != null && live != null => switch (live.status) {
          RegStatus.registered => (t.success, 'statusConnected'.tr()),
          RegStatus.failed => (t.danger, live.error.isNotEmpty ? live.error : 'testFailed'.tr()),
          RegStatus.off => (t.grey, 'statusOff'.tr()),
          _ => (t.warn, 'regReconnecting'.tr()),
        },
      _ => (t.grey, 'notTested'.tr()),
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        Avatar(c.user.isEmpty ? '?' : c.user, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c.label.isEmpty ? 'addAccount'.tr() : c.label,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Row(children: [
              Dot(dot, size: 7),
              const SizedBox(width: 6),
              Expanded(
                child: Text(status,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.text2)),
              ),
            ]),
          ]),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: _testing || _inCall ? null : _test,
          style: OutlinedButton.styleFrom(
            foregroundColor: t.accentText,
            side: BorderSide(color: t.accentText, width: 1.5),
            shape: const StadiumBorder(),
            minimumSize: const Size(0, 38),
          ),
          child: _testing
              ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: t.accentText))
              : Text('test'.tr(), style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }

  static IconData _icon(_Section s) => switch (s) {
        _Section.signIn => Icons.person_outline,
        _Section.connection => Icons.link,
        _Section.security => Icons.lock_outline,
        _Section.network => Icons.hub_outlined,
        _Section.audio => Icons.graphic_eq,
        _Section.calls => Icons.phone_outlined,
        _Section.dialing => Icons.dialpad,
        _Section.extras => Icons.add_box_outlined,
      };
}

String _title(_Section s) => switch (s) {
      _Section.signIn => 'secSignIn'.tr(),
      _Section.connection => 'connection'.tr(),
      _Section.security => 'secSecurity'.tr(),
      _Section.network => 'secNetwork'.tr(),
      _Section.audio => 'secAudio'.tr(),
      _Section.calls => 'secCalls'.tr(),
      _Section.dialing => 'secDialing'.tr(),
      _Section.extras => 'secExtras'.tr(),
    };

/// `stun:stun.l.google.com:19302` → `stun.l.google.com`.
String _host(String url) => url.replaceFirst(RegExp(r'^(stuns?|turns?):', caseSensitive: false), '').split(':').first;

String _summary(_Section s, SipAccountConfig c, List<String> codecOrder) {
  final web = c.transport == 'ws' || c.transport == 'wss';
  final secure = c.transport == 'tls' || c.transport == 'wss';
  return switch (s) {
    _Section.signIn => [
        c.user.isEmpty ? '—' : c.user,
        if (c.authUser.isNotEmpty) 'sumLogin'.tr(namedArgs: {'u': c.authUser}),
        if (c.domain.isNotEmpty) c.domain,
      ].join(' · '),
    _Section.connection => [
        c.transport.toUpperCase(),
        if (web) c.serverUrl.isEmpty ? 'sumNoLink'.tr() : c.serverUrl,
        if (!web) c.port > 0 ? 'sumPort'.tr(namedArgs: {'p': '${c.port}'}) : 'sumDefaultPort'.tr(),
        if (c.outboundProxy.isNotEmpty) 'sumProxy'.tr(),
      ].join(' · '),
    _Section.security => [
        switch (c.mediaEnc) { 'sdes' => 'SDES-SRTP', 'dtls' => 'DTLS-SRTP', _ => 'enc_none'.tr() },
        if (secure) c.verifyTls ? 'sumCertChecked'.tr() : 'sumCertNotChecked'.tr(),
      ].join(' · '),
    _Section.network => c.ice
        ? [
            'ICE',
            if (c.stun.isNotEmpty) 'STUN ${_host(c.stun)}',
            c.turn.isNotEmpty ? 'TURN ${_host(c.turn)}' : 'sumNoTurn'.tr(),
          ].join(' · ')
        : 'sumIceOff'.tr(),
    _Section.audio => codecNames(c.codecsFrom(codecOrder)),
    _Section.calls => [
        'DTMF ${switch (c.dtmf) { 'info' => 'SIP INFO', 'auto' => 'auto', _ => 'RFC 4733' }}',
      ].join(' · '),
    _Section.dialing => [
        if (c.dialPrefix.isNotEmpty) 'sumPrefix'.tr(namedArgs: {'p': c.dialPrefix}),
        if (c.plusReplace.isNotEmpty) '+ → ${c.plusReplace}',
      ].join(' · ').ifEmpty('sumNoRules'.tr()),
    _Section.extras => [
        if (c.headers.isNotEmpty) 'sumHeaders'.tr(namedArgs: {'n': '${c.headers.split('\n').where((l) => l.contains(':')).length}'}),
        // A computer stays registered while Medut runs: there is no push to wake it.
        if (!isDesktop) c.push ? 'sumPushOn'.tr() : 'sumPushOff'.tr(),
        if (c.isDefault) 'sumDefault'.tr(),
      ].join(' · '),
  };
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// One section of the technical settings.
class _SectionPage extends StatelessWidget {
  const _SectionPage(
      {required this.draft, required this.section, required this.recordingAlways, required this.codecOrder});
  final AccountDraft draft;
  final _Section section;
  final bool recordingAlways;
  final List<String> codecOrder;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_title(section), style: const TextStyle(fontWeight: FontWeight.w800))),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: draft,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: switch (section) {
                _Section.signIn => _signIn(context),
                _Section.connection => _connection(context),
                _Section.security => _security(context),
                _Section.network => _network(context),
                _Section.audio => _audio(context),
                _Section.calls => _calls(context),
                _Section.dialing => _dialing(context),
                _Section.extras => _extras(context),
              },
            ),
          ),
        ),
      );

  List<Widget> _signIn(BuildContext context) => [
        _Field(draft.name, 'accountName'.tr(), hint: 'Office PBX', ltr: false),
        _Field(draft.user, 'user'.tr(), hint: '201'),
        _PasswordField(draft.pass, 'password'.tr()),
        _Field(draft.domain, 'server'.tr(), hint: 'serverHint'.tr(), keyboard: TextInputType.url),
        _Field(draft.authUser, 'loginName'.tr(), helper: 'loginNameSub'.tr()),
        _Field(draft.display, 'nameOnCalls'.tr(), ltr: false),
      ];

  List<Widget> _connection(BuildContext context) {
    final a = draft.choices;
    final web = a.transport == 'ws' || a.transport == 'wss';
    return [
      SectionLabel('howToReach'.tr()),
      _Choices(
        value: a.transport,
        onChanged: draft.setTransport,
        options: [
          ('udp', 'UDP', 'tSubUdp'.tr()),
          ('tcp', 'TCP', 'tSubTcp'.tr()),
          ('tls', 'transport_tls'.tr(), 'tSubTls'.tr()),
          ('wss', 'transport_wss'.tr(), 'tSubWss'.tr()),
          ('ws', 'transport_ws'.tr(), 'tSubWs'.tr()),
        ],
      ),
      SectionLabel('server'.tr()),
      if (web)
        _Field(draft.wsUrl, 'webLink'.tr(), hint: 'wss://pbx.example.com:8089/ws', helper: 'webLinkHelp'.tr(), keyboard: TextInputType.url)
      else
        _Field(draft.port, 'port'.tr(),
            hint: switch (a.transport) { 'tls' => '5061', _ => '5060' }, helper: 'portHelp'.tr(), keyboard: TextInputType.number),
      _Field(draft.proxy, 'outboundProxy'.tr(), hint: 'sip:proxy.example.com;lr', helper: 'proxySub'.tr()),
      if (a.transport == 'tls' || a.transport == 'wss')
        _Switch('checkCert'.tr(), 'checkCertSub'.tr(), a.verifyTls, (v) => draft.set((x) => x.copyWith(verifyTls: v))),
    ];
  }

  List<Widget> _security(BuildContext context) {
    final a = draft.choices;
    final t = context.t;
    if (!AccountDraft.canEncrypt(a.transport)) {
      return [
        SectionLabel('mediaEnc'.tr()),
        ECard(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.lock_open, size: 20, color: t.text2),
            const SizedBox(width: 12),
            Expanded(
              child: Text('encNeedsSecure'.tr(namedArgs: {'t': a.transport.toUpperCase()}),
                  style: TextStyle(fontSize: 13.5, height: 1.4, color: t.text2)),
            ),
          ]),
        ),
      ];
    }
    return [
      SectionLabel('mediaEnc'.tr()),
      _Choices(
        value: a.mediaEnc,
        onChanged: (v) => draft.set((x) => x.copyWith(mediaEnc: v)),
        options: [
          ('none', 'enc_none'.tr(), 'encNoneSub'.tr()),
          ('sdes', 'SDES-SRTP', 'encSdesSub'.tr()),
          ('dtls', 'DTLS-SRTP', 'encDtlsSub'.tr()),
        ],
      ),
      if (a.mediaEnc != 'dtls' && (a.transport == 'wss' || a.transport == 'ws'))
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(6, 12, 6, 0),
          child: Text('encWebSub'.tr(), style: TextStyle(fontSize: 12.5, height: 1.4, color: t.warn)),
        ),
    ];
  }

  List<Widget> _network(BuildContext context) {
    final a = draft.choices;
    return [
      const SizedBox(height: 8),
      _Switch('iceTitle'.tr(), 'iceSub'.tr(), a.ice, draft.setIce),
      if (a.ice) ...[
        const SizedBox(height: 8),
        _Field(draft.stun, 'stunServer'.tr(), hint: kDefaultStun, helper: 'stunDefaultHelp'.tr(), keyboard: TextInputType.url),
        _Field(draft.turn, 'turnServer'.tr(), hint: 'turn:turn.example.com:3478', helper: 'turnHelp'.tr(), keyboard: TextInputType.url),
        _Field(draft.turnUser, 'turnUser'.tr()),
        _PasswordField(draft.turnPass, 'turnPass'.tr()),
      ],
    ];
  }

  /// Read-only: the codec order is app-wide (Advanced call settings → Codecs).
  List<Widget> _audio(BuildContext context) => [
        SectionLabel('codecs'.tr()),
        ECard(
          child: Text(codecNames(draft.choices.codecsFrom(codecOrder)),
              textDirection: ui.TextDirection.ltr, style: mono(context, size: 14)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
          child: Text('codecsFromSettings'.tr(), style: TextStyle(fontSize: 12.5, color: context.t.text2)),
        ),
      ];

  List<Widget> _calls(BuildContext context) {
    final a = draft.choices;
    return [
      SectionLabel('dtmf'.tr()),
      _Choices(
        value: a.dtmf,
        onChanged: (v) => draft.set((x) => x.copyWith(dtmf: v)),
        options: [
          ('rfc4733', 'RFC 4733', 'dtmf4733Sub'.tr()),
          ('info', 'SIP INFO', 'dtmfInfoSub'.tr()),
          ('auto', 'connAuto'.tr(), 'dtmfAutoSub'.tr()),
        ],
      ),
      if (recordingAlways)
        _Switch('recordThisAccount'.tr(), 'recordThisAccountSub'.tr(), a.recordCalls,
            (v) => draft.set((x) => x.copyWith(recordCalls: v))),
    ];
  }

  List<Widget> _dialing(BuildContext context) => [
        const SizedBox(height: 8),
        _Field(draft.prefix, 'dialPrefix'.tr(), hint: '9', helper: 'dialPrefixHelp'.tr(), keyboard: TextInputType.phone),
        _Field(draft.plus, 'plusReplace'.tr(), hint: '00', helper: 'plusReplaceHelp'.tr(), keyboard: TextInputType.phone),
      ];

  List<Widget> _extras(BuildContext context) {
    final a = draft.choices;
    return [
      const SizedBox(height: 8),
      _Field(draft.headers, 'customHeaders'.tr(), hint: 'Privacy: id\nX-Department: sales', lines: 4, code: true),
      if (!isDesktop) _Switch('push'.tr(), 'pushSub'.tr(), a.push, (v) => draft.set((x) => x.copyWith(push: v))),
      _Switch('setDefault'.tr(), 'setDefaultSub'.tr(), a.isDefault, (v) => draft.set((x) => x.copyWith(isDefault: v))),
    ];
  }
}

class _Field extends StatelessWidget {
  const _Field(this.controller, this.label,
      {this.hint, this.helper, this.keyboard, this.ltr = true, this.lines = 1, this.code = false});
  final TextEditingController controller;
  final String label;
  final String? hint, helper;
  final TextInputType? keyboard;

  /// SIP names, hosts and URIs read left to right in Arabic too.
  final bool ltr;
  final int lines;

  /// Monospace, for SIP headers.
  final bool code;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextField(
          controller: controller,
          autocorrect: false,
          keyboardType: lines > 1 ? TextInputType.multiline : keyboard,
          minLines: lines > 1 ? 2 : 1,
          maxLines: lines,
          textDirection: ltr ? ui.TextDirection.ltr : null,
          style: code ? mono(context, size: 12.5, color: context.t.text) : null,
          decoration: InputDecoration(labelText: label, hintText: hint, helperText: helper, helperMaxLines: 3),
        ),
      );
}

class _PasswordField extends StatefulWidget {
  const _PasswordField(this.controller, this.label);
  final TextEditingController controller;
  final String label;

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _show = false;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextField(
          controller: widget.controller,
          obscureText: !_show,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: widget.label,
            suffixIcon: IconButton(
              tooltip: _show ? 'hidePassword'.tr() : 'showPassword'.tr(),
              icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => setState(() => _show = !_show),
            ),
          ),
        ),
      );
}

class _Switch extends StatelessWidget {
  const _Switch(this.title, this.sub, this.value, this.onChanged);
  final String title, sub;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        subtitle: Text(sub, style: TextStyle(fontSize: 12.5, color: context.t.text2)),
        value: value,
        onChanged: onChanged,
      );
}

/// A one-of-several choice as a card of radio rows, each with a line saying
/// what it is for.
class _Choices extends StatelessWidget {
  const _Choices({required this.value, required this.options, required this.onChanged});
  final String value;
  final List<(String, String, String)> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.surface,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: RadioGroup<String>(
        groupValue: value,
        onChanged: (v) => v == null ? null : onChanged(v),
        child: Column(children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) Divider(height: 1, color: t.border),
            RadioListTile<String>(
              value: options[i].$1,
              activeColor: t.accent,
              title: Text(options[i].$2, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              subtitle: Text(options[i].$3, style: TextStyle(fontSize: 12, color: t.text2)),
            ),
          ],
        ]),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: t.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 64,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 20, color: t.accentText),
            const SizedBox(height: 5),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// The account as Medut-SDK account JSON: read it, copy it, or edit and apply.
class _JsonDialog extends StatefulWidget {
  const _JsonDialog({required this.initial});
  final String initial;

  @override
  State<_JsonDialog> createState() => _JsonDialogState();
}

class _JsonDialogState extends State<_JsonDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('accountJson'.tr()),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: _text,
            minLines: 8,
            maxLines: 16,
            autocorrect: false,
            textDirection: ui.TextDirection.ltr,
            style: mono(context, size: 11.5, color: context.t.text),
            decoration: InputDecoration(helperText: 'accountJsonHelp'.tr(), helperMaxLines: 2),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _text.text));
              if (context.mounted) Navigator.pop(context);
            },
            child: Text('copy'.tr()),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: Text('cancel'.tr())),
          FilledButton(onPressed: () => Navigator.pop(context, _text.text), child: Text('apply'.tr())),
        ],
      );
}

/// Full-screen camera that pops with the first QR code's text.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('scanQr'.tr())),
      body: Stack(children: [
        MobileScanner(
          onDetect: (capture) {
            final raw = capture.barcodes.firstOrNull?.rawValue;
            if (raw == null || _done) return;
            _done = true;
            Navigator.pop(context, raw);
          },
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
            child: Text('scanHint'.tr(), style: const TextStyle(color: Colors.white)),
          ),
        ),
      ]),
    );
  }
}
