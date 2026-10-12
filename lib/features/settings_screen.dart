import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../core/providers.dart';
import '../core/theme.dart';
import '../sip/native_bridge.dart';
import '../sip/tones.dart';
import '../ui/widgets.dart';

/// Shown on the Accounts tab when something will make the phone miss calls:
/// Android battery optimisation, or no full-screen ringing permission.
class ReachabilityBanner extends ConsumerStatefulWidget {
  const ReachabilityBanner({super.key});

  @override
  ConsumerState<ReachabilityBanner> createState() => _ReachabilityBannerState();
}

class _ReachabilityBannerState extends ConsumerState<ReachabilityBanner> with WidgetsBindingObserver {
  bool _battery = true;
  bool _fullScreen = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final b = await NativeBridge.instance.isBatteryExempt();
    final f = await NativeBridge.instance.canUseFullScreenIntent();
    if (mounted) {
      setState(() {
        _battery = b;
        _fullScreen = f;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final settings = ref.watch(settingsProvider);
    final hasAccounts = ref.watch(accountsProvider).accounts.isNotEmpty;
    if (!Platform.isAndroid || !hasAccounts) return const SizedBox.shrink();
    final items = <Widget>[
      if (settings.keepAlive && !_battery)
        _row(context, 'batteryOpt'.tr(), 'batteryOptOn'.tr(), NativeBridge.instance.requestBatteryExemption),
      if (!_fullScreen) _row(context, 'fullScreen'.tr(), 'fullScreenOff'.tr(), NativeBridge.instance.openFullScreenIntentSettings),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ECard(borderColor: t.warn.withValues(alpha: 0.6), child: Column(children: items)),
    );
  }

  Widget _row(BuildContext context, String title, String sub, Future<void> Function() fix) {
    final t = context.t;
    return Row(children: [
      Icon(Icons.warning_amber_rounded, color: t.warn),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(sub, style: TextStyle(fontSize: 12, color: t.text2)),
        ]),
      ),
      TextButton(onPressed: () async => fix(), child: Text('allow'.tr())),
    ]);
  }
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(settingsProvider);
    final sip = ref.watch(sipProvider);

    Widget section(String title, List<Widget> children) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionLabel(title),
          ECard(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4), child: Column(children: children)),
        ]);

    return Scaffold(
      appBar: AppBar(title: Text('settings'.tr(), style: const TextStyle(fontWeight: FontWeight.w700))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
        section('appearance'.tr(), [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('theme'.tr()),
            trailing: DropdownButton<String>(
              value: s.themeMode,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(value: 'system', child: Text('themeSystem'.tr())),
                DropdownMenuItem(value: 'light', child: Text('themeLight'.tr())),
                DropdownMenuItem(value: 'dark', child: Text('themeDark'.tr())),
              ],
              onChanged: (v) => s.themeMode = v ?? 'system',
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('language'.tr()),
            trailing: DropdownButton<String>(
              value: context.locale.languageCode,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 'en', child: Text('English')),
                DropdownMenuItem(value: 'ar', child: Text('العربية')),
              ],
              onChanged: (v) => context.setLocale(Locale(v ?? 'en')),
            ),
          ),
        ]),
        section('ringing'.tr(), [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('ringtone'.tr()),
            subtitle: Text(Tones.byId(s.ringtoneId).labelKey.tr()),
            trailing: Icon(Icons.chevron_right, color: t.text2),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RingtoneScreen())),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('vibrate'.tr()),
            value: s.vibrate,
            onChanged: (v) => s.vibrate = v,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('ringbackTone'.tr()),
            subtitle: Text('ringbackSub'.tr()),
            value: s.ringback,
            onChanged: (v) => s.ringback = v,
          ),
        ]),
        section('callsSection'.tr(), [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('autoAnswer'.tr()),
            subtitle: Text('autoAnswerSub'.tr()),
            value: s.autoAnswer,
            onChanged: (v) => s.autoAnswer = v,
          ),
          if (s.autoAnswer)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('autoAnswerDelay'.tr()),
              trailing: DropdownButton<int>(
                value: s.autoAnswerDelay,
                underline: const SizedBox.shrink(),
                items: [for (final d in [0, 1, 3, 5, 10]) DropdownMenuItem(value: d, child: Text('${d}s'))],
                onChanged: (v) => s.autoAnswerDelay = v ?? 3,
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('showCallQuality'.tr()),
            subtitle: Text('showCallQualitySub'.tr()),
            value: s.showCallQuality,
            onChanged: (v) => s.showCallQuality = v,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('blockedNumbers'.tr()),
            subtitle: Text('${s.blocked.length}'),
            trailing: Icon(Icons.chevron_right, color: t.text2),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BlockedScreen())),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('clearHistory'.tr(), style: TextStyle(color: t.danger)),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text('clearHistory'.tr()),
                  content: Text('clearHistoryConfirm'.tr()),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('cancel'.tr())),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('delete'.tr())),
                  ],
                ),
              );
              if (ok == true) await ref.read(dbProvider).clearCalls();
            },
          ),
        ]),
        section('reachability'.tr(), [
          if (Platform.isAndroid)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('stayReachable'.tr()),
              subtitle: Text('stayReachableSub'.tr()),
              value: s.keepAlive,
              onChanged: (v) => s.keepAlive = v,
            ),
          if (Platform.isAndroid) const ReachabilityBanner(),
          const _PermissionTile(Permission.microphone, 'microphone'),
          const _PermissionTile(Permission.notification, 'notifications'),
        ]),
        section('audio'.tr(), [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('echoCancel'.tr()),
            trailing: DropdownButton<int>(
              value: s.aecMode,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(value: 0, child: Text('aecOff'.tr())),
                DropdownMenuItem(value: 1, child: Text('aecBasic'.tr())),
                DropdownMenuItem(value: 2, child: Text('aecWebrtc'.tr())),
              ],
              onChanged: (v) => s.aecMode = v ?? 2,
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('jitterBuffer'.tr()),
            subtitle: Text(switch (s.jitterMode) {
              'low' => 'jitterLowSub'.tr(),
              'robust' => 'jitterRobustSub'.tr(),
              _ => 'jitterAutoSub'.tr(),
            }),
            trailing: DropdownButton<String>(
              value: s.jitterMode,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(value: 'auto', child: Text('jitterAuto'.tr())),
                DropdownMenuItem(value: 'low', child: Text('jitterLow'.tr())),
                DropdownMenuItem(value: 'robust', child: Text('jitterRobust'.tr())),
              ],
              onChanged: (v) => s.jitterMode = v ?? 'auto',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('noiseSup'.tr()),
            value: s.noiseSuppression,
            onChanged: (v) => s.noiseSuppression = v,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('autoGain'.tr()),
            value: s.autoGain,
            onChanged: (v) => s.autoGain = v,
          ),
        ]),
        section('recording'.tr(), [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('callRecording'.tr()),
            subtitle: Text(switch (s.recordingMode) {
              'off' => 'recOffSub'.tr(),
              'always' => 'recAlwaysSub'.tr(),
              _ => 'recManualSub'.tr(),
            }),
            trailing: DropdownButton<String>(
              value: s.recordingMode,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(value: 'off', child: Text('recOff'.tr())),
                DropdownMenuItem(value: 'manual', child: Text('recManual'.tr())),
                DropdownMenuItem(value: 'always', child: Text('recAlways'.tr())),
              ],
              onChanged: (v) => s.recordingMode = v ?? 'manual',
            ),
          ),
        ]),
        section('network'.tr(), [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('iceServers'.tr()),
            subtitle: Text(s.iceServers.isEmpty ? 'iceServersNone'.tr() : '${s.iceServers.length}'),
            trailing: Icon(Icons.chevron_right, color: t.text2),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const IceServersScreen())),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('forceRelay'.tr()),
            subtitle: Text('forceRelaySub'.tr()),
            value: s.forceRelay,
            onChanged: (v) => s.forceRelay = v,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('regExpires'.tr()),
            subtitle: Text('restartApp'.tr()),
            trailing: DropdownButton<int>(
              value: s.regExpires,
              underline: const SizedBox.shrink(),
              items: [for (final v in [60, 120, 300, 600, 1800, 3600]) DropdownMenuItem(value: v, child: Text('${v}s'))],
              onChanged: (v) => s.regExpires = v ?? 300,
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('keepalive'.tr()),
            subtitle: Text('restartApp'.tr()),
            trailing: DropdownButton<int>(
              value: s.keepaliveSec,
              underline: const SizedBox.shrink(),
              items: [for (final v in [15, 30, 60, 120]) DropdownMenuItem(value: v, child: Text('${v}s'))],
              onChanged: (v) => s.keepaliveSec = v ?? 30,
            ),
          ),
        ]),
        section('diagnostics'.tr(), [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('debugLogging'.tr()),
            subtitle: Text('restartApp'.tr()),
            value: s.debugLogging,
            onChanged: (v) => s.debugLogging = v,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('connectionLog'.tr()),
            trailing: Icon(Icons.chevron_right, color: t.text2),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => LogScreen(title: 'connectionLog'.tr(), read: (r) => r.read(sipProvider).connLog))),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('sipTrace'.tr()),
            subtitle: Text('restartNote'.tr()),
            value: s.traceSip,
            onChanged: (v) => s.traceSip = v,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('sipLog'.tr()),
            trailing: Icon(Icons.chevron_right, color: t.text2),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => LogScreen(title: 'sipLog'.tr(), read: (r) => r.read(sipProvider).sipLog))),
          ),
        ]),
        section('about'.tr(), [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('sdk'.tr()),
            trailing: Text(sip.sdk?.version ?? '—', style: mono(context, size: 12)),
          ),
        ]),
      ]),
    );
  }
}

