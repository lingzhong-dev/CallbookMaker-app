import 'dart:convert';
import 'dart:io';

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

  group('AudioMetronomeService cue compatibility & diagnostics', () {
    test('Android SoundPool cues preload cached WAV DeviceFileSource before first beat and never stall on seek', () async {
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        useLowLatencyCuesOverride: true,
        onTimeUpdate: (_) {},
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await service.init();

      expect(service.areCuesReady, isTrue);
      expect(service.lastCueError, isNull);
      expect(audioHarness.cuePlayerIds.length, 3);

      for (final kind in CueKind.values) {
        final diag = service.cueDiagnostic(kind);
        expect(diag.status, CueStatus.ready);
        expect(diag.cachedFilePath, isNotNull);
        final file = File(diag.cachedFilePath!);
        expect(file.existsSync(), isTrue);
        final bytes = file.readAsBytesSync();
        expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
        expect(ascii.decode(bytes.sublist(8, 12)), 'WAVE');
      }

      for (final cueId in audioHarness.cuePlayerIds) {
        expect(
          audioHarness.playerModeFor(cueId),
          PlayerMode.lowLatency.toString(),
        );
        expect(
          audioHarness.releaseModeFor(cueId),
          ReleaseMode.stop.toString(),
        );
      }

      // No BytesSource used on SoundPool, and cues are already loaded before first trigger.
      expect(audioHarness.calls.where((c) => c.method == 'setSourceBytes'), isEmpty);
      expect(
        audioHarness.calls
            .where((c) => c.method == 'setSourceUrl' && audioHarness.cuePlayerIds.contains(c.playerId))
            .length,
        3,
      );

      audioHarness.calls.clear();

      // Trigger first beat & rapid consecutive triggers for accent, sub, and GT alert.
      for (var i = 0; i < 6; i++) {
        await service.testMetronomeClick(accent: true);
        await service.testMetronomeClick(accent: false);
        await service.testGtAlertBeep();
      }

      expect(
        audioHarness.calls.where((c) => c.method == 'setSourceUrl'),
        isEmpty,
      );
      expect(
        audioHarness.calls.where((c) => c.method == 'seek'),
        isEmpty,
      );
      expect(
        audioHarness.calls.where((c) => c.method == 'getCurrentPosition'),
        isEmpty,
      );
      expect(audioHarness.ignoredLowLatencyResumes, 0);
      expect(audioHarness.lowLatencyPlayStarts, 18);
      expect(service.cueDiagnostic(CueKind.accent).playCount, 6);
      expect(service.cueDiagnostic(CueKind.sub).playCount, 6);
      expect(service.cueDiagnostic(CueKind.alert).playCount, 6);

      // Verify first-beat & GT alert clock scheduling triggers preloaded cues without stalling.
      final beatEvents = <BeatSnapshot>[];
      final gtEvents = <String>[];
      final clockService = AudioMetronomeService(
        enablePlatformAudio: true,
        useLowLatencyCuesOverride: true,
        onTimeUpdate: (_) {},
        onBeatTrigger: beatEvents.add,
        onGtAlertBeep: gtEvents.add,
      );
      await clockService.init();
      clockService.configure(
        bpm: 120,
        beatsPerBar: 4,
        offsetMs: 0,
        metronomeEnabled: true,
        metronomeVolume: 1.0,
        gtBeepEnabled: true,
        playbackRate: 1.0,
      );
      clockService.setAlerts(const [
        (id: 'gt-1', triggerTimeMs: 500, leadBeats: 1),
      ]);
      expect(await clockService.play(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 620));
      await clockService.pause();
      expect(beatEvents, isNotEmpty);
      expect(beatEvents.first.beatInBar, 1);
      expect(gtEvents, contains('gt-1'));
      expect(clockService.cueDiagnostic(CueKind.accent).playCount, greaterThanOrEqualTo(1));
      expect(clockService.cueDiagnostic(CueKind.sub).playCount, greaterThanOrEqualTo(1));
      expect(clockService.cueDiagnostic(CueKind.alert).playCount, 1);

      await clockService.dispose();
      await service.dispose();
    });

    test('Windows/standard mediaPlayer cues preload DeviceFileSource and never stall even without seekComplete', () async {
      audioHarness.autoCompleteSeek = false;
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        useLowLatencyCuesOverride: false,
        onTimeUpdate: (_) {},
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await service.init();

      expect(service.areCuesReady, isTrue);
      for (final cueId in audioHarness.cuePlayerIds) {
        expect(
          audioHarness.playerModeFor(cueId),
          PlayerMode.mediaPlayer.toString(),
        );
        expect(
          audioHarness.releaseModeFor(cueId),
          ReleaseMode.stop.toString(),
        );
      }

      // Rapid triggers while playing, then natural completion + trigger again.
      await service.testMetronomeClick(accent: true);
      await service.testMetronomeClick(accent: true);
      final accentCueId = audioHarness.cuePlayerIds.firstWhere(
        (id) => id.contains('accent'),
      );
      audioHarness.emitPlayerComplete(accentCueId);
      await Future<void>.delayed(Duration.zero);
      await service.testMetronomeClick(accent: true);

      expect(service.cueDiagnostic(CueKind.accent).playCount, 3);
      expect(
        audioHarness.calls.where(
          (c) => c.method == 'seek' && audioHarness.cuePlayerIds.contains(c.playerId),
        ),
        isEmpty,
      );

      await service.dispose();
    });

    test('cue load and playback failures expose observable diagnostic state and logs', () async {
      final logs = <String>[];
      final failingService = AudioMetronomeService(
        enablePlatformAudio: true,
        useLowLatencyCuesOverride: true,
        tempDirProvider: () async =>
            throw const FileSystemException('Temp dir unavailable'),
        onDiagnosticLog: logs.add,
        onTimeUpdate: (_) {},
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await failingService.init();

      expect(failingService.areCuesReady, isFalse);
      expect(failingService.lastCueError, contains('Temp dir unavailable'));
      expect(logs.any((m) => m.contains('Cue preload failed')), isTrue);
      for (final kind in CueKind.values) {
        final diag = failingService.cueDiagnostic(kind);
        expect(diag.status, CueStatus.failed);
        expect(diag.failureCount, greaterThanOrEqualTo(1));
        expect(diag.lastError, contains('Temp dir unavailable'));
      }
      await failingService.dispose();

      // Also verify runtime cue playback failure is recorded and recoverable.
      final runtimeLogs = <String>[];
      final runtimeService = AudioMetronomeService(
        enablePlatformAudio: true,
        useLowLatencyCuesOverride: true,
        onDiagnosticLog: runtimeLogs.add,
        onTimeUpdate: (_) {},
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await runtimeService.init();
      expect(runtimeService.areCuesReady, isTrue);

      final accentId = audioHarness.cuePlayerIds.lastWhere(
        (id) => id.contains('accent'),
      );
      audioHarness.throwOnResumePlayerIds.add(accentId);
      await runtimeService.testMetronomeClick(accent: true);

      final failedDiag = runtimeService.cueDiagnostic(CueKind.accent);
      expect(failedDiag.status, CueStatus.failed);
      expect(failedDiag.failureCount, 1);
      expect(failedDiag.lastError, contains('PLAY_FAILED'));
      expect(runtimeLogs.any((m) => m.contains('Cue playback failed (accent)')), isTrue);

      // Clear injected failure and verify recovery succeeds on next trigger.
      audioHarness.throwOnResumePlayerIds.remove(accentId);
      await runtimeService.testMetronomeClick(accent: true);
      final recoveredDiag = runtimeService.cueDiagnostic(CueKind.accent);
      expect(recoveredDiag.status, CueStatus.ready);
      expect(recoveredDiag.playCount, 1);
      expect(recoveredDiag.lastError, isNull);

      await runtimeService.dispose();
    });
  });

  group('AudioMetronomeService EOF replay, near-EOF pause, seek coalescing, and recovery', () {
    test('music player configures ReleaseMode.stop before source load and replays local & remote tracks 3 consecutive times after natural EOF', () async {
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        onTimeUpdate: (_) {},
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await service.init();

      // 1) Local track: 3 consecutive natural EOF replays without reloading source.
      await service.setAudioSource(
        localPath: '/tmp/local_song.mp3',
        fallbackDurationMs: 30000,
      );
      final localMusicId = audioHarness.activeMusicPlayerId!;
      final initCalls = audioHarness.calls
          .where((c) => c.playerId == localMusicId)
          .map((c) => c.method)
          .toList();
      expect(
        initCalls.indexOf('setReleaseMode'),
        lessThan(initCalls.indexOf('setSourceUrl')),
      );
      expect(
        audioHarness.releaseModeFor(localMusicId),
        ReleaseMode.stop.toString(),
      );

      for (var round = 0; round < 3; round++) {
        expect(await service.play(), isTrue);
        expect(service.isPlaying, isTrue);
        audioHarness.mockMusicPositionMs = 29950;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        audioHarness.emitPlayerComplete(localMusicId);
        await Future<void>.delayed(Duration.zero);
        expect(service.isPlaying, isFalse);
        expect(service.hasCompleted, isTrue);
      }

      // Final replay after 3rd EOF starts cleanly from 0 without reloading source.
      expect(await service.play(), isTrue);
      expect(service.currentTimeMs, 0);
      expect(service.hasCompleted, isFalse);
      final localSourceLoads = audioHarness.calls
          .where(
            (c) => c.playerId == localMusicId && c.method == 'setSourceUrl',
          )
          .length;
      expect(localSourceLoads, 1);

      // 2) Remote track: 3 consecutive natural EOF replays reuse retained UrlSource without re-fetching URL.
      audioHarness.calls.clear();
      await service.setAudioSource(
        url: 'https://cdn.example.com/remote_song.mp3',
        fallbackDurationMs: 42000,
      );
      final remoteMusicId = audioHarness.activeMusicPlayerId!;
      expect(remoteMusicId, isNot(localMusicId));
      expect(
        audioHarness.releaseModeFor(remoteMusicId),
        ReleaseMode.stop.toString(),
      );

      for (var round = 0; round < 3; round++) {
        expect(await service.play(), isTrue);
        expect(service.currentTimeMs, 0);
        audioHarness.mockMusicPositionMs = 41950;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        audioHarness.emitPlayerComplete(remoteMusicId);
        await Future<void>.delayed(Duration.zero);
        expect(service.isPlaying, isFalse);
        expect(service.hasCompleted, isTrue);
      }

      expect(await service.play(), isTrue);
      expect(service.currentTimeMs, 0);
      final remoteSourceLoads = audioHarness.calls
          .where(
            (c) =>
                c.method == 'setSourceUrl' &&
                c.arguments['url'] == 'https://cdn.example.com/remote_song.mp3',
          )
          .length;
      expect(remoteSourceLoads, 1);

      await service.dispose();
    });

    test('source-released recovery on natural EOF reloads cached source safely and guards stale source tokens', () async {
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        onTimeUpdate: (_) {},
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await service.init();

      await service.setAudioSource(
        url: 'https://cdn.example.com/released_eof.mp3',
        fallbackDurationMs: 36000,
      );

      // Simulate 3 consecutive EOFs where native unexpectedly released the source.
      for (var round = 0; round < 3; round++) {
        expect(await service.play(), isTrue);
        final activeId = audioHarness.activeMusicPlayerId!;
        audioHarness.emitPlayerComplete(activeId, simulateSourceRelease: true);
        await Future<void>.delayed(Duration.zero);
        expect(service.hasCompleted, isTrue);
        expect(audioHarness.isPlayerReleased(activeId), isTrue);
      }
      expect(await service.play(), isTrue);
      expect(service.isPlaying, isTrue);
      expect(service.currentTimeMs, 0);

      // Guard stale async recovery against source switch.
      final beforeSwitchId = audioHarness.activeMusicPlayerId!;
      audioHarness.emitPlayerComplete(beforeSwitchId, simulateSourceRelease: true);
      await Future<void>.delayed(Duration.zero);
      audioHarness.autoCompletePrepared = false;
      final stalePlayFuture = service.play();
      await Future<void>.delayed(Duration.zero);

      // Switch to another track before stale recovery completes preparation.
      audioHarness.autoCompletePrepared = true;
      await service.setAudioSource(
        localPath: '/tmp/new_track.mp3',
        fallbackDurationMs: 22000,
      );
      final newMusicId = audioHarness.activeMusicPlayerId!;
      // Unblock old prepared channel if still listening.
      for (final id in audioHarness.musicPlayerIds) {
        if (id != newMusicId) {
          audioHarness.emitPrepared(id, true);
        }
      }
      expect(await stalePlayFuture, isFalse);
      expect(service.durationMs, 22000);
      expect(audioHarness.sourceUrlFor(newMusicId), '/tmp/new_track.mp3');

      await service.dispose();
    });

    test('pausing within last 100ms before EOF and resuming continues from pause position instead of 00:00', () async {
      final observedTimes = <int>[];
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        onTimeUpdate: observedTimes.add,
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await service.init();
      await service.setAudioSource(
        localPath: '/tmp/tail_pause.mp3',
        fallbackDurationMs: 25000,
      );

      expect(await service.play(), isTrue);
      await service.seek(24930); // 70ms before EOF
      audioHarness.mockMusicPositionMs = 24930;
      await service.pause();
      expect(service.isPlaying, isFalse);
      expect(service.hasCompleted, isFalse);
      expect(service.currentTimeMs, 24930);

      observedTimes.clear();
      audioHarness.calls.clear();
      expect(await service.play(), isTrue);
      expect(service.isPlaying, isTrue);
      expect(service.currentTimeMs, 24930);
      expect(observedTimes.contains(0), isFalse);
      expect(
        audioHarness.calls.any(
          (c) => c.method == 'seek' && c.arguments['position'] == 0,
        ),
        isFalse,
      );

      await service.dispose();
    });

    test('seeking to middle after natural EOF clears completed state and plays from seek target', () async {
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        onTimeUpdate: (_) {},
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await service.init();
      await service.setAudioSource(
        localPath: '/tmp/seek_after_eof.mp3',
        fallbackDurationMs: 40000,
      );

      expect(await service.play(), isTrue);
      final musicId = audioHarness.activeMusicPlayerId!;
      audioHarness.emitPlayerComplete(musicId);
      await Future<void>.delayed(Duration.zero);
      expect(service.hasCompleted, isTrue);
      expect(service.isPlaying, isFalse);

      await service.seek(18500);
      expect(service.hasCompleted, isFalse);
      expect(service.currentTimeMs, 18500);

      audioHarness.calls.clear();
      expect(await service.play(), isTrue);
      expect(service.currentTimeMs, 18500);
      expect(
        audioHarness.calls.any(
          (c) => c.method == 'seek' && c.arguments['position'] == 0,
        ),
        isFalse,
      );

      // Also verify seek-to-middle after source-released EOF recovers and plays at 18500.
      audioHarness.emitPlayerComplete(
        audioHarness.activeMusicPlayerId!,
        simulateSourceRelease: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(service.hasCompleted, isTrue);
      await service.seek(18500);
      expect(service.hasCompleted, isFalse);
      expect(await service.play(), isTrue);
      expect(service.currentTimeMs, 18500);

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

    test('rapid source switches recreate player cleanly and watchdog recovers stalled stream', () async {
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

      // Watchdog polls getCurrentPosition() when onPositionChanged stalls >= 320ms
      expect(await service.play(), isTrue);
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
