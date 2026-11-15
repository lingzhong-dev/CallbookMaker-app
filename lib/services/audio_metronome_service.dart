import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

class BeatSnapshot {
  const BeatSnapshot({
    required this.beatIndex,
    required this.bar,
    required this.beatInBar,
  });

  final int beatIndex;
  final int bar;
  final int beatInBar;
}

class BpmEstimateResult {
  const BpmEstimateResult({required this.bpm, required this.confidence});

  final int bpm;
  final double confidence;
}

/// Cross-platform Audio + High-Precision Metronome Clock for Flutter Desktop & Android.
/// Uses synthesized PCM WAV click buffers played via low-latency AudioPlayers,
/// plus a monotonic Stopwatch clock when running without external audio tracks.
class AudioMetronomeService {
  AudioMetronomeService({
    required this.onTimeUpdate,
    required this.onBeatTrigger,
    required this.onGtAlertBeep,
    this.onDurationChanged,
    this.onEnded,
    this.enablePlatformAudio = true,
  });

  final void Function(int timeMs) onTimeUpdate;
  final void Function(BeatSnapshot snapshot) onBeatTrigger;
  final void Function(String alertId) onGtAlertBeep;
  final void Function(int durationMs)? onDurationChanged;
  final void Function()? onEnded;
  final bool enablePlatformAudio;

  late final AudioPlayer? _musicPlayer =
      enablePlatformAudio ? AudioPlayer() : null;
  late final AudioPlayer? _accentClickPlayer =
      enablePlatformAudio ? AudioPlayer() : null;
  late final AudioPlayer? _subClickPlayer =
      enablePlatformAudio ? AudioPlayer() : null;
  late final AudioPlayer? _alertBeepPlayer =
      enablePlatformAudio ? AudioPlayer() : null;

  late final Uint8List _accentWav = _buildClickWav(freqHz: 1480, ms: 42, gain: 0.9);
  late final Uint8List _subWav = _buildClickWav(freqHz: 940, ms: 34, gain: 0.6);
  late final Uint8List _alertWav = _buildClickWav(freqHz: 1860, ms: 75, gain: 0.85);

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<void>? _completeSub;
  Timer? _clockTimer;

  bool _hasExternalAudio = false;
  bool _isPlaying = false;
  bool _metronomeEnabled = true;
  bool _gtBeepEnabled = true;
  double _metronomeVolume = 0.95;
  double _playbackRate = 1.0;
  int _bpm = 175;
  int _beatsPerBar = 4;
  int _offsetMs = 0;
  int _durationMs = 48000;
  int _currentTimeMs = 0;

  int _lastTriggeredBeatIndex = -999999;
  final Set<String> _beepedAlerts = <String>{};
  List<({String id, int triggerTimeMs, int leadBeats})> _alerts = const [];

  final List<int> _tapHistoryMs = <int>[];
  DateTime _syntheticAnchorWall = DateTime.now();
  int _syntheticAnchorTrackMs = 0;

  bool get isPlaying => _isPlaying;
  int get currentTimeMs => _currentTimeMs;
  int get durationMs => _durationMs;
  bool get hasExternalAudio => _hasExternalAudio;

  Future<void> init() async {
    final music = _musicPlayer;
    if (!enablePlatformAudio || music == null) return;
    await _accentClickPlayer?.setPlayerMode(PlayerMode.lowLatency);
    await _subClickPlayer?.setPlayerMode(PlayerMode.lowLatency);
    await _alertBeepPlayer?.setPlayerMode(PlayerMode.lowLatency);

    _posSub = music.onPositionChanged.listen((pos) {
      if (!_hasExternalAudio) return;
      _currentTimeMs = pos.inMilliseconds;
      onTimeUpdate(_currentTimeMs);
      _evaluateClocks(_currentTimeMs);
    });

    _durSub = music.onDurationChanged.listen((dur) {
      if (dur.inMilliseconds > 0) {
        _durationMs = dur.inMilliseconds;
        onDurationChanged?.call(_durationMs);
      }
    });

    _completeSub = music.onPlayerComplete.listen((_) {
      _isPlaying = false;
      _clockTimer?.cancel();
      onEnded?.call();
    });
  }

