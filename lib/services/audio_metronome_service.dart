import 'dart:async';
import 'dart:io' show Directory, File;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:path_provider/path_provider.dart';

import '../models/callbook_models.dart';
import '../platform/app_platform.dart';

/// Monotonic microsecond clock abstraction for deterministic scheduling tests.
abstract interface class MonotonicClock {
  int get elapsedMicroseconds;
  void start();
  void stop();
  void reset();
}

class _SystemStopwatchClock implements MonotonicClock {
  final Stopwatch _watch = Stopwatch();

  @override
  int get elapsedMicroseconds => _watch.elapsedMicroseconds;

  @override
  void start() => _watch.start();

  @override
  void stop() => _watch.stop();

  @override
  void reset() => _watch.reset();
}

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
  const BpmEstimateResult({
    required this.bpm,
    required this.confidence,
    this.sampleCount = 0,
    this.validIntervalCount = 0,
  });

  final int bpm;
  final double confidence;
  final int sampleCount;
  final int validIntervalCount;
}

/// Identifies each synthesized metronome or GT alert cue channel.
enum CueKind {
  accent,
  sub,
  alert,
}

/// Readiness lifecycle state for an individual cue audio player.
enum CueStatus {
  uninitialized,
  ready,
  failed,
}

/// Immutable diagnostic snapshot for a cue player.
class CueDiagnosticEntry {
  const CueDiagnosticEntry({
    required this.kind,
    required this.status,
    this.cachedFilePath,
    this.lastError,
    this.failureCount = 0,
    this.playCount = 0,
  });

  final CueKind kind;
  final CueStatus status;
  final String? cachedFilePath;
  final String? lastError;
  final int failureCount;
  final int playCount;
}

typedef CueTempDirProvider = Future<Directory> Function();

class _CuePlayerState {
  _CuePlayerState(this.kind, this.player, this.wavBytes)
      : fileName = AudioMetronomeService._cueFileName(kind, wavBytes);

  final CueKind kind;
  final AudioPlayer? player;
  final Uint8List wavBytes;
  final String fileName;
  CueStatus status = CueStatus.uninitialized;
  bool prepared = false;
  bool inFlight = false;
  Future<bool>? preloadFuture;
  double? lastVolume;
  String? cachedFilePath;
  String? lastError;
  int failureCount = 0;
  int playCount = 0;

  CueDiagnosticEntry toDiagnostic() => CueDiagnosticEntry(
        kind: kind,
        status: status,
        cachedFilePath: cachedFilePath,
        lastError: lastError,
        failureCount: failureCount,
        playCount: playCount,
      );
}

class _SafeFramePositionUpdater implements PositionUpdater {
  _SafeFramePositionUpdater({required this.getPosition});

  @override
  final Future<Duration?> Function() getPosition;

  final StreamController<Duration> _controller =
      StreamController<Duration>.broadcast();
  int? _frameCallbackId;
  bool _isRunning = false;
  bool _closed = false;

  @override
  Stream<Duration> get positionStream => _controller.stream;

  @override
  Future<void> update() async {
    if (_closed) return;
    try {
      final position = await getPosition();
      if (!_closed && position != null && !_controller.isClosed) {
        _controller.add(position);
      }
    } catch (_) {
      // Ignore transient position queries during teardown or source switching.
    }
  }

  void _tick(Duration? timestamp) {
    if (_isRunning && !_closed) {
      unawaited(update());
      _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(_tick);
    }
  }

  @override
  void start() {
    if (_closed) return;
    _isRunning = true;
    _tick(null);
  }

  @override
  void stop() {
    _isRunning = false;
    final id = _frameCallbackId;
    if (id != null) {
      _frameCallbackId = null;
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
    }
  }

  @override
  Future<void> stopAndUpdate() async {
    stop();
    await update();
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    stop();
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}

/// Cross-platform Audio + High-Precision Metronome Clock for Flutter Desktop & Android.
/// Uses synthesized PCM WAV click files materialized to app temp cache and played via
/// platform-appropriate AudioPlayers (low-latency SoundPool on Android, mediaPlayer on
/// Windows/other platforms), plus a monotonic clock when running without external tracks.
class AudioMetronomeService {
  AudioMetronomeService({
    required this.onTimeUpdate,
    required this.onBeatTrigger,
    required this.onGtAlertBeep,
    this.onDurationChanged,
    this.onEnded,
    this.enablePlatformAudio = true,
    this.tempDirProvider,
    bool? useLowLatencyCuesOverride,
    this.onDiagnosticLog,
    MonotonicClock? clock,
    this.driftThresholdMs = defaultDriftThresholdMs,
  }) : _useSoundPoolCues = useLowLatencyCuesOverride ?? AppPlatform.isAndroid,
       _clock = clock ?? _SystemStopwatchClock() {
    _clock.start();
  }

  static const int defaultDriftThresholdMs = 25;
  static const int maxBufferExtrapolationMs = 350;
  static int _nextInstanceId = 0;
  static final Set<String> _verifiedCueFiles = <String>{};

  final int _instanceId = ++_nextInstanceId;
  int _musicPlayerSeq = 0;

  final void Function(int timeMs) onTimeUpdate;
  final void Function(BeatSnapshot snapshot) onBeatTrigger;
  final void Function(String alertId) onGtAlertBeep;
  final void Function(int durationMs)? onDurationChanged;
  final void Function()? onEnded;
  final bool enablePlatformAudio;
  final CueTempDirProvider? tempDirProvider;
  final bool _useSoundPoolCues;
  final void Function(String message)? onDiagnosticLog;
  final MonotonicClock _clock;
  final int driftThresholdMs;

  AudioPlayer? _musicPlayer;
  AudioPlayer? _configuredMusicPlayer;
  Future<void>? _musicConfigFuture;

  late final AudioPlayer? _accentClickPlayer = enablePlatformAudio
      ? AudioPlayer(playerId: 'callbook_cue_accent_$_instanceId')
      : null;
  late final AudioPlayer? _subClickPlayer = enablePlatformAudio
      ? AudioPlayer(playerId: 'callbook_cue_sub_$_instanceId')
      : null;
  late final AudioPlayer? _alertBeepPlayer = enablePlatformAudio
      ? AudioPlayer(playerId: 'callbook_cue_alert_$_instanceId')
      : null;

