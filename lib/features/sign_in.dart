import 'package:easy_localization/easy_localization.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/accounts.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../sip/sip_service.dart';
import '../ui/widgets.dart';
import 'account_edit.dart';

/// Pocket · Sign in: a SIP address and a password. The connection is found
/// by trying TLS, then TCP, then UDP, and the first that registers is kept.
/// "More options" holds the few settings a PBX may need at sign-in, and
/// "All technical settings" opens the full account form.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key, this.another = false});

  /// Adding one more account (pushed from Accounts) rather than first launch.
  final bool another;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _id = SipAccountConfig.newId();
  late final SipService _sip = ref.read(sipProvider);
  final _address = TextEditingController();
  final _pass = TextEditingController();
  final _passFocus = FocusNode();
  final _authUser = TextEditingController();
  final _proxy = TextEditingController();
  final _display = TextEditingController();

  /// What a scanned QR code carried beyond the form (codecs, STUN, …).
  late SipAccountConfig _base = SipAccountConfig(id: _id, name: '', user: '', domain: '');
  String _transport = 'auto'; // auto | tls | tcp | udp
  bool _srtp = false;
  bool _showPass = false;
  bool _busy = false;
  String? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sip; // read now: dispose may need it after the root has switched away
    _address.addListener(_changed);
    _pass.addListener(_changed);
  }

  @override
  void dispose() {
    if (_busy) _sip.cancelProbe(_id);
    for (final c in [_address, _pass, _authUser, _proxy, _display]) {
      c.dispose();
    }
    _passFocus.dispose();
    super.dispose();
  }

  void _changed() => setState(() => _error = null);

  /// `201@pbx.example.com[:port]`, with or without `sip:`.
  ({String user, String domain, int port})? _parse() {
    final s = _address.text.trim().replaceFirst(RegExp(r'^sips?:', caseSensitive: false), '');
    final at = s.lastIndexOf('@');
    if (at <= 0 || at == s.length - 1) return null;
    var host = s.substring(at + 1);
    var port = 0;
    final colon = host.lastIndexOf(':');
    if (colon > 0) {
      port = int.tryParse(host.substring(colon + 1)) ?? -1;
      host = host.substring(0, colon);
    }
    if (port < 0 || host.isEmpty || host.contains(' ')) return null;
    return (user: s.substring(0, at), domain: host, port: port);
  }

  bool get _canSubmit => !_busy && _address.text.trim().isNotEmpty && _pass.text.isNotEmpty;

  SipAccountConfig _config(String transport) {
    final p = _parse();
    return _base.copyWith(
      name: p?.domain ?? '',
      user: p?.user ?? '',
      domain: p?.domain ?? '',
      port: p?.port ?? 0,
      password: _pass.text,
      transport: transport,
      authUser: _authUser.text.trim(),
      outboundProxy: _proxy.text.trim(),
      displayName: _display.text.trim(),
      mediaEnc: _srtp ? (_base.mediaEnc == 'none' ? 'sdes' : _base.mediaEnc) : 'none',
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
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final order = _transport == 'auto' ? const ['tls', 'tcp', 'udp'] : [_transport];
    RegProbe? last;
    for (final via in order) {
      setState(() => _progress = 'trying_$via'.tr());
      final cfg = _config(via);
      final r = await _sip.tryRegister(cfg);
      if (!mounted) return;
      last = r;
      if (r.ok) {
        setState(() => _progress = 'connectedOver'.tr(namedArgs: {'t': via.toUpperCase()}));
        await ref.read(accountsProvider).save(cfg);
        // Ask once, at the moment it makes sense: calls need the mic, and
        // ringing in the background needs notifications.
        await [Permission.microphone, Permission.notification].request();
        // First launch: the app root switches to the tabs by itself.
        if (mounted && widget.another) Navigator.pop(context);
        return;
      }
      // The server answered with a SIP refusal, so this transport works and
      // the others would get the same answer.
      if (r.sipCode >= 400 && r.sipCode != 408 && r.sipCode != 503) break;
    }
    setState(() {
      _busy = false;
      _progress = null;
      _error = _failText(last, p, order);
    });
  }

  String _failText(RegProbe? r, ({String user, String domain, int port}) p, List<String> order) {
    if (r != null && r.badPassword) return 'signInWrongPassword'.tr();
    if (r != null && r.sipCode == 404) return 'signInNotFound'.tr(namedArgs: {'server': p.domain, 'user': p.user});
    if (r != null && r.sipCode >= 400 && r.sipCode != 408 && r.sipCode != 503) {
      return 'signInRefused'.tr(namedArgs: {'code': '${r.sipCode}'});
    }
    final how = order.length > 1 ? 'tlsTcpUdp'.tr() : order.first.toUpperCase();
    return 'signInNoAnswer'.tr(namedArgs: {'server': p.domain, 'how': how});
  }

  Future<void> _scan() async {
    if (!(await Permission.camera.request()).isGranted || !mounted) return;
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw == null || !mounted) return;
    final p = SipAccountConfig.parseProvisioning(raw);
    if (p == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('invalidQr'.tr())));
      return;
    }
    final scanned = SipAccountConfig.fromJson({...p.toJson(), 'id': _id}, password: p.password, turnPass: p.turnPass);
    // A WebSocket account needs its URL: that lives in the full form.
    if (scanned.transport == 'ws' || scanned.transport == 'wss') {
      await _openTechnical(scanned.copyWith(isDefault: ref.read(accountsProvider).accounts.isEmpty));
      return;
    }
    setState(() {
      _base = scanned;
      _address.text = p.port > 0 ? '${p.user}@${p.domain}:${p.port}' : '${p.user}@${p.domain}';
      _pass.text = p.password;
      _authUser.text = p.authUser;
      _proxy.text = p.outboundProxy;
      _display.text = p.displayName;
      _srtp = p.mediaEnc != 'none';
      _transport = p.transport;
    });
    // A code without the password: ask for it, then sign in.
    if (p.password.isEmpty) {
      _passFocus.requestFocus();
    } else {
      await _signIn();
    }
  }

  Future<void> _openTechnical([SipAccountConfig? initial]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => AccountEditScreen(initial: initial ?? _config(_transport == 'auto' ? 'tls' : _transport)),
    ));
    if (saved == true && mounted && widget.another) Navigator.pop(context);
  }

  /// "More options · TCP · SRTP" when the connection differs from the defaults.
  String get _moreLabel => [
        'moreOptions'.tr(),
        if (_transport != 'auto') _transport.toUpperCase(),
        if (_srtp) 'SRTP',
      ].join(' · ');

  Future<void> _moreOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        void update(VoidCallback f) {
          setState(f);
          setSheet(() {});
        }

        return _MoreOptionsSheet(
          transport: _transport,
          srtp: _srtp,
          authUser: _authUser,
          proxy: _proxy,
          display: _display,
          onTransport: (v) => update(() => _transport = v),
          onSrtp: (v) => update(() => _srtp = v),
          onTechnical: () {
            Navigator.pop(ctx);
            _openTechnical();
          },
        );
      }),
    );
    setState(() {});
  }

  void _toggleLanguage() =>
      context.setLocale(Locale(context.locale.languageCode == 'ar' ? 'en' : 'ar'));

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 6, 22, 8),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight - 14),
              child: IntrinsicHeight(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
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
                    Flexible(
                      child: TextButton(
                        onPressed: _toggleLanguage,
                        style: TextButton.styleFrom(foregroundColor: t.text2),
                        child: Text('otherLanguage'.tr(), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 26),
                  Text(widget.another ? 'addAnotherTitle'.tr() : 'signIn'.tr(),
                      style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.05)),
                  const SizedBox(height: 8),
                  Text('signInSub'.tr(), style: TextStyle(fontSize: 14.5, color: t.text2, height: 1.4)),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _address,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    textDirection: ui.TextDirection.ltr,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    onSubmitted: (_) => _passFocus.requestFocus(),
                    decoration: InputDecoration(
                      labelText: 'sipAddress'.tr(),
                      hintText: '201@pbx.example.com',
                      helperText: 'sipAddressHelp'.tr(),
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pass,
                    focusNode: _passFocus,
                    enabled: !_busy,
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
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    alignment: AlignmentDirectional.topStart,
                    child: _StatusLine(progress: _progress, error: _error),
                  ),
                  const SizedBox(height: 16),
                  PrimaryButton(label: _busy ? 'signingIn'.tr() : 'signIn'.tr(), onPressed: _canSubmit ? _signIn : null),
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: _busy ? null : _scan,
                    style: TextButton.styleFrom(foregroundColor: t.text, minimumSize: const Size(0, 48)),
                    icon: const Icon(Icons.qr_code_scanner, size: 20),
                    label: Text('scanQrInstead'.tr(), style: const TextStyle(fontSize: 14.5)),
                  ),
                  const Spacer(),
                  const SizedBox(height: 16),
                  Center(
                    child: TextButton.icon(
                      onPressed: _busy ? null : _moreOptions,
                      style: TextButton.styleFrom(foregroundColor: t.text2),
                      icon: const Icon(Icons.tune, size: 18),
                      label: Text(_moreLabel),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The line under the password: what is being tried, or what went wrong.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.progress, required this.error});
  final String? progress, error;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    if (error == null && progress == null) return const SizedBox(width: double.infinity);
    final isError = error != null;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(6, 12, 6, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 18,
          height: 18,
          child: isError
              ? Icon(Icons.error_outline, size: 18, color: t.danger)
              : CircularProgressIndicator(strokeWidth: 2, color: t.accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(error ?? progress!,
              style: TextStyle(fontSize: 13, height: 1.35, color: isError ? t.danger : t.text2)),
        ),
      ]),
    );
  }
}

