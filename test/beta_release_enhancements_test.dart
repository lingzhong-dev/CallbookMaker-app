import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_call_studio/data/default_songs.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/ui/export_view.dart';
import 'package:live_call_studio/ui/home_shell.dart';
import 'package:live_call_studio/ui/theme_view.dart';
import 'package:live_call_studio/ui/widgets/call_badge_pill.dart';
import 'package:live_call_studio/ui/widgets/callbook_glyphs.dart';
import 'package:live_call_studio/ui/widgets/timeline_editor_widget.dart';
import 'package:live_call_studio/utils/color_parser.dart';
import 'package:live_call_studio/utils/lrc_ruby_parser.dart';
import 'package:live_call_studio/utils/section_detector.dart';
import 'package:live_call_studio/utils/xlsx_export.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mock_audioplayers_harness.dart';

Map<String, String> _unzipXmlEntries(Uint8List zipBytes) {
  final out = <String, String>{};
  final bd = ByteData.sublistView(zipBytes);
  var offset = 0;
  while (offset + 30 <= zipBytes.length) {
    final sig = bd.getUint32(offset, Endian.little);
    if (sig != 0x04034B50) break;
    final method = bd.getUint16(offset + 8, Endian.little);
    final compSize = bd.getUint32(offset + 18, Endian.little);
    final nameLen = bd.getUint16(offset + 26, Endian.little);
    final extraLen = bd.getUint16(offset + 28, Endian.little);
    final nameStart = offset + 30;
    final dataStart = nameStart + nameLen + extraLen;
    final name = utf8.decode(zipBytes.sublist(nameStart, nameStart + nameLen));
    final payload = zipBytes.sublist(dataStart, dataStart + compSize);
    final raw = method == 8 ? ZLibCodec(raw: true).decode(payload) : payload;
    out[name] = utf8.decode(raw);
    offset = dataStart + compSize;
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MockAudioplayersHarness().install();
  });

  group('Req 1: Light mode tile-vs-background contrast', () {
    test('SurfaceLevel separates page, card, block, and inset in light mode while keeping dark mode unchanged', () {
      final light = prism.seededColorScheme(
        seedColor: const Color(0xFF66CCFF),
        brightness: Brightness.light,
        style: prism.ColorStyle.vivid,
      );
      final page = prism.SurfaceLevel.page.colorOf(light);
      final card = prism.SurfaceLevel.card.colorOf(light);
      final block = prism.SurfaceLevel.block.colorOf(light);
      final inset = prism.SurfaceLevel.inset.colorOf(light);

      expect(card, equals(light.surfaceContainerLowest));
      expect(page.toARGB32(), isNot(equals(card.toARGB32())));
      expect(card.computeLuminance() - page.computeLuminance(), greaterThan(0.05));
      expect(card.toARGB32(), isNot(equals(block.toARGB32())));
      expect(block.toARGB32(), isNot(equals(inset.toARGB32())));

      final dark = prism.seededColorScheme(
        seedColor: const Color(0xFF66CCFF),
        brightness: Brightness.dark,
        style: prism.ColorStyle.vivid,
      );
      expect(prism.SurfaceLevel.page.colorOf(dark), dark.surface);
      expect(prism.SurfaceLevel.card.colorOf(dark), dark.surfaceContainer);
    });

    testWidgets('Unselected non-section timeline cards gain subtle border in light mode', (tester) async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      controller.setThemeMode(prism.ThemeMode.light);
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;

      try {
        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));

        final unselectedCards = tester.widgetList<prism.Card>(
          find.descendant(
            of: find.byType(TimelineEditorWidget),
            matching: find.byWidgetPredicate(
              (w) => w is prism.Card && !w.isSelected && w.shape is RoundedSuperellipseBorder,
            ),
          ),
        );
        expect(unselectedCards, isNotEmpty);
        final hasBorderedCard = unselectedCards.any((c) {
          final shape = c.shape! as RoundedSuperellipseBorder;
          return shape.side != BorderSide.none && shape.side.width > 0;
        });
        expect(hasBorderedCard, isTrue);
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });
  });

  group('Req 2 & Theme Hex: arranger, mixer, supportColor & ThemeView custom hex', () {
    test('CallProjectMeta serializes arranger, mixer, supportColor and extractSupportColor parses hex/name', () {
      const meta = CallProjectMeta(
        title: 'Test Song',
        artist: 'Vocaloid',
        composer: 'CompA',
        lyricist: 'LyricB',
        arranger: 'ArrC',
        mixer: 'MixD',
        vocalist: 'Miku',
        supportColor: '初音绿 #39C5BB',
      );
      final roundtrip = CallProjectMeta.fromJson(meta.toJson());
      expect(roundtrip.arranger, 'ArrC');
      expect(roundtrip.mixer, 'MixD');
      expect(roundtrip.supportColor, '初音绿 #39C5BB');

      final legacy = CallProjectMeta.fromJson(const {'title': 'Old', 'artist': 'OldArtist'});
      expect(legacy.arranger, '');
      expect(legacy.mixer, '');
      expect(legacy.supportColor, '');

      expect(extractSupportColor('#FF6699'), const Color(0xFFFF6699));
      expect(extractSupportColor('39c5bb'), const Color(0xFF39C5BB));
      expect(extractSupportColor('天依蓝 #66CCFF'), const Color(0xFF66CCFF));
      expect(extractSupportColor('初音绿'), const Color(0xFF39C5BB));
    });

    test('buildCallBookXlsxBytes includes arranger, mixer, supportColor & updated merge range', () {
      final base = defaultPrimarySong.buildCleanProject();
      final proj = base.copyWith(
        meta: base.meta.copyWith(
          arranger: 'litterzy',
          mixer: 'CreuzerMix',
          supportColor: '#66CCFF',
          tuner: '',
          showTuner: false,
        ),
      );
      final noTunerBytes = buildCallBookXlsxBytes(proj, defaultCallPresets);
      final noTunerEntries = _unzipXmlEntries(noTunerBytes);
      expect(noTunerEntries['xl/sharedStrings.xml'], contains('编曲：'));
      expect(noTunerEntries['xl/sharedStrings.xml'], contains('混音：'));
      expect(noTunerEntries['xl/sharedStrings.xml'], contains('应援色：'));
      expect(noTunerEntries['xl/sharedStrings.xml'], contains('CreuzerMix'));
      expect(noTunerEntries['xl/sharedStrings.xml'], contains('#66CCFF'));
      expect(noTunerEntries['xl/worksheets/sheet1.xml'], contains('<mergeCell ref="A3:B7"/>'));

      final withTunerBytes = buildCallBookXlsxBytes(
        proj.copyWith(meta: proj.meta.copyWith(showTuner: true, tuner: 'TunerX')),
        defaultCallPresets,
      );
      final withTunerEntries = _unzipXmlEntries(withTunerBytes);
      expect(withTunerEntries['xl/sharedStrings.xml'], contains('调教：'));
      expect(withTunerEntries['xl/worksheets/sheet1.xml'], contains('<mergeCell ref="A3:B8"/>'));
    });

    testWidgets('ThemeView supports custom hexadecimal support color input and updates controller.seedColor', (tester) async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;

      try {
        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
        controller.setRoute(StudioRoute.more);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        await tester.tap(find.text('主题'));
        await tester.pumpAndSettle();

        expect(find.byType(ThemeView), findsOneWidget);
        expect(find.text('自定义十六进制应援色 (#RRGGBB)'), findsOneWidget);

        final hexInputFinder = find.descendant(
          of: find.ancestor(
            of: find.text('自定义十六进制应援色 (#RRGGBB)'),
            matching: find.byType(Column),
          ).first,
          matching: find.byType(prism.TextField),
        );
        expect(hexInputFinder, findsOneWidget);
        await tester.enterText(hexInputFinder, '#FF6699');
        await tester.tap(find.text('应用'));
        await tester.pumpAndSettle();

        expect(controller.seedColor, const Color(0xFFFF6699));
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });
  });

  group('Req 3: Non-blocking startup init & instant launch', () {
    testWidgets('LiveCallStudioApp mounts HomeShell immediately on first frame without a splash overlay', (tester) async {
      SharedPreferences.setMockInitialValues({
        'live_call_studio_onboarding_v1': true,
      });
      final controller = CallbookController(enableAudioOutput: false);
      expect(controller.isLocalInitDone, isFalse);
      await controller.init(awaitBackgroundSync: false);
      expect(controller.isLocalInitDone, isTrue);

      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;

      try {
        await tester.pumpWidget(
          LiveCallStudioApp(controller: controller),
        );
        await tester.pump();

        expect(find.byType(HomeShell), findsOneWidget);
        expect(find.text('正在准备演练工作台…'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });
  });

  group('Req 4: Default LRC replacement, interlude coalescing, legacy migration & auto-follow', () {
    test('Default songs match replaced LRCs with single coalesced interludes & full Ruby/Romaji/Translation', () {
      final vanaheim = defaultSongs[0];
      expect(vanaheim.project.meta.arranger, 'litterzy');
      expect(vanaheim.project.meta.supportColor, '#66CCFF');
      final vLyricRaw = vanaheim.project.lines.where((l) => !l.kind.isSection).toList();
      expect(vLyricRaw.length, 33);
      expect(vLyricRaw.first.startTimeMs, 782);
      expect(vLyricRaw.first.text.original, '带我捕捉那道光芒向更远远方');
      expect(vLyricRaw.last.startTimeMs, 202824);
      final vClean = vanaheim.buildCleanProject();
      expect(vClean.lines.where((l) => l.kind == LyricLineKind.interlude).length, 3);
      expect(vClean.lines.where((l) => l.kind == LyricLineKind.outro).length, 1);

      final wim = defaultSongs[2];
      expect(wim.project.meta.arranger, 'ryo (supercell)');
      expect(wim.project.meta.supportColor, '#39C5BB');
      final wClean = wim.buildCleanProject();
      final wLyrics = wClean.lines.where((l) => !l.kind.isSection).toList();
      expect(wLyrics.length, 53);
      expect(wLyrics.first.startTimeMs, 680);
      expect(wLyrics.first.text.original, '世界で一番おひめさま');
      expect(wClean.lines.where((l) => l.kind == LyricLineKind.interlude).length, 3);
      expect(wClean.lines.where((l) => l.kind == LyricLineKind.outro).length, 1);

      // No two consecutive section rows share interlude kind
      for (var i = 0; i < wClean.lines.length - 1; i++) {
        if (wClean.lines[i].kind == LyricLineKind.interlude) {
          expect(wClean.lines[i + 1].kind, isNot(LyricLineKind.interlude));
        }
      }

      // All 53 lyric lines have complete Ruby/Romaji/Chinese translation
      expect(wLyrics.every((l) => (l.text.ruby ?? '').isNotEmpty), isTrue);
      expect(wLyrics.every((l) => (l.text.romaji ?? '').trim().isNotEmpty), isTrue);
      expect(wLyrics.every((l) => (l.text.translation ?? '').trim().isNotEmpty), isTrue);
    });

    test('parseLrcOffline recognizes 【间奏】/【尾奏】 and detectAndMergeSections coalesces consecutive interludes', () {
      const sampleLrc = '''
[00:00.68]世界で一番おひめさま
[00:05.99]そういう扱い 心得てよね
[00:17.68]【间奏】
[00:28.53]その一 いつもと違う髪形に気が付くこと
[03:48.54]……こっちのが危ないわよ
[03:51.54]【尾奏】
''';
      final parsed = parseLrcOffline(sampleLrc);
      expect(parsed[2].kind, LyricLineKind.interlude);
      expect(parsed[2].autoGenerated, isFalse);
      expect(parsed.last.kind, LyricLineKind.outro);
      expect(parsed.last.autoGenerated, isFalse);

      final merged = detectAndMergeSections(parsed, totalDurationMs: 255000);
      final interludesBetweenFirstAndThird = merged.lines
          .where((l) => l.kind == LyricLineKind.interlude && l.startTimeMs < 30000)
          .toList();
      expect(interludesBetweenFirstAndThird.length, 1);
      expect(interludesBetweenFirstAndThird.first.startTimeMs, 17680);

      // Also verify two manually/auto colliding consecutive interludes merge cleanly while keeping Calls
      final dupInterludes = detectAndMergeSections([
        const LyricLine(
          id: 'l1',
          startTimeMs: 0,
          endTimeMs: 6000,
          text: LyricText(original: 'Line 1'),
        ),
        const LyricLine(
          id: 'sec-a',
          startTimeMs: 6000,
          endTimeMs: 14000,
          kind: LyricLineKind.interlude,
          autoGenerated: false,
          calls: [LineCallTag(presetId: 'clap')],
          text: LyricText(original: '【间奏】'),
        ),
        const LyricLine(
          id: 'sec-b',
          startTimeMs: 14000,
          endTimeMs: 24000,
          kind: LyricLineKind.interlude,
          autoGenerated: false,
          calls: [LineCallTag(presetId: 'front-wave')],
          customShout: 'Tiger Mix',
          text: LyricText(original: '【间奏】'),
        ),
        const LyricLine(
          id: 'l2',
          startTimeMs: 24000,
          endTimeMs: 28000,
          text: LyricText(original: 'Line 2'),
        ),
      ]);
      final mergedInts = dupInterludes.lines.where((l) => l.kind == LyricLineKind.interlude).toList();
      expect(mergedInts.length, 1);
      expect(mergedInts.first.startTimeMs, 6000);
      expect(mergedInts.first.endTimeMs, 24000);
      expect(mergedInts.first.calls.map((c) => c.presetId).toList(), ['clap', 'front-wave']);
      expect(mergedInts.first.customShout, 'Tiger Mix');
    });

    test('Controller upgrades untouched legacy default project while preserving tagged user archives', () async {
      const legacyVanaheim = CallProject(
        meta: CallProjectMeta(
          title: '来自瓦纳海姆',
          artist: '洛天依',
          platform: 'netease',
          bpm: 148,
          composer: 'litterzy',
          lyricist: '冥凰',
          vocalist: '洛天依',
          tuner: 'Creuzer',
          showTuner: true,
        ),
        lines: [
          LyricLine(
            id: 'old-van-1',
            startTimeMs: 12000,
            endTimeMs: 19000,
            text: LyricText(original: '带我捕捉那道光芒 向更远远方'),
          ),
        ],
      );
      final taggedArchive = CallbookArchiveEntry(
        id: 'arch-user-tagged',
        name: '来自瓦纳海姆',
        createdAt: 1000,
        savedAt: 2000,
        project: legacyVanaheim.copyWith(
          lines: [
            legacyVanaheim.lines.first.copyWith(
              calls: const [LineCallTag(presetId: 'front-wave')],
            ),
          ],
        ),
        customPresets: const [],
        lineCount: 1,
        taggedCount: 1,
        alertCount: 0,
      );

      final ctrl = await createTestCallbookController(
        enableAudioOutput: false,
        initialPrefs: {
          'live_call_studio_onboarding_v1': true,
          'live_call_studio_project_v1': jsonEncode(legacyVanaheim.toJson()),
          'live_call_studio_archives_v1': jsonEncode([taggedArchive.toJson()]),
        },
      );
      try {
        expect(ctrl.sortedLines.where((l) => !l.kind.isSection).first.startTimeMs, 782);
        expect(ctrl.project.meta.arranger, 'litterzy');
        expect(ctrl.archives.first.project.lines.first.startTimeMs, 12000);
        expect(ctrl.archives.first.project.lines.first.calls, isNotEmpty);
      } finally {
        ctrl.dispose();
      }
    });

    test('addEmptyLine and addSectionLine trim overlapping prior lines, extend duration, and follow immediately', () async {
      final ctrl = await createTestCallbookController(enableAudioOutput: false);
      try {
        await ctrl.importLrcText(
          lrc: '''
[00:00.00] First wide line
[00:12.00] Second line
''',
        );
        await ctrl.seek(2000);
        expect(ctrl.playingLineId, ctrl.sortedLines.first.id);

        var syncFired = 0;
        ctrl.playbackSyncListenable.addListener(() => syncFired++);

        ctrl.addEmptyLine();
        final addedLine = ctrl.sortedLines.firstWhere((l) => l.text.original == '新歌词行（点击编辑）');
        expect(addedLine.startTimeMs, 2000);
        expect(ctrl.sortedLines.first.endTimeMs, 2000);
        expect(ctrl.playingLineId, addedLine.id);
        expect(ctrl.followTargetLineId, addedLine.id);
        expect(syncFired, greaterThanOrEqualTo(1));

        // Seek inside auto-generated interlude and insert another manual lyric line
        await ctrl.seek(6000);
        ctrl.addEmptyLine();
        final addedSecond = ctrl.sortedLines.firstWhere((l) => l.startTimeMs == 6000);
        expect(ctrl.playingLineId, addedSecond.id);
        expect(ctrl.followTargetLineId, addedSecond.id);

        // Add outro past existing project duration and seek into it
        ctrl.addSectionLine(
          kind: LyricLineKind.outro,
          startTimeMs: 300000,
          endTimeMs: 315000,
        );
        expect(ctrl.durationMs, greaterThanOrEqualTo(315000));
        await ctrl.seek(305000);
        final outro = ctrl.sortedLines.lastWhere((l) => l.kind == LyricLineKind.outro);
        expect(ctrl.playingLineId, outro.id);
        expect(ctrl.followTargetLineId, outro.id);
      } finally {
        ctrl.dispose();
      }
    });
  });

  group('Req 5 & 6: Windows binary naming & approved copy overrides', () {
    test('Windows CMakeLists, Runner.rc, and CallbookMaker.iss configure CallbookMaker.exe', () {
      final cmake = File('windows/CMakeLists.txt').readAsStringSync();
      final rc = File('windows/runner/Runner.rc').readAsStringSync();
      final iss = File('windows/installer/CallbookMaker.iss').readAsStringSync();

      expect(cmake, contains('set(BINARY_NAME "CallbookMaker")'));
      expect(rc, contains('VALUE "InternalName", "CallbookMaker"'));
      expect(rc, contains('VALUE "OriginalFilename", "CallbookMaker.exe"'));
      expect(iss, contains('#define MyAppExeName "CallbookMaker.exe"'));
      expect(iss, contains('[InstallDelete]'));
      expect(iss, contains(r'{app}\live_call_studio.exe'));
    });

    testWidgets('Finalized copy overrides and simplified Export footer are active while PPPH is preserved', (tester) async {
      expect(defaultCallPresets.any((p) => p.label == 'PPPH'), isTrue);

      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;

      try {
        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
        expect(find.text('Made with ❤ by 澪终'), findsOneWidget);

        controller.setRoute(StudioRoute.export);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        expect(find.byType(ExportView), findsOneWidget);
        expect(find.text('可导出PNG长图和Excel来分享与整合'), findsOneWidget);
        expect(find.text('共 ${controller.sortedLines.length} 句歌词'), findsOneWidget);

        controller.setRoute(StudioRoute.more);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        expect(find.text('更改主题色与其他高级设置'), findsOneWidget);
        expect(find.text('关于CallbookMaker'), findsOneWidget);
        expect(find.text('配置网易云 Cookie 与内置日语注音'), findsOneWidget);

        await tester.tap(find.text('关于'));
        await tester.pumpAndSettle();
        expect(find.text('LingZhong · CallbookMaker'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('返回更多'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('主题'));
        await tester.pumpAndSettle();
        expect(find.text('HCT 色彩调色盘'), findsOneWidget);
        expect(find.text('应援色预设'), findsOneWidget);
        expect(find.text('Callbook Maker'), findsWidgets);
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });
  });

  group('Hotfixes: Windows startup white screen & workbench shortcut visibility', () {
    test('Windows startup avoids SetWindowCompositionAttribute backgroundColor and uses WS_CLIPCHILDREN + surface nudge', () {
      final mainDart = File('lib/main.dart').readAsStringSync();
      final win32Cpp = File('windows/runner/win32_window.cpp').readAsStringSync();
      final flutterWinCpp =
          File('windows/runner/flutter_window.cpp').readAsStringSync();

      expect(mainDart, isNot(contains('backgroundColor:')));
      expect(mainDart, contains('addPostFrameCallback'));
      expect(win32Cpp, contains('window_class.hbrBackground = 0;'));
      expect(win32Cpp, contains('WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN'));
      expect(flutterWinCpp, isNot(contains('this->Show()')));
      expect(flutterWinCpp, contains('WM_SHOWWINDOW'));
      expect(flutterWinCpp, contains('kInitialSurfaceNudgeTimerId'));
    });

    testWidgets('CallBadgePill keeps shortcut digit visible when selected and showShortcut is true, but hides it by default', (tester) async {
      final preset = defaultCallPresets.firstWhere((p) => p.shortcut == '3');
      final controller = CallbookController();

      try {
        await tester.pumpWidget(
          prism.PrismApp(
            theme: controller.buildPrismTheme(Brightness.light),
            home: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CallBadgePill(
                  key: const ValueKey('selected-with-shortcut'),
                  preset: preset,
                  selected: true,
                  showShortcut: true,
                ),
                CallBadgePill(
                  key: const ValueKey('selected-default'),
                  preset: preset,
                  selected: true,
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        expect(
          find.descendant(
            of: find.byKey(const ValueKey('selected-with-shortcut')),
            matching: find.text('3'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('selected-default')),
            matching: find.text('3'),
          ),
          findsNothing,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        controller.dispose();
      }
    });

    testWidgets('Workbench preset pill retains its shortcut digit after tapping to select', (tester) async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;

      try {
        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();

        final workbenchPillFinder = find.byWidgetPredicate(
          (w) =>
              w is CallBadgePill &&
              w.preset.shortcut == '3' &&
              w.showShortcut,
        );
        expect(workbenchPillFinder, findsOneWidget);
        expect(
          find.descendant(of: workbenchPillFinder, matching: find.text('3')),
          findsOneWidget,
        );

        await tester.tap(workbenchPillFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        final selectedWorkbenchPillFinder = find.byWidgetPredicate(
          (w) =>
              w is CallBadgePill &&
              w.preset.shortcut == '3' &&
              w.showShortcut &&
              w.selected,
        );
        expect(selectedWorkbenchPillFinder, findsOneWidget);
        expect(
          find.descendant(
            of: selectedWorkbenchPillFinder,
            matching: find.text('3'),
          ),
          findsOneWidget,
        );
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });

    testWidgets('Sidebar theme toggle shows Material 3 moon in light mode and sun in dark mode', (tester) async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      controller.setThemeMode(prism.ThemeMode.light);
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;

      try {
        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();

        expect(find.byIcon(CallbookGlyphs.darkModeOutlined), findsOneWidget);
        expect(find.byIcon(CallbookGlyphs.lightModeOutlined), findsNothing);

        await tester.tap(find.byIcon(CallbookGlyphs.darkModeOutlined));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(controller.themeMode, prism.ThemeMode.dark);
        expect(find.byIcon(CallbookGlyphs.lightModeOutlined), findsOneWidget);
        expect(find.byIcon(CallbookGlyphs.darkModeOutlined), findsNothing);
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });
  });
}
