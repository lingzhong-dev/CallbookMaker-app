import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/services/api_client.dart';
import 'package:live_call_studio/services/audio_metronome_service.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mock_audioplayers_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockAudioplayersHarness audioHarness;

  setUp(() {
    audioHarness = MockAudioplayersHarness()..install();
  });

  group('AudioMetronomeService buffer reuse, seek coalescing, and error recovery', () {
    test('low-latency click buffers call setSourceBytes once, reuse resume(), and never poll position', () async {
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        onTimeUpdate: (_) {},
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await service.init();

      final setModes =
          audioHarness.calls.where((c) => c.method == 'setPlayerMode');
      final setReleases =
          audioHarness.calls.where((c) => c.method == 'setReleaseMode');
      expect(
        setModes
            .where((c) => c.arguments['playerMode'] == PlayerMode.lowLatency.toString())
            .length,
        3,
      );
      expect(
        setReleases
            .where((c) => c.arguments['releaseMode'] == ReleaseMode.stop.toString())
            .length,
        3,
      );

      audioHarness.calls.clear();
      await service.testMetronomeClick(accent: true);
      await service.testMetronomeClick(accent: true);
      await service.testMetronomeClick(accent: true);

      final byteSources =
          audioHarness.calls.where((c) => c.method == 'setSourceBytes').length;
      final resumes =
          audioHarness.calls.where((c) => c.method == 'resume').length;
      final posPolls =
          audioHarness.calls.where((c) => c.method == 'getCurrentPosition').length;
      expect(byteSources, 1);
      expect(resumes, 3);
      expect(posPolls, 0);

      await service.dispose();
    });

    test('rapid seek() coalesces intermediate targets while updating clock immediately', () async {
      final observedTimes = <int>[];
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        onTimeUpdate: observedTimes.add,
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await service.init();
      await service.setAudioSource(
        url: 'https://example.com/track.mp3',
        fallbackDurationMs: 60000,
      );

      observedTimes.clear();
      audioHarness.calls.clear();
      audioHarness.autoCompleteSeek = false;

      final f1 = service.seek(1000);
      final f2 = service.seek(2000);
      final f3 = service.seek(3000);
      final f4 = service.seek(4000);
      final f5 = service.seek(5000);

      expect(service.currentTimeMs, 5000);
      expect(observedTimes, [1000, 2000, 3000, 4000, 5000]);

      // Drain first seek, then final coalesced seek (5000).
      await Future<void>.delayed(Duration.zero);
      audioHarness.completeNextSeek();
      await Future<void>.delayed(Duration.zero);
      audioHarness.completeNextSeek();
      await Future.wait([f1, f2, f3, f4, f5]);

      final seekCalls = audioHarness.calls
          .where((c) => c.method == 'seek')
          .map((c) => c.arguments['position'])
          .toList();
      expect(seekCalls, [1000, 5000]);

      await service.dispose();
    });

    test('play() returns false and recovers cleanly if external player resume throws', () async {
      final controller = await createTestCallbookController(enableAudioOutput: true);
      try {
        audioHarness.throwOnMusicResume = true;
        await controller.loadLocalAudioFile('/tmp/fake.mp3', 'fake.mp3');
        await controller.togglePlay();

        expect(controller.isPlaying, isFalse);
        expect(controller.statusMessage, contains('音频播放失败'));
      } finally {
        controller.dispose();
      }
    });

    test('rapid source switches recreate player cleanly, EOF play seeks to 0, and watchdog recovers stalled stream', () async {
      final observedTimes = <int>[];
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        onTimeUpdate: observedTimes.add,
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await service.init();

      // Sequential and rapid switches between URL, local file, synthetic, and URL again
      await service.setAudioSource(
        url: 'https://example.com/one.mp3',
        fallbackDurationMs: 30000,
      );
      await Future.wait([
        service.setAudioSource(localPath: '/tmp/two.mp3', fallbackDurationMs: 40000),
        service.setAudioSource(fallbackDurationMs: 48000),
        service.setAudioSource(url: 'https://example.com/final.mp3', fallbackDurationMs: 25000),
      ]);
      expect(service.hasExternalAudio, isTrue);
      expect(service.durationMs, 25000);

      // Replaying near EOF rewinds to 0 before resume
      await service.seek(24900);
      audioHarness.calls.clear();
      expect(await service.play(), isTrue);
      expect(service.currentTimeMs, 0);
      expect(
        audioHarness.calls.any(
          (c) => c.method == 'seek' && c.arguments['position'] == 0,
        ),
        isTrue,
      );

      // Watchdog polls getCurrentPosition() when onPositionChanged stalls >= 320ms
      audioHarness.mockMusicPositionMs = 4321;
      await Future<void>.delayed(const Duration(milliseconds: 420));
      expect(service.currentTimeMs, 4321);

      await service.pause();
      await service.dispose();
    });

    test('CallbookController.init() restores saved local and remote audio sources on app relaunch', () async {
      const savedLocalProject = CallProject(
        meta: CallProjectMeta(
          title: 'Saved Local Song',
          artist: 'Artist',
          platform: 'local',
          audioUrl: '/tmp/saved_song.mp3',
          bpm: 170,
        ),
        lines: [
          LyricLine(
            id: 'l1',
            startTimeMs: 1000,
            endTimeMs: 5000,
            text: LyricText(original: 'Line 1'),
          ),
        ],
      );
      SharedPreferences.setMockInitialValues({
        'live_call_studio_project_v1': jsonEncode(savedLocalProject.toJson()),
      });
      final offlineApi = CallbookApiClient(
        baseUrl: 'http://127.0.0.1:8000',
        httpClient: MockClient((_) async => http.Response('offline', 503)),
      );
      final localController = CallbookController(
        apiClient: offlineApi,
        enableAudioOutput: true,
      );
      await localController.init();
      try {
        expect(localController.hasExternalAudio, isTrue);
        expect(
          audioHarness.calls.any(
            (c) =>
                c.method == 'setSourceUrl' &&
                c.arguments['url'] == '/tmp/saved_song.mp3' &&
                c.arguments['isLocal'] == true,
          ),
          isTrue,
        );
      } finally {
        localController.dispose();
      }

      // Also verify NetEase project with empty/expired audioUrl refreshes fresh stream URL on startup
      audioHarness.calls.clear();
      const savedNeteaseProject = CallProject(
        meta: CallProjectMeta(
          title: 'Saved Remote Song',
          artist: 'Miku',
          platform: 'netease',
          trackId: '998877',
          audioUrl: '',
          bpm: 175,
        ),
        lines: [
          LyricLine(
            id: 'n1',
            startTimeMs: 2000,
            endTimeMs: 8000,
            text: LyricText(original: 'Remote line'),
          ),
        ],
      );
      SharedPreferences.setMockInitialValues({
        'live_call_studio_project_v1': jsonEncode(savedNeteaseProject.toJson()),
      });
      final onlineApi = CallbookApiClient(
        baseUrl: 'http://127.0.0.1:8000',
        httpClient: MockClient((req) async {
          if (req.url.path == '/health') {
            return http.Response('{"status":"ok","providers":["netease"]}', 200);
          }
          if (req.url.path == '/api/track/netease/998877') {
            return http.Response(
              jsonEncode({
                'track': {
                  'id': '998877',
                  'title': 'Saved Remote Song',
                  'artist': 'Miku',
                  'platform': 'netease',
                  'durationMs': 180000,
                },
                'audioUrl': 'https://cdn.example.com/refreshed_998877.mp3',
                'rawLrc': '[00:02.00] Remote line',
                'translatedLrc': '',
                'lines': [],
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );
      final neteaseController = CallbookController(
        apiClient: onlineApi,
        enableAudioOutput: true,
      );
      await neteaseController.init();
      try {
        expect(neteaseController.hasExternalAudio, isTrue);
        expect(
          neteaseController.project.meta.audioUrl,
          'https://cdn.example.com/refreshed_998877.mp3',
        );
      } finally {
        neteaseController.dispose();
      }
    });
  });
}