  late final Uint8List _accentWav = _buildClickWav(freqHz: 1480, ms: 42, gain: 0.9);
  late final Uint8List _subWav = _buildClickWav(freqHz: 940, ms: 34, gain: 0.6);
  late final Uint8List _alertWav = _buildClickWav(freqHz: 1860, ms: 75, gain: 0.85);

  late final _CuePlayerState _accentCue = _CuePlayerState(
    CueKind.accent,
    _accentClickPlayer,
    _accentWav,
  );
  late final _CuePlayerState _subCue = _CuePlayerState(
    CueKind.sub,
    _subClickPlayer,
    _subWav,
  );
  late final _CuePlayerState _alertCue = _CuePlayerState(
    CueKind.alert,
    _alertBeepPlayer,
    _alertWav,
  );

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<void>? _completeSub;
  Timer? _clockTimer;
  Timer? _positionWatchdogTimer;
  int _lastPositionEventClockUs = 0;

  bool _disposed = false;
  bool _hasExternalAudio = false;
  bool _hasPreparedMusicSource = false;
  bool _hasMeasuredExternalDuration = false;
  bool _hasCompleted = false;
  Source? _currentMusicSource;
  String? _currentMusicSourceKey;
  bool _isPlaying = false;
  bool _metronomeEnabled = true;
  bool _gtBeepEnabled = true;
  double _metronomeVolume = 0.95;
  double _playbackRate = 1.0;
  int _bpm = 175;
  int _beatsPerBar = 4;
  int _offsetMs = 0;
  int _cueOutputCompensationMs = 0;
  int _durationMs = 48000;
  int _currentTimeMs = 0;

  int _sourceLoadToken = 0;
  int _playSeq = 0;
  Future<void> _sourceOpChain = Future<void>.value();

  bool _seekInFlight = false;
  int? _pendingSeekMs;
  Completer<void>? _seekCompleter;

  int _lastDisplayedBeatIndex = -999999;
  int _lastTriggeredAudioBeatIndex = -999999;
  final Set<String> _beepedAlerts = <String>{};
  List<({String id, int triggerTimeMs, int leadBeats})> _alerts = const [];

  final List<int> _tapHistoryMs = <int>[];
  int _anchorClockUs = 0;
  int _anchorMediaMs = 0;
  int _lastConfirmedPlayerPosMs = 0;
  int _lastConfirmedPlayerClockUs = 0;
  bool _bufferStalled = false;

  final List<String> _diagnosticLogs = <String>[];
  String? _lastCueError;

  bool get isPlaying => _isPlaying;
  int get currentTimeMs => _currentTimeMs;
  int get durationMs => _durationMs;
  bool get hasExternalAudio => _hasExternalAudio;
  bool get hasMeasuredExternalDuration => _hasMeasuredExternalDuration;
  bool get hasCompleted => _hasCompleted;
  int get tapSampleCount => _tapHistoryMs.length;
  int get cueOutputCompensationMs => _cueOutputCompensationMs;
  bool get areCuesReady =>
      enablePlatformAudio &&
      _accentCue.prepared &&
      _subCue.prepared &&
      _alertCue.prepared;
  String? get lastCueError => _lastCueError;
  List<String> get diagnosticLogs => List<String>.unmodifiable(_diagnosticLogs);

  Map<CueKind, CueDiagnosticEntry> get cueDiagnostics =>
      Map<CueKind, CueDiagnosticEntry>.unmodifiable({
        CueKind.accent: _accentCue.toDiagnostic(),
        CueKind.sub: _subCue.toDiagnostic(),
        CueKind.alert: _alertCue.toDiagnostic(),
      });

  CueDiagnosticEntry cueDiagnostic(CueKind kind) {
    return switch (kind) {
      CueKind.accent => _accentCue.toDiagnostic(),
      CueKind.sub => _subCue.toDiagnostic(),
      CueKind.alert => _alertCue.toDiagnostic(),
    };
  }

  void _recordDiagnostic(String message, {bool isCueFailure = false}) {
    if (isCueFailure) {
      _lastCueError = message;
    }
    _diagnosticLogs.add(message);
    if (_diagnosticLogs.length > 50) {
      _diagnosticLogs.removeAt(0);
    }
    onDiagnosticLog?.call(message);
    debugPrint('[AudioMetronomeService] $message');
  }

  AudioPlayer _createAndAttachMusicPlayer() {
    final player = AudioPlayer(
      playerId: 'callbook_music_${_instanceId}_${++_musicPlayerSeq}',
    );
    player.positionUpdater = _SafeFramePositionUpdater(
      getPosition: player.getCurrentPosition,
    );
    _musicPlayer = player;
    _configuredMusicPlayer = null;
    _musicConfigFuture = null;
    _attachMusicListeners(player);
    return player;
  }

  Future<void> _ensureMusicPlayerConfigured(AudioPlayer player) {
    if (_configuredMusicPlayer == player && _musicConfigFuture != null) {
      return _musicConfigFuture!;
    }
    _configuredMusicPlayer = player;
    final future = () async {
      await player.setPlayerMode(PlayerMode.mediaPlayer);
      await player.setReleaseMode(ReleaseMode.stop);
    }();
    _musicConfigFuture = future.catchError((Object err, StackTrace st) {
      if (_configuredMusicPlayer == player) {
        _configuredMusicPlayer = null;
        _musicConfigFuture = null;
      }
      _recordDiagnostic('Music player configuration failed: $err');
      Error.throwWithStackTrace(err, st);
    });
    return _musicConfigFuture!;
  }

  int _nowUs() => _clock.elapsedMicroseconds;

  int _computeInterpolatedTimeMs(int nowUs) {
    final elapsedUs = math.max(0, nowUs - _anchorClockUs);
    final deltaMs = (elapsedUs * _playbackRate / 1000.0).round();
    return (_anchorMediaMs + deltaMs).clamp(0, _durationMs).toInt();
  }

  void _rebuildAnchor(int trackMs, {int? nowUs}) {
    final ts = nowUs ?? _nowUs();
    _anchorMediaMs = trackMs.clamp(0, _durationMs).toInt();
    _anchorClockUs = ts;
  }

