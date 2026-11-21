import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/ui/widgets/continuous_auto_scroller.dart';
import 'package:live_call_studio/ui/widgets/timeline_editor_widget.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import 'support/mock_audioplayers_harness.dart';

String _buildLongReproLrc() {
  return '''
[00:00.00] 序章开始 准备挥棒
[00:04.50] 灯光亮起 舞台中央
[00:09.00] 呼吸同步 心跳加速
[00:13.50] 听见前奏 回响四周
[00:18.00] 挥起荧光 照亮夜空
[00:22.50] 全场准备 倒数迎接
[00:27.04] 第一句高潮 27秒定位测试
[00:30.14] 第二句衔接 30秒定位测试
[00:32.80] 第三句推进 32秒定位测试
[00:36.20] 第四句延续 36秒不漂移
[00:40.00] 第五句继续 40秒稳定居中
[00:44.00] 第六句合唱 44秒保持可见
[00:48.00] 第七句高音 48秒绝不跑偏
[00:52.00] 第八句加速 52秒依然准确
[00:56.00] 第九句情绪 56秒继续跟随
[01:00.00] 第十句一分钟 60秒正常到达
[01:02.60] 第十一句 62秒以后才会出现
[01:06.50] 第十二句 66秒后段旋律
[01:10.50] 第十三句 70秒继续演唱
[01:15.00] 第十四句 75秒尾声渐近
[01:20.00] 第十五句 80秒最终收尾句
''';
}

Future<void> _pumpAndSettleFrames(
  WidgetTester tester, {
  int steps = 16,
  Duration step = const Duration(milliseconds: 50),
}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(step);
  }
}

