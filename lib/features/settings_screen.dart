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
import '../core/db.dart';
import '../sip/native_bridge.dart';
import '../sip/sip_service.dart';
import '../sip/tones.dart';
import '../ui/widgets.dart';
import 'accounts.dart';
import 'contacts_screen.dart' show StatusRulesScreen, officeHoursText;
import 'status.dart';
import 'status_codes.dart';

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
    final def = ref.watch(accountsProvider).defaultAccount;
    final nav = Navigator.of(context);
    void open(Widget page) => nav.push(MaterialPageRoute(builder: (_) => page));
    final status = s.effectiveStatus();
    final (statusLabel, statusColor, statusIcon) = statusLook(t, status);

    return Scaffold(
      appBar: AppBar(title: Text('settings'.tr(), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: ListView(padding: const EdgeInsets.only(bottom: 48), children: [
        const _ProfileCard(),
        SettingsSection(title: 'appearance'.tr(), children: [
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SettingsTile(
              icon: switch (s.themeMode) { 'light' => Icons.light_mode, 'dark' => Icons.dark_mode, _ => Icons.brightness_auto },
              tint: t.warn,
              title: 'theme'.tr(),
              subtitle: switch (s.themeMode) { 'light' => 'themeLight'.tr(), 'dark' => 'themeDark'.tr(), _ => 'themeSystem'.tr() },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: _ThemeSwatches(value: s.themeMode, onChanged: (v) => s.themeMode = v),
            ),
          ]),
          SettingsTile(
            icon: Icons.translate,
            tint: t.info,
            title: 'language'.tr(),
            trailing: SizedBox(
              width: 104,
              child: PocketSegments(
                options: const ['en', 'ar'],
                labels: const ['EN', 'ع'],
                value: Localizations.localeOf(context).languageCode,
                onChanged: (v) => context.setLocale(Locale(v)),
              ),
            ),
          ),
        ]),
        SettingsSection(title: 'statusSection'.tr(), children: [
          SettingsTile(
            icon: statusIcon,
            tint: statusColor,
            title: 'yourStatus'.tr(),
            subtitle: statusLabel,
            onTap: () => showStatusSheet(context),
          ),
          SettingsTile(
            icon: Icons.schedule,
            tint: t.purple,
            title: 'statusRules'.tr(),
            subtitle: officeHoursText(s),
            onTap: () => open(const StatusRulesScreen()),
          ),
          SettingsTile(
            icon: Icons.dialpad,
            tint: t.accent,
            title: 'statusCodes'.tr(),
            subtitle: def == null ? 'statusCodesSub'.tr() : codesSummary(def),
            onTap: () => open(const StatusCodesScreen()),
          ),
        ]),
        SettingsSection(title: 'callsSection'.tr(), children: [
          SettingsTile(
            icon: Icons.notifications_active_outlined,
            tint: t.purple,
            title: 'ringtone'.tr(),
            subtitle: Tones.byId(s.ringtoneId).labelKey.tr(),
            onTap: () => open(const RingtoneScreen()),
          ),
          _switch(context, Icons.vibration, t.info, 'vibrate'.tr(), null, s.vibrate, (v) => s.vibrate = v),
          _switch(context, Icons.ring_volume_outlined, t.info, 'ringbackTone'.tr(), 'ringbackSub'.tr(), s.ringback,
              (v) => s.ringback = v),
          _switch(context, Icons.call_received, t.success, 'autoAnswer'.tr(), 'autoAnswerSub'.tr(), s.autoAnswer,
              (v) => s.autoAnswer = v),
          if (s.autoAnswer)
            SettingsTile(
              icon: Icons.timer_outlined,
              tint: t.warn,
              title: 'autoAnswerDelay'.tr(),
              subtitle: 'autoAnswerDelayValue'.tr(namedArgs: {'s': '${s.autoAnswerDelay}'}),
              onTap: () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                builder: (_) => const _AutoAnswerDelaySheet(),
              ),
            ),
          SettingsTile(
            icon: Icons.block,
            tint: t.danger,
            title: 'blockedNumbers'.tr(),
            subtitle: '${s.blocked.length}',
            onTap: () => open(const BlockedScreen()),
          ),
          if (Platform.isAndroid)
            _switch(context, Icons.wifi_tethering, t.info, 'stayReachable'.tr(), 'stayReachableSub'.tr(), s.keepAlive,
                (v) => s.keepAlive = v),
        ]),
        if (Platform.isAndroid)
          const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 0), child: ReachabilityBanner()),
        SettingsSection(title: 'recording'.tr(), children: [
          SettingsTile(
            icon: Icons.fiber_manual_record,
            tint: t.danger,
            title: 'callRecording'.tr(),
            subtitle: switch (s.recordingMode) {
              'off' => 'recOffSub'.tr(),
              'always' => '${'recAlwaysSub'.tr()}\n${'recLaw'.tr()}',
              _ => '${'recManualSub'.tr()}\n${'recLaw'.tr()}',
            },
            onTap: () async {
              final v = await chooseOne(context, 'callRecording'.tr(), s.recordingMode, [
                ('off', 'recOff'.tr(), 'recOffSub'.tr()),
                ('manual', 'recManual'.tr(), 'recManualSub'.tr()),
                ('always', 'recAlways'.tr(), 'recAlwaysSub'.tr()),
              ]);
              if (v != null) s.recordingMode = v;
            },
          ),
          FutureBuilder<Directory>(
            future: SipService.recordingsDir(s),
            builder: (_, snap) => SettingsTile(
              icon: Icons.folder_outlined,
              tint: t.warn,
              title: 'recordingsFolder'.tr(),
              subtitle: '${switch (s.recordingDir) {
                'private' => 'folderPrivate'.tr(),
                'custom' => 'folderCustom'.tr(),
                _ => 'folderShared'.tr(),
              }}\n${snap.data?.path ?? ''}',
              onTap: () => showModalBottomSheet<void>(
                  context: context, showDragHandle: true, builder: (_) => const _RecordingFolderSheet()),
            ),
          ),
        ]),
        SettingsSection(title: 'historySection'.tr(), children: [
          SettingsTile(
            icon: Icons.ios_share,
            tint: t.info,
            title: 'exportHistory'.tr(),
            subtitle: 'exportHistorySub'.tr(),
            trailing: const SizedBox.shrink(),
            onTap: () => _exportHistory(ref),
          ),
          SettingsTile(
            icon: Icons.delete_outline,
            tint: t.danger,
            title: 'clearHistory'.tr(),
            titleColor: t.danger,
            trailing: const SizedBox.shrink(),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text('clearHistory'.tr()),
                  content: Text('clearHistoryConfirm'.tr()),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('cancel'.tr())),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: t.danger),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text('delete'.tr()),
                    ),
                  ],
                ),
              );
              if (ok == true) await ref.read(dbProvider).clearCalls();
            },
          ),
        ]),
        SettingsSection(title: 'more'.tr(), children: [
          SettingsTile(
            icon: Icons.tune,
            tint: t.purple,
            title: 'advancedCall'.tr(),
            subtitle: 'advancedCallSub'.tr(),
            onTap: () => open(const AdvancedCallSettingsScreen()),
          ),
          SettingsTile(
            icon: Icons.support_outlined,
            tint: t.warn,
            title: 'helpDiagnostics'.tr(),
            subtitle: s.debugLogging ? 'debugLogging'.tr() : 'helpDiagnosticsSub'.tr(),
            trailing: s.debugLogging
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    SettingsBadge('on'.tr(), color: t.warn),
                    Icon(Icons.chevron_right, size: 20, color: t.text2.withValues(alpha: 0.6)),
                  ])
                : null,
            onTap: () => open(const DiagnosticsScreen()),
          ),
        ]),
      ]),
    );
  }

  static Future<void> _exportHistory(WidgetRef ref) async {
    final calls = await ref.read(dbProvider).calls(limit: 100000);
    String cell(Object? v) {
      final text = v?.toString() ?? '';
      return text.contains(RegExp(r'[",\n]')) ? '"${text.replaceAll('"', '""')}"' : text;
    }

    final csv = [
      CallRecord.csvHeader.join(','),
      for (final c in calls) c.toCsv().map(cell).join(','),
    ].join('\n');
    final f = File('${(await getTemporaryDirectory()).path}/medut-calls-${DateTime.now().millisecondsSinceEpoch}.csv');
    await f.writeAsString(csv);
    await Share.shareXFiles([XFile(f.path)]);
  }
}

