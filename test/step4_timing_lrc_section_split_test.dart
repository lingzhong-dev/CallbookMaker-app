import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/services/audio_metronome_service.dart';
import 'package:live_call_studio/ui/widgets/timeline_editor_widget.dart';
import 'package:live_call_studio/utils/lrc_ruby_parser.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import 'support/mock_audioplayers_harness.dart';

class _FakeClock implements MonotonicClock {
  int _us = 0;
  bool _running = false;

  void advanceMs(int ms) {
    if (_running) {
      _us += ms * 1000;
    }
  }

  @override
  int get elapsedMicroseconds => _us;

  @override
  void reset() => _us = 0;

  @override
  void start() => _running = true;

  @override
  void stop() => _running = false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockAudioplayersHarness audioHarness;

  setUp(() {
    audioHarness = MockAudioplayersHarness()..install();
  });

  group('Step 04: Snap Debounce, Short Intervals, LRC Groups & Section Splitting', () {
    test('allows 100ms short lyric intervals, commits intentional 50ms fine-tune, debounces rapid double-tap, and does not auto-jump on snap', () async {
      final clock = _FakeClock();
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
        audioClock: clock,
      );
      try {
        await controller.importLrcText(
          lrc: '''
[00:05.00] Fast line A
[00:05.10] Fast line B
[00:08.00] Line C
''',
        );
        controller.setAutoAdvanceOnTag(true);

        final lines = controller.sortedLines
            .where((l) => !l.kind.isSection)
            .toList();
        final lineA = lines[0];
        final lineB = lines[1];
        final lineC = lines[2];

        // 100ms interval between lineA and lineB is legal (no 400ms overlap).
        expect(lineA.startTimeMs, 5000);
        expect(lineA.endTimeMs, 5100);
        expect(lineB.startTimeMs, 5100);

        // Editing lineA to a 100ms interval directly preserves 100ms (end > start).
        controller.updateLineDetails(
          lineId: lineA.id,
          startTimeMs: 5000,
          endTimeMs: 5100,
        );
        expect(
          controller.sortedLines.firstWhere((l) => l.id == lineA.id).endTimeMs,
          5100,
        );
        expect(controller.canUndo, isFalse); // unchanged -> no-op

        // Intentional 50ms fine-tune via updateLineDetails is never swallowed.
        controller.updateLineDetails(
          lineId: lineA.id,
          startTimeMs: 5050,
          endTimeMs: 5100,
        );
        var updatedA = controller.sortedLines.firstWhere((l) => l.id == lineA.id);
        expect(updatedA.startTimeMs, 5050);
        expect(updatedA.endTimeMs, 5100);
        expect(controller.canUndo, isTrue);
        expect(controller.undoLastTimelineEdit(), isTrue);

        // Snap lineC to 7000ms -> does NOT auto-jump even with autoAdvanceOnTag == true.
        controller.selectLine(lineC.id);
        await controller.seek(7000);
        controller.snapLineToCurrentTime(lineC.id);
        expect(controller.activeLineId, lineC.id);
        expect(
          controller.sortedLines.firstWhere((l) => l.id == lineC.id).startTimeMs,
          7000,
        );

        // Accidental double-tap bounce within 60ms on the same line is ignored (no undo push).
        clock.advanceMs(60);
        await controller.seek(7080);
        controller.snapLineToCurrentTime(lineC.id);
        expect(
          controller.sortedLines.firstWhere((l) => l.id == lineC.id).startTimeMs,
          7000,
        );

        // Intentional 50ms snap adjustment after debounce window (>160ms) succeeds.
        clock.advanceMs(250);
        await controller.seek(7050);
        controller.snapLineToCurrentTime(lineC.id);
        expect(
          controller.sortedLines.firstWhere((l) => l.id == lineC.id).startTimeMs,
          7050,
        );
      } finally {
        controller.dispose();
      }
    });

    test('parseLrcOffline preserves multi-line same-timestamp groups in source order ending at next distinct timestamp', () {
      const lrc = '''
[00:10.00] Lead vocal line
[00:10.00] Backing chorus line
[00:10.00] Third harmony line
[00:14.50] Next lyric // 下一句译文
[00:20.00] Tail duo A
[00:20.00] Tail duo B
''';
      final parsed = parseLrcOffline(lrc);
      expect(parsed.length, 6);

      expect(parsed[0].text.original, 'Lead vocal line');
      expect(parsed[1].text.original, 'Backing chorus line');
      expect(parsed[2].text.original, 'Third harmony line');

      // All three lines at 10.00s end at 14.50s and never infer second line as translation.
      for (var i = 0; i < 3; i++) {
        expect(parsed[i].startTimeMs, 10000);
        expect(parsed[i].endTimeMs, 14500);
        expect(parsed[i].text.translation, isNull);
      }

      // Inline bilingual separator still populates translation explicitly.
      expect(parsed[3].text.original, 'Next lyric');
      expect(parsed[3].text.translation, '下一句译文');
      expect(parsed[3].startTimeMs, 14500);
      expect(parsed[3].endTimeMs, 20000);

      // Trailing same-timestamp group shares groupMs + defaultDurationMs.
      expect(parsed[4].text.original, 'Tail duo A');
      expect(parsed[5].text.original, 'Tail duo B');
      expect(parsed[4].endTimeMs, 23000);
      expect(parsed[5].endTimeMs, 23000);
    });

    test('deleteLine extends auto-maintainable intro only when earliest lyric shifts later and protects manual/tagged/same-start/last cases', () async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      try {
        // 1) Auto intro [0, 8000] extends to [0, 13000] when earliest lyric (8000) is deleted, keeping offsetMs intact.
        await controller.importLrcText(
          lrc: '''
[00:08.00] First lyric
[00:13.00] Second lyric
[00:18.00] Third lyric
''',
        );
        controller.setOffset(120);
        final intro1 = controller.sortedLines.firstWhere(
          (l) => l.kind == LyricLineKind.intro,
        );
        expect(intro1.autoGenerated, isTrue);
        expect(intro1.endTimeMs, 8000);

        final firstLyric = controller.sortedLines.firstWhere(
          (l) => l.text.original == 'First lyric',
        );
        controller.deleteLine(firstLyric.id);

        final extendedIntro = controller.sortedLines.firstWhere(
          (l) => l.id == intro1.id,
        );
        expect(extendedIntro.endTimeMs, 13000);
        expect(controller.project.meta.offsetMs, 120);

        // Single undo reverts both deleted lyric and intro extension.
        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(
          controller.sortedLines.any((l) => l.id == firstLyric.id),
          isTrue,
        );
        expect(
          controller.sortedLines.firstWhere((l) => l.id == intro1.id).endTimeMs,
          8000,
        );

        // 2) Auto intro with a Call tag is protected from extension.
        controller.toggleLineCall(intro1.id, 'clap');
        controller.deleteLine(firstLyric.id);
        expect(
          controller.sortedLines.firstWhere((l) => l.id == intro1.id).endTimeMs,
          8000,
        );
        expect(controller.undoLastTimelineEdit(), isTrue);
        controller.toggleLineCall(intro1.id, 'clap'); // untag

        // 3) Manually edited or manually created intro is protected from extension.
        controller.updateLineDetails(
          lineId: intro1.id,
          original: '【手改前奏】',
          endTimeMs: 7900,
        );
        expect(
          controller.sortedLines
              .firstWhere((l) => l.id == intro1.id)
              .autoGenerated,
          isFalse,
        );
        controller.deleteLine(firstLyric.id);
        expect(
          controller.sortedLines.firstWhere((l) => l.id == intro1.id).endTimeMs,
          7900,
        );
        expect(controller.undoLastTimelineEdit(), isTrue); // restore lyric
        expect(controller.undoLastTimelineEdit(), isTrue); // restore auto intro

        // Snapping an auto section also marks it manually adjusted (autoGenerated = false).
        await controller.seek(500);
        controller.snapLineToCurrentTime(intro1.id);
        expect(
          controller.sortedLines
              .firstWhere((l) => l.id == intro1.id)
              .autoGenerated,
          isFalse,
        );
        controller.deleteLine(firstLyric.id);
        expect(
          controller.sortedLines.firstWhere((l) => l.id == intro1.id).endTimeMs,
          8000,
        );
        expect(controller.undoLastTimelineEdit(), isTrue); // restore lyric
        expect(controller.undoLastTimelineEdit(), isTrue); // restore auto intro

        // Manual intro via addSectionLine is also protected from extension.
        controller.deleteLine(intro1.id);
        controller.addSectionLine(
          kind: LyricLineKind.intro,
          startTimeMs: 0,
          endTimeMs: 8000,
        );
        final manualIntroId = controller.sortedLines
            .firstWhere((l) => l.kind == LyricLineKind.intro)
            .id;
        controller.deleteLine(firstLyric.id);
        expect(
          controller.sortedLines
              .firstWhere((l) => l.id == manualIntroId)
              .endTimeMs,
          8000,
        );

        // 4) Deleting one line in a same-timestamp earliest group does NOT extend auto intro.
        await controller.importLrcText(
          lrc: '''
[00:08.00] Co-start A
[00:08.00] Co-start B
[00:14.00] Later lyric
''',
        );
        final autoIntroId = controller.sortedLines
            .firstWhere((l) => l.kind == LyricLineKind.intro)
            .id;
        final coA = controller.sortedLines.firstWhere(
          (l) => l.text.original == 'Co-start A',
        );
        controller.deleteLine(coA.id);
        expect(
          controller.sortedLines
              .firstWhere((l) => l.id == autoIntroId)
              .endTimeMs,
          8000,
        );

        // 5) Deleting the last remaining lyric does NOT fabricate or alter intro.
        final coB = controller.sortedLines.firstWhere(
          (l) => l.text.original == 'Co-start B',
        );
        final later = controller.sortedLines.firstWhere(
          (l) => l.text.original == 'Later lyric',
        );
        controller.deleteLine(coB.id); // extends to 14000
        expect(
          controller.sortedLines
              .firstWhere((l) => l.id == autoIntroId)
              .endTimeMs,
          14000,
        );
        controller.deleteLine(later.id); // deletes last lyric -> keeps 14000
        expect(
          controller.sortedLines
              .firstWhere((l) => l.id == autoIntroId)
              .endTimeMs,
          14000,
        );
      } finally {
        controller.dispose();
      }
    });

