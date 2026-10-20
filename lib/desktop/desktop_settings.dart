import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medut/medut.dart' show AudioDevice;

import '../core/providers.dart';
import '../core/theme.dart';
import '../ui/widgets.dart';
import 'call_links.dart';
import 'desktop_shell.dart';
import 'engine.dart';

/// Settings › This computer: audio devices, start at login, the tray, and
/// Medut as the app for call links.
class DesktopSettingsSection extends ConsumerStatefulWidget {
  const DesktopSettingsSection({super.key});

  @override
  ConsumerState<DesktopSettingsSection> createState() => _DesktopSettingsSectionState();
}

class _DesktopSettingsSectionState extends ConsumerState<DesktopSettingsSection> with WidgetsBindingObserver {
  bool? _atLogin;
  bool? _links;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from Windows' Default apps, or another app took the links.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check() async {
    final atLogin = await DesktopShell.instance.startsAtLogin;
    final links = await CallLinks.isDefault();
    if (mounted) {
      setState(() {
        _atLogin = atLogin;
        _links = links;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final s = ref.watch(settingsProvider);
    return SettingsSection(title: 'thisComputer'.tr(), children: [
      SettingsTile(
        icon: Icons.headset_mic_outlined,
        tint: t.accent,
        title: 'audioDevices'.tr(),
        subtitle: 'audioDevicesSub'.tr(),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AudioDevicesScreen())),
      ),
      SettingsTile(
        icon: Icons.link,
        tint: t.info,
        title: 'callLinks'.tr(),
        subtitle: _links == true ? 'callLinksOn'.tr() : 'callLinksSub'.tr(),
        trailing: _links == true
            ? SettingsBadge('on'.tr(), color: t.success)
            : TextButton(onPressed: _useForLinks, child: Text('callLinksUse'.tr())),
        onTap: _links == true ? null : _useForLinks,
      ),
      SettingsTile(
        icon: Icons.power_settings_new,
        tint: t.success,
        title: 'startAtLogin'.tr(),
        subtitle: 'startAtLoginSub'.tr(),
        trailing: Switch(value: _atLogin ?? false, onChanged: _atLogin == null ? null : _setAtLogin),
        onTap: _atLogin == null ? null : () => _setAtLogin(!_atLogin!),
      ),
      SettingsTile(
        icon: Icons.move_to_inbox_outlined,
        tint: t.purple,
        title: 'closeToTray'.tr(),
        subtitle: 'closeToTraySub'.tr(),
        trailing: Switch(value: s.closeToTray, onChanged: (v) => s.closeToTray = v),
        onTap: () => s.closeToTray = !s.closeToTray,
      ),
    ]);
  }

  Future<void> _setAtLogin(bool on) async {
    await DesktopShell.instance.setStartAtLogin(on);
    await _check();
  }

  Future<void> _useForLinks() async {
    final ok = await CallLinks.makeDefault();
    if (!mounted) return;
    setState(() => _links = ok);
    // Windows asks the user to confirm in Settings › Default apps, which is open now.
    if (!ok && Platform.isWindows) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('callLinksWindows'.tr())));
    }
  }
}

/// The microphone and speaker calls use, and where the ringtone plays.
class AudioDevicesScreen extends ConsumerStatefulWidget {
  const AudioDevicesScreen({super.key});

  @override
  ConsumerState<AudioDevicesScreen> createState() => _AudioDevicesScreenState();
}

class _AudioDevicesScreenState extends ConsumerState<AudioDevicesScreen> {
  List<AudioDevice>? _mics, _speakers;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final mics = await DesktopEngine.instance.inputDevices();
    final speakers = await DesktopEngine.instance.outputDevices();
    if (mounted) {
      setState(() {
        _mics = mics;
        _speakers = speakers;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final loading = _mics == null;
    return Scaffold(
      appBar: AppBar(
        title: Text('audioDevices'.tr()),
        actions: [IconButton(tooltip: 'refresh'.tr(), icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.only(bottom: 32), children: [
              _group(context, 'microphone'.tr(), Icons.mic_none, _mics!, s.micDevice, (v) => s.micDevice = v),
              _group(context, 'speakerDevice'.tr(), Icons.volume_up_outlined, _speakers!, s.speakerDevice, (v) => s.speakerDevice = v),
              // Windows plays the ringtone on the default device only (PlaySound).
              if (Platform.isLinux)
                _group(context, 'ringDevice'.tr(), Icons.notifications_active_outlined, _speakers!, s.ringDevice,
                    (v) => s.ringDevice = v,
                    note: 'ringDeviceSub'.tr()),
            ]),
    );
  }

  Widget _group(BuildContext context, String title, IconData icon, List<AudioDevice> list, String value,
      ValueChanged<String> pick,
      {String? note}) {
    final t = context.t;
    final options = [('', 'systemDefault'.tr()), for (final d in list) (d.name, d.description.isEmpty ? d.name : d.description)];
    return SettingsSection(title: title, children: [
      RadioGroup<String>(
        groupValue: options.any((o) => o.$1 == value) ? value : '',
        onChanged: (v) => pick(v ?? ''),
        child: Column(children: [
          for (final (name, label) in options)
            RadioListTile<String>(
              value: name,
              activeColor: t.accent,
              secondary: Icon(icon, color: t.text2),
              title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(note, style: TextStyle(fontSize: 12, color: t.text2)),
            ),
        ]),
      ),
    ]);
  }
}