class _MoreOptionsSheet extends StatelessWidget {
  const _MoreOptionsSheet({
    required this.transport,
    required this.srtp,
    required this.authUser,
    required this.proxy,
    required this.display,
    required this.onTransport,
    required this.onSrtp,
    required this.onTechnical,
  });

  final String transport;
  final bool srtp;
  final TextEditingController authUser, proxy, display;
  final ValueChanged<String> onTransport;
  final ValueChanged<bool> onSrtp;
  final VoidCallback onTechnical;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    Widget heading(String title, String sub) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(sub, style: TextStyle(fontSize: 12.5, color: t.text2)),
        ]);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
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
              child: Text('moreOptions'.tr(), style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: Text('done'.tr())),
          ]),
          const SizedBox(height: 10),
          heading('connection'.tr(),
              transport == 'auto' ? 'connAutoSub'.tr() : 'connFixedSub'.tr(namedArgs: {'t': transport.toUpperCase()})),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 'auto', label: Text('connAuto'.tr())),
              const ButtonSegment(value: 'tls', label: Text('TLS')),
              const ButtonSegment(value: 'tcp', label: Text('TCP')),
              const ButtonSegment(value: 'udp', label: Text('UDP')),
            ],
            selected: {transport},
            onSelectionChanged: (s) => onTransport(s.first),
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: t.accentSoft,
              selectedForegroundColor: t.accent,
              foregroundColor: t.text2,
              side: BorderSide(color: t.border),
            ),
          ),
          const SizedBox(height: 14),
          Divider(color: t.border, height: 1),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('encryptCalls'.tr(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            subtitle: Text('encryptCallsSub'.tr(), style: TextStyle(fontSize: 12.5, color: t.text2)),
            value: srtp,
            onChanged: onSrtp,
          ),
          Divider(color: t.border, height: 1),
          const SizedBox(height: 14),
          TextField(
            controller: authUser,
            autocorrect: false,
            textDirection: ui.TextDirection.ltr,
            decoration: InputDecoration(labelText: 'loginName'.tr(), helperText: 'loginNameSub'.tr()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: proxy,
            autocorrect: false,
            keyboardType: TextInputType.url,
            textDirection: ui.TextDirection.ltr,
            decoration: InputDecoration(
              labelText: 'outboundProxy'.tr(),
              hintText: 'sip:proxy.example.com;lr',
              helperText: 'proxySub'.tr(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: display,
            decoration: InputDecoration(labelText: 'nameOnCalls'.tr()),
          ),
          const SizedBox(height: 18),
          Material(
            color: t.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: t.border)),
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
    );
  }
}
