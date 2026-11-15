import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/state/callbook_controller.dart';

import 'support/mock_audioplayers_harness.dart';

Future<void> _disposeApp(
  WidgetTester tester,
  CallbookController controller,
) async {
  if (controller.isPlaying) {
    await controller.togglePlay();
  }
  await tester.pump(const Duration(milliseconds: 500));
  // LiveCallStudioApp.dispose() invokes controller.dispose() automatically.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockAudioplayersHarness audioHarness;

  setUp(() {
    audioHarness = MockAudioplayersHarness()..install();
  });

  group('Playback UI freeze & ThemeCrossFade regression suite', () {
    testWidgets(
      'Desktop external-audio playback frames do not rebuild PrismApp, ThemeCrossFade, HomeShell, DashboardView, TimelineEditorWidget, or idle line cards',
      timeout: const Timeout(Duration(seconds: 25)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: true,
        );
        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Load external audio track to exercise the real FramePositionUpdater +
        // AudioPlayer onPositionChanged playback path.
        await controller.loadLocalAudioFile('/tmp/fake.mp3', 'fake.mp3');
        expect(controller.project.meta.platform, 'local');

        // Start playback and settle initial 450ms orb/watermark morph transition.
        await controller.togglePlay();
        expect(controller.isPlaying, isTrue);
        await tester.pump(const Duration(milliseconds: 550));
        audioHarness.mockMusicPositionMs = 100;
        await controller.seek(100);
        await tester.pump();

        final prevRebuildHook = debugOnRebuildDirtyWidget;
        final rebuildCounts = <String, int>{};
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          if (!builtOnce) return;
          final name = element.widget.runtimeType.toString();
          rebuildCounts[name] = (rebuildCounts[name] ?? 0) + 1;
        };

        try {
          // Run 40 continuous playback frames (~640ms) inside the first lyric line
          // (lines[0] spans 500..4400ms in demo project, so start at 600ms).
          audioHarness.mockMusicPositionMs = 600;
          await controller.seek(600);
          await tester.pump();
          rebuildCounts.clear();

          for (var i = 0; i < 40; i++) {
            audioHarness.mockMusicPositionMs = 600 + (i + 1) * 16;
            await tester.pump(const Duration(milliseconds: 16));
          }

          expect(rebuildCounts['PrismApp'] ?? 0, 0);
          expect(rebuildCounts['ThemeCrossFade'] ?? 0, 0);
          expect(rebuildCounts['HomeShell'] ?? 0, 0);
          expect(rebuildCounts['DashboardView'] ?? 0, 0);
          expect(rebuildCounts['TimelineEditorWidget'] ?? 0, 0);
          expect(rebuildCounts['_ReactiveTimelineLineCard'] ?? 0, 0);
          expect(rebuildCounts['TextField'] ?? 0, 0);

          // Verify Hero card clock actually updated live via FramePositionUpdater.
          expect(controller.currentTimeMs, greaterThan(1000));
          expect(find.text('00:00.00'), findsNothing);
          expect(find.text('Running'), findsOneWidget);

          // Verify ThemeCrossFade never captured an overlay snapshot during playback.
          final fadeLayer = tester.widget<Widget>(
            find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_ThemeCrossFadeLayer',
            ),
          );
          expect(
            fadeLayer.toDiagnosticsNode().getProperties().any(
              (p) => p.name == 'snapshot' && p.value != null,
            ),
            isFalse,
          );

          // Now cross a lyric line boundary (line 0 -> line 1).
          rebuildCounts.clear();
          final lines = controller.sortedLines;
          expect(lines.length, greaterThanOrEqualTo(3));
          audioHarness.mockMusicPositionMs = lines[1].startTimeMs + 50;
          await controller.seek(lines[1].startTimeMs + 50);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 260));

          // Still ZERO full-tree or TimelineEditorWidget rebuilds, and ONLY the 2
          // transitioning cards rebuild instead of all project lines.
          expect(rebuildCounts['PrismApp'] ?? 0, 0);
          expect(rebuildCounts['ThemeCrossFade'] ?? 0, 0);
          expect(rebuildCounts['HomeShell'] ?? 0, 0);
          expect(rebuildCounts['DashboardView'] ?? 0, 0);
          expect(rebuildCounts['TimelineEditorWidget'] ?? 0, 0);
          expect(
            rebuildCounts['_ReactiveTimelineLineCard'] ?? 0,
            lessThanOrEqualTo(2),
          );
          expect(controller.playingLineId, lines[1].id);
        } finally {
          debugOnRebuildDirtyWidget = prevRebuildHook;
          await _disposeApp(tester, controller);
        }
      },
    );

    testWidgets(
      'PracticeOverlay updates clock/slider/GT banner smoothly while keeping RubyLyricText rebuilds scoped to line transitions',
      timeout: const Timeout(Duration(seconds: 25)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
        controller.setPracticeMode(true);
        await tester.pump();

        await controller.seek(controller.sortedLines[1].startTimeMs + 50);
        await tester.pump();

        final prevRebuildHook = debugOnRebuildDirtyWidget;
        final rebuildCounts = <String, int>{};
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          if (!builtOnce) return;
          final name = element.widget.runtimeType.toString();
          rebuildCounts[name] = (rebuildCounts[name] ?? 0) + 1;
        };

        try {
          await controller.togglePlay();
          await tester.pump(const Duration(milliseconds: 500));
          rebuildCounts.clear();

          // Pump 25 frames inside same line: PracticeOverlay teleprompter text must not rebuild.
          for (var i = 0; i < 25; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          expect(rebuildCounts['PrismApp'] ?? 0, 0);
          expect(rebuildCounts['ThemeCrossFade'] ?? 0, 0);
          expect(rebuildCounts['PracticeOverlay'] ?? 0, 0);
          expect(rebuildCounts['RubyLyricText'] ?? 0, 0);
          expect(
            find.textContaining('00:00.00 /'),
            findsNothing,
          );

          // Jump into an active GT countdown window and verify alert banner renders live.
          final gtAlert = controller.sortedAlerts.first;
          await controller.seek(gtAlert.triggerTimeMs - 500);
          await tester.pump();
          expect(controller.activeGtAlertStatus, isNotNull);
          expect(find.textContaining('倒数'), findsWidgets);
        } finally {
          debugOnRebuildDirtyWidget = prevRebuildHook;
          await _disposeApp(tester, controller);
        }
      },
    );

    testWidgets(
      'Mobile quick-tray live clock updates during playback without rebuilding HomeShell or PrismApp',
      timeout: const Timeout(Duration(seconds: 25)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        await controller.togglePlay();
        await tester.pump(const Duration(milliseconds: 500));

        final prevRebuildHook = debugOnRebuildDirtyWidget;
        final rebuildCounts = <String, int>{};
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          if (!builtOnce) return;
          final name = element.widget.runtimeType.toString();
          rebuildCounts[name] = (rebuildCounts[name] ?? 0) + 1;
        };

        try {
          await controller.seek(12050);
          await tester.pump();
          rebuildCounts.clear();

          for (var i = 0; i < 15; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          expect(rebuildCounts['PrismApp'] ?? 0, 0);
          expect(rebuildCounts['HomeShell'] ?? 0, 0);
          expect(find.textContaining('00:12.'), findsWidgets);
        } finally {
          debugOnRebuildDirtyWidget = prevRebuildHook;
          await _disposeApp(tester, controller);
        }
      },
    );
  });

  group('CallbookController O(1) cache consistency', () {
    test('sortedLines, getAlertForLine, and activeGtAlertStatus stay consistent across edits', () async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      try {
        final initialCount = controller.sortedLines.length;
        expect(controller.timelineItems.length, initialCount);

        await controller.importLrcText(
          lrc: '''
[00:05.00] First line
[00:10.00] Second line
[00:15.00] Third line
''',
        );
        expect(controller.sortedLines.length, 3);
        expect(controller.sortedLines[0].text.original, 'First line');
        expect(controller.sortedLines[2].text.original, 'Third line');

        final line2 = controller.sortedLines[1];
        controller.toggleLineGtAlert(lineId: line2.id);
        expect(controller.sortedAlerts.length, 1);
        expect(controller.getAlertForLine(line2.id), isNotNull);

        await controller.seek(line2.startTimeMs - 300);
        expect(controller.activeGtAlertStatus?.targetLineId, line2.id);

        // Shifting line2 earlier updates sorted order and alert map.
        controller.updateLineDetails(
          lineId: line2.id,
          startTimeMs: 2000,
          endTimeMs: 4000,
        );
        expect(controller.sortedLines.first.id, line2.id);
        expect(controller.getAlertForLine(line2.id)?.triggerTimeMs, 2000);

        controller.deleteLine(line2.id);
        expect(controller.sortedLines.length, 2);
        expect(controller.getAlertForLine(line2.id), isNull);
      } finally {
        controller.dispose();
      }
    });
  });
}