class _PermissionTile extends StatefulWidget {
  const _PermissionTile(this.permission, this.labelKey);
  final Permission permission;
  final String labelKey;

  @override
  State<_PermissionTile> createState() => _PermissionTileState();
}

class _PermissionTileState extends State<_PermissionTile> {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    widget.permission.isGranted.then((g) => mounted ? setState(() => _granted = g) : null);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(widget.labelKey.tr()),
      trailing: _granted == true
          ? Text('granted'.tr(), style: TextStyle(color: t.success, fontWeight: FontWeight.w600))
          : TextButton(
              onPressed: () async {
                final s = await widget.permission.request();
                if (s.isPermanentlyDenied) await openAppSettings();
                if (mounted) setState(() => _granted = s.isGranted);
              },
              child: Text('grant'.tr()),
            ),
    );
  }
}

/// SIP messages, or the connection log, for troubleshooting a PBX.
class LogScreen extends ConsumerWidget {
  const LogScreen({super.key, required this.title, required this.read});
  final String title;
  final List<String> Function(WidgetRef ref) read;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    ref.watch(sipProvider);
    final log = read(ref).reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'share'.tr(),
            icon: const Icon(Icons.ios_share),
            onPressed: log.isEmpty
                ? null
                : () async {
                    final f = File('${(await getTemporaryDirectory()).path}/medut-sip-${DateTime.now().millisecondsSinceEpoch}.log');
                    await f.writeAsString(log.reversed.join('\n\n'));
                    await Share.shareXFiles([XFile(f.path)]);
                  },
          ),
        ],
      ),
      body: log.isEmpty
          ? Center(child: Text('emptyLog'.tr(), style: TextStyle(color: t.text2)))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: log.length,
              separatorBuilder: (_, _) => Divider(color: t.border),
              itemBuilder: (_, i) => SelectableText(log[i], style: mono(context, size: 11, color: t.text)),
            ),
    );
  }
}

