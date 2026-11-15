import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_call_studio/services/audio_metronome_service.dart';

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
  });
}
