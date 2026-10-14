import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// A selectable ringtone. Bundled ones ship in `assets/sounds/ringtones/` and,
/// for CallKit, in the iOS app bundle as `medut_<id>.wav`.
class RingtoneOption {
  const RingtoneOption(this.id, this.labelKey, {this.asset});
  final String id;
  final String labelKey;
  final String? asset;
}

class Tones {
  Tones._();

  static const system = RingtoneOption('system', 'ringSystem');
  static const classic = RingtoneOption('classic', 'ringClassic', asset: 'assets/sounds/ringtones/classic.wav');
  static const soft = RingtoneOption('soft', 'ringSoft', asset: 'assets/sounds/ringtones/soft.wav');
  static const custom = RingtoneOption('custom', 'ringCustom');
  static const all = [system, classic, soft, custom];

  static RingtoneOption byId(String id) => all.firstWhere((r) => r.id == id, orElse: () => system);

  /// What the native ringer plays: a file path, or "system" for the phone's
  /// own ringtone. Bundled tones are copied out of the asset bundle once,
  /// because the native ringer cannot read Flutter assets directly.
  static Future<String> nativeSource(String id, String customPath) async {
    final r = byId(id);
    if (r.id == 'custom') {
      return customPath.isNotEmpty && await File(customPath).exists() ? customPath : 'system';
    }
    final asset = r.asset;
    if (asset == null) return 'system';
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/tones/${r.id}.wav');
    if (!await f.exists()) {
      await f.parent.create(recursive: true);
      final data = await rootBundle.load(asset);
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return f.path;
  }

  // ── Preview (settings) ────────────────────────────────────────────────────

  static AudioPlayer? _preview;

  static Future<void> preview(String id, String customPath) async {
    await stopPreview();
    final r = byId(id);
    final p = AudioPlayer();
    _preview = p;
    try {
      if (r.asset != null) {
        await p.setAsset(r.asset!);
      } else if (r.id == 'custom' && customPath.isNotEmpty) {
        await p.setFilePath(customPath);
      } else {
        return; // the phone's own ringtone is previewed by the OS picker
      }
      await p.play();
    } catch (e) {
      debugPrint('ringtone preview failed: $e');
    }
  }

  static Future<void> stopPreview() async {
    final p = _preview;
    _preview = null;
    try {
      await p?.stop();
      await p?.dispose();
    } catch (_) {}
  }
}