/// Ringtone picker: the phone's own ringtone, Medut's tones, or a file of
/// your own. Tapping a tone plays it.
class RingtoneScreen extends ConsumerStatefulWidget {
  const RingtoneScreen({super.key});

  @override
  ConsumerState<RingtoneScreen> createState() => _RingtoneScreenState();
}

class _RingtoneScreenState extends ConsumerState<RingtoneScreen> {
  @override
  void dispose() {
    Tones.stopPreview();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.audio);
    final path = r?.files.single.path;
    if (path == null) return;
    final ext = path.contains('.') ? path.split('.').last : 'm4a';
    final dir = await getApplicationSupportDirectory();
    final dest = File('${dir.path}/tones/custom_ringtone.$ext');
    await dest.parent.create(recursive: true);
    await File(path).copy(dest.path);
    final s = ref.read(settingsProvider);
    s.customRingtonePath = dest.path;
    s.ringtoneId = 'custom';
    await Tones.preview('custom', dest.path);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final s = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: Text('ringtone'.tr())),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ECard(
          padding: EdgeInsets.zero,
          child: RadioGroup<String>(
            groupValue: s.ringtoneId,
            onChanged: (id) async {
              if (id == null) return;
              if (id == 'custom' && s.customRingtonePath.isEmpty) return _pickFile();
              s.ringtoneId = id;
              await Tones.preview(id, s.customRingtonePath);
            },
            child: Column(children: [
              for (final r in Tones.all)
                RadioListTile<String>(
                  value: r.id,
                  activeColor: t.accent,
                  title: Text(r.labelKey.tr()),
                  subtitle: r.id == 'custom' && s.customRingtonePath.isNotEmpty
                      ? Text(s.customRingtonePath.split('/').last, style: TextStyle(color: t.text2))
                      : null,
                  secondary: r.id == 'custom'
                      ? TextButton(onPressed: _pickFile, child: Text('chooseFile'.tr()))
                      : null,
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class BlockedScreen extends ConsumerWidget {
  const BlockedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(settingsProvider);
    final list = s.blocked.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: Text('blockedNumbers'.tr())),
      floatingActionButton: FloatingActionButton(
        tooltip: 'add'.tr(),
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        onPressed: () async {
          final c = TextEditingController();
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('blockNumber'.tr()),
              content: TextField(controller: c, keyboardType: TextInputType.phone, autofocus: true),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('cancel'.tr())),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('add'.tr())),
              ],
            ),
          );
          if (ok == true && c.text.trim().isNotEmpty) s.blocked = {...s.blocked, c.text.trim()};
        },
        child: const Icon(Icons.add),
      ),
      body: list.isEmpty
          ? Center(child: Text('blockedNone'.tr(), style: TextStyle(color: t.text2)))
          : ListView(padding: const EdgeInsets.all(16), children: [
              for (final n in list)
                ListTile(
                  leading: Icon(Icons.block, color: t.danger),
                  title: Text(n),
                  trailing: IconButton(
                    tooltip: 'unblock'.tr(),
                    icon: const Icon(Icons.close),
                    onPressed: () => s.blocked = s.blocked.where((x) => x != n).toSet(),
                  ),
                ),
            ]),
    );
  }
}