  void configure({
    required int bpm,
    required int beatsPerBar,
    required int offsetMs,
    required bool metronomeEnabled,
    required double metronomeVolume,
    required bool gtBeepEnabled,
    required double playbackRate,
  }) {
    _bpm = bpm.clamp(30, 300);
    _beatsPerBar = beatsPerBar <= 3 ? 3 : 4;
    _offsetMs = offsetMs;
    _metronomeEnabled = metronomeEnabled;
    _metronomeVolume = metronomeVolume.clamp(0.05, 1.5);
    _gtBeepEnabled = gtBeepEnabled;
    if ((_playbackRate - playbackRate).abs() > 0.001) {
      _playbackRate = playbackRate.clamp(0.5, 2.0);
      if (_isPlaying && !_hasExternalAudio) {
        _syntheticAnchorTrackMs = _currentTimeMs;
        _syntheticAnchorWall = DateTime.now();
      }
      if (_hasExternalAudio) {
        _musicPlayer?.setPlaybackRate(_playbackRate);
      }
    }
  }

  void setAlerts(List<({String id, int triggerTimeMs, int leadBeats})> alerts) {
    _alerts = alerts;
  }

  Future<void> setAudioSource({
    String? url,
    String? localPath,
    int? fallbackDurationMs,
  }) async {
    await pause();
    _beepedAlerts.clear();
    _lastTriggeredBeatIndex = -999999;
    _currentTimeMs = 0;

    if (localPath != null && localPath.isNotEmpty) {
      _hasExternalAudio = true;
      await _musicPlayer?.setSource(DeviceFileSource(localPath));
      if (fallbackDurationMs != null && fallbackDurationMs > 0) {
        _durationMs = fallbackDurationMs;
      }
    } else if (url != null && url.isNotEmpty) {
      _hasExternalAudio = true;
      await _musicPlayer?.setSource(UrlSource(url));
      if (fallbackDurationMs != null && fallbackDurationMs > 0) {
        _durationMs = fallbackDurationMs;
      }
    } else {
      _hasExternalAudio = false;
      _durationMs = (fallbackDurationMs != null && fallbackDurationMs > 1000)
          ? fallbackDurationMs
          : 48000;
    }

    onDurationChanged?.call(_durationMs);
    onTimeUpdate(0);
  }

