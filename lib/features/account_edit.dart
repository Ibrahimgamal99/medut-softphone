import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/accounts.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../ui/widgets.dart';

/// Every Medut-SDK account option: editing an account, or "All technical
/// settings" from sign-in, which hands over what was typed there as [initial].
/// Pops with `true` once the account is saved.
class AccountEditScreen extends ConsumerStatefulWidget {
  const AccountEditScreen({super.key, this.existing, this.initial});
  final SipAccountConfig? existing;
  final SipAccountConfig? initial;

  @override
  ConsumerState<AccountEditScreen> createState() => _AccountEditScreenState();
}

class _AccountEditScreenState extends ConsumerState<AccountEditScreen> {
  final _form = GlobalKey<FormState>();
  late SipAccountConfig _a = widget.existing ??
      widget.initial ??
      SipAccountConfig(id: SipAccountConfig.newId(), name: '', user: '', domain: '');
  late final _name = TextEditingController(text: _a.name);
  late final _user = TextEditingController(text: _a.user);
  late final _pass = TextEditingController(text: _a.password);
  late final _domain = TextEditingController(text: _a.domain);
  late final _port = TextEditingController(text: _a.port > 0 ? '${_a.port}' : '');
  late final _wsUrl = TextEditingController(text: _a.serverUrl);
  late final _authUser = TextEditingController(text: _a.authUser);
  late final _display = TextEditingController(text: _a.displayName);
  late final _proxy = TextEditingController(text: _a.outboundProxy);
  late final _stun = TextEditingController(text: _a.stun);
  late final _turn = TextEditingController(text: _a.turn);
  late final _turnUser = TextEditingController(text: _a.turnUser);
  late final _turnPass = TextEditingController(text: _a.turnPass);
  late final _voicemail = TextEditingController(text: _a.voicemail);
  late final _prefix = TextEditingController(text: _a.dialPrefix);
  late final _plus = TextEditingController(text: _a.plusReplace);
  late final _headers = TextEditingController(text: _a.headers);
  late bool _advanced = widget.initial != null;
  bool _showPass = false;

  @override
  void dispose() {
    for (final c in [_name, _user, _pass, _domain, _port, _wsUrl, _authUser, _display, _proxy, _stun, _turn, _turnUser, _turnPass, _voicemail, _prefix, _plus, _headers]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(SipAccountConfig p) {
    setState(() {
      _a = p.copyWith().copyWith(isDefault: _a.isDefault);
      _name.text = p.name;
      _user.text = p.user;
      _pass.text = p.password;
      _domain.text = p.domain;
      _port.text = p.port > 0 ? '${p.port}' : '';
      _wsUrl.text = p.serverUrl;
      _authUser.text = p.authUser;
      _display.text = p.displayName;
      _proxy.text = p.outboundProxy;
      _stun.text = p.stun;
      _turn.text = p.turn;
      _turnUser.text = p.turnUser;
      _turnPass.text = p.turnPass;
      _advanced = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('imported'.tr())));
  }

  SipAccountConfig? _parseOrWarn(String raw) {
    final p = SipAccountConfig.parseProvisioning(raw);
    if (p == null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('invalidQr'.tr())));
    return p;
  }

  Future<void> _scan() async {
    if (!(await Permission.camera.request()).isGranted || !mounted) return;
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw == null || !mounted) return;
    final p = _parseOrWarn(raw);
    if (p != null) _fill(SipAccountConfig.fromJson({...p.toJson(), 'id': _a.id}, password: p.password, turnPass: p.turnPass));
  }