/// Extra STUN / TURN servers for every account (Settings → Network).
class IceServersScreen extends ConsumerWidget {
  const IceServersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(settingsProvider);
    final list = s.iceServers;

    Future<void> edit([int? index]) async {
      final cur = index == null ? <String, String>{} : list[index];
      final url = TextEditingController(text: cur['url'] ?? '');
      final user = TextEditingController(text: cur['user'] ?? '');
      final pass = TextEditingController(text: cur['pass'] ?? '');
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(index == null ? 'addServer'.tr() : 'edit'.tr()),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: url, decoration: const InputDecoration(labelText: 'URL', hintText: 'turn:turn.example.com:3478')),
            const SizedBox(height: 10),
            TextField(controller: user, decoration: InputDecoration(labelText: 'turnUser'.tr())),
            const SizedBox(height: 10),
            TextField(controller: pass, obscureText: true, decoration: InputDecoration(labelText: 'turnPass'.tr())),
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => url.text = 'stun:stun.l.google.com:19302',
                child: Text('addPresetStun'.tr()),
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('cancel'.tr())),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('save'.tr())),
          ],
        ),
      );
      if (ok != true || url.text.trim().isEmpty) return;
      final entry = {'url': url.text.trim(), 'user': user.text.trim(), 'pass': pass.text};
      final next = [...list];
      index == null ? next.add(entry) : next[index] = entry;
      s.iceServers = next;
    }

    return Scaffold(
      appBar: AppBar(title: Text('iceServers'.tr())),
      floatingActionButton: FloatingActionButton(
        tooltip: 'addServer'.tr(),
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        onPressed: edit,
        child: const Icon(Icons.add),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('iceServersHint'.tr(), style: TextStyle(color: t.text2, fontSize: 13)),
        const SizedBox(height: 12),
        for (var i = 0; i < list.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ECard(
              onTap: () => edit(i),
              padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(list[i]['url'] ?? '', style: mono(context, size: 12, color: t.text)),
                    if ((list[i]['user'] ?? '').isNotEmpty) Text(list[i]['user']!, style: mono(context)),
                  ]),
                ),
                IconButton(
                  tooltip: 'delete'.tr(),
                  icon: Icon(Icons.delete_outline, color: t.danger),
                  onPressed: () => s.iceServers = [...list]..removeAt(i),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}