  Future<void> play() async {
    if (_isPlaying) return;
    _isPlaying = true;

    if (_hasExternalAudio && _musicPlayer != null) {
      await _musicPlayer.setPlaybackRate(_playbackRate);
      await _musicPlayer.resume();
    } else {
      _syntheticAnchorTrackMs = _currentTimeMs;
      _syntheticAnchorWall = DateTime.now();
    }

    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_isPlaying) return;
      if (!_hasExternalAudio) {
        final elapsedMs =
            DateTime.now().difference(_syntheticAnchorWall).inMicroseconds /
            1000.0;
        var next = _syntheticAnchorTrackMs + (elapsedMs * _playbackRate).round();
        if (next >= _durationMs) {
          next = 0;
          _syntheticAnchorTrackMs = 0;
          _syntheticAnchorWall = DateTime.now();
          _beepedAlerts.clear();
          _lastTriggeredBeatIndex = -999999;
        }
        _currentTimeMs = next;
        onTimeUpdate(_currentTimeMs);
      }
      _evaluateClocks(_currentTimeMs);
    });
  }

  Future<void> pause() async {
    if (!_isPlaying) return;
    _isPlaying = false;
    _clockTimer?.cancel();
    if (_hasExternalAudio) {
      await _musicPlayer?.pause();
    }
  }

  Future<void> seek(int ms) async {
    final target = ms.clamp(0, math.max<int>(1000, _durationMs)).toInt();
    _currentTimeMs = target;
    _lastTriggeredBeatIndex = -999999;
    _beepedAlerts.clear();
    if (_hasExternalAudio && _musicPlayer != null) {
      await _musicPlayer.seek(Duration(milliseconds: target));
    } else {
      _syntheticAnchorTrackMs = target;
      _syntheticAnchorWall = DateTime.now();
    }
    onTimeUpdate(target);
    _evaluateClocks(target, playAudio: false);
  }

  Future<void> testMetronomeClick({bool accent = true}) async {
    await _playClick(accent: accent);
  }

  /// Tap Tempo estimator with double/half-time octave normalization into 70..195 BPM.
  int? tapTempo() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_tapHistoryMs.isNotEmpty && nowMs - _tapHistoryMs.last > 2400) {
      _tapHistoryMs.clear();
    }
    _tapHistoryMs.add(nowMs);
    if (_tapHistoryMs.length > 8) {
      _tapHistoryMs.removeAt(0);
    }
    if (_tapHistoryMs.length < 2) return null;

    final intervals = <int>[];
    for (var i = 1; i < _tapHistoryMs.length; i++) {
      final delta = _tapHistoryMs[i] - _tapHistoryMs[i - 1];
      if (delta >= 180 && delta <= 2000) {
        intervals.add(delta);
      }
    }
    if (intervals.isEmpty) return null;

    intervals.sort();
    final medianMs = intervals[intervals.length ~/ 2];
    var bpm = (60000 / medianMs).round();
    while (bpm > 195) {
      bpm = (bpm / 2).round();
    }
    while (bpm < 70) {
      bpm = bpm * 2;
    }
    return bpm.clamp(40, 260);
  }

  void _evaluateClocks(int trackMs, {bool playAudio = true}) {
    final beatDurationMs = 60000.0 / math.max(30, _bpm);
    final relativeMs = trackMs - _offsetMs;
    if (relativeMs >= 0) {
      final beatIndex = (relativeMs / beatDurationMs).floor();
      final bar = (beatIndex ~/ _beatsPerBar) + 1;
      final beatInBar = (beatIndex % _beatsPerBar) + 1;
      if (beatIndex != _lastTriggeredBeatIndex) {
        _lastTriggeredBeatIndex = beatIndex;
        onBeatTrigger(
          BeatSnapshot(beatIndex: beatIndex, bar: bar, beatInBar: beatInBar),
        );
        if (playAudio && _metronomeEnabled) {
          _playClick(accent: beatInBar == 1);
        }
      }
    }

    if (playAudio && _gtBeepEnabled) {
      for (final alert in _alerts) {
        if (_beepedAlerts.contains(alert.id)) continue;
        final leadMs = (alert.leadBeats * beatDurationMs).round();
        final warnStart = alert.triggerTimeMs - leadMs;
        if (trackMs >= warnStart && trackMs <= alert.triggerTimeMs + 250) {
          _beepedAlerts.add(alert.id);
          _alertBeepPlayer?.setVolume(
            (_metronomeVolume / 1.5).clamp(0.15, 1.0),
          );
          _alertBeepPlayer?.play(BytesSource(_alertWav));
          onGtAlertBeep(alert.id);
        }
      }
    }
  }

  Future<void> _playClick({required bool accent}) async {
    final vol = (_metronomeVolume / 1.5).clamp(0.1, 1.0);
    if (accent) {
      await _accentClickPlayer?.setVolume(vol);
      await _accentClickPlayer?.play(BytesSource(_accentWav));
    } else {
      await _subClickPlayer?.setVolume(vol * 0.78);
      await _subClickPlayer?.play(BytesSource(_subWav));
    }
  }

  static Uint8List _buildClickWav({
    required double freqHz,
    required int ms,
    required double gain,
  }) {
    const sampleRate = 22050;
    final sampleCount = (sampleRate * ms / 1000).round();
    final dataBytes = sampleCount * 2;
    final buffer = ByteData(44 + dataBytes);

    // RIFF header
    void writeAscii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        buffer.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    buffer.setUint32(4, 36 + dataBytes, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little); // PCM
    buffer.setUint16(20, 1, Endian.little); // Linear PCM
    buffer.setUint16(22, 1, Endian.little); // Mono
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little);
    buffer.setUint16(32, 2, Endian.little);
    buffer.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    buffer.setUint32(40, dataBytes, Endian.little);

    for (var i = 0; i < sampleCount; i++) {
      final t = i / sampleRate;
      final env = math.exp(-t * 90.0);
      final sample =
          (math.sin(2 * math.pi * freqHz * t) * gain * env * 32767)
              .round()
              .clamp(-32768, 32767);
      buffer.setInt16(44 + i * 2, sample, Endian.little);
    }
    return buffer.buffer.asUint8List();
  }

  Future<void> dispose() async {
    _clockTimer?.cancel();
    await _posSub?.cancel();
    await _durSub?.cancel();
    await _completeSub?.cancel();
    await _musicPlayer?.dispose();
    await _accentClickPlayer?.dispose();
    await _subClickPlayer?.dispose();
    await _alertBeepPlayer?.dispose();
  }
}