Widget _switch(BuildContext context, IconData icon, Color tint, String title, String? sub, bool value,
        ValueChanged<bool> onChanged) =>
    SettingsTile(
      icon: icon,
      tint: tint,
      title: title,
      subtitle: sub,
      trailing: Switch(value: value, onChanged: onChanged),
      onTap: () => onChanged(!value),
    );

/// One choice from a short list, in a sheet that closes on the pick.
Future<T?> chooseOne<T>(BuildContext context, String title, T current, List<(T, String, String?)> options) =>
    showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: RadioGroup<T>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(ctx, v),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final o in options)
              RadioListTile<T>(
                value: o.$1,
                activeColor: ctx.t.accent,
                title: Text(o.$2),
                subtitle: o.$3 == null ? null : Text(o.$3!, style: TextStyle(fontSize: 12.5, color: ctx.t.text2)),
              ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );

/// Who you are on the default account, and whether it is registered; tap
/// for Accounts.
class _ProfileCard extends ConsumerWidget {
  const _ProfileCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final def = ref.watch(accountsProvider).defaultAccount;
    final rt = def == null ? null : ref.watch(sipProvider).runtimes[def.id];
    final ok = rt?.status == RegStatus.registered;
    final name = def == null ? '' : (def.displayName.isNotEmpty ? def.displayName : def.user);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: t.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: t.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountsScreen())),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Avatar(name.isEmpty ? '?' : name, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name.isEmpty ? 'noAccountsYet'.tr() : name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  if (def != null)
                    Text('${def.user} · ${def.label}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: t.text2)),
                ]),
              ),
              if (def != null) SettingsBadge(ok ? 'registered'.tr() : 'notRegistered'.tr(), color: ok ? t.success : t.danger),
            ]),
          ),
        ),
      ),
    );
  }
}