  void _handlePlatformPosition(int reportedMs) {
    if (_disposed || !_hasExternalAudio) return;
    if (_seekInFlight || _pendingSeekMs != null) return;
    if (_hasCompleted && !_isPlaying) return;

    final nowUs = _nowUs();
    _lastPositionEventClockUs = nowUs;
    final posMs = reportedMs.clamp(0, _durationMs).toInt();

    if (!_isPlaying) {
      _lastConfirmedPlayerPosMs = posMs;
      _lastConfirmedPlayerClockUs = nowUs;
      if (posMs != _currentTimeMs) {
        _currentTimeMs = posMs;
        _rebuildAnchor(posMs, nowUs: nowUs);
        onTimeUpdate(_currentTimeMs);
      }
      return;
    }

    // Ignore out-of-order backward callbacks during active playback.
    if (posMs < _lastConfirmedPlayerPosMs) {
      return;
    }

    if (posMs == _lastConfirmedPlayerPosMs) {
      if ((nowUs - _lastConfirmedPlayerClockUs) >=
          maxBufferExtrapolationMs * 1000) {
        _bufferStalled = true;
        _rebuildAnchor(_currentTimeMs, nowUs: nowUs);
      }
      return;
    }

    _lastConfirmedPlayerPosMs = posMs;
    _lastConfirmedPlayerClockUs = nowUs;
    _bufferStalled = false;

    final predictedMs = _computeInterpolatedTimeMs(nowUs);
    final driftMs = (posMs - predictedMs).abs();
    if (driftMs > driftThresholdMs) {
      _rebuildAnchor(posMs, nowUs: nowUs);
    }

    if (posMs > _currentTimeMs) {
      _currentTimeMs = posMs;
      onTimeUpdate(_currentTimeMs);
      _evaluateClocks(_currentTimeMs);
    }
  }

  @visibleForTesting
  void debugHandleExternalPositionMs(int positionMs) {
    _handlePlatformPosition(positionMs);
  }

  void _attachMusicListeners(AudioPlayer music) {
    unawaited(_posSub?.cancel());
    unawaited(_durSub?.cancel());
    unawaited(_completeSub?.cancel());

    _posSub = music.onPositionChanged.listen((pos) {
      if (_disposed || !_hasExternalAudio || _musicPlayer != music) return;
      _handlePlatformPosition(pos.inMilliseconds);
    });

    _durSub = music.onDurationChanged.listen((dur) {
      if (_disposed || _musicPlayer != music) return;
      if (dur.inMilliseconds > 0) {
        _hasMeasuredExternalDuration = true;
        _durationMs = dur.inMilliseconds;
        onDurationChanged?.call(_durationMs);
      }
    });

    _completeSub = music.onPlayerComplete.listen((_) {
      if (_disposed || _musicPlayer != music) return;
      _isPlaying = false;
      _hasCompleted = true;
      _bufferStalled = false;
      ++_playSeq;
      _clockTimer?.cancel();
      _positionWatchdogTimer?.cancel();
      _rebuildAnchor(_currentTimeMs);
      onEnded?.call();
    });
  }

  Future<AudioPlayer?> _recreateMusicPlayer() async {
    if (!enablePlatformAudio || _disposed) return null;
    final old = _musicPlayer;
    _hasPreparedMusicSource = false;
    _hasCompleted = false;
    _configuredMusicPlayer = null;
    _musicConfigFuture = null;
    unawaited(_posSub?.cancel());
    unawaited(_durSub?.cancel());
    unawaited(_completeSub?.cancel());
    _posSub = null;
    _durSub = null;
    _completeSub = null;
    if (old != null) {
      old.positionUpdater = null;
      unawaited(
        old
            .stop()
            .catchError((Object _) {})
            .timeout(const Duration(milliseconds: 500), onTimeout: () {})
            .whenComplete(() => old.dispose().catchError((Object _) {})),
      );
    }
    final next = _createAndAttachMusicPlayer();
    await _ensureMusicPlayerConfigured(next);
    if (_disposed || _musicPlayer != next) return null;
    return next;
  }

  Future<void> init() async {
    if (!enablePlatformAudio || _disposed) return;
    final music = _musicPlayer ?? _createAndAttachMusicPlayer();
    await Future.wait([
      _ensureMusicPlayerConfigured(music),
      _preloadCue(_accentCue),
      _preloadCue(_subCue),
      _preloadCue(_alertCue),
    ]);
  }

  Future<bool> _preloadCue(_CuePlayerState cue) {
    final player = cue.player;
    if (_disposed || !enablePlatformAudio || player == null) {
      return Future<bool>.value(false);
    }
    if (cue.prepared && player.source != null) {
      return Future<bool>.value(true);
    }
    final existing = cue.preloadFuture;
    if (existing != null) return existing;

    final future = _performPreloadCue(cue).whenComplete(() {
      if (identical(cue.preloadFuture, null)) return;
      cue.preloadFuture = null;
    });
    cue.preloadFuture = future;
    return future;
  }

  Future<bool> _performPreloadCue(_CuePlayerState cue) async {
    final player = cue.player;
    if (_disposed || player == null) return false;
    try {
      player.positionUpdater = null;
      await player.setPlayerMode(
        _useSoundPoolCues ? PlayerMode.lowLatency : PlayerMode.mediaPlayer,
      );
      await player.setReleaseMode(ReleaseMode.stop);
      if (_disposed) return false;

      final filePath = await _materializeCueWavFile(cue);
      if (_disposed) return false;
      cue.cachedFilePath = filePath;

      await player
          .setSource(DeviceFileSource(filePath))
          .timeout(const Duration(seconds: 5));
      if (_disposed) return false;
      if (player.source == null) {
        throw StateError('Cue source was not bound for ${cue.kind.name}');
      }

      cue.prepared = true;
      cue.status = CueStatus.ready;
      cue.lastError = null;
      return true;
    } catch (err) {
      cue.prepared = false;
      cue.status = CueStatus.failed;
      cue.failureCount++;
      cue.lastError = err.toString();
      _recordDiagnostic(
        'Cue preload failed (${cue.kind.name}): $err',
        isCueFailure: true,
      );
      return false;
    }
  }