    test('splitSectionAtTime enforces ownership and survives detectSections, onlyOutro, duration callbacks, and JSON/archive reload', () async {
      final controller = await createTestCallbookController(
        enableAudioOutput: true,
      );
      try {
        await controller.loadLocalAudioFile('/tmp/track_100s.mp3', 'track_100s.mp3');
        await controller.importLrcText(
          lrc: '''
[00:12.00] Intro end lyric
[00:16.00] Before interlude
[00:40.00] After interlude
[00:46.00] Final lyric
''',
        );
        // Simulate external audio reporting 100s duration -> auto-generates 47s-100s outro.
        audioHarness.mockMusicDurationMs = 100000;
        final musicId = audioHarness.activeMusicPlayerId!;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final codec = const StandardMethodCodec();
        messenger.handlePlatformMessage(
          'xyz.luan/audioplayers/events/$musicId',
          codec.encodeSuccessEnvelope({
            'event': 'audio.onDuration',
            'value': 100000,
          }),
          (_) {},
        );
        await Future<void>.delayed(Duration.zero);

        final intro = controller.sortedLines.firstWhere(
          (l) => l.kind == LyricLineKind.intro,
        );
        final interlude = controller.sortedLines.firstWhere(
          (l) => l.kind == LyricLineKind.interlude,
        );
        final outro = controller.sortedLines.firstWhere(
          (l) => l.kind == LyricLineKind.outro,
        );
        expect(outro.startTimeMs, greaterThanOrEqualTo(46000));
        expect(outro.endTimeMs, 100000);

        // Attach Calls, customShout, tailUpdraft, and start GT alert to outro before splitting.
        controller.toggleLineCall(outro.id, 'ppph');
        controller.updateLineDetails(
          lineId: outro.id,
          customShout: 'Tiger Fire Mix',
        );
        controller.toggleTailUpdraft(outro.id);
        controller.toggleLineGtAlert(lineId: outro.id);

        final splitPoint = (outro.startTimeMs + outro.endTimeMs) ~/ 2;
        expect(
          controller.splitSectionAtTime(
            outro.id,
            splitPoint,
            firstTitle: '【尾奏·前半】',
            secondTitle: '【尾奏·后半】',
          ),
          isTrue,
        );

        final splitOutros = controller.sortedLines
            .where((l) => l.kind == LyricLineKind.outro)
            .toList();
        expect(splitOutros.length, 2);
        final o1 = splitOutros[0];
        final o2 = splitOutros[1];

        // Segment 1 ownership: original ID, calls, customShout, start GT alert, tailUpdraft == false, autoGenerated == false.
        expect(o1.id, outro.id);
        expect(o1.startTimeMs, outro.startTimeMs);
        expect(o1.endTimeMs, splitPoint);
        expect(o1.autoGenerated, isFalse);
        expect(o1.calls.map((c) => c.presetId), ['ppph']);
        expect(o1.customShout, 'Tiger Fire Mix');
        expect(o1.tailUpdraft, isFalse);
        expect(o1.text.original, '【尾奏·前半】');
        expect(controller.getAlertForLine(o1.id), isNotNull);

        // Segment 2 ownership: new ID, empty calls/customShout, inherits tailUpdraft == true, autoGenerated == false.
        expect(o2.id, isNot(outro.id));
        expect(o2.startTimeMs, splitPoint);
        expect(o2.endTimeMs, 100000);
        expect(o2.autoGenerated, isFalse);
        expect(o2.calls, isEmpty);
        expect(o2.customShout, '');
        expect(o2.tailUpdraft, isTrue);
        expect(o2.text.original, '【尾奏·后半】');
        expect(controller.getAlertForLine(o2.id), isNull);

        // Also split intro & interlude.
        expect(
          controller.splitSectionAtTime(intro.id, intro.endTimeMs ~/ 2),
          isTrue,
        );
        expect(
          controller.splitSectionAtTime(
            interlude.id,
            (interlude.startTimeMs + interlude.endTimeMs) ~/ 2,
          ),
          isTrue,
        );

        // Repeat full detectSections, onlyOutro, and extended duration callback (110s):
        // split sections must stay separate and first outro must NOT expand over second outro!
        controller.detectSections();
        controller.detectSections(onlyOutro: true);
        messenger.handlePlatformMessage(
          'xyz.luan/audioplayers/events/$musicId',
          codec.encodeSuccessEnvelope({
            'event': 'audio.onDuration',
            'value': 110000,
          }),
          (_) {},
        );
        await Future<void>.delayed(Duration.zero);

        final introsAfter = controller.sortedLines
            .where((l) => l.kind == LyricLineKind.intro)
            .toList();
        final interludesAfter = controller.sortedLines
            .where((l) => l.kind == LyricLineKind.interlude)
            .toList();
        final outrosAfter = controller.sortedLines
            .where((l) => l.kind == LyricLineKind.outro)
            .toList();
        expect(introsAfter.length, 2);
        expect(interludesAfter.length, 2);
        expect(outrosAfter.length, 2);
        expect(outrosAfter[0].id, o1.id);
        expect(outrosAfter[0].endTimeMs, splitPoint);
        expect(outrosAfter[1].id, o2.id);
        expect(outrosAfter[1].startTimeMs, splitPoint);
        expect(outrosAfter[1].endTimeMs, 100000);
        expect(outrosAfter[0].calls.map((c) => c.presetId), ['ppph']);
        expect(outrosAfter[0].customShout, 'Tiger Fire Mix');
        expect(outrosAfter[1].tailUpdraft, isTrue);
        expect(controller.getAlertForLine(o1.id), isNotNull);

        // JSON export/import and archive save/switch reload keep everything intact.
        final exported = jsonEncode(controller.project.toJson());
        final archive = controller.saveCurrentToArchive(asNew: true, customName: 'Split Sections');
        expect(await controller.importProjectJson(exported), isTrue);
        expect(
          controller.sortedLines.where((l) => l.kind == LyricLineKind.outro).length,
          2,
        );
        expect(await controller.switchToArchive(archive.id), isTrue);
        final reloadedOutros = controller.sortedLines
            .where((l) => l.kind == LyricLineKind.outro)
            .toList();
        expect(reloadedOutros.length, 2);
        expect(reloadedOutros[0].endTimeMs, splitPoint);
        expect(reloadedOutros[1].tailUpdraft, isTrue);
      } finally {
        controller.dispose();
      }
    });

