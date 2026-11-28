import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/services/audio_metronome_service.dart';
import 'package:live_call_studio/services/project_storage.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/ui/dashboard_view.dart';
import 'package:live_call_studio/ui/more_view.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mock_audioplayers_harness.dart';

class _FakeMonotonicClock implements MonotonicClock {
  int _elapsedUs = 0;
  bool _running = false;

  @override
  int get elapsedMicroseconds => _elapsedUs;

  @override
  void start() {
    _running = true;
  }

  @override
  void stop() {
    _running = false;
  }

  @override
  void reset() {
    _elapsedUs = 0;
  }

  void advanceMs(int ms) {
    if (_running) {
      _elapsedUs += ms * 1000;
    }
  }
}

Widget _wrapWithPrism({
  required CallbookController controller,
  required Widget child,
}) {
  return AnimatedBuilder(
    animation: controller,
    builder: (context, _) => prism.PrismApp(
      title: 'Step 03 Test',
      theme: controller.buildPrismTheme(Brightness.light),
      darkTheme: controller.buildPrismTheme(Brightness.dark),
      themeMode: controller.themeMode,
      home: prism.BottomInsetScope(inset: 24, child: child),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockAudioplayersHarness audioHarness;

  setUp(() {
    audioHarness = MockAudioplayersHarness()..install();
  });

  group('Step 03 AudioMetronomeService clock, seek, compensation & tap tests', () {
    test('seek(0), exact-beat seek, and mid-beat seek preserve first audible beat without double firing', () async {
      final clock = _FakeMonotonicClock();
      final beats = <BeatSnapshot>[];
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        clock: clock,
        onTimeUpdate: (_) {},
        onBeatTrigger: beats.add,
        onGtAlertBeep: (_) {},
      );
      await service.init();
      service.configure(
        bpm: 120,
        beatsPerBar: 4,
        offsetMs: 0,
        cueOutputCompensationMs: 0,
        metronomeEnabled: true,
        metronomeVolume: 1.0,
        gtBeepEnabled: false,
        playbackRate: 1.0,
      );

      // 1) seek(0) updates display beat without consuming audio beat 0.
      await service.seek(0);
      expect(beats.length, 1);
      expect(beats.last.beatIndex, 0);
      expect(service.cueDiagnostic(CueKind.accent).playCount, 0);

      expect(await service.play(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(service.cueDiagnostic(CueKind.accent).playCount, 1);
      expect(beats.length, 1);

      // Pausing after beat 0 and resuming at 20ms must not double-fire beat 0.
      clock.advanceMs(20);
      await service.pause();
      expect(await service.play(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(service.cueDiagnostic(CueKind.accent).playCount, 1);
      await service.pause();

      // 2) seek to exact beat 1 (500ms at 120 BPM) triggers beat 1 immediately on play().
      await service.seek(500);
      expect(beats.last.beatIndex, 1);
      final subBefore = service.cueDiagnostic(CueKind.sub).playCount;
      expect(await service.play(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(service.cueDiagnostic(CueKind.sub).playCount, subBefore + 1);
      await service.pause();

      // 3) seek to mid-beat (250ms) skips late beat 0, then fires beat 1 at 500ms.
      await service.seek(250);
      final accentMidBefore = service.cueDiagnostic(CueKind.accent).playCount;
      final subMidBefore = service.cueDiagnostic(CueKind.sub).playCount;
      expect(await service.play(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(service.cueDiagnostic(CueKind.accent).playCount, accentMidBefore);
      clock.advanceMs(250);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(service.cueDiagnostic(CueKind.sub).playCount, subMidBefore + 1);

      await service.pause();
      await service.dispose();
    });

    test('monotonic interpolation and cue output compensation scale with 0.5x/1.0x/2.0x without shifting playhead', () async {
      final clock = _FakeMonotonicClock();
      final reportedTimes = <int>[];
      final displayBeats = <BeatSnapshot>[];
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        clock: clock,
        onTimeUpdate: reportedTimes.add,
        onBeatTrigger: displayBeats.add,
        onGtAlertBeep: (_) {},
      );
      await service.init();
      await service.setAudioSource(
        localPath: '/tmp/rate_comp.mp3',
        fallbackDurationMs: 60000,
      );

      // +40ms cue output compensation at 2.0x => 80ms media lead for cues only.
      service.configure(
        bpm: 120,
        beatsPerBar: 4,
        offsetMs: 0,
        cueOutputCompensationMs: 40,
        metronomeEnabled: true,
        metronomeVolume: 1.0,
        gtBeepEnabled: false,
        playbackRate: 2.0,
      );

      await service.seek(0);
      displayBeats.clear();
      reportedTimes.clear();
      expect(await service.play(), isTrue);
      await Future<void>.delayed(Duration.zero);
      final subAtStart = service.cueDiagnostic(CueKind.sub).playCount;

      // Advance 210ms real time at 2.0x => media time 420ms; cueSchedule = 420 + 80 = 500ms (beat 1!).
      // Confirm via external position callback at 420ms: cue fires early while display/playhead stay at 420ms.
      clock.advanceMs(210);
      audioHarness.mockMusicPositionMs = 420;
      service.debugHandleExternalPositionMs(420);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(service.currentTimeMs, 420);
      expect(reportedTimes.last, 420);
      expect(service.cueDiagnostic(CueKind.sub).playCount, subAtStart + 1);
      expect(displayBeats, isEmpty);

      // At 500ms media time, display beat 1 fires without double-firing sub cue audio.
      clock.advanceMs(40);
      audioHarness.mockMusicPositionMs = 500;
      service.debugHandleExternalPositionMs(500);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(displayBeats.map((b) => b.beatIndex), [1]);
      expect(service.cueDiagnostic(CueKind.sub).playCount, subAtStart + 1);

      // Switch to 0.5x => mediaLeadMs = 20ms, interpolation advances at half speed.
      service.configure(
        bpm: 120,
        beatsPerBar: 4,
        offsetMs: 0,
        cueOutputCompensationMs: 40,
        metronomeEnabled: true,
        metronomeVolume: 1.0,
        gtBeepEnabled: false,
        playbackRate: 0.5,
      );
      await service.pause();
      await service.seek(900);
      expect(await service.play(), isTrue);
      await Future<void>.delayed(Duration.zero);
      final beat2SubBefore = service.cueDiagnostic(CueKind.sub).playCount;
      // 160ms real at 0.5x = 80ms media => 980ms (+20ms lead = 1000ms = beat 2!).
      clock.advanceMs(160);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(service.currentTimeMs, 980);
      expect(service.cueDiagnostic(CueKind.sub).playCount, beat2SubBefore + 1);

      await service.pause();
      await service.dispose();
    });

    test('callback stall, jitter, out-of-order position, and app resume never burst expired beats or extrapolate unboundedly', () async {
      final clock = _FakeMonotonicClock();
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        clock: clock,
        onTimeUpdate: (_) {},
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await service.init();
      await service.setAudioSource(
        localPath: '/tmp/stall_jitter.mp3',
        fallbackDurationMs: 60000,
      );
      service.configure(
        bpm: 120,
        beatsPerBar: 4,
        offsetMs: 0,
        cueOutputCompensationMs: 0,
        metronomeEnabled: true,
        metronomeVolume: 1.0,
        gtBeepEnabled: false,
        playbackRate: 1.0,
      );

      await service.seek(0);
      expect(await service.play(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(service.cueDiagnostic(CueKind.accent).playCount, 1);

      // 1) Stall without advancing player position for 1000ms => capped at maxBufferExtrapolationMs (350ms).
      clock.advanceMs(1000);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(service.currentTimeMs, AudioMetronomeService.maxBufferExtrapolationMs);
      expect(service.cueDiagnostic(CueKind.sub).playCount, 0);

      // 2) Out-of-order backward callback is ignored and never replays beat 0.
      service.debugHandleExternalPositionMs(300);
      await Future<void>.delayed(Duration.zero);
      expect(service.currentTimeMs, AudioMetronomeService.maxBufferExtrapolationMs);
      expect(service.cueDiagnostic(CueKind.accent).playCount, 1);

      // 3) Large jump after stall straight to 1900ms (crossing beats 1, 2, 3) must NOT burst expired beats.
      service.debugHandleExternalPositionMs(1900);
      await Future<void>.delayed(Duration.zero);
      expect(service.currentTimeMs, 1900);
      expect(service.cueDiagnostic(CueKind.sub).playCount, 0);
      expect(service.cueDiagnostic(CueKind.accent).playCount, 1);

      // Next beat (beat 4 at 2000ms) resumes normally.
      clock.advanceMs(100);
      service.debugHandleExternalPositionMs(2000);
      await Future<void>.delayed(Duration.zero);
      expect(service.cueDiagnostic(CueKind.accent).playCount, 2);

      // 4) Background resume rebuilds anchor cleanly from player position without bursting or re-firing beats.
      audioHarness.mockMusicPositionMs = 2400;
      clock.advanceMs(5000);
      await service.onAppResumed();
      expect(service.currentTimeMs, 2400);
      expect(service.cueDiagnostic(CueKind.sub).playCount, 0);

      await service.pause();
      await service.dispose();
    });

    test('changing offsetMs (set beat 1 at t=20s) or lowering BPM while playing resyncs beat grid immediately without silence', () async {
      final clock = _FakeMonotonicClock();
      final beats = <BeatSnapshot>[];
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        clock: clock,
        onTimeUpdate: (_) {},
        onBeatTrigger: beats.add,
        onGtAlertBeep: (_) {},
      );
      await service.init();
      service.configure(
        bpm: 120,
        beatsPerBar: 4,
        offsetMs: 0,
        cueOutputCompensationMs: 0,
        metronomeEnabled: true,
        metronomeVolume: 1.0,
        gtBeepEnabled: false,
        playbackRate: 1.0,
      );

      // Advance synthetic playback to t=20000ms (beatIndex=40 at 120 BPM).
      await service.seek(20000);
      expect(await service.play(), isTrue);
      await Future<void>.delayed(Duration.zero);
      final accentBefore = service.cueDiagnostic(CueKind.accent).playCount;
      final subBefore = service.cueDiagnostic(CueKind.sub).playCount;

      // Simulate setting current time (20000ms) as beat 1 (offsetMs=20000): beat 0 must fire immediately and beat 1 at 20500ms.
      beats.clear();
      service.configure(
        bpm: 120,
        beatsPerBar: 4,
        offsetMs: 20000,
        cueOutputCompensationMs: 0,
        metronomeEnabled: true,
        metronomeVolume: 1.0,
        gtBeepEnabled: false,
        playbackRate: 1.0,
      );
      await Future<void>.delayed(Duration.zero);
      expect(beats.last.beatIndex, 0);
      expect(beats.last.beatInBar, 1);
      expect(service.cueDiagnostic(CueKind.accent).playCount, accentBefore + 1);

      clock.advanceMs(500);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(beats.last.beatIndex, 1);
      expect(service.cueDiagnostic(CueKind.sub).playCount, subBefore + 1);

      // Lowering BPM from 120 to 60 at t=20500ms (mid-beat on new 1000ms grid: beat 0, 500ms past) must fire beat 1 at 21000ms without silence.
      service.configure(
        bpm: 60,
        beatsPerBar: 4,
        offsetMs: 20000,
        cueOutputCompensationMs: 0,
        metronomeEnabled: true,
        metronomeVolume: 1.0,
        gtBeepEnabled: false,
        playbackRate: 1.0,
      );
      clock.advanceMs(500);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(service.cueDiagnostic(CueKind.sub).playCount, subBefore + 2);

      await service.pause();
      await service.dispose();
    });

    test('Tap Tempo accumulates 1..3 taps, outputs outlier-filtered candidate at 4th tap without overwriting BPM, and clears on seek/rate/source', () async {
      final clock = _FakeMonotonicClock();
      final service = AudioMetronomeService(
        enablePlatformAudio: true,
        clock: clock,
        onTimeUpdate: (_) {},
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      await service.init();

      // Taps 1..3 return null.
      expect(service.recordTapSample(), isNull);
      expect(service.tapSampleCount, 1);
      clock.advanceMs(500);
      expect(service.recordTapSample(), isNull);
      clock.advanceMs(500);
      expect(service.recordTapSample(), isNull);
      expect(service.tapSampleCount, 3);

      // Tap 4 returns ~120 BPM candidate with confidence.
      clock.advanceMs(500);
      final c4 = service.recordTapSample();
      expect(c4, isNotNull);
      expect(c4!.bpm, 120);
      expect(c4.confidence, greaterThan(0.5));

      // Inject an outlier short tap (200ms) then steady 500ms taps -> outlier filtered out.
      clock.advanceMs(200);
      final withOutlier = service.recordTapSample();
      expect(withOutlier, isNotNull);
      expect(withOutlier!.bpm, 120);
      expect(withOutlier.confidence, lessThan(c4.confidence));

      // Seek, playbackRate change, and source switch all clear tap samples.
      await service.seek(1000);
      expect(service.tapSampleCount, 0);

      expect(service.recordTapSample(), isNull);
      expect(service.tapSampleCount, 1);
      service.configure(
        bpm: 120,
        beatsPerBar: 4,
        offsetMs: 0,
        metronomeEnabled: true,
        metronomeVolume: 1.0,
        gtBeepEnabled: false,
        playbackRate: 1.25,
      );
      expect(service.tapSampleCount, 0);

      expect(service.recordTapSample(), isNull);
      await service.setAudioSource(fallbackDurationMs: 48000);
      expect(service.tapSampleCount, 0);

      await service.dispose();
    });

    test('offsetMs bounds clamp uniformly across models, controller, JSON import, and archives, independent of cue compensation', () async {
      final badMeta = CallProjectMeta.fromJson({
        'title': 'Bounds Song',
        'bpm': 160,
        'offsetMs': 250000,
      });
      expect(badMeta.offsetMs, kMaxSongOffsetMs);
      final negMeta = CallProjectMeta.fromJson({
        'title': 'Neg Bounds Song',
        'bpm': 160,
        'offsetMs': -250000,
      });
      expect(negMeta.offsetMs, kMinSongOffsetMs);

      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      try {
        controller.setOffset(999999);
        expect(controller.project.meta.offsetMs, kMaxSongOffsetMs);
        controller.adjustOffset(-500000);
        expect(controller.project.meta.offsetMs, kMinSongOffsetMs);

        // Device cue compensation persists separately and survives resetTheme().
        controller.setOffset(120);
        controller.setCueOutputCompensationMs(350);
        expect(controller.cueOutputCompensationMs, kMaxCueOutputCompensationMs);
        controller.setCueOutputCompensationMs(-45);
        expect(controller.cueOutputCompensationMs, -45);
        expect(controller.project.meta.offsetMs, 120);

        controller.resetTheme();
        expect(controller.cueOutputCompensationMs, -45);
        expect(await ProjectStorage().loadCueOutputCompensationMs(), -45);

        // Importing JSON with out-of-range offsetMs clamps cleanly.
        final imported = await controller.importProjectJson(
          jsonEncode({
            'meta': {'title': 'Imported', 'bpm': 140, 'offsetMs': -999999},
            'lines': [
              {
                'id': 'l1',
                'startTimeMs': 1000,
                'endTimeMs': 4000,
                'text': {'original': 'Line'},
              },
            ],
          }),
        );
        expect(imported, isTrue);
        expect(controller.project.meta.offsetMs, kMinSongOffsetMs);

        // Paused lock-BPM mode forbids inferring downbeat from frozen trackMs.
        await controller.seek(3500);
        controller.setOffset(0);
        controller.setLockBpmCalibrateDownbeat(true);
        controller.tapTempo();
        expect(controller.project.meta.offsetMs, 0);
        expect(controller.statusMessage, contains('已暂停'));
      } finally {
        controller.dispose();
      }
    });
  });

  group('Step 03 Dashboard & MoreView Alignment UI', () {
    testWidgets(
      'DashboardView Tap candidate bar, lock BPM mode, set-beat-1, ±half-beat, and ms fine-tune work without overflow',
      (tester) async {
        SharedPreferences.setMockInitialValues(const {
          'live_call_studio_onboarding_v1': true,
        });
        final clock = _FakeMonotonicClock();
        final controller = CallbookController(
          enableAudioOutput: false,
          audioClock: clock,
        );
        await controller.init();
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        try {
          await tester.pumpWidget(
            _wrapWithPrism(
              controller: controller,
              child: DashboardView(controller: controller),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);

          final initialBpm = controller.project.meta.bpm;
          // Tap 4 times at 400ms (150 BPM) -> candidate appears, BPM not overwritten yet.
          for (var i = 0; i < 4; i++) {
            await tester.ensureVisible(find.text('Tap'));
            await tester.tap(find.text('Tap'));
            await tester.pump();
            if (i < 3) {
              clock.advanceMs(400);
            }
          }
          expect(controller.project.meta.bpm, initialBpm);
          expect(find.text('应用 BPM'), findsOneWidget);
          expect(find.textContaining('150 BPM'), findsOneWidget);
          expect(find.textContaining('置信度'), findsOneWidget);

          // Seeking clears active Tap candidate & hides the candidate bar via alignmentListenable.
          await controller.seek(500);
          await tester.pump();
          expect(controller.tapBpmCandidate, isNull);
          expect(find.text('应用 BPM'), findsNothing);

          // Re-tap 4 times at 400ms (150 BPM) and apply candidate.
          for (var i = 0; i < 4; i++) {
            await tester.ensureVisible(find.text('Tap'));
            await tester.tap(find.text('Tap'));
            await tester.pump();
            if (i < 3) {
              clock.advanceMs(400);
            }
          }
          expect(find.text('应用 BPM'), findsOneWidget);

          await tester.ensureVisible(find.text('应用 BPM'));
          await tester.tap(find.text('应用 BPM'));
          await tester.pump();
          expect(controller.project.meta.bpm, 150);
          expect(find.text('应用 BPM'), findsNothing);

          // Expand offset tools and exercise controls.
          await tester.ensureVisible(find.textContaining('首拍 '));
          await tester.tap(find.textContaining('首拍 '));
          await tester.pump();
          expect(find.text('设当前为第 1 拍'), findsOneWidget);
          expect(find.text('锁定 BPM 仅校准首拍'), findsOneWidget);
          expect(find.text('−半拍'), findsOneWidget);
          expect(find.text('+半拍'), findsOneWidget);

          await controller.seek(1234);
          await tester.ensureVisible(find.text('设当前为第 1 拍'));
          await tester.tap(find.text('设当前为第 1 拍'));
          await tester.pump();
          expect(controller.project.meta.offsetMs, 1234);

          await tester.ensureVisible(find.text('+1'));
          await tester.tap(find.text('+1'));
          await tester.pump();
          expect(controller.project.meta.offsetMs, 1235);

          await tester.ensureVisible(find.text('−半拍'));
          await tester.tap(find.text('−半拍'));
          await tester.pump();
          final expectedHalfBeat =
              (30000.0 / controller.project.meta.bpm).round();
          expect(controller.project.meta.offsetMs, 1235 - expectedHalfBeat);

          // Enable BPM lock and verify '-' button does not alter BPM.
          final lockedBpm = controller.project.meta.bpm;
          await tester.ensureVisible(find.text('锁定 BPM 仅校准首拍'));
          await tester.tap(find.text('锁定 BPM 仅校准首拍'));
          await tester.pump();
          expect(controller.lockBpmCalibrateDownbeat, isTrue);
          expect(find.text('已锁定'), findsOneWidget);

          await tester.ensureVisible(find.text('−'));
          await tester.tap(find.text('−'));
          await tester.pump();
          expect(controller.project.meta.bpm, lockedBpm);
          expect(tester.takeException(), isNull);
        } finally {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          controller.dispose();
        }
      },
    );

    testWidgets(
      'MoreView hosts device cue output compensation control, persists values, and leaves song offsetMs untouched',
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        controller.setOffset(320);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        try {
          await tester.pumpWidget(
            _wrapWithPrism(
              controller: controller,
              child: MoreView(controller: controller),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);

          expect(find.text('音频与节拍器'), findsOneWidget);
          expect(find.textContaining('提示音输出补偿 (ms)'), findsOneWidget);
          expect(find.text('0ms'), findsOneWidget);

          await tester.ensureVisible(find.text('+10ms'));
          await tester.tap(find.text('+10ms'));
          await tester.pump();
          await tester.tap(find.text('+1ms'));
          await tester.pump();

          expect(controller.cueOutputCompensationMs, 11);
          expect(controller.project.meta.offsetMs, 320);
          expect(find.text('+11ms'), findsOneWidget);
          expect(await ProjectStorage().loadCueOutputCompensationMs(), 11);

          await tester.tap(find.text('归零'));
          await tester.pump();
          expect(controller.cueOutputCompensationMs, 0);
          expect(await ProjectStorage().loadCueOutputCompensationMs(), 0);
          expect(tester.takeException(), isNull);
        } finally {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          controller.dispose();
        }
      },
    );
  });
}
