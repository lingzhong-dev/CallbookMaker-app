import 'dart:async';
import 'dart:io' show Directory;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_call_studio/services/api_client.dart';
import 'package:live_call_studio/services/lrclib_direct_client.dart';
import 'package:live_call_studio/services/netease_direct_client.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecordedAudioCall {
  RecordedAudioCall(this.method, this.playerId, this.arguments);

  final String method;
  final String playerId;
  final Map<dynamic, dynamic> arguments;
}

class _MockPlayerState {
  _MockPlayerState(this.playerId);

  final String playerId;
  String playerMode = PlayerMode.mediaPlayer.toString();
  String releaseMode = ReleaseMode.release.toString();
  String? sourceUrl;
  bool? isLocal;
  bool hasBytesSource = false;
  bool prepared = false;
  bool playing = false;
  bool released = true;
  bool isMusic = false;
  bool isCue = false;
  int positionMs = 0;
}

class MockAudioplayersHarness {
  final List<RecordedAudioCall> calls = [];
  final Set<String> registeredEventChannels = {};
  bool autoCompletePrepared = true;
  bool autoCompleteSeek = true;
  bool throwOnMusicResume = false;
  bool throwOnReleasedResume = true;
  bool throwOnReleasedSeek = true;
  bool autoRewindOnStopComplete = true;
  bool enforceLowLatencyConstraints = true;
  int mockMusicPositionMs = 0;
  int mockMusicDurationMs = 48000;
  Directory? tempDir;

  final Set<String> throwOnResumePlayerIds = <String>{};
  final Set<String> throwOnSetSourcePlayerIds = <String>{};

  final Map<String, _MockPlayerState> _players = <String, _MockPlayerState>{};
  final List<String> _musicPlayerIds = <String>[];
  final List<String> _cuePlayerIds = <String>[];
  final List<Completer<void>> _manualSeekCompleters = [];

  int _lowLatencyPlayStarts = 0;
  int _ignoredLowLatencyResumes = 0;

  List<String> get musicPlayerIds => List<String>.unmodifiable(_musicPlayerIds);
  String? get activeMusicPlayerId =>
      _musicPlayerIds.isEmpty ? null : _musicPlayerIds.last;
  List<String> get cuePlayerIds => List<String>.unmodifiable(_cuePlayerIds);
  int get lowLatencyPlayStarts => _lowLatencyPlayStarts;
  int get ignoredLowLatencyResumes => _ignoredLowLatencyResumes;

  String? playerModeFor(String playerId) => _players[playerId]?.playerMode;
  String? releaseModeFor(String playerId) => _players[playerId]?.releaseMode;
  bool isPlayerReleased(String playerId) =>
      _players[playerId]?.released ?? true;
  bool isPlayerPrepared(String playerId) =>
      _players[playerId]?.prepared ?? false;
  bool isPlayerPlaying(String playerId) =>
      _players[playerId]?.playing ?? false;
  String? sourceUrlFor(String playerId) => _players[playerId]?.sourceUrl;

  bool _isCueCall(String playerId, String? url, _MockPlayerState state) {
    if (playerId.startsWith('callbook_cue_')) return true;
    if (state.playerMode == PlayerMode.lowLatency.toString()) return true;
    if (url != null && url.contains('callbook_cues')) return true;
    return false;
  }

  _MockPlayerState _ensurePlayer(String playerId) {
    return _players.putIfAbsent(playerId, () => _MockPlayerState(playerId));
  }

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StandardMethodCodec();

    final createdTemp = Directory.systemTemp.createTempSync(
      'callbook_audio_harness_',
    );
    tempDir = createdTemp;
    try {
      addTearDown(() {
        try {
          if (createdTemp.existsSync()) {
            createdTemp.deleteSync(recursive: true);
          }
        } catch (_) {}
      });
    } catch (_) {
      // Allow install() outside test zones if called manually.
    }