Future<void> _disposeApp(
  WidgetTester tester,
  CallbookController controller,
) async {
  if (controller.isPlaying) {
    await controller.togglePlay();
  }
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MockAudioplayersHarness().install();
  });

  group('Follow scroll, layout accessibility & PLAYING state regressions', () {
    testWidgets(
      'ContinuousAutoScroller.computeTargetOffset does not compound offset across nested shrinkWrap ListView inside SingleChildScrollView',
      (tester) async {
        final outerCtrl = ScrollController();
        final innerCtrl = ScrollController();
        final itemKeys = List.generate(24, (_) => GlobalKey());

        try {
          await tester.pumpWidget(
            prism.PrismApp(
              theme: prism.ThemeData(
                colorScheme: prism.seededColorScheme(
                  seedColor: const Color(0xFF66CCFF),
                  brightness: Brightness.light,
                ),
              ),
              home: SizedBox(
                width: 600,
                height: 500,
                child: SingleChildScrollView(
                  controller: outerCtrl,
                  child: Column(
                    children: [
                      const SizedBox(height: 180),
                      ListView.separated(
                        controller: innerCtrl,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: itemKeys.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (_, idx) => SizedBox(
                          key: itemKeys[idx],
                          height: 88,
                          child: Text('Item $idx'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final target6Initial = ContinuousAutoScroller.computeTargetOffset(
            scrollController: outerCtrl,
            itemContext: itemKeys[6].currentContext!,
            alignment: 0.42,
          )!;
          outerCtrl.jumpTo(target6Initial);
          await tester.pump();

          final target7AfterScroll = ContinuousAutoScroller.computeTargetOffset(
            scrollController: outerCtrl,
            itemContext: itemKeys[7].currentContext!,
            alignment: 0.42,
          )!;
          // Item 7 is exactly 96px (88 + 8) below item 6, so target offset
          // must advance by ~96px rather than adding target6Initial again.
          expect(target7AfterScroll - target6Initial, closeTo(96.0, 1.5));

          outerCtrl.jumpTo(target7AfterScroll);
          await tester.pump();

          final target8AfterScroll = ContinuousAutoScroller.computeTargetOffset(
            scrollController: outerCtrl,
            itemContext: itemKeys[8].currentContext!,
            alignment: 0.42,
          )!;
          expect(target8AfterScroll - target7AfterScroll, closeTo(96.0, 1.5));
        } finally {
          outerCtrl.dispose();
          innerCtrl.dispose();
        }
      },
    );

    testWidgets(
      'Repro 00:27.04 -> 00:30.14 -> 00:32.80, 10+ transitions without cumulative drift, and immediate locate on follow ON',
      timeout: const Timeout(Duration(seconds: 30)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        await controller.importLrcText(lrc: _buildLongReproLrc());
        controller.setFollowPlayback(false);

        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        try {
          final timelineFinder = find.byType(TimelineEditorWidget);
          final listViewFinder = find.descendant(
            of: timelineFinder,
            matching: find.byWidgetPredicate(
              (w) => w is ListView && w.scrollDirection == Axis.vertical,
            ),
          );
          final listView = tester.widget<ListView>(listViewFinder);
          final timelineSc = listView.controller!;
          expect(timelineSc.offset, 0.0);

          // Start playing with follow OFF, advance to ~25s -> viewport stays at 0.
          await controller.togglePlay();
          expect(controller.isPlaying, isTrue);
          await controller.seek(25000);
          await _pumpAndSettleFrames(tester);
          expect(timelineSc.offset, 0.0);

          // Turn follow ON via left switch -> immediately locates current line (~00:22.50)!
          await tester.ensureVisible(find.bySemanticsLabel('歌词时间轴跟随'));
          await tester.tap(find.bySemanticsLabel('歌词时间轴跟随'));
          await _pumpAndSettleFrames(tester);
          expect(controller.followPlayback, isTrue);
          expect(timelineSc.offset, greaterThan(100.0));

          // Both switches stay synchronized.
          final leftSwitch = tester.widget<prism.Switch>(
            find.byWidgetPredicate(
              (w) => w is prism.Switch && w.semanticLabel == '歌词时间轴跟随',
            ),
          );
          final rightSwitch = tester.widget<prism.Switch>(
            find.byWidgetPredicate(
              (w) => w is prism.Switch && w.semanticLabel == '跟随播放滚动',
            ),
          );
          expect(leftSwitch.value, isTrue);
          expect(rightSwitch.value, isTrue);

          final listBox = tester.renderObject<RenderBox>(listViewFinder);
          final listRect = listBox.localToGlobal(Offset.zero) & listBox.size;

          void expectLineVisibleInListViewport(String textSnippet) {
            final lineFinder = find.textContaining(textSnippet);
            expect(
              lineFinder,
              findsAtLeastNWidgets(1),
              reason: 'Expected "$textSnippet" to be mounted & visible',
            );
            final box = tester.renderObject<RenderBox>(lineFinder.first);
            final rect = box.localToGlobal(Offset.zero) & box.size;
            expect(
              rect.bottom,
              greaterThan(listRect.top),
              reason: '"$textSnippet" scrolled above viewport',
            );
            expect(
              rect.top,
              lessThan(listRect.bottom),
              reason: '"$textSnippet" scrolled below viewport',
            );
          }

          // Exact repro sequence: 00:27.04 -> 00:30.14 -> 00:32.80
          await controller.seek(27200);
          await _pumpAndSettleFrames(tester);
          expectLineVisibleInListViewport('第一句高潮 27秒定位测试');
          expect(find.textContaining('62秒以后才会出现'), findsNothing);

          await controller.seek(30300);
          await _pumpAndSettleFrames(tester);
          expectLineVisibleInListViewport('第二句衔接 30秒定位测试');
          expect(find.textContaining('62秒以后才会出现'), findsNothing);

          await controller.seek(33000);
          await _pumpAndSettleFrames(tester);
          expectLineVisibleInListViewport('第三句推进 32秒定位测试');
          expect(find.textContaining('62秒以后才会出现'), findsNothing);

          // Continue across >= 10 consecutive line transitions without cumulative drift.
          final lines = controller.sortedLines;
          final startIdx = lines.indexWhere(
            (l) => l.text.original.contains('第四句延续'),
          );
          expect(startIdx, greaterThanOrEqualTo(0));

          final centerErrors = <double>[];
          for (var i = startIdx; i < startIdx + 11 && i < lines.length; i++) {
            final line = lines[i];
            await controller.seek(line.startTimeMs + 200);
            await _pumpAndSettleFrames(tester);

            final snippet = line.text.original;
            expectLineVisibleInListViewport(snippet);

            final box = tester.renderObject<RenderBox>(
              find.textContaining(snippet).first,
            );
            final lineCenterY =
                box.localToGlobal(Offset.zero).dy + box.size.height / 2;
            final viewportCenterY = listRect.top + listRect.height * 0.42;
            // Ignore boundary-clamped last line if near maxScrollExtent.
            if (timelineSc.offset > 5.0 &&
                timelineSc.offset < timelineSc.position.maxScrollExtent - 5.0) {
              centerErrors.add((lineCenterY - viewportCenterY).abs());
            }
          }
          expect(centerErrors.length, greaterThanOrEqualTo(5));
          for (final err in centerErrors) {
            expect(err, lessThan(80.0));
          }

          // Left Hero player & right Sticky Call Toolbar stay visible after scrolling!
          final heroTitleFinder = find.text('播放状态');
          final toolbarFinder = find.text('编写工作台');
          expect(heroTitleFinder, findsOneWidget);
          expect(toolbarFinder, findsOneWidget);
          final heroRect =
              tester.renderObject<RenderBox>(heroTitleFinder).localToGlobal(
                    Offset.zero,
                  ) &
              tester.getSize(heroTitleFinder);
          final toolbarRect =
              tester.renderObject<RenderBox>(toolbarFinder).localToGlobal(
                    Offset.zero,
                  ) &
              tester.getSize(toolbarFinder);
          expect(heroRect.top, greaterThanOrEqualTo(0.0));
          expect(heroRect.bottom, lessThanOrEqualTo(820.0));
          expect(toolbarRect.top, greaterThanOrEqualTo(0.0));
          expect(toolbarRect.bottom, lessThanOrEqualTo(820.0));

          // Boundary test: seek to first line & last line cleanly.
          await controller.seek(lines.first.startTimeMs + 100);
          await _pumpAndSettleFrames(tester);
          expect(timelineSc.offset, closeTo(0.0, 1.0));
          expectLineVisibleInListViewport(lines.first.text.original);

          await controller.seek(lines.last.startTimeMs + 100);
          await _pumpAndSettleFrames(tester);
          expect(
            timelineSc.offset,
            closeTo(timelineSc.position.maxScrollExtent, 1.0),
          );
          expectLineVisibleInListViewport(lines.last.text.original);
        } finally {
          await _disposeApp(tester, controller);
        }
      },
    );

    testWidgets(
      'Pause/Resume PLAYING badge consistency & forward/backward seek while paused vs playing',
      timeout: const Timeout(Duration(seconds: 25)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        await controller.importLrcText(lrc: _buildLongReproLrc());

        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        try {
          // Initial paused state at 00:00.00: must NOT show PLAYING, shows 当前句 · 已暂停
          expect(controller.isPlaying, isFalse);
          expect(find.text('已暂停'), findsOneWidget);
          expect(find.text('PLAYING'), findsNothing);
          expect(find.text('当前句 · 已暂停'), findsOneWidget);

          // Seek while paused -> stays paused, updates current line & locates it
          await controller.seek(40200);
          await _pumpAndSettleFrames(tester);
          expect(controller.isPlaying, isFalse);
          expect(find.text('PLAYING'), findsNothing);
          expect(find.text('当前句 · 已暂停'), findsOneWidget);
          expect(find.textContaining('第五句继续 40秒稳定居中'), findsOneWidget);

          // Start playing -> PLAYING appears and 已暂停 chip disappears from line
          await controller.togglePlay();
          await tester.pump();
          expect(controller.isPlaying, isTrue);
          expect(find.text('播放中'), findsOneWidget);
          expect(find.text('PLAYING'), findsOneWidget);
          expect(find.text('当前句 · 已暂停'), findsNothing);

          // Pause -> PLAYING disappears immediately, 当前句 · 已暂停 returns
          await controller.togglePlay();
          await tester.pump();
          expect(controller.isPlaying, isFalse);
          expect(find.text('已暂停'), findsOneWidget);
          expect(find.text('PLAYING'), findsNothing);
          expect(find.text('当前句 · 已暂停'), findsOneWidget);

          // Seek backward with follow OFF -> does not move viewport, updates marker
          final listViewFinder = find.descendant(
            of: find.byType(TimelineEditorWidget),
            matching: find.byWidgetPredicate(
              (w) => w is ListView && w.scrollDirection == Axis.vertical,
            ),
          );
          final timelineSc = tester.widget<ListView>(listViewFinder).controller!;
          final offsetBefore = timelineSc.offset;

          controller.setFollowPlayback(false);
          await tester.pump();
          await controller.seek(500);
          await _pumpAndSettleFrames(tester);
          expect(timelineSc.offset, closeTo(offsetBefore, 0.5));
          expect(controller.playingLineId, controller.sortedLines.first.id);
        } finally {
          await _disposeApp(tester, controller);
        }
      },
    );

    testWidgets(
      'Variable row heights (GT alert, expanded inline editor, multiline) & editing focus preserved during playback transitions',
      timeout: const Timeout(Duration(seconds: 25)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        await controller.importLrcText(
          lrc: _buildLongReproLrc(),
          translationLrc: '''
[00:00.00] 翻译第一行\\n包含换行说明
[00:04.50] 翻译第二行\\n包含换行说明
[00:09.00] 翻译第三行
''',
        );
        controller.updateDisplayLayers(showTranslation: true);
        final lines = controller.sortedLines;
        controller.toggleLineGtAlert(lineId: lines[2].id);
        controller.updateLineGtAlert(lines[2].id, note: '超长 GT 警报备注用于验证动态行高测量');
        controller.selectLine(lines[1].id);

        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        try {
          // Focus inline custom shout TextField on lines[1] and type text.
          final shoutField = find.byWidgetPredicate(
            (w) =>
                w is prism.TextField &&
                w.decoration?.hintText == '输入自定义 Mix / 口上...',
          );
          expect(shoutField, findsOneWidget);
          await tester.tap(shoutField);
          await tester.pump();
          await tester.enterText(shoutField, 'Fuwa Fuwa!');
          await tester.pump();

          final editableBefore = tester.state<EditableTextState>(
            find.descendant(
              of: shoutField,
              matching: find.byType(EditableText),
            ),
          );
          expect(editableBefore.widget.focusNode.hasFocus, isTrue);

          // Play and advance far down the timeline (past lines[14])!
          await controller.togglePlay();
          await controller.seek(lines[14].startTimeMs + 200);
          await _pumpAndSettleFrames(tester);

          // Editing selection, text content, and focus on lines[1] remain intact!
          expect(controller.activeLineId, lines[1].id);
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == lines[1].id)
                .customShout,
            'Fuwa Fuwa!',
          );
          expect(editableBefore.widget.focusNode.hasFocus, isTrue);
          expect(
            find.textContaining(lines[14].text.original),
            findsOneWidget,
          );
        } finally {
          await _disposeApp(tester, controller);
        }
      },
    );

    testWidgets(
      'Narrow windows (900x800 & 420x800) reveal sticky compact transport bar on scroll without overflow',
      timeout: const Timeout(Duration(seconds: 25)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        await controller.importLrcText(lrc: _buildLongReproLrc());

        try {
          for (final size in [const Size(900, 800), const Size(420, 800)]) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            await tester.pumpWidget(LiveCallStudioApp(controller: controller));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 100));

            await controller.seek(48200);
            await _pumpAndSettleFrames(tester);

            expect(tester.takeException(), isNull);
            // Sticky bar appears with follow switch and locate chip.
            expect(find.bySemanticsLabel('悬浮条跟随播放滚动'), findsOneWidget);
            expect(find.text('定位'), findsOneWidget);

            // Current line remains visible and un-occluded above bottom tray on mobile.
            final lineFinder = find.textContaining('第七句高音 48秒绝不跑偏');
            expect(lineFinder, findsOneWidget);
            final stickyBarRect =
                tester.renderObject<RenderBox>(find.text('定位')).localToGlobal(
                      Offset.zero,
                    ) &
                tester.getSize(find.text('定位'));
            final lineRect =
                tester.renderObject<RenderBox>(lineFinder).localToGlobal(
                      Offset.zero,
                    ) &
                tester.getSize(lineFinder);
            expect(lineRect.top, greaterThan(stickyBarRect.bottom));
            if (size.width < 600) {
              final trayToggleFinder = find.text('收起速标');
              expect(trayToggleFinder, findsOneWidget);
              final trayTop = tester
                  .renderObject<RenderBox>(trayToggleFinder)
                  .localToGlobal(Offset.zero)
                  .dy;
              expect(lineRect.bottom, lessThanOrEqualTo(trayTop));
            }
          }
        } finally {
          await _disposeApp(tester, controller);
        }
      },
    );
  });
}
