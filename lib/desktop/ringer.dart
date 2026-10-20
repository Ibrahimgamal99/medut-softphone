import 'dart:async';
import 'dart:ffi' show nullptr;
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart' as win;

import '../sip/tones.dart';

/// The ringtone and the ringback tone on the desktop, with no audio plugin:
/// Linux plays WAV files through PulseAudio / PipeWire's own players
/// (`paplay`, which can pick the ring device by sink name, or `pw-play`);
/// Windows through winmm's PlaySound. One sound at a time, as on a phone:
/// starting one stops the other.
class DesktopRinger {
  DesktopRinger._();

  static Process? _proc;
  static bool _looping = false;
  static int _gen = 0;

  /// Rings [source] (a WAV path, or "system" for Medut's classic tone) on
  /// [device] (a sink name, '' for the default), until [stop].
  static Future<void> ring(String source, {String device = ''}) async {
    var path = source;
    if (path.isEmpty || path == 'system' || !File(path).existsSync()) {
      path = await Tones.nativeSource(Tones.classic.id, '');
    }
    await _loop(path, device: device, gap: const Duration(milliseconds: 300));
  }

  /// The far end's "brrng… brrng…" (425 Hz, 1 s on, 4 s off, as on Android).
  static Future<void> ringback({String device = ''}) async =>
      _loop(await _ringbackFile(), device: device, gap: Duration.zero);

  static Future<void> stop() async {
    _gen++;
    _looping = false;
    if (Platform.isWindows) {
      win.PlaySound(nullptr, 0, 0);
      return;
    }
    _proc?.kill();
    _proc = null;
  }

  static bool get playing => _looping;

  static Future<void> _loop(String path, {required String device, required Duration gap}) async {
    await stop();
    final gen = _gen;
    _looping = true;
    if (Platform.isWindows) {
      final p = path.toNativeUtf16();
      try {
        win.PlaySound(p, 0, win.SND_FILENAME | win.SND_ASYNC | win.SND_LOOP | win.SND_NODEFAULT);
      } finally {
        calloc.free(p);
      }
      return;
    }
    // Each pass runs the player once; stop() kills the one playing. A player
    // that fails at once (a ring device that is gone) is tried once more on
    // the default device, then given up.
    var dev = device;
    var failures = 0;
    while (_looping && gen == _gen) {
      final proc = await _start(path, dev);
      if (proc == null) {
        _looping = false;
        return;
      }
      _proc = proc;
      final began = DateTime.now();
      final code = await proc.exitCode;
      if (gen != _gen) return;
      if (code != 0 && DateTime.now().difference(began) < const Duration(milliseconds: 500)) {
        if (++failures >= 2) {
          debugPrint('ringer: $path does not play (exit $code)');
          _looping = false;
          return;
        }
        dev = '';
        continue;
      }
      failures = 0;
      if (gap > Duration.zero) await Future<void>.delayed(gap);
    }
  }

  static Future<Process?> _start(String path, String device) async {
    final tries = [
      ['paplay', if (device.isNotEmpty) '--device=$device', path],
      ['pw-play', if (device.isNotEmpty) '--target=$device', path],
      ['aplay', '-q', path],
    ];
    for (final t in tries) {
      try {
        return await Process.start(t.first, t.sublist(1));
      } on ProcessException {
        continue;
      }
    }
    debugPrint('no WAV player found (paplay, pw-play, aplay)');
    return null;
  }

  static String? _ringbackPath;

  static Future<String> _ringbackFile() async {
    final known = _ringbackPath;
    if (known != null) return known;
    final f = File('${(await getApplicationSupportDirectory()).path}/tones/ringback.wav');
    if (!await f.exists()) {
      await f.parent.create(recursive: true);
      await f.writeAsBytes(_tone(hz: 425, on: 1.0, total: 5.0), flush: true);
    }
    return _ringbackPath = f.path;
  }

  /// 16-bit mono PCM at 22.05 kHz: [on] seconds of a sine, then silence to [total].
  static Uint8List _tone({required double hz, required double on, required double total}) {
    const rate = 22050;
    final frames = (rate * total).round();
    final data = ByteData(44 + frames * 2);
    void tag(int at, String s) {
      for (var i = 0; i < 4; i++) {
        data.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    data.setUint32(4, 36 + frames * 2, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    data.setUint32(40, frames * 2, Endian.little);
    final onFrames = (rate * on).round();
    const fade = 220; // 10 ms in and out, so it does not click
    for (var i = 0; i < onFrames; i++) {
      final env = math.min(1.0, math.min(i, onFrames - i) / fade);
      final v = (9600 * env * math.sin(2 * math.pi * hz * i / rate)).round();
      data.setInt16(44 + i * 2, v, Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