/// System, Light, Dark as three little previews of the app.
class _ThemeSwatches extends StatelessWidget {
  const _ThemeSwatches({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  static Widget _canvas(Color bg, Color bar, Color accent) => Container(
        color: bg,
        padding: const EdgeInsets.all(8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 18, height: 6, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(3))),
          const SizedBox(height: 6),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: bar, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 4),
          Container(width: 28, height: 4, decoration: BoxDecoration(color: bar, borderRadius: BorderRadius.circular(2))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final light = _canvas(Tokens.light.bg, Tokens.light.border, Tokens.light.accent);
    final dark = _canvas(Tokens.darkTokens.bg, Tokens.darkTokens.border, Tokens.darkTokens.accent);
    return Row(children: [
      for (final (mode, label, preview) in [
        ('system', 'themeSystem'.tr(), Row(children: [Expanded(child: light), Expanded(child: dark)])),
        ('light', 'themeLight'.tr(), light),
        ('dark', 'themeDark'.tr(), dark),
      ])
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Semantics(
              button: true,
              selected: value == mode,
              label: label,
              child: GestureDetector(
                onTap: () => onChanged(mode),
                child: Column(children: [
                  Container(
                    height: 52,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: value == mode ? t.accent : t.border, width: value == mode ? 2 : 1),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox.expand(child: preview),
                  ),
                  const SizedBox(height: 6),
                  Text(label,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: value == mode ? FontWeight.w700 : FontWeight.w500,
                          color: value == mode ? t.accent : t.text2)),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// Settings → Advanced call settings: voice processing, quality, network.
class AdvancedCallSettingsScreen extends ConsumerWidget {
  const AdvancedCallSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(settingsProvider);
    String aec(int v) => switch (v) { 0 => 'aecOff'.tr(), 1 => 'aecBasic'.tr(), _ => 'aecWebrtc'.tr() };
    String jitter(String v) => switch (v) { 'low' => 'jitterLow'.tr(), 'robust' => 'jitterRobust'.tr(), _ => 'jitterAuto'.tr() };
    return Scaffold(
      appBar: AppBar(title: Text('advancedCall'.tr(), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: ListView(padding: const EdgeInsets.only(bottom: 48), children: [
        Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: t.info.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: t.info.withValues(alpha: 0.3)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 20, color: t.info),
            const SizedBox(width: 10),
            Expanded(child: Text('advancedNotice'.tr(), style: const TextStyle(fontSize: 13, height: 1.45))),
          ]),
        ),
        SettingsSection(title: 'audio'.tr(), children: [
          SettingsTile(
            icon: Icons.surround_sound_outlined,
            tint: t.accent,
            title: 'echoCancel'.tr(),
            subtitle: aec(s.aecMode),
            onTap: () async {
              final v = await chooseOne<int>(context, 'echoCancel'.tr(), s.aecMode, [
                (0, 'aecOff'.tr(), null),
                (1, 'aecBasic'.tr(), null),
                (2, 'aecWebrtc'.tr(), null),
              ]);
              if (v != null) s.aecMode = v;
            },
          ),
          _switch(context, Icons.noise_aware, t.info, 'noiseSup'.tr(), null, s.noiseSuppression, (v) => s.noiseSuppression = v),
          _switch(context, Icons.volume_up_outlined, t.info, 'autoGain'.tr(), null, s.autoGain, (v) => s.autoGain = v),
        ]),
        SettingsSection(title: 'voiceQuality'.tr(), children: [
          SettingsTile(
            icon: Icons.equalizer,
            tint: t.info,
            title: 'jitterBuffer'.tr(),
            subtitle: jitter(s.jitterMode),
            onTap: () async {
              final v = await chooseOne<String>(context, 'jitterBuffer'.tr(), s.jitterMode, [
                ('auto', 'jitterAuto'.tr(), 'jitterAutoSub'.tr()),
                ('low', 'jitterLow'.tr(), 'jitterLowSub'.tr()),
                ('robust', 'jitterRobust'.tr(), 'jitterRobustSub'.tr()),
              ]);
              if (v != null) s.jitterMode = v;
            },
          ),
          _switch(context, Icons.signal_cellular_alt, t.success, 'showCallQuality'.tr(), 'showCallQualitySub'.tr(),
              s.showCallQuality, (v) => s.showCallQuality = v),
        ]),
        SettingsSection(title: 'network'.tr(), children: [
          SettingsTile(
            icon: Icons.hub_outlined,
            tint: t.accent,
            title: 'iceServers'.tr(),
            subtitle: s.iceServers.isEmpty ? 'iceServersNone'.tr() : '${s.iceServers.length}',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const IceServersScreen())),
          ),
          _switch(context, Icons.shield_outlined, t.warn, 'forceRelay'.tr(), 'forceRelaySub'.tr(), s.forceRelay,
              (v) => s.forceRelay = v),
          SettingsTile(
            icon: Icons.timer_outlined,
            tint: t.purple,
            title: 'regExpires'.tr(),
            subtitle: '${s.regExpires}s · ${'restartApp'.tr()}',
            onTap: () async {
              final v = await chooseOne<int>(context, 'regExpires'.tr(), s.regExpires,
                  [for (final v in [60, 120, 300, 600, 1800, 3600]) (v, '${v}s', null)]);
              if (v != null) s.regExpires = v;
            },
          ),
          SettingsTile(
            icon: Icons.monitor_heart_outlined,
            tint: t.purple,
            title: 'keepalive'.tr(),
            subtitle: '${s.keepaliveSec}s · ${'restartApp'.tr()}',
            onTap: () async {
              final v = await chooseOne<int>(context, 'keepalive'.tr(), s.keepaliveSec,
                  [for (final v in [15, 30, 60, 120]) (v, '${v}s', null)]);
              if (v != null) s.keepaliveSec = v;
            },
          ),
        ]),
      ]),
    );
  }
}

/// Settings → Help & diagnostics: registration, permissions, logs, version.
class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(settingsProvider);
    final sip = ref.watch(sipProvider);
    final accounts = ref.watch(accountsProvider).accounts;
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    return Scaffold(
      appBar: AppBar(title: Text('helpDiagnostics'.tr(), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: ListView(padding: const EdgeInsets.only(bottom: 48), children: [
        SettingsSection(title: 'connection'.tr(), children: [
          for (final a in accounts)
            Builder(builder: (context) {
              final rt = sip.runtimes[a.id];
              final ok = rt?.status == RegStatus.registered;
              return SettingsTile(
                icon: ok ? Icons.cloud_done_outlined : Icons.cloud_off,
                tint: ok ? t.success : t.danger,
                title: a.label,
                subtitle: a.enabled ? regText(rt) : 'regOff'.tr(),
                trailing: SettingsBadge(ok ? 'registered'.tr() : 'notRegistered'.tr(), color: ok ? t.success : t.danger),
                onTap: ok ? null : () => sip.retryNow(a.id),
              );
            }),
        ]),
        SettingsSection(title: 'permissions'.tr(), children: const [
          _PermissionTile(Permission.microphone, 'microphone', Icons.mic_none),
          _PermissionTile(Permission.notification, 'notifications', Icons.notifications_none),
        ]),
        SettingsSection(title: 'diagnostics'.tr(), children: [
          _switch(context, Icons.bug_report_outlined, t.warn, 'debugLogging'.tr(), 'restartApp'.tr(), s.debugLogging,
              (v) => s.debugLogging = v),
          SettingsTile(
            icon: Icons.article_outlined,
            tint: t.info,
            title: 'connectionLog'.tr(),
            subtitle: 'logLines'.tr(namedArgs: {'n': '${sip.connLog.length}'}),
            onTap: () => open(LogScreen(title: 'connectionLog'.tr(), read: (r) => r.read(sipProvider).connLog)),
          ),
          _switch(context, Icons.swap_vert, t.purple, 'sipTrace'.tr(), 'restartNote'.tr(), s.traceSip, (v) => s.traceSip = v),
          SettingsTile(
            icon: Icons.receipt_long_outlined,
            tint: t.purple,
            title: 'sipLog'.tr(),
            subtitle: 'logLines'.tr(namedArgs: {'n': '${sip.sipLog.length}'}),
            onTap: () => open(LogScreen(title: 'sipLog'.tr(), read: (r) => r.read(sipProvider).sipLog)),
          ),
        ]),
        SettingsSection(title: 'about'.tr(), children: [
          SettingsTile(
            icon: Icons.info_outline,
            tint: t.text2,
            title: 'sdk'.tr(),
            trailing: Text(sip.sdk?.version ?? '—', style: mono(context, size: 12)),
          ),
        ]),
      ]),
    );
  }
}

class _PermissionTile extends StatefulWidget {
  const _PermissionTile(this.permission, this.labelKey, this.icon);
  final Permission permission;
  final String labelKey;
  final IconData icon;

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
    return SettingsTile(
      icon: widget.icon,
      tint: _granted == true ? t.success : t.warn,
      title: widget.labelKey.tr(),
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

class _AutoAnswerDelaySheet extends ConsumerStatefulWidget {
  const _AutoAnswerDelaySheet();

  @override
  ConsumerState<_AutoAnswerDelaySheet> createState() => _AutoAnswerDelaySheetState();
}

class _AutoAnswerDelaySheetState extends ConsumerState<_AutoAnswerDelaySheet> {
  late double _value = ref.read(settingsProvider).autoAnswerDelay.toDouble();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('autoAnswerDelay'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('autoAnswerDelayValue'.tr(namedArgs: {'s': '${_value.round()}'})),
          Slider(
            value: _value,
            min: 0,
            max: 30,
            divisions: 30,
            label: '${_value.round()}s',
            onChanged: (v) => setState(() => _value = v),
            onChangeEnd: (v) => ref.read(settingsProvider).autoAnswerDelay = v.round(),
          ),
        ]),
      ),
    );
  }
}

