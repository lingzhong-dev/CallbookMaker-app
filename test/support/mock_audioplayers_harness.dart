import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_call_studio/services/api_client.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecordedAudioCall {
  RecordedAudioCall(this.method, this.playerId, this.arguments);

  final String method;
  final String playerId;
  final Map<dynamic, dynamic> arguments;
}

class MockAudioplayersHarness {
  final List<RecordedAudioCall> calls = [];
  final Set<String> registeredEventChannels = {};
  bool autoCompletePrepared = true;
  bool autoCompleteSeek = true;
  bool throwOnMusicResume = false;
  int mockMusicPositionMs = 0;
  final Set<String> _musicPlayerIds = {};
  final List<Completer<void>> _manualSeekCompleters = [];

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StandardMethodCodec();

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

        Object? result;
        switch (call.method) {
          case 'setSourceUrl':
            _musicPlayerIds.add(playerId);
            if (autoCompletePrepared && playerId.isNotEmpty) {
              scheduleMicrotask(() => emitPrepared(playerId, true));
            }
            break;
          case 'setSourceBytes':
            if (autoCompletePrepared && playerId.isNotEmpty) {
              scheduleMicrotask(() => emitPrepared(playerId, true));
            }
            break;
          case 'resume':
            if (throwOnMusicResume && _musicPlayerIds.contains(playerId)) {
              return Future<ByteData?>.value(
                codec.encodeErrorEnvelope(
                  code: 'PLAY_FAILED',
                  message: 'Mock Windows audio device error',
                ),
              );
            }
            break;
          case 'seek':
            if (playerId.isNotEmpty) {
              if (autoCompleteSeek) {
                scheduleMicrotask(() => emitSeekComplete(playerId));
              } else if (_musicPlayerIds.contains(playerId)) {
                final c = Completer<void>();
                _manualSeekCompleters.add(c);
                scheduleMicrotask(() async {
                  await c.future;
                  emitSeekComplete(playerId);
                });
              }
            }
            break;
          case 'getCurrentPosition':
            result = mockMusicPositionMs;
            break;
          case 'getDuration':
            result = 48000;
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
    _emitEvent(playerId, {'event': 'audio.onPrepared', 'value': value});
  }

  void emitSeekComplete(String playerId) {
    _emitEvent(playerId, {'event': 'audio.onSeekComplete'});
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
}) async {
  SharedPreferences.setMockInitialValues({});
  final api = CallbookApiClient(
    baseUrl: 'http://127.0.0.1:8000',
    httpClient: MockClient((_) async => http.Response('offline', 503)),
  );
  final controller = CallbookController(
    apiClient: api,
    enableAudioOutput: enableAudioOutput,
  );
  await controller.init();
  return controller;
}