    testWidgets('TimelineEditorWidget splits selected section via dialog and saves 100ms short interval in Edit dialog', (tester) async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      try {
        await controller.importLrcText(
          lrc: '''
[00:10.00] First lyric
[00:14.00] Second lyric
''',
        );
        final intro = controller.sortedLines.firstWhere(
          (l) => l.kind == LyricLineKind.intro,
        );
        controller.selectLine(intro.id);
        await controller.seek(4000);

        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          LiveCallStudioApp(
            controller: controller,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 280));

        // Selected section card exposes '拆分' and opens split dialog defaulting to current time 00:04.00.
        final splitBtn = find.descendant(
          of: find.byType(TimelineEditorWidget),
          matching: find.text('拆分'),
        );
        expect(splitBtn, findsOneWidget);
        await tester.tap(splitBtn);
        await tester.pumpAndSettle();

        expect(find.text('拆分前奏段落'), findsOneWidget);
        expect(find.text('采用当前时刻 00:04.00'), findsOneWidget);
        await tester.tap(find.text('确认拆分'));
        await tester.pumpAndSettle();

        final splitIntros = controller.sortedLines
            .where((l) => l.kind == LyricLineKind.intro)
            .toList();
        expect(splitIntros.length, 2);
        expect(splitIntros[0].endTimeMs, 4000);
        expect(splitIntros[1].startTimeMs, 4000);
        expect(splitIntros[1].endTimeMs, 10000);

        // Undo merges back to single intro cleanly.
        expect(controller.undoLastTimelineEdit(), isTrue);
        await tester.pump();
        expect(
          controller.sortedLines.where((l) => l.kind == LyricLineKind.intro).length,
          1,
        );

        // Edit dialog saves a 100ms lyric interval without forcing +500ms floor.
        final firstLyric = controller.sortedLines.firstWhere(
          (l) => l.text.original == 'First lyric',
        );
        controller.selectLine(firstLyric.id);
        await tester.pumpAndSettle();

        final editChips = find.descendant(
          of: find.byType(TimelineEditorWidget),
          matching: find.text('编辑'),
        );
        await tester.ensureVisible(editChips.at(1));
        await tester.tap(editChips.at(1));
        await tester.pumpAndSettle();

        final dialogFields = find.descendant(
          of: find.byType(prism.AlertDialog),
          matching: find.byType(EditableText),
        );
        await tester.enterText(dialogFields.at(1), '00:10.10');
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();

        final editedLyric = controller.sortedLines.firstWhere(
          (l) => l.id == firstLyric.id,
        );
        expect(editedLyric.startTimeMs, 10000);
        expect(editedLyric.endTimeMs, 10100);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  });
}
