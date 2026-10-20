import 'dart:async';
import 'dart:ffi' show nullptr;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart' as win;

import 'platform.dart';

/// What the recording player needs from a player: just_audio's AudioPlayer
/// on the phone, [WavPlayer] on the desktop.
abstract class Playback {
  factory Playback() => isDesktop ? WavPlayer() : _JustAudio();

  Stream<PlayerState> get playerStateStream;
  Stream<Duration> get positionStream;
  Duration? get duration;
  Future<void> setFilePath(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Future<void> dispose();
}

class _JustAudio implements Playback {
  final _p = AudioPlayer();

  @override
  Stream<PlayerState> get playerStateStream => _p.playerStateStream;
  @override
  Stream<Duration> get positionStream => _p.positionStream;
  @override
  Duration? get duration => _p.duration;
  @override
  Future<void> setFilePath(String path) => _p.setFilePath(path);
  @override
  Future<void> play() => _p.play();
  @override
  Future<void> pause() => _p.pause();
  @override
  Future<void> seek(Duration to) => _p.seek(to);
  @override
  Future<void> dispose() => _p.dispose();
}

/// Plays a PCM WAV file on the desktop with the system's own player
/// (`paplay` / `pw-play` on Linux, winmm PlaySound on Windows). Seeking plays
/// a copy that starts at that point; the position is the clock since play.
class WavPlayer implements Playback {
  final _state = StreamController<PlayerState>.broadcast();
  String _path = '';
  int _dataStart = 44, _dataLen = 0, _byteRate = 0, _align = 2;
  Duration? _duration;

  Duration _from = Duration.zero; // where the playing copy starts
  DateTime? _since; // when it started; null while paused
  Process? _proc;
  Timer? _end;
  int _gen = 0;

  Duration get _position {
    final since = _since;
    final at = since == null ? _from : _from + DateTime.now().difference(since);
    final d = _duration ?? Duration.zero;
    return at > d ? d : at;
  }

  bool get _playing => _since != null;

  void _emit(ProcessingState s) {
    if (!_state.isClosed) _state.add(PlayerState(_playing, s));
  }

  @override
  Stream<PlayerState> get playerStateStream async* {
    yield PlayerState(_playing, _duration == null ? ProcessingState.idle : ProcessingState.ready);
    yield* _state.stream;
  }

  @override
  Stream<Duration> get positionStream =>
      Stream<Duration>.periodic(const Duration(milliseconds: 200), (_) => _position).takeWhile((_) => !_state.isClosed);

  @override
  Duration? get duration => _duration;

  @override
  Future<void> setFilePath(String path) async {
    final raf = await File(path).open();
    try {
      final h = await raf.read(44);
      String tag(int at) => String.fromCharCodes(h.sublist(at, at + 4));
      if (h.length < 44 || tag(0) != 'RIFF' || tag(8) != 'WAVE') throw const FormatException('not a WAV file');
      int u32(int at) => h[at] | h[at + 1] << 8 | h[at + 2] << 16 | h[at + 3] << 24;
      _byteRate = u32(28);
      _align = (h[32] | h[33] << 8).clamp(1, 64);
      _dataStart = 44;
      _dataLen = await raf.length() - 44;
    } finally {
      await raf.close();
    }
    if (_byteRate <= 0) throw const FormatException('WAV without a byte rate');
    _path = path;
    _duration = Duration(milliseconds: _dataLen * 1000 ~/ _byteRate);
    _emit(ProcessingState.ready);
  }

  @override
  Future<void> play() async {
    if (_path.isEmpty || _playing) return;
    if (_position >= (_duration ?? Duration.zero)) _from = Duration.zero;
    final gen = ++_gen;
    final file = _from == Duration.zero ? _path : await _slice(_from);
    if (gen != _gen) return;
    _since = DateTime.now();
    _emit(ProcessingState.ready);
    final left = (_duration ?? Duration.zero) - _from;
    _end = Timer(left, () {
      if (gen != _gen) return;
      _from = _duration ?? Duration.zero;
      _since = null;
      _emit(ProcessingState.completed);
    });
    if (Platform.isWindows) {
      final p = file.toNativeUtf16();
      try {
        win.PlaySound(p, 0, win.SND_FILENAME | win.SND_ASYNC | win.SND_NODEFAULT);
      } finally {
        calloc.free(p);
      }
      return;
    }
    for (final cmd in const ['paplay', 'pw-play', 'aplay']) {
      try {
        _proc = await Process.start(cmd, [file]);
        return;
      } on ProcessException {
        continue;
      }
    }
  }

  @override
  Future<void> pause() async {
    if (!_playing) return;
    _from = _position;
    _since = null;
    _stopSound();
    _emit(ProcessingState.ready);
  }

  @override
  Future<void> seek(Duration to) async {
    final was = _playing;
    _stopSound();
    _since = null;
    _from = to < Duration.zero ? Duration.zero : to;
    if (was) {
      await play();
    } else {
      _emit(ProcessingState.ready);
    }
  }

  @override
  Future<void> dispose() async {
    _stopSound();
    _since = null;
    await _state.close();
  }

  void _stopSound() {
    _gen++;
    _end?.cancel();
    if (Platform.isWindows) {
      win.PlaySound(nullptr, 0, 0);
    } else {
      _proc?.kill();
      _proc = null;
    }
  }

  /// A copy of the file from [at] on: the same header, the data after it.
  Future<String> _slice(Duration at) async {
    final skip = (at.inMilliseconds * _byteRate ~/ 1000) ~/ _align * _align;
    final src = await File(_path).open();
    try {
      final header = await src.read(_dataStart);
      await src.setPosition(_dataStart + skip);
      final data = await src.read(_dataLen - skip);
      final len = data.length;
      void le(int at, int v) {
        for (var i = 0; i < 4; i++) {
          header[at + i] = v >> (8 * i) & 0xff;
        }
      }

      le(4, 36 + len);
      le(40, len);
      final out = File('${(await getTemporaryDirectory()).path}/medut-play.wav');
      await out.writeAsBytes([...header, ...data], flush: true);
      return out.path;
    } finally {
      await src.close();
    }
  }
}