    void ensureEventChannelMock(String channelName) {
      if (!registeredEventChannels.add(channelName)) return;
      messenger.setMockMessageHandler(channelName, (ByteData? message) {
        if (message == null) return SynchronousFuture<ByteData?>(null);
        final decoded = codec.decodeMethodCall(message);
        if (decoded.method == 'listen' || decoded.method == 'cancel') {
          return SynchronousFuture<ByteData?>(
            codec.encodeSuccessEnvelope(null),
          );
        }
        return SynchronousFuture<ByteData?>(null);
      });
    }

    ensureEventChannelMock('xyz.luan/audioplayers.global/events');

    messenger.setMockMessageHandler(
      'xyz.luan/audioplayers.global',
      (ByteData? message) {
        if (message == null) return SynchronousFuture<ByteData?>(null);
        return SynchronousFuture<ByteData?>(codec.encodeSuccessEnvelope(null));
      },
    );

    messenger.setMockMessageHandler(
      'xyz.luan/audioplayers',
      (ByteData? message) {
        if (message == null) return SynchronousFuture<ByteData?>(null);
        final call = codec.decodeMethodCall(message);
        final args = call.arguments as Map<dynamic, dynamic>? ?? const {};
        final playerId = args['playerId']?.toString() ?? '';
        if (playerId.isNotEmpty) {
          ensureEventChannelMock('xyz.luan/audioplayers/events/$playerId');
        }
        calls.add(RecordedAudioCall(call.method, playerId, args));

        final state = playerId.isNotEmpty ? _ensurePlayer(playerId) : null;
        Object? result;
        switch (call.method) {
          case 'create':
            if (state != null &&
                playerId.startsWith('callbook_cue_') &&
                !_cuePlayerIds.contains(playerId)) {
              state.isCue = true;
              _cuePlayerIds.add(playerId);
            }
            break;
          case 'setPlayerMode':
            if (state != null) {
              state.playerMode =
                  args['playerMode']?.toString() ?? state.playerMode;
              if (state.playerMode == PlayerMode.lowLatency.toString()) {
                state.isCue = true;
                if (!_cuePlayerIds.contains(playerId)) {
                  _cuePlayerIds.add(playerId);
                }
              }
            }
            break;
          case 'setReleaseMode':
            if (state != null) {
              state.releaseMode =
                  args['releaseMode']?.toString() ?? state.releaseMode;
            }
            break;
          case 'setSourceUrl':
            final url = args['url']?.toString();
            final isLocal = args['isLocal'] as bool?;
            if (throwOnSetSourcePlayerIds.contains(playerId)) {
              return Future<ByteData?>.value(
                codec.encodeErrorEnvelope(
                  code: 'SET_SOURCE_FAILED',
                  message: 'Mock source load error for $playerId',
                ),
              );
            }
            if (state != null) {
              final cue = _isCueCall(playerId, url, state);
              state.isCue = cue;
              state.isMusic = !cue;
              state.sourceUrl = url;
              state.isLocal = isLocal;
              state.hasBytesSource = false;
              state.released = false;
              state.playing = false;
              state.positionMs = 0;
              if (cue) {
                if (!_cuePlayerIds.contains(playerId)) {
                  _cuePlayerIds.add(playerId);
                }
              } else {
                if (!_musicPlayerIds.contains(playerId)) {
                  _musicPlayerIds.add(playerId);
                }
              }
              if (autoCompletePrepared && playerId.isNotEmpty) {
                scheduleMicrotask(() => emitPrepared(playerId, true));
              }
            }
            break;
          case 'setSourceBytes':
            if (state != null &&
                enforceLowLatencyConstraints &&
                state.playerMode == PlayerMode.lowLatency.toString()) {
              return Future<ByteData?>.value(
                codec.encodeErrorEnvelope(
                  code: 'AndroidAudioError',
                  message:
                      'Bytes sources are not supported on LOW_LATENCY mode yet.',
                ),
              );
            }
            if (throwOnSetSourcePlayerIds.contains(playerId)) {
              return Future<ByteData?>.value(
                codec.encodeErrorEnvelope(
                  code: 'SET_SOURCE_FAILED',
                  message: 'Mock bytes source load error for $playerId',
                ),
              );
            }
            if (state != null) {
              state.hasBytesSource = true;
              state.released = false;
              if (autoCompletePrepared && playerId.isNotEmpty) {
                scheduleMicrotask(() => emitPrepared(playerId, true));
              }
            }
            break;
          case 'resume':
            if (throwOnResumePlayerIds.contains(playerId) ||
                (throwOnMusicResume && (state?.isMusic ?? false))) {
              return Future<ByteData?>.value(
                codec.encodeErrorEnvelope(
                  code: 'PLAY_FAILED',
                  message: 'Mock audio device play error',
                ),
              );
            }
            if (state != null &&
                throwOnReleasedResume &&
                (state.released || !state.prepared)) {
              return Future<ByteData?>.value(
                codec.encodeErrorEnvelope(
                  code: 'SOURCE_RELEASED',
                  message: 'Cannot resume released or unprepared player',
                ),
              );
            }
            if (state != null) {
              if (enforceLowLatencyConstraints &&
                  state.playerMode == PlayerMode.lowLatency.toString()) {
                if (state.playing) {
                  _ignoredLowLatencyResumes++;
                } else {
                  state.playing = true;
                  _lowLatencyPlayStarts++;
                }
              } else {
                state.playing = true;
              }
            }
            break;
          case 'pause':
            if (state != null) {
              state.playing = false;
            }
            break;
          case 'stop':
            if (state != null) {
              state.playing = false;
              if (state.releaseMode == ReleaseMode.release.toString()) {
                state.released = true;
                state.prepared = false;
                state.sourceUrl = null;
                state.hasBytesSource = false;
              } else {
                state.positionMs = 0;
                if (state.isMusic) {
                  mockMusicPositionMs = 0;
                }
              }
            }
            break;
          case 'release':
          case 'dispose':
            if (state != null) {
              state.playing = false;
              state.released = true;
              state.prepared = false;
              state.sourceUrl = null;
              state.hasBytesSource = false;
            }
            break;
          case 'seek':
            if (playerId.isNotEmpty && state != null) {
              final targetPos = (args['position'] as num?)?.toInt();
              if (enforceLowLatencyConstraints &&
                  state.playerMode == PlayerMode.lowLatency.toString()) {
                if (targetPos != null && targetPos != 0) {
                  return Future<ByteData?>.value(
                    codec.encodeErrorEnvelope(
                      code: 'AndroidAudioError',
                      message: 'LOW_LATENCY mode does not support: seek',
                    ),
                  );
                }
                // SoundPool never emits onSeekComplete.
                break;
              }
              if (state.released || !state.prepared) {
                if (throwOnReleasedSeek) {
                  return Future<ByteData?>.value(
                    codec.encodeErrorEnvelope(
                      code: 'SOURCE_RELEASED',
                      message: 'Cannot seek released or unprepared player',
                    ),
                  );
                }
                break;
              }
              if (autoCompleteSeek) {
                if (targetPos != null) {
                  state.positionMs = targetPos;
                  if (state.isMusic) {
                    mockMusicPositionMs = targetPos;
                  }
                }
                scheduleMicrotask(() => emitSeekComplete(playerId));
              } else if (state.isMusic) {
                final c = Completer<void>();
                _manualSeekCompleters.add(c);
                scheduleMicrotask(() async {
                  await c.future;
                  if (targetPos != null) {
                    state.positionMs = targetPos;
                    mockMusicPositionMs = targetPos;
                  }
                  emitSeekComplete(playerId);
                });
              }
            }
            break;
          case 'getCurrentPosition':
            if (state != null &&
                state.playerMode == PlayerMode.lowLatency.toString()) {
              result = null;
            } else if (state != null && state.isMusic) {
              result = mockMusicPositionMs;
            } else {
              result = state?.positionMs ?? 0;
            }
            break;
          case 'getDuration':
            if (state != null &&
                state.playerMode == PlayerMode.lowLatency.toString()) {
              result = null;
            } else if (state != null && state.isMusic) {
              result = mockMusicDurationMs;
            } else {
              result = 50;
            }
            break;
          default:
            result = null;
        }
        return SynchronousFuture<ByteData?>(
          codec.encodeSuccessEnvelope(result),
        );
      },
    );

    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getTemporaryDirectory') {
          return createdTemp.path;
        }
        return createdTemp.path;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('miguelruivo.flutter.plugins.filepicker'),
      (MethodCall call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/share'),
      (MethodCall call) async => 'unavailable',
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (MethodCall call) async => true,
    );
  }

  void completeNextSeek() {
    if (_manualSeekCompleters.isNotEmpty) {
      final c = _manualSeekCompleters.removeAt(0);
      if (!c.isCompleted) c.complete();
    }
  }

  void emitPrepared(String playerId, bool value) {
    final state = _players[playerId];
    if (state != null) {
      state.prepared = value;
      if (value) {
        state.released = false;
      }
    }
    _emitEvent(playerId, {'event': 'audio.onPrepared', 'value': value});
  }

  void emitSeekComplete(String playerId) {
    _emitEvent(playerId, {'event': 'audio.onSeekComplete'});
  }

  void emitPlayerComplete(
    String playerId, {
    bool simulateSourceRelease = false,
  }) {
    final state = _players[playerId];
    if (state != null) {
      if (state.releaseMode == ReleaseMode.loop.toString()) {
        state.playing = true;
        state.positionMs = 0;
        if (state.isMusic) {
          mockMusicPositionMs = 0;
        }
      } else {
        state.playing = false;
        if (simulateSourceRelease ||
            state.releaseMode == ReleaseMode.release.toString()) {
          state.released = true;
          state.prepared = false;
          state.sourceUrl = null;
          state.hasBytesSource = false;
        } else {
          if (autoRewindOnStopComplete) {
            state.positionMs = 0;
            if (state.isMusic) {
              mockMusicPositionMs = 0;
            }
          }
        }
      }
    }
    _emitEvent(playerId, {'event': 'audio.onComplete'});
  }

  void _emitEvent(String playerId, Map<String, Object?> payload) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bytes = const StandardMethodCodec().encodeSuccessEnvelope(payload);
    messenger.handlePlatformMessage(
      'xyz.luan/audioplayers/events/$playerId',
      bytes,
      (_) {},
    );
  }
}

Future<CallbookController> createTestCallbookController({
  bool enableAudioOutput = true,
  Map<String, Object> initialPrefs = const {
    'live_call_studio_onboarding_v1': true,
  },
  http.Client? apiHttpClient,
  http.Client? neteaseHttpClient,
  http.Client? lrclibHttpClient,
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final api = CallbookApiClient(
    baseUrl: 'http://127.0.0.1:8000',
    httpClient:
        apiHttpClient ?? MockClient((_) async => http.Response('offline', 503)),
  );
  final neteaseDirect = NeteaseDirectClient(
    httpClient:
        neteaseHttpClient ??
        MockClient((_) async => http.Response('offline', 503)),
  );
  final lrclibDirect = LrclibDirectClient(
    httpClient:
        lrclibHttpClient ??
        MockClient((_) async => http.Response('offline', 503)),
  );
  final controller = CallbookController(
    apiClient: api,
    neteaseDirectClient: neteaseDirect,
    lrclibDirectClient: lrclibDirect,
    enableAudioOutput: enableAudioOutput,
  );
  await controller.init();
  return controller;
}
