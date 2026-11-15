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

class _CuePlayerState {
  _CuePlayerState(this.player, this.wavBytes);

  final AudioPlayer? player;
  final Uint8List wavBytes;
  bool prepared = false;
  bool inFlight = false;
  double? lastVolume;
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

  late final _CuePlayerState _accentCue =
      _CuePlayerState(_accentClickPlayer, _accentWav);
  late final _CuePlayerState _subCue =
      _CuePlayerState(_subClickPlayer, _subWav);
  late final _CuePlayerState _alertCue =
      _CuePlayerState(_alertBeepPlayer, _alertWav);

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<void>? _completeSub;
  Timer? _clockTimer;

  bool _disposed = false;
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

  bool _seekInFlight = false;
  int? _pendingSeekMs;
  Completer<void>? _seekCompleter;

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
    // Configure click/alert players without awaiting setSource() so headless
    // test mocks that do not emit audio.onPrepared never hang during init().
    for (final cuePlayer in [
      _accentClickPlayer,
      _subClickPlayer,
      _alertBeepPlayer,
    ]) {
      if (cuePlayer == null) continue;
      cuePlayer.positionUpdater = null;
      try {
        await cuePlayer.setPlayerMode(PlayerMode.lowLatency);
        await cuePlayer.setReleaseMode(ReleaseMode.stop);
      } catch (_) {
        // Ignore platform configuration errors during headless initialization.
      }
    }

    _posSub = music.onPositionChanged.listen((pos) {
      if (_disposed || !_hasExternalAudio) return;
      if (_seekInFlight || _pendingSeekMs != null) return;
      final nextMs = pos.inMilliseconds;
      if (nextMs == _currentTimeMs) return;
      _currentTimeMs = nextMs;
      onTimeUpdate(_currentTimeMs);
      if (_isPlaying) {
        _evaluateClocks(_currentTimeMs);
      }
    });

    _durSub = music.onDurationChanged.listen((dur) {
      if (_disposed) return;
      if (dur.inMilliseconds > 0) {
        _durationMs = dur.inMilliseconds;
        onDurationChanged?.call(_durationMs);
      }
    });