  Future<String> _materializeCueWavFile(_CuePlayerState cue) async {
    final baseDir = tempDirProvider != null
        ? await tempDirProvider!()
        : await getTemporaryDirectory();
    final cueDir = Directory(
      '${baseDir.path}${AppPlatform.pathSeparator}callbook_cues',
    );
    if (!cueDir.existsSync()) {
      cueDir.createSync(recursive: true);
    }
    final filePath =
        '${cueDir.path}${AppPlatform.pathSeparator}${cue.fileName}';
    final file = File(filePath);
    final expectedBytes = cue.wavBytes.length;
    if (!_verifiedCueFiles.contains(filePath) ||
        !file.existsSync() ||
        file.lengthSync() != expectedBytes) {
      file.writeAsBytesSync(cue.wavBytes, flush: true);
      if (!file.existsSync() || file.lengthSync() != expectedBytes) {
        throw StateError(
          'Cached cue WAV verification failed for ${cue.kind.name} at $filePath',
        );
      }
      _verifiedCueFiles.add(filePath);
    }
    return file.path;
  }

  void _resyncBeatGridAt(
    int trackMs, {
    required bool triggerIfOnBoundary,
  }) {
    if (!_isPlaying) {
      final hadDisplayedBeat = _lastDisplayedBeatIndex != -999999;
      _lastTriggeredAudioBeatIndex = -999999;
      if (hadDisplayedBeat) {
        _lastDisplayedBeatIndex = -999999;
        _evaluateClocks(trackMs, playAudio: false);
      }
      return;
    }
    _lastDisplayedBeatIndex = -999999;

    _evaluateClocks(trackMs, playAudio: false);
    final beatDurationMs = 60000.0 / math.max(30, _bpm);
    final mediaLeadMs = (_cueOutputCompensationMs * _playbackRate).round();
    final relCueMs = trackMs + mediaLeadMs - _offsetMs;
    if (relCueMs < 0) {
      _lastTriggeredAudioBeatIndex = -999999;
      return;
    }
    final curBeat = (relCueMs / beatDurationMs).floor();
    final msPastBoundary = relCueMs - (curBeat * beatDurationMs);
    final edgeToleranceMs = math.max(35.0, 40.0 * _playbackRate);
    _lastTriggeredAudioBeatIndex =
        (triggerIfOnBoundary && msPastBoundary <= edgeToleranceMs)
        ? (curBeat - 1)
        : curBeat;
  }

  void configure({
    required int bpm,
    required int beatsPerBar,
    required int offsetMs,
    int cueOutputCompensationMs = 0,
    required bool metronomeEnabled,
    required double metronomeVolume,
    required bool gtBeepEnabled,
    required double playbackRate,
  }) {
    final nextBpm = bpm.clamp(30, 300);
    final nextBeatsPerBar = beatsPerBar <= 3 ? 3 : 4;
    final nextOffsetMs = clampSongOffsetMs(offsetMs);
    final nextCompMs = clampCueOutputCompensationMs(cueOutputCompensationMs);
    final gridChanged =
        _bpm != nextBpm ||
        _beatsPerBar != nextBeatsPerBar ||
        _offsetMs != nextOffsetMs ||
        _cueOutputCompensationMs != nextCompMs;

    _bpm = nextBpm;
    _beatsPerBar = nextBeatsPerBar;
    _offsetMs = nextOffsetMs;
    _cueOutputCompensationMs = nextCompMs;
    _metronomeEnabled = metronomeEnabled;
    _metronomeVolume = metronomeVolume.clamp(0.05, 1.5);
    _gtBeepEnabled = gtBeepEnabled;

    if ((_playbackRate - playbackRate).abs() > 0.001) {
      final nowUs = _nowUs();
      if (_isPlaying) {
        final current = _computeInterpolatedTimeMs(nowUs);
        if (current > _currentTimeMs) {
          _currentTimeMs = current;
        }
        _rebuildAnchor(_currentTimeMs, nowUs: nowUs);
        _lastConfirmedPlayerClockUs = nowUs;
      }
      _playbackRate = playbackRate.clamp(0.5, 2.0);
      clearTapSamples();
      if (_hasExternalAudio) {
        final future = _musicPlayer?.setPlaybackRate(_playbackRate);
        if (future != null) {
          unawaited(future.catchError((Object _) {}));
        }
      }
    }

    if (gridChanged) {
      _resyncBeatGridAt(_currentTimeMs, triggerIfOnBoundary: true);
      if (_isPlaying && _metronomeEnabled) {
        _evaluateClocks(_currentTimeMs);
      }
    }
  }

  void setAlerts(List<({String id, int triggerTimeMs, int leadBeats})> alerts) {
    _alerts = alerts;
  }

  void setFallbackDurationMs(int durationMs) {
    if (_disposed || _hasExternalAudio || durationMs <= 1000) return;
    _durationMs = durationMs;
    if (_currentTimeMs > _durationMs) {
      _currentTimeMs = _durationMs;
      _rebuildAnchor(_currentTimeMs);
      _lastDisplayedBeatIndex = -999999;
      _lastTriggeredAudioBeatIndex = -999999;
      _beepedAlerts.clear();
      onTimeUpdate(_currentTimeMs);
      _evaluateClocks(_currentTimeMs, playAudio: false);
    }
  }

  Future<void> setAudioSource({
    String? url,
    String? localPath,
    int? fallbackDurationMs,
  }) {
    final token = ++_sourceLoadToken;
    ++_playSeq;
    _isPlaying = false;
    _hasCompleted = false;
    _bufferStalled = false;
    clearTapSamples();
    _clockTimer?.cancel();
    _positionWatchdogTimer?.cancel();
    _pendingSeekMs = null;
    if (_seekCompleter != null && !_seekCompleter!.isCompleted) {
      _seekCompleter!.complete();
      _seekCompleter = null;
    }

    final completer = Completer<void>();
    _sourceOpChain = _sourceOpChain.catchError((Object _) {}).then((_) async {
      try {
        await _performSetAudioSource(
          token: token,
          url: url,
          localPath: localPath,
          fallbackDurationMs: fallbackDurationMs,
        );
        if (!completer.isCompleted) completer.complete();
      } catch (err, st) {
        if (!completer.isCompleted) completer.completeError(err, st);
      }
    });
    return completer.future;
  }