  Future<void> _import() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json', 'txt']);
    final path = r?.files.single.path;
    if (path == null || !mounted) return;
    final p = _parseOrWarn(await File(path).readAsString(encoding: utf8));
    if (p != null) _fill(SipAccountConfig.fromJson({...p.toJson(), 'id': _a.id}, password: p.password, turnPass: p.turnPass));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final domain = _domain.text.trim();
    final a = _a.copyWith(
      name: _name.text.trim().isEmpty ? domain : _name.text.trim(),
      user: _user.text.trim(),
      password: _pass.text,
      domain: domain,
      port: int.tryParse(_port.text.trim()) ?? 0,
      serverUrl: _wsUrl.text.trim(),
      authUser: _authUser.text.trim(),
      displayName: _display.text.trim(),
      outboundProxy: _proxy.text.trim(),
      stun: _stun.text.trim(),
      turn: _turn.text.trim(),
      turnUser: _turnUser.text.trim(),
      turnPass: _turnPass.text,
      voicemail: _voicemail.text.trim().isEmpty ? '*97' : _voicemail.text.trim(),
      dialPrefix: _prefix.text.trim(),
      plusReplace: _plus.text.trim(),
      headers: _headers.text.trim(),
      enabled: true,
    );
    await ref.read(accountsProvider).save(a);
    // Ask once, at the moment it makes sense: calls need the mic, and ringing
    // in the background needs notifications.
    await [Permission.microphone, Permission.notification].request();
    if (mounted) Navigator.pop(context, true);
  }

  /// Show the account as a provisioning QR, to set up another phone.
  Future<void> _shareQr() async {
    final t = context.t;
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
              child: QrImageView(data: _a.copyWith(password: _pass.text).toProvisioning(), size: 240),
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
      await ref.read(accountsProvider).remove(_a.id);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final ws = _a.transport == 'ws' || _a.transport == 'wss';
    String? req(String? v) => (v == null || v.trim().isEmpty) ? 'required'.tr() : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'addAccount'.tr() : 'editAccount'.tr(),
            style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (widget.existing != null)
            IconButton(tooltip: 'shareAccount'.tr(), icon: const Icon(Icons.qr_code_2), onPressed: _shareQr),
          if (widget.existing != null)
            IconButton(tooltip: 'deleteAccount'.tr(), icon: Icon(Icons.delete_outline, color: t.danger), onPressed: _delete),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
                Row(children: [
                  Expanded(child: _MethodTile(icon: Icons.qr_code_scanner, label: 'scanQr'.tr(), onTap: _scan)),
                  const SizedBox(width: 8),
                  Expanded(child: _MethodTile(icon: Icons.description_outlined, label: 'importFile'.tr(), onTap: _import)),
                  const SizedBox(width: 8),
                  Expanded(child: _MethodTile(icon: Icons.edit_outlined, label: 'typeIn'.tr(), selected: true, onTap: () {})),
                ]),
                const SizedBox(height: 14),
                TextFormField(controller: _name, decoration: InputDecoration(labelText: 'accountName'.tr(), hintText: 'Office PBX')),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _user,
                      validator: req,
                      autocorrect: false,
                      decoration: InputDecoration(labelText: 'user'.tr(), hintText: '201'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _pass,
                      obscureText: !_showPass,
                      decoration: InputDecoration(
                        labelText: 'password'.tr(),
                        suffixIcon: IconButton(
                          tooltip: 'password'.tr(),
                          icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _showPass = !_showPass),
                        ),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: _domain,
                      validator: req,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(labelText: 'server'.tr(), hintText: 'serverHint'.tr()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _port,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: 'port'.tr(), hintText: _defaultPort(_a.transport)),
                    ),
                  ),
                ]),
                const SizedBox(height: 14),
                ECard(
                  onTap: () => setState(() => _advanced = !_advanced),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('advanced'.tr(), style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${_a.transport.toUpperCase()} · ${_encLabel(_a.mediaEnc)} · ${_codecLabel(_a.codecs)}',
                            style: mono(context)),
                      ]),
                    ),
                    Icon(_advanced ? Icons.expand_less : Icons.expand_more, color: t.text2),
                  ]),
                ),
                if (_advanced) ...[
                  _label(context, 'transport'.tr()),
                  _Segments(
                    options: const ['udp', 'tcp', 'tls', 'ws', 'wss'],
                    labels: const ['UDP', 'TCP', 'TLS', 'WS', 'WSS'],
                    value: _a.transport,
                    onChanged: (v) => setState(() => _a = _a.copyWith(transport: v)),
                  ),
                  if (ws) ...[
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _wsUrl,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(labelText: 'wsUrl'.tr(), hintText: 'wss://${_domain.text.isEmpty ? 'pbx.example.com' : _domain.text}:8089/ws'),
                    ),
                  ],
                  _label(context, 'mediaEnc'.tr()),
                  _Segments(
                    options: const ['none', 'sdes', 'dtls'],
                    labels: ['encNone'.tr(), 'SDES', 'DTLS-SRTP'],
                    value: _a.mediaEnc,
                    onChanged: (v) => setState(() => _a = _a.copyWith(mediaEnc: v)),
                  ),
                  _label(context, '${'codecs'.tr()} · ${'codecOrder'.tr()}'),
                  _CodecList(codecs: _a.codecs, onChanged: (c) => setState(() => _a = _a.copyWith(codecs: c))),
                  _label(context, 'nat'.tr()),
                  ECard(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Column(children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('ice'.tr()),
                        value: _a.ice,
                        onChanged: (v) => setState(() => _a = _a.copyWith(ice: v)),
                      ),
                      TextFormField(controller: _stun, decoration: InputDecoration(labelText: 'stunServer'.tr(), hintText: 'stun:stun.l.google.com:19302')),
                      const SizedBox(height: 10),
                      TextFormField(controller: _turn, decoration: InputDecoration(labelText: 'turnServer'.tr(), hintText: 'turn:turn.example.com:3478')),
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(child: TextFormField(controller: _turnUser, decoration: InputDecoration(labelText: 'turnUser'.tr()))),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextFormField(controller: _turnPass, obscureText: true, decoration: InputDecoration(labelText: 'turnPass'.tr())),
                        ),
                      ]),
                      const SizedBox(height: 10),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(controller: _proxy, decoration: InputDecoration(labelText: 'outboundProxy'.tr(), hintText: 'sip:proxy.example.com;lr')),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: TextFormField(controller: _authUser, decoration: InputDecoration(labelText: 'authUser'.tr()))),
                    const SizedBox(width: 10),
                    Expanded(child: TextFormField(controller: _display, decoration: InputDecoration(labelText: 'displayName'.tr()))),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _a.dtmf,
                        decoration: InputDecoration(labelText: 'dtmf'.tr()),
                        items: const [
                          DropdownMenuItem(value: 'rfc4733', child: Text('RFC 4733')),
                          DropdownMenuItem(value: 'info', child: Text('SIP INFO')),
                          DropdownMenuItem(value: 'auto', child: Text('Auto')),
                        ],
                        onChanged: (v) => setState(() => _a = _a.copyWith(dtmf: v)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: TextFormField(controller: _voicemail, decoration: InputDecoration(labelText: 'voicemail'.tr()))),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _prefix,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(labelText: 'dialPrefix'.tr(), hintText: '9'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _plus,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(labelText: 'plusReplace'.tr(), hintText: '00'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _headers,
                    minLines: 2,
                    maxLines: 5,
                    style: mono(context, size: 12, color: t.text),
                    decoration: InputDecoration(labelText: 'customHeaders'.tr(), hintText: 'Privacy: id\nX-Department: sales'),
                  ),
                  const SizedBox(height: 6),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('verifyTls'.tr()),
                    value: _a.verifyTls,
                    onChanged: (v) => setState(() => _a = _a.copyWith(verifyTls: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('push'.tr()),
                    subtitle: Text('pushSub'.tr()),
                    value: _a.push,
                    onChanged: (v) => setState(() => _a = _a.copyWith(push: v)),
                  ),
                ],
                if (ref.watch(settingsProvider).recordingMode == 'always')
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('recordThisAccount'.tr()),
                    subtitle: Text('recordThisAccountSub'.tr()),
                    value: _a.recordCalls,
                    onChanged: (v) => setState(() => _a = _a.copyWith(recordCalls: v)),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('setDefault'.tr()),
                  value: _a.isDefault,
                  onChanged: (v) => setState(() => _a = _a.copyWith(isDefault: v)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(width: double.infinity, child: PrimaryButton(label: 'saveConnect'.tr(), onPressed: _save)),
            ),
          ]),
        ),
      ),
    );
  }

  static String _defaultPort(String transport) => switch (transport) {
        'tls' => '5061',
        'ws' => '8088',
        'wss' => '8089',
        _ => '5060',
      };

  static String _encLabel(String e) => switch (e) { 'sdes' => 'SDES', 'dtls' => 'DTLS-SRTP', _ => 'encNone'.tr() };

  static String _codecLabel(List<String> c) =>
      c.map((x) => x == 'alaw' ? 'PCMA' : x == 'ulaw' ? 'PCMU' : 'Opus').join(', ');

  Widget _label(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 14, 2, 6),
        child: Text(s, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.t.text2)),
      );
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({required this.icon, required this.label, required this.onTap, this.selected = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: selected ? t.accentSoft : t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: selected ? t.accent : t.border, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          height: 68,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: t.accent),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

class _Segments extends StatelessWidget {
  const _Segments({required this.options, required this.labels, required this.value, required this.onChanged});
  final List<String> options, labels;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(children: [
      for (var i = 0; i < options.length; i++)
        Expanded(
          child: Padding(
            padding: EdgeInsetsDirectional.only(end: i == options.length - 1 ? 0 : 6),
            child: Material(
              color: value == options[i] ? t.accent : t.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: value == options[i] ? t.accent : t.border),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onChanged(options[i]),
                child: SizedBox(
                  height: 40,
                  child: Center(
                    child: Text(labels[i],
                        style: mono(context, size: 11, color: value == options[i] ? t.onAccent : t.text2, weight: FontWeight.w600)),
                  ),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// Codec order and on/off: Opus, G.711 A-law, G.711 µ-law (all Medut-SDK builds).
class _CodecList extends StatelessWidget {
  const _CodecList({required this.codecs, required this.onChanged});
  final List<String> codecs;
  final ValueChanged<List<String>> onChanged;

  static const _all = ['opus', 'alaw', 'ulaw'];
  static const _names = {'opus': 'Opus', 'alaw': 'G.711 A-law (PCMA)', 'ulaw': 'G.711 µ-law (PCMU)'};

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final ordered = [...codecs, ..._all.where((c) => !codecs.contains(c))];
    return ECard(
      padding: EdgeInsets.zero,
      child: ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorderItem: (from, to) {
          final l = [...ordered];
          final item = l.removeAt(from);
          l.insert(to, item);
          onChanged(l.where(codecs.contains).toList());
        },
        children: [
          for (var i = 0; i < ordered.length; i++)
            ListTile(
              key: ValueKey(ordered[i]),
              leading: Checkbox(
                value: codecs.contains(ordered[i]),
                activeColor: t.accent,
                onChanged: (on) {
                  final next = on == true
                      ? ordered.where((c) => codecs.contains(c) || c == ordered[i]).toList()
                      : codecs.where((c) => c != ordered[i]).toList();
                  if (next.isNotEmpty) onChanged(next);
                },
              ),
              title: Text(_names[ordered[i]]!),
              trailing: ReorderableDragStartListener(index: i, child: Icon(Icons.drag_handle, color: t.text2)),
            ),
        ],
      ),
    );
  }
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