    _completeSub = music.onPlayerComplete.listen((_) {
      if (_disposed) return;
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
        final future = _musicPlayer?.setPlaybackRate(_playbackRate);
        if (future != null) {
          unawaited(future.catchError((Object _) {}));
        }
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

    final resolvedFallback =
        (fallbackDurationMs != null && fallbackDurationMs > 1000)
            ? fallbackDurationMs
            : 48000;

    try {
      if (localPath != null && localPath.isNotEmpty) {
        _hasExternalAudio = true;
        await _musicPlayer?.setSource(DeviceFileSource(localPath));
        _durationMs = (fallbackDurationMs != null && fallbackDurationMs > 0)
            ? fallbackDurationMs
            : _durationMs;
      } else if (url != null && url.isNotEmpty) {
        _hasExternalAudio = true;
        await _musicPlayer?.setSource(UrlSource(url));
        _durationMs = (fallbackDurationMs != null && fallbackDurationMs > 0)
            ? fallbackDurationMs
            : _durationMs;
      } else {
        _hasExternalAudio = false;
        _durationMs = resolvedFallback;
      }
    } catch (_) {
      _hasExternalAudio = false;
      _durationMs = resolvedFallback;
      onDurationChanged?.call(_durationMs);
      onTimeUpdate(0);
      rethrow;
    }

    onDurationChanged?.call(_durationMs);
    onTimeUpdate(0);
  }

  Future<bool> play() async {
    if (_disposed) return false;
    if (_isPlaying) return true;
    _isPlaying = true;

    if (_hasExternalAudio && _musicPlayer != null) {
      try {
        await _musicPlayer.setPlaybackRate(_playbackRate);
        await _musicPlayer.resume();
      } catch (_) {
        _isPlaying = false;
        _clockTimer?.cancel();
        return false;
      }
      // External audio drives position updates via AudioPlayer's FramePositionUpdater
      // onPositionChanged listener; no redundant 16ms periodic timer is needed.
      _clockTimer?.cancel();
      return true;
    }

    _syntheticAnchorTrackMs = _currentTimeMs;
    _syntheticAnchorWall = DateTime.now();
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_isPlaying || _disposed) return;
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
      if (next != _currentTimeMs) {
        _currentTimeMs = next;
        onTimeUpdate(_currentTimeMs);
        _evaluateClocks(_currentTimeMs);
      }
    });
    return true;
  }

  Future<void> pause() async {
    if (!_isPlaying) return;
    _isPlaying = false;
    _clockTimer?.cancel();
    if (_hasExternalAudio) {
      try {
        await _musicPlayer?.pause();
      } catch (_) {
        // Ignore pause errors if platform player was not ready.
      }
    }
  }

  Future<void> seek(int ms) {
    if (_disposed) return Future.value();
    final target = ms.clamp(0, math.max<int>(1000, _durationMs)).toInt();
    _currentTimeMs = target;
    _lastTriggeredBeatIndex = -999999;
    _beepedAlerts.clear();

    if (!_hasExternalAudio || _musicPlayer == null) {
      _syntheticAnchorTrackMs = target;
      _syntheticAnchorWall = DateTime.now();
      onTimeUpdate(target);
      _evaluateClocks(target, playAudio: false);
      return Future.value();
    }

    onTimeUpdate(target);
    _evaluateClocks(target, playAudio: false);

    _pendingSeekMs = target;
    _seekCompleter ??= Completer<void>();
    final future = _seekCompleter!.future;
    if (!_seekInFlight) {
      unawaited(_drainPendingSeeks());
    }
    return future;
  }

  Future<void> _drainPendingSeeks() async {
    final music = _musicPlayer;
    if (music == null) {
      _pendingSeekMs = null;
      _seekCompleter?.complete();
      _seekCompleter = null;
      return;
    }
    _seekInFlight = true;
    try {
      while (!_disposed && _pendingSeekMs != null) {
        final nextTarget = _pendingSeekMs!;
        _pendingSeekMs = null;
        try {
          await music.seek(Duration(milliseconds: nextTarget));
        } catch (_) {
          // Ignore seek errors when source is not yet prepared or player disposed.
        }
      }
    } finally {
      _seekInFlight = false;
      final completer = _seekCompleter;
      _seekCompleter = null;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
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
          unawaited(_playClick(accent: beatInBar == 1));
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
          final vol = (_metronomeVolume / 1.5).clamp(0.15, 1.0);
          unawaited(_triggerCue(_alertCue, vol));
          onGtAlertBeep(alert.id);
        }
      }
    }
  }

  Future<void> _playClick({required bool accent}) async {
    final vol = (_metronomeVolume / 1.5).clamp(0.1, 1.0);
    if (accent) {
      await _triggerCue(_accentCue, vol);
    } else {
      await _triggerCue(_subCue, vol * 0.78);
    }
  }

  Future<void> _triggerCue(_CuePlayerState cue, double volume) async {
    final player = cue.player;
    if (_disposed || player == null || cue.inFlight) return;
    cue.inFlight = true;
    try {
      if (cue.lastVolume == null || (cue.lastVolume! - volume).abs() > 0.005) {
        await player.setVolume(volume);
        cue.lastVolume = volume;
      }
      if (!cue.prepared) {
        await player.setSource(BytesSource(cue.wavBytes));
        cue.prepared = true;
      } else if (player.state == PlayerState.playing) {
        await player.seek(Duration.zero);
      }
      await player.resume();
    } catch (_) {
      cue.prepared = false;
    } finally {
      cue.inFlight = false;
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
    _disposed = true;
    _clockTimer?.cancel();
    _pendingSeekMs = null;
    if (_seekCompleter != null && !_seekCompleter!.isCompleted) {
      _seekCompleter!.complete();
      _seekCompleter = null;
    }
    _musicPlayer?.positionUpdater = null;
    _accentClickPlayer?.positionUpdater = null;
    _subClickPlayer?.positionUpdater = null;
    _alertBeepPlayer?.positionUpdater = null;
    await _posSub?.cancel();
    await _durSub?.cancel();
    await _completeSub?.cancel();
    await _musicPlayer?.dispose();
    await _accentClickPlayer?.dispose();
    await _subClickPlayer?.dispose();
    await _alertBeepPlayer?.dispose();
  }
}
