import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
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

  // ── Ringback ──────────────────────────────────────────────────────────────

  static AudioPlayer? _ringback;
  static bool _ringingBack = false;

  /// The "brrng… brrng…" while the far end rings (180 Ringing), stopped the
  /// moment the call connects, fails or ends. Voice-call audio attributes, so
  /// it plays where the user is already listening, like a native dialer.
  static Future<void> startRingback() async {
    if (_ringingBack) return;
    _ringingBack = true;
    try {
      final session = await AudioSession.instance;
      // iOS must keep the call's own category: a playback-only category would
      // take the microphone away from the call that shares the session.
      await session.configure(Platform.isIOS
          ? const AudioSessionConfiguration(
              avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
              avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth,
              avAudioSessionMode: AVAudioSessionMode.voiceChat,
            )
          : const AudioSessionConfiguration(
              androidAudioAttributes: AndroidAudioAttributes(
                contentType: AndroidAudioContentType.sonification,
                usage: AndroidAudioUsage.voiceCommunicationSignalling,
              ),
              androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
            ));
      final p = AudioPlayer(handleAudioSessionActivation: false);
      _ringback = p;
      await p.setLoopMode(LoopMode.one);
      await p.setAsset('assets/sounds/ringback.wav');
      // The call may have connected while the source was loading.
      if (!_ringingBack || !identical(_ringback, p)) {
        await _dispose(p);
        return;
      }
      await p.play();
    } catch (e) {
      debugPrint('ringback failed: $e');
    }
  }

  static void stopRingback() {
    if (!_ringingBack) return;
    _ringingBack = false;
    final p = _ringback;
    _ringback = null;
    unawaited(_dispose(p));
  }

  // stop() before dispose(), errors swallowed: disposing while a load is in
  // flight (answer the instant it rings) otherwise throws out of teardown.
  static Future<void> _dispose(AudioPlayer? p) async {
    if (p == null) return;
    try {
      await p.stop();
    } catch (_) {}
    try {
      await p.dispose();
    } catch (_) {}
  }
}