  Future<void> _performSetAudioSource({
    required int token,
    String? url,
    String? localPath,
    int? fallbackDurationMs,
  }) async {
    if (_disposed || token != _sourceLoadToken) return;

    _beepedAlerts.clear();
    _lastDisplayedBeatIndex = -999999;
    _lastTriggeredAudioBeatIndex = -999999;
    _currentTimeMs = 0;
    _rebuildAnchor(0);
    _lastConfirmedPlayerPosMs = 0;
    _lastConfirmedPlayerClockUs = _anchorClockUs;
    _bufferStalled = false;
    _hasCompleted = false;
    _hasMeasuredExternalDuration = false;
    _currentMusicSource = null;
    _currentMusicSourceKey = null;

    final resolvedFallback =
        (fallbackDurationMs != null && fallbackDurationMs > 1000)
            ? fallbackDurationMs
            : 48000;

    final hasLocal = localPath != null && localPath.isNotEmpty;
    final hasUrl = !hasLocal && url != null && url.isNotEmpty;

    if (!hasLocal && !hasUrl) {
      if (_hasPreparedMusicSource && _musicPlayer != null) {
        await _recreateMusicPlayer();
      } else if (_musicPlayer != null) {
        try {
          await _musicPlayer!.stop().timeout(
            const Duration(milliseconds: 500),
            onTimeout: () {},
          );
        } catch (_) {}
      }
      if (_disposed || token != _sourceLoadToken) return;
      _hasExternalAudio = false;
      _hasPreparedMusicSource = false;
      _hasCompleted = false;
      _durationMs = resolvedFallback;
      onDurationChanged?.call(_durationMs);
      onTimeUpdate(0);
      return;
    }

    // Reuse initial untouched AudioPlayer on first external load; recreate on
    // subsequent source switches so native Windows/Android players never wedge.
    var player = _musicPlayer;
    if (enablePlatformAudio) {
      if (_hasPreparedMusicSource || player == null) {
        player = await _recreateMusicPlayer();
      } else {
        await _ensureMusicPlayerConfigured(player);
        try {
          await player.stop().timeout(
            const Duration(milliseconds: 500),
            onTimeout: () {},
          );
        } catch (_) {}
      }
    }
    if (_disposed || token != _sourceLoadToken) return;

    final source = hasLocal
        ? DeviceFileSource(localPath) as Source
        : UrlSource(url!);
    final sourceKey = hasLocal ? 'file:$localPath' : 'url:$url';

    try {
      _hasExternalAudio = true;
      if (player != null) {
        await player.setSource(source).timeout(const Duration(seconds: 12));
        if (_disposed || token != _sourceLoadToken) return;
        _hasPreparedMusicSource = true;
      }
      _currentMusicSource = source;
      _currentMusicSourceKey = sourceKey;
      _durationMs = (fallbackDurationMs != null && fallbackDurationMs > 0)
          ? fallbackDurationMs
          : _durationMs;
    } catch (_) {
      if (enablePlatformAudio && !_disposed && token == _sourceLoadToken) {
        await _recreateMusicPlayer();
      }
      if (_disposed || token != _sourceLoadToken) return;
      _hasExternalAudio = false;
      _hasPreparedMusicSource = false;
      _hasCompleted = false;
      _currentMusicSource = null;
      _currentMusicSourceKey = null;
      _durationMs = resolvedFallback;
      onDurationChanged?.call(_durationMs);
      onTimeUpdate(0);
      rethrow;
    }

    onDurationChanged?.call(_durationMs);
    onTimeUpdate(0);
  }

  void _startPositionWatchdog(AudioPlayer music) {
    _positionWatchdogTimer?.cancel();
    _lastPositionEventClockUs = _nowUs();
    _positionWatchdogTimer = Timer.periodic(
      const Duration(milliseconds: 350),
      (_) async {
        if (_disposed ||
            !_isPlaying ||
            !_hasExternalAudio ||
            _musicPlayer != music ||
            _seekInFlight ||
            _pendingSeekMs != null) {
          return;
        }
        final sinceLastEventMs =
            (_nowUs() - _lastPositionEventClockUs) ~/ 1000;
        if (sinceLastEventMs < 320) return;
        try {
          final pos = await music.getCurrentPosition();
          if (_disposed ||
              !_isPlaying ||
              !_hasExternalAudio ||
              _musicPlayer != music ||
              _seekInFlight ||
              _pendingSeekMs != null ||
              pos == null) {
            return;
          }
          _handlePlatformPosition(pos.inMilliseconds);
        } catch (_) {
          // Ignore transient platform position query failures.
        }
      },
    );
  }

  Future<bool> play() async {
    if (_disposed) return false;
    if (_isPlaying) return true;
    _isPlaying = true;
    final playSeq = ++_playSeq;

    final music = _musicPlayer;
    if (_hasExternalAudio && music != null) {
      final loadToken = _sourceLoadToken;
      final sourceKey = _currentMusicSourceKey;
      final cachedSource = _currentMusicSource;
      final replayingFromCompleted = _hasCompleted;
      if (replayingFromCompleted) {
        _hasCompleted = false;
        _currentTimeMs = 0;
        _rebuildAnchor(0);
        _lastConfirmedPlayerPosMs = 0;
        _lastConfirmedPlayerClockUs = _anchorClockUs;
        _lastDisplayedBeatIndex = -999999;
        _lastTriggeredAudioBeatIndex = -999999;
        _beepedAlerts.clear();
        onTimeUpdate(0);
      }

      bool isAborted() =>
          _disposed ||
          !_isPlaying ||
          _playSeq != playSeq ||
          !_hasExternalAudio ||
          _sourceLoadToken != loadToken ||
          _currentMusicSourceKey != sourceKey;

      try {
        final started = await _playOrRecoverExternalMusic(
          music: music,
          replayingFromCompleted: replayingFromCompleted,
          cachedSource: cachedSource,
          sourceKey: sourceKey,
          loadToken: loadToken,
          isAborted: isAborted,
        );
        if (!started || isAborted()) {
          if (!_disposed &&
              _playSeq == playSeq &&
              _sourceLoadToken == loadToken) {
            _isPlaying = false;
            _clockTimer?.cancel();
            _positionWatchdogTimer?.cancel();
          }
          return false;
        }
      } catch (err) {
        _recordDiagnostic('Music play failed: $err');
        if (!_disposed &&
            _playSeq == playSeq &&
            _sourceLoadToken == loadToken) {
          _isPlaying = false;
          _hasCompleted = false;
          _clockTimer?.cancel();
          _positionWatchdogTimer?.cancel();
        }
        return false;
      }

      final activePlayer = _musicPlayer;
      if (activePlayer == null || isAborted()) {
        return false;
      }
      final startUs = _nowUs();
      _rebuildAnchor(_currentTimeMs, nowUs: startUs);
      _lastConfirmedPlayerPosMs = _currentTimeMs;
      _lastConfirmedPlayerClockUs = startUs;
      _bufferStalled = false;
      _evaluateClocks(_currentTimeMs, isInitialPlayEvaluation: true);

      _clockTimer?.cancel();
      _clockTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
        if (!_isPlaying ||
            _disposed ||
            !_hasExternalAudio ||
            _seekInFlight ||
            _pendingSeekMs != null ||
            _bufferStalled) {
          return;
        }
        final nowUs = _nowUs();
        var next = _computeInterpolatedTimeMs(nowUs);
        final maxAllowed = (_lastConfirmedPlayerPosMs +
                (maxBufferExtrapolationMs * _playbackRate).round())
            .clamp(0, _durationMs)
            .toInt();
        if (next >= maxAllowed) {
          next = maxAllowed;
          _bufferStalled = true;
          _rebuildAnchor(next, nowUs: nowUs);
        }
        if (next > _currentTimeMs) {
          _currentTimeMs = next;
          onTimeUpdate(_currentTimeMs);
          _evaluateClocks(_currentTimeMs);
        }
      });
      _startPositionWatchdog(activePlayer);
      return true;
    }

