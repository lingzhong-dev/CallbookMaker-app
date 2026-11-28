import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/services/audio_metronome_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mock_audioplayers_harness.dart';

http.Response _jsonResp(Object data) => http.Response.bytes(
  utf8.encode(jsonEncode(data)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MockAudioplayersHarness().install();
  });

  group('Step 02: Timeline Undo Scope, Atomic Transactions & Duration Bounds', () {
    test('delete line -> edit BPM/offset/meta -> undo restores line & GT without rolling back meta', () async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      try {
        await controller.importLrcText(
          lrc: '''
[00:05.00] First line
[00:10.00] Second line
[00:15.00] Third line
''',
        );
        final second = controller.sortedLines.firstWhere(
          (l) => l.text.original == 'Second line',
        );
        controller.toggleLineCall(second.id, 'clap');
        controller.toggleLineGtAlert(lineId: second.id);
        controller.updateLineGtAlert(second.id, note: 'Watch cue');

        await controller.seek(14000);
        final countBeforeDelete = controller.sortedLines.length;
        controller.deleteLine(second.id);
        expect(controller.sortedLines.length, countBeforeDelete - 1);
        expect(controller.getAlertForLine(second.id), isNull);

        controller.setBpm(192);
        controller.setOffset(85);
        controller.setTimeSignature('3/4');
        controller.updateMeta(title: 'Updated Song Title');

        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(controller.sortedLines.length, countBeforeDelete);
        final restored = controller.sortedLines.firstWhere(
          (l) => l.id == second.id,
        );
        expect(restored.text.original, 'Second line');
        expect(restored.calls.single.presetId, 'clap');
        expect(controller.getAlertForLine(second.id)?.note, 'Watch cue');

        // Meta and current playback timestamp must be preserved across timeline undo.
        expect(controller.project.meta.bpm, 192);
        expect(controller.project.meta.offsetMs, 85);
        expect(controller.project.meta.timeSignature, '3/4');
        expect(controller.project.meta.title, 'Updated Song Title');
        expect(controller.currentTimeMs, 14000);
      } finally {
        controller.dispose();
      }
    });

    test('atomic 1-op-1-history: tailUpdraft, quickTag+autoAdvance, delete-with-GT, aligned calls, sections & no-ops', () async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      try {
        await controller.importLrcText(
          lrc: '''
[00:05.00] Alpha line
[00:10.00] Beta line
[00:15.00] Gamma line
''',
        );
        final lines = controller.sortedLines
            .where((l) => !l.kind.isSection)
            .toList();
        final alpha = lines[0];
        final beta = lines[1];
        final gamma = lines[2];

        int historyDepth() {
          // Helper verifies exact history depth by inspecting undo behavior on isolated slices below.
          return controller.canUndo ? 1 : 0;
        }

        expect(historyDepth(), 0);

        // 1) toggleTailUpdraft -> setTailUpdraft produces exactly 1 entry; repeated setTailUpdraft is no-op.
        expect(controller.toggleTailUpdraft(alpha.id), isTrue);
        controller.setTailUpdraft(alpha.id, true); // no-op
        expect(controller.canUndo, isTrue);
        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(controller.canUndo, isFalse);
        expect(
          controller.sortedLines.firstWhere((l) => l.id == alpha.id).tailUpdraft,
          isFalse,
        );

        // 2) quickTagActiveLine with autoAdvance advances activeLineId and pushes exactly 1 history entry.
        controller.selectLine(alpha.id);
        expect(
          controller.quickTagActiveLine('front-wave', autoAdvance: true),
          isTrue,
        );
        expect(controller.activeLineId, beta.id);
        expect(
          controller.sortedLines
              .firstWhere((l) => l.id == alpha.id)
              .calls
              .any((t) => t.presetId == 'front-wave'),
          isTrue,
        );
        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(controller.canUndo, isFalse);
        expect(controller.activeLineId, alpha.id);
        expect(
          controller.sortedLines.firstWhere((l) => l.id == alpha.id).calls,
          isEmpty,
        );

        // 3) deleteLine with bound GT alert produces 1 entry and 1 undo restores both.
        controller.toggleLineGtAlert(lineId: beta.id);
        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(controller.canUndo, isFalse);

        controller.insertGtAlert(lineId: beta.id); // wrapper -> 1 entry
        expect(controller.getAlertForLine(beta.id), isNotNull);
        controller.deleteLine(beta.id); // 2nd entry
        expect(controller.sortedLines.any((l) => l.id == beta.id), isFalse);
        expect(controller.getAlertForLine(beta.id), isNull);

        expect(controller.undoLastTimelineEdit(), isTrue); // undo delete
        expect(controller.sortedLines.any((l) => l.id == beta.id), isTrue);
        expect(controller.getAlertForLine(beta.id), isNotNull);

        expect(controller.undoLastTimelineEdit(), isTrue); // undo insertGtAlert
        expect(controller.canUndo, isFalse);
        expect(controller.getAlertForLine(beta.id), isNull);

        // 4) No-op calls never push undo history.
        controller.deleteLine('non-existent-id');
        controller.setCallTagSuffix(alpha.id, 'sing-along', 'test'); // missing tag
        controller.removeAlignedCall(alpha.id, 'missing-cue');
        controller.updateLineDetails(lineId: alpha.id); // unchanged
        controller.updateLineGtAlert(alpha.id, note: 'missing alert');
        expect(controller.splitLineAtRunes(alpha.id, const []), isFalse);
        await controller.seek(5000);
        controller.snapLineToCurrentTime(alpha.id); // already 5000..10000
        expect(controller.canUndo, isFalse);

        // 5) Remaining timeline ops push 1 entry each and undo cleanly.
        controller.toggleLineCall(gamma.id, 'sing-along', suffix: 'La la');
        controller.setCallTagSuffix(gamma.id, 'sing-along', 'La la'); // no-op
        controller.setCallTagSuffix(gamma.id, 'sing-along', 'Hey hey');
        expect(
          controller.sortedLines
              .firstWhere((l) => l.id == gamma.id)
              .calls
              .single
              .suffix,
          'Hey hey',
        );
        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(
          controller.sortedLines
              .firstWhere((l) => l.id == gamma.id)
              .calls
              .single
              .suffix,
          'La la',
        );
        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(controller.canUndo, isFalse);

        controller.upsertAlignedCall(
          gamma.id,
          id: 'cue-1',
          start: 0,
          end: 2,
          text: 'Go!',
        );
        controller.upsertAlignedCall(
          gamma.id,
          id: 'cue-1',
          start: 0,
          end: 2,
          text: 'Go!',
        ); // no-op
        controller.removeAlignedCall(gamma.id, 'cue-1');
        expect(controller.undoLastTimelineEdit(), isTrue); // restores cue-1
        expect(
          controller.sortedLines
              .firstWhere((l) => l.id == gamma.id)
              .alignedCalls
              .single
              .text,
          'Go!',
        );
        expect(controller.undoLastTimelineEdit(), isTrue); // removes cue-1
        expect(controller.canUndo, isFalse);

        controller.addEmptyLine();
        controller.addSectionLine(
          kind: LyricLineKind.interlude,
          startTimeMs: 20000,
          endTimeMs: 28000,
        );
        controller.updateLineDetails(
          lineId: alpha.id,
          customShout: 'Custom shout',
        );
        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(
          controller.sortedLines.firstWhere((l) => l.id == alpha.id).customShout,
          '',
        );
        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(controller.canUndo, isFalse);
      } finally {
        controller.dispose();
      }
    });

    test('duration shrinks properly when 200s track timeline is pulled to 260s then reverted/undone, and clamps non-audio clock', () async {
      final neteaseClient = MockClient((req) async {
        if (req.url.path == '/eapi/song/lyric/v1') {
          return _jsonResp({
            'code': 200,
            'lrc': {
              'lyric': '[00:10.00] Line 1\n[03:00.00] Line 2\n',
            },
          });
        }
        if (req.url.path == '/eapi/v3/song/detail') {
          return _jsonResp({
            'code': 200,
            'songs': [
              {
                'id': 200100,
                'name': '200s Track',
                'dt': 200000,
                'ar': [{'name': 'Artist'}],
              },
            ],
          });
        }
        return _jsonResp({'code': 200});
      });

      final controller = await createTestCallbookController(
        enableAudioOutput: false,
        neteaseHttpClient: neteaseClient,
      );
      try {
        await controller.loadRemoteTrack(
          const TrackSummary(
            id: '200100',
            title: '200s Track',
            artist: 'Artist',
            platform: 'netease',
            durationMs: 200000,
            provider: 'netease_direct',
          ),
        );
        expect(controller.knownAudioDurationMs, 200000);
        expect(controller.durationMs, 200000);

        final line2 = controller.sortedLines.lastWhere(
          (l) => l.kind == LyricLineKind.lyric,
        );
        controller.updateLineDetails(
          lineId: line2.id,
          startTimeMs: 255000,
          endTimeMs: 260000,
        );
        expect(controller.knownAudioDurationMs, 200000);
        expect(controller.durationMs, 260000);

        // Editing back to 190s shrinks durationMs back to knownAudioDurationMs (200s).
        controller.updateLineDetails(
          lineId: line2.id,
          startTimeMs: 185000,
          endTimeMs: 190000,
        );
        expect(controller.durationMs, 200000);

        // Undo back to 260s, then undo again to initial 183s -> durationMs falls back to 200s.
        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(controller.durationMs, 260000);
        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(controller.durationMs, 200000);

        // Synthetic / no-audio timeline: shrinking range clamps out-of-range _currentTimeMs & audio clock.
        await controller.importLrcText(
          lrc: '''
[00:05.00] Short line A
[00:10.00] Short line B
''',
        );
        expect(controller.knownAudioDurationMs, 0);
        await controller.seek(10000);
        controller.addSectionLine(
          kind: LyricLineKind.outro,
          startTimeMs: 90000,
          endTimeMs: 120000,
        );
        expect(controller.durationMs, 120000);

        await controller.seek(115000);
        expect(controller.currentTimeMs, 115000);

        // Undo adding the extended outro shrinks duration back down and clamps currentTimeMs.
        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(controller.durationMs, 48000);
        expect(controller.currentTimeMs, 48000);
      } finally {
        controller.dispose();
      }
    });

    test('AudioMetronomeService.setFallbackDurationMs clamps position when duration shrinks', () async {
      final observedTimes = <int>[];
      final service = AudioMetronomeService(
        enablePlatformAudio: false,
        onTimeUpdate: observedTimes.add,
        onBeatTrigger: (_) {},
        onGtAlertBeep: (_) {},
      );
      service.setFallbackDurationMs(120000);
      await service.seek(110000);
      expect(service.currentTimeMs, 110000);

      service.setFallbackDurationMs(48000);
      expect(service.durationMs, 48000);
      expect(service.currentTimeMs, 48000);
      expect(observedTimes.last, 48000);
      await service.dispose();
    });

    testWidgets('Mobile persistent Undo stays reachable with tray collapsed, handles narrow/large-text, and Ctrl+Z respects focused text input', (tester) async {
      SharedPreferences.setMockInitialValues({
        'live_call_studio_onboarding_v1': true,
      });
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );

      final captured = <FlutterErrorDetails>[];
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (d) => captured.add(d);

      try {
        // 1) Mobile 390x844: collapsed tray still shows Undo (disabled initially, enabled after edit).
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 280));

        final undoBtnFinder = find.byKey(
          const ValueKey('mobile-persistent-undo-button'),
        );
        expect(undoBtnFinder, findsOneWidget);
        expect(controller.canUndo, isFalse);

        // Collapse quick-tag tray.
        await tester.tap(find.text('收起速标'));
        await tester.pumpAndSettle();
        expect(find.text('速标栏'), findsOneWidget);
        expect(undoBtnFinder, findsOneWidget);

        // Tapping disabled undo does nothing.
        await tester.tap(undoBtnFinder);
        await tester.pump();
        expect(controller.canUndo, isFalse);

        // Perform a timeline mutation -> Undo button remains visible on collapsed mobile bar and works.
        final firstLyric = controller.sortedLines.firstWhere(
          (l) => !l.kind.isSection,
        );
        controller.deleteLine(firstLyric.id);
        await tester.pump();
        expect(controller.canUndo, isTrue);
        expect(
          controller.sortedLines.any((l) => l.id == firstLyric.id),
          isFalse,
        );

        await tester.tap(undoBtnFinder);
        await tester.pump();
        expect(controller.canUndo, isFalse);
        expect(
          controller.sortedLines.any((l) => l.id == firstLyric.id),
          isTrue,
        );
        expect(undoBtnFinder, findsOneWidget);

        // 2) Narrow mobile (360x720) + 1.25x textScale + long scroll has zero overflow.
        tester.view.physicalSize = const Size(360, 720);
        controller.setTextScale(1.25);
        await tester.pumpAndSettle();
        expect(undoBtnFinder, findsOneWidget);
        final scrollable = find.byType(Scrollable).first;
        await tester.drag(scrollable, const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(undoBtnFinder, findsOneWidget);
        expect(captured, isEmpty);
        expect(tester.takeException(), isNull);

        // 3) Desktop 1280x820: Ctrl+Z does NOT trigger timeline undo while a TextField has focus.
        controller.setTextScale(1.0);
        tester.view.physicalSize = const Size(1280, 820);
        await tester.pumpAndSettle();

        final lineToEdit = controller.sortedLines.firstWhere(
          (l) => !l.kind.isSection,
        );
        controller.deleteLine(lineToEdit.id);
        await tester.pump();
        expect(controller.canUndo, isTrue);

        // Focus a TextField in DashboardView (song title field).
        final titleField = find.byType(EditableText).first;
        await tester.tap(titleField);
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        // Timeline undo must NOT have fired while TextField was focused.
        expect(controller.canUndo, isTrue);
        expect(
          controller.sortedLines.any((l) => l.id == lineToEdit.id),
          isFalse,
        );

        // Clear text focus, then Ctrl+Z triggers timeline undo cleanly.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        expect(controller.canUndo, isFalse);
        expect(
          controller.sortedLines.any((l) => l.id == lineToEdit.id),
          isTrue,
        );
        expect(captured, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        FlutterError.onError = prevOnError;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  });
}