/// Settings → Recording → Save recordings in.
class _RecordingFolderSheet extends ConsumerWidget {
  const _RecordingFolderSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(settingsProvider);

    Future<void> pickCustom() async {
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null) return;
      // The recorder writes the file natively, so the folder must be
      // writable as a plain path; test before switching to it.
      if (!await SipService.canWrite(dir)) {
        if (context.mounted) {
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('folderNotWritableTitle'.tr()),
              content: Text('folderNotWritable'.tr(namedArgs: {'dir': dir})),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text('close'.tr()))],
            ),
          );
        }
        return;
      }
      s.recordingCustomDir = dir;
      s.recordingDir = 'custom';
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: RadioGroup<String>(
          groupValue: s.recordingDir,
          onChanged: (v) {
            if (v == 'custom') {
              pickCustom();
            } else if (v != null) {
              s.recordingDir = v;
            }
          },
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('recordingsFolder'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            RadioListTile<String>(
              value: 'shared',
              activeColor: t.accent,
              title: Text('folderShared'.tr()),
              subtitle: Text(Platform.isIOS ? 'folderSharedIos'.tr() : 'folderSharedAndroid'.tr()),
            ),
            RadioListTile<String>(
              value: 'private',
              activeColor: t.accent,
              title: Text('folderPrivate'.tr()),
              subtitle: Text('folderPrivateSub'.tr()),
            ),
            if (Platform.isAndroid)
              RadioListTile<String>(
                value: 'custom',
                activeColor: t.accent,
                title: Text('folderCustom'.tr()),
                subtitle: Text(s.recordingCustomDir.isEmpty ? 'folderCustomSub'.tr() : s.recordingCustomDir),
                secondary: TextButton(onPressed: pickCustom, child: Text('chooseFile'.tr())),
              ),
            const SizedBox(height: 6),
            Text('folderNote'.tr(), style: TextStyle(fontSize: 12, color: t.text2)),
          ]),
        ),
      ),
    );
  }
}