    _positionWatchdogTimer?.cancel();
    _bufferStalled = false;
    _rebuildAnchor(_currentTimeMs);
    _evaluateClocks(_currentTimeMs, isInitialPlayEvaluation: true);
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_isPlaying || _disposed) return;
      final nowUs = _nowUs();
      final elapsedUs = math.max(0, nowUs - _anchorClockUs);
      var next = _anchorMediaMs + (elapsedUs * _playbackRate / 1000.0).round();
      if (next >= _durationMs) {
        next = 0;
        _rebuildAnchor(0, nowUs: nowUs);
        _beepedAlerts.clear();
        _lastDisplayedBeatIndex = -999999;
        _lastTriggeredAudioBeatIndex = -999999;
        _currentTimeMs = 0;
        onTimeUpdate(0);
        _evaluateClocks(0, isInitialPlayEvaluation: true);
        return;
      }
      if (next > _currentTimeMs) {
        _currentTimeMs = next;
        onTimeUpdate(_currentTimeMs);
        _evaluateClocks(_currentTimeMs);
      }
    });
    return true;
  }

  Future<bool> _playOrRecoverExternalMusic({
    required AudioPlayer music,
    required bool replayingFromCompleted,
    required Source? cachedSource,
    required String? sourceKey,
    required int loadToken,
    required bool Function() isAborted,
  }) async {
    final pendingSeek = _seekCompleter?.future;
    if (pendingSeek != null) {
      await pendingSeek;
      if (isAborted()) return false;
    }

    final currentMusic = _musicPlayer;
    if (currentMusic == null) return false;
    await _ensureMusicPlayerConfigured(currentMusic);
    if (isAborted() || _musicPlayer != currentMusic) return false;

    // Fast path: reuse the retained source without re-fetching remote URLs.
    if (currentMusic.source != null && _hasPreparedMusicSource) {
      try {
        if (replayingFromCompleted) {
          final pos = await currentMusic.getCurrentPosition().timeout(
            const Duration(milliseconds: 500),
            onTimeout: () => null,
          );
          if (isAborted() || _musicPlayer != currentMusic) return false;
          if (pos == null || pos.inMilliseconds != 0) {
            await currentMusic
                .seek(Duration.zero)
                .timeout(const Duration(seconds: 3));
            if (isAborted() || _musicPlayer != currentMusic) return false;
          }
        }
        await currentMusic.setPlaybackRate(_playbackRate);
        if (isAborted() || _musicPlayer != currentMusic) return false;
        await currentMusic.resume();
        if (isAborted() || _musicPlayer != currentMusic) {
          if (!_disposed && !_isPlaying && _musicPlayer == currentMusic) {
            unawaited(currentMusic.pause().catchError((Object _) {}));
          }
          return false;
        }
        return true;
      } catch (err) {
        _recordDiagnostic(
          'Music source reuse failed (${replayingFromCompleted ? "EOF" : "resume"}), attempting bounded reload: $err',
        );
        if (isAborted() || _musicPlayer != currentMusic) return false;
      }
    }

    // Bounded single-attempt reload using cached source when resume/reuse fails.
    if (cachedSource == null || sourceKey == null) {
      return false;
    }
    final recovered = await _recoverMusicPlayerWithCachedSource(
      cachedSource: cachedSource,
      sourceKey: sourceKey,
      loadToken: loadToken,
      targetPositionMs: replayingFromCompleted ? 0 : _currentTimeMs,
    );
    if (recovered == null || isAborted() || _musicPlayer != recovered) {
      return false;
    }
    await recovered.setPlaybackRate(_playbackRate);
    if (isAborted() || _musicPlayer != recovered) return false;
    await recovered.resume();
    if (isAborted() || _musicPlayer != recovered) {
      if (!_disposed && !_isPlaying && _musicPlayer == recovered) {
        unawaited(recovered.pause().catchError((Object _) {}));
      }
      return false;
    }
    return true;
  }

  Future<AudioPlayer?> _recoverMusicPlayerWithCachedSource({
    required Source cachedSource,
    required String sourceKey,
    required int loadToken,
    required int targetPositionMs,
  }) async {
    if (_disposed ||
        !_hasExternalAudio ||
        _sourceLoadToken != loadToken ||
        _currentMusicSourceKey != sourceKey) {
      return null;
    }
    final player = await _recreateMusicPlayer();
    if (player == null ||
        _disposed ||
        !_hasExternalAudio ||
        _sourceLoadToken != loadToken ||
        _currentMusicSourceKey != sourceKey ||
        _musicPlayer != player) {
      return null;
    }
    try {
      await player
          .setSource(cachedSource)
          .timeout(const Duration(seconds: 12));
      if (_disposed ||
          !_hasExternalAudio ||
          _sourceLoadToken != loadToken ||
          _currentMusicSourceKey != sourceKey ||
          _musicPlayer != player) {
        return null;
      }
      _hasPreparedMusicSource = true;
      if (targetPositionMs > 0) {
        await player
            .seek(Duration(milliseconds: targetPositionMs))
            .timeout(const Duration(seconds: 3));
        if (_disposed ||
            !_hasExternalAudio ||
            _sourceLoadToken != loadToken ||
            _currentMusicSourceKey != sourceKey ||
            _musicPlayer != player) {
          return null;
        }
      }
      return player;
    } catch (err) {
      _recordDiagnostic('Music cached source recovery failed: $err');
      if (!_disposed &&
          _musicPlayer == player &&
          _sourceLoadToken == loadToken) {
        _hasPreparedMusicSource = false;
        _hasCompleted = false;
      }
      return null;
    }
  }

  Future<void> pause() async {
    _positionWatchdogTimer?.cancel();
    ++_playSeq;
    if (!_isPlaying) return;
    final nowUs = _nowUs();
    if (!_bufferStalled) {
      final interpolated = _computeInterpolatedTimeMs(nowUs);
      if (interpolated > _currentTimeMs) {
        _currentTimeMs = interpolated;
        onTimeUpdate(_currentTimeMs);
      }
    }
    _rebuildAnchor(_currentTimeMs, nowUs: nowUs);
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

  /// Rebuilds the monotonic anchor after returning from OS background sleep.
  Future<void> onAppResumed() async {
    if (_disposed || !_isPlaying) return;
    if (_hasExternalAudio && _musicPlayer != null) {
      try {
        final pos = await _musicPlayer!.getCurrentPosition().timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => null,
        );
        if (_disposed || !_isPlaying) return;
        final nowUs = _nowUs();
        if (pos != null) {
          final clamped = pos.inMilliseconds.clamp(0, _durationMs).toInt();
          _lastConfirmedPlayerPosMs = clamped;
          _lastConfirmedPlayerClockUs = nowUs;
          _bufferStalled = false;
          _rebuildAnchor(clamped, nowUs: nowUs);
          if (clamped != _currentTimeMs) {
            _currentTimeMs = clamped;
            onTimeUpdate(_currentTimeMs);
            _resyncBeatGridAt(clamped, triggerIfOnBoundary: false);
          }
          return;
        }
      } catch (_) {}
    }
    if (_disposed || !_isPlaying) return;
    _bufferStalled = false;
    _rebuildAnchor(_currentTimeMs, nowUs: _nowUs());
  }

  Future<void> seek(int ms) {
    if (_disposed) return Future.value();
    final target = ms.clamp(0, math.max<int>(1000, _durationMs)).toInt();
    final nowUs = _nowUs();
    _hasCompleted = false;
    _currentTimeMs = target;
    _rebuildAnchor(target, nowUs: nowUs);
    _lastConfirmedPlayerPosMs = target;
    _lastConfirmedPlayerClockUs = nowUs;
    _bufferStalled = false;
    _lastDisplayedBeatIndex = -999999;
    _lastTriggeredAudioBeatIndex = -999999;
    _beepedAlerts.clear();
    clearTapSamples();

    if (!_hasExternalAudio || _musicPlayer == null) {
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
    final initialMusic = _musicPlayer;
    if (initialMusic == null) {
      _pendingSeekMs = null;
      _seekCompleter?.complete();
      _seekCompleter = null;
      return;
    }
    var music = initialMusic;
    _seekInFlight = true;
    try {
      while (!_disposed &&
          _pendingSeekMs != null &&
          _musicPlayer == music) {
        final nextTarget = _pendingSeekMs!;
        _pendingSeekMs = null;
        final loadToken = _sourceLoadToken;
        final sourceKey = _currentMusicSourceKey;
        final cachedSource = _currentMusicSource;
        try {
          if (music.source == null &&
              cachedSource != null &&
              sourceKey != null) {
            final recovered = await _recoverMusicPlayerWithCachedSource(
              cachedSource: cachedSource,
              sourceKey: sourceKey,
              loadToken: loadToken,
              targetPositionMs: nextTarget,
            );
            if (recovered != null) {
              music = recovered;
            }
            continue;
          }
          await music
              .seek(Duration(milliseconds: nextTarget))
              .timeout(const Duration(seconds: 3));
        } catch (err) {
          if (!_disposed &&
              _musicPlayer == music &&
              cachedSource != null &&
              sourceKey != null) {
            final recovered = await _recoverMusicPlayerWithCachedSource(
              cachedSource: cachedSource,
              sourceKey: sourceKey,
              loadToken: loadToken,
              targetPositionMs: nextTarget,
            );
            if (recovered != null) {
              music = recovered;
              continue;
            }
          }
          _recordDiagnostic('Music seek failed: $err');
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

  Future<void> testGtAlertBeep() async {
    final vol = (_metronomeVolume / 1.5).clamp(0.15, 1.0);
    await _triggerCue(_alertCue, vol);
  }

  void clearTapSamples() {
    _tapHistoryMs.clear();
  }

  /// Accumulates monotonic Tap Tempo samples and returns a candidate BPM with
  /// confidence starting at the 4th tap after filtering outlier intervals.
  BpmEstimateResult? recordTapSample() {
    final nowMs = _nowUs() ~/ 1000;
    if (_tapHistoryMs.isNotEmpty && nowMs - _tapHistoryMs.last > 2400) {
      _tapHistoryMs.clear();
    }
    _tapHistoryMs.add(nowMs);
    if (_tapHistoryMs.length > 12) {
      _tapHistoryMs.removeAt(0);
    }
    if (_tapHistoryMs.length < 4) return null;

    final rawIntervals = <int>[];
    for (var i = 1; i < _tapHistoryMs.length; i++) {
      final delta = _tapHistoryMs[i] - _tapHistoryMs[i - 1];
      if (delta >= 180 && delta <= 2000) {
        rawIntervals.add(delta);
      }
    }
    if (rawIntervals.length < 2) return null;

    final sorted = [...rawIntervals]..sort();
    final medianMs = sorted[sorted.length ~/ 2].toDouble();
    final inliers = rawIntervals
        .where((d) => (d - medianMs).abs() <= medianMs * 0.25)
        .toList();
    if (inliers.length < 2) return null;

    final meanMs =
        inliers.reduce((a, b) => a + b) / inliers.length;
    var bpm = (60000.0 / meanMs).round();
    while (bpm > 195) {
      bpm = (bpm / 2).round();
    }
    while (bpm < 70) {
      bpm = bpm * 2;
    }

    var sqDiffSum = 0.0;
    for (final v in inliers) {
      final diff = v - meanMs;
      sqDiffSum += diff * diff;
    }
    final stdDev = math.sqrt(sqDiffSum / inliers.length);
    final cv = stdDev / math.max(1.0, meanMs);
    final consistencyScore = (1.0 - (cv / 0.18)).clamp(0.0, 1.0);
    final inlierRatio = inliers.length / rawIntervals.length;
    final sampleFactor = (inliers.length / 5.0).clamp(0.6, 1.0);
    final confidence =
        (consistencyScore * 0.7 + inlierRatio * 0.3) * sampleFactor;

    return BpmEstimateResult(
      bpm: bpm.clamp(30, 300),
      confidence: confidence.clamp(0.05, 0.99),
      sampleCount: _tapHistoryMs.length,
      validIntervalCount: inliers.length,
    );
  }

  int? tapTempo() => recordTapSample()?.bpm;

  void _evaluateClocks(
    int trackMs, {
    bool playAudio = true,
    bool isInitialPlayEvaluation = false,
  }) {
    final beatDurationMs = 60000.0 / math.max(30, _bpm);
    final relativeDisplayMs = trackMs - _offsetMs;
    if (relativeDisplayMs >= 0) {
      final displayBeatIndex = (relativeDisplayMs / beatDurationMs).floor();
      if (displayBeatIndex > _lastDisplayedBeatIndex) {
        _lastDisplayedBeatIndex = displayBeatIndex;
        final bar = (displayBeatIndex ~/ _beatsPerBar) + 1;
        final beatInBar = (displayBeatIndex % _beatsPerBar) + 1;
        onBeatTrigger(
          BeatSnapshot(beatIndex: displayBeatIndex, bar: bar, beatInBar: beatInBar),
        );
      }
    }

    if (playAudio && _metronomeEnabled) {
      final mediaLeadMs = (_cueOutputCompensationMs * _playbackRate).round();
      final cueScheduleMs = trackMs + mediaLeadMs;
      final relativeCueMs = cueScheduleMs - _offsetMs;
      if (relativeCueMs >= 0) {
        final cueBeatIndex = (relativeCueMs / beatDurationMs).floor();
        if (cueBeatIndex > _lastTriggeredAudioBeatIndex) {
          final msPastBoundary =
              relativeCueMs - (cueBeatIndex * beatDurationMs);
          final edgeToleranceMs = math.max(35.0, 40.0 * _playbackRate);
          final jumpedMultipleBeats =
              _lastTriggeredAudioBeatIndex >= 0 &&
              (cueBeatIndex - _lastTriggeredAudioBeatIndex) > 1;
          final shouldSkipMidBeatInitial =
              isInitialPlayEvaluation &&
              _lastTriggeredAudioBeatIndex < 0 &&
              relativeDisplayMs >= 0 &&
              (relativeDisplayMs -
                      (relativeDisplayMs / beatDurationMs).floor() *
                          beatDurationMs) >
                  edgeToleranceMs &&
              cueBeatIndex == (relativeDisplayMs / beatDurationMs).floor();
          final shouldSkipExpiredJump =
              jumpedMultipleBeats &&
              msPastBoundary > math.max(80.0, 50.0 * _playbackRate);

          _lastTriggeredAudioBeatIndex = cueBeatIndex;
          if (!shouldSkipMidBeatInitial && !shouldSkipExpiredJump) {
            final beatInBar = (cueBeatIndex % _beatsPerBar) + 1;
            unawaited(_playClick(accent: beatInBar == 1));
          }
        }
      }
    }

    if (playAudio && _gtBeepEnabled) {
      final mediaLeadMs = (_cueOutputCompensationMs * _playbackRate).round();
      final cueTrackMs = trackMs + mediaLeadMs;
      for (final alert in _alerts) {
        if (_beepedAlerts.contains(alert.id)) continue;
        final leadMs = (alert.leadBeats * beatDurationMs).round();
        final warnStart = alert.triggerTimeMs - leadMs;
        if (cueTrackMs >= warnStart &&
            cueTrackMs <= alert.triggerTimeMs + 250) {
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
    if (_disposed || !enablePlatformAudio || player == null || cue.inFlight) {
      return;
    }
    cue.inFlight = true;
    try {
      if (!cue.prepared || player.source == null) {
        final ready = await _preloadCue(cue);
        if (!ready || _disposed) return;
      }
      if (cue.lastVolume == null || (cue.lastVolume! - volume).abs() > 0.005) {
        await player.setVolume(volume);
        cue.lastVolume = volume;
        if (_disposed) return;
      }
      final needsStopBeforeReplay = _useSoundPoolCues
          ? player.state != PlayerState.stopped
          : (player.state == PlayerState.playing ||
                player.state == PlayerState.paused);
      if (needsStopBeforeReplay) {
        await player.stop().timeout(const Duration(milliseconds: 500));
        if (_disposed) return;
      }
      await player.resume().timeout(const Duration(seconds: 2));
      if (_disposed) return;
      cue.playCount++;
      cue.status = CueStatus.ready;
      cue.lastError = null;
    } catch (err) {
      cue.prepared = false;
      cue.status = CueStatus.failed;
      cue.failureCount++;
      cue.lastError = err.toString();
      _recordDiagnostic(
        'Cue playback failed (${cue.kind.name}): $err',
        isCueFailure: true,
      );
    } finally {
      cue.inFlight = false;
    }
  }

  static String _cueFileName(CueKind kind, Uint8List wavBytes) {
    var hash = 0x811c9dc5;
    for (final byte in wavBytes) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    final hex = hash.toRadixString(16).padLeft(8, '0');
    return 'cue_${kind.name}_$hex.wav';
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
    ++_sourceLoadToken;
    ++_playSeq;
    _clockTimer?.cancel();
    _positionWatchdogTimer?.cancel();
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
