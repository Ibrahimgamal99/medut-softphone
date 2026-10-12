import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../core/providers.dart';
import '../core/theme.dart';
import '../sip/native_bridge.dart';
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
        section('diagnostics'.tr(), [
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
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SipLogScreen())),
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

/// Last SIP messages sent and received, for troubleshooting a PBX.
class SipLogScreen extends ConsumerWidget {
  const SipLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final log = ref.watch(sipProvider).sipLog.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text('sipLog'.tr()),
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
