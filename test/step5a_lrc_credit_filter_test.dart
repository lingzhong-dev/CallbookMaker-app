import 'dart:convert';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/services/api_client.dart';
import 'package:live_call_studio/services/lrclib_direct_client.dart';
import 'package:live_call_studio/services/netease_direct_client.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/ui/widgets/audio_source_panel.dart';
import 'package:live_call_studio/utils/lrc_ruby_parser.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mock_audioplayers_harness.dart';

class _TestUiLocalizations implements prism.UiLocalizations {
  const _TestUiLocalizations();

  @override
  String get back => 'Back';
  @override
  String get cancel => 'Cancel';
  @override
  String get clearSearch => 'Clear';
  @override
  String get close => 'Close';
  @override
  String get copy => 'Copy';
  @override
  String get cut => 'Cut';
  @override
  String get dialog => 'Dialog';
  @override
  String get hidePassword => 'Hide';
  @override
  String get more => 'More';
  @override
  String get noSearchResults => 'No results';
  @override
  String get paste => 'Paste';
  @override
  String get reset => 'Reset';
  @override
  String get select => 'Select';
  @override
  String get search => 'Search';
  @override
  String get selectAll => 'Select all';
  @override
  String get showLess => 'Show less';
  @override
  String get showMore => 'Show more';
  @override
  String get showPassword => 'Show';
  @override
  String get sort => 'Sort';
  @override
  String get submit => 'Submit';
}

class _TestUiLocalizationsDelegate
    extends LocalizationsDelegate<prism.UiLocalizations> {
  const _TestUiLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<prism.UiLocalizations> load(Locale locale) =>
      SynchronousFuture(const _TestUiLocalizations());

  @override
  bool shouldReload(
    covariant LocalizationsDelegate<prism.UiLocalizations> old,
  ) => false;
}

http.Response _jsonResp(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MockAudioplayersHarness().install();
  });

  group('Step 05-A: LRC Header Credit Filter & Recovery', () {
    test('parseLrcOfflineDetailed recognizes full-width and half-width credit lines within 10 lines / 20s and avoids false positives', () {
      const sampleLrc = '''
[00:00.50] 作词：田渊智也
[00:01.00] 作曲 : 田中秀和
[00:01.50] 編曲：MONACA
[00:02.00] 制作人: 山田太郎
[00:02.50] 混音：Studio A
[00:03.00] Vocal: Miku
[00:04.00] 她说：今夜不要停下
[00:08.00] 注意：全场准备起跳
[00:12.00] 12:30 的星光约定
[00:16.00] 演唱：
[00:18.00] 作曲：第11行超出前10条限制不应过滤
[00:22.00] 作词：超过20秒的不应过滤
''';

      // Default backwards-compatible parseLrcOffline preserves all lines unless opted in.
      expect(parseLrcOffline(sampleLrc).length, 12);

      // Detailed parse with filtering enabled removes only the 6 matched credit lines.
      final filtered = parseLrcOfflineDetailed(
        sampleLrc,
        filterHeaderCredits: true,
      );
      expect(filtered.originalLines.length, 12);
      expect(filtered.filteredCreditLines.length, 6);
      expect(
        filtered.filteredCreditLines.map((l) => l.text.original).toList(),
        [
          '作词：田渊智也',
          '作曲 : 田中秀和',
          '編曲：MONACA',
          '制作人: 山田太郎',
          '混音：Studio A',
          'Vocal: Miku',
        ],
      );
      expect(filtered.extractedMeta.lyricist, '田渊智也');
      expect(filtered.extractedMeta.composer, '田中秀和');
      expect(filtered.extractedMeta.arranger, 'MONACA');
      expect(filtered.extractedMeta.mixer, 'Studio A');
      expect(filtered.extractedMeta.vocalist, 'Miku');

      expect(
        filtered.lines.map((l) => l.text.original).toList(),
        [
          '她说：今夜不要停下',
          '注意：全场准备起跳',
          '12:30 的星光约定',
          '演唱：',
          '作曲：第11行超出前10条限制不应过滤',
          '作词：超过20秒的不应过滤',
        ],
      );

      // Toggle off keeps all lines and returns no filtered lines.
      final unfiltered = parseLrcOfflineDetailed(
        sampleLrc,
        filterHeaderCredits: false,
      );
      expect(unfiltered.lines.length, 12);
      expect(unfiltered.filteredCreditLines, isEmpty);
    });

    test('parseLrcOfflineDetailed never filters untimestamped plain text even within synthetic first 20s', () {
      const plainText = '''
作词：不带时间戳的第一行
作曲：不带时间戳的第二行
真正的普通歌词正文
''';
      final result = parseLrcOfflineDetailed(
        plainText,
        filterHeaderCredits: true,
      );
      expect(result.filteredCreditLines, isEmpty);
      expect(result.lines.length, 3);
      expect(result.lines.first.text.original, '作词：不带时间戳的第一行');
    });

    test('CallbookController fills only empty metadata, preserves offsetMs & lyric timestamps, and restores credits independently of Undo', () async {
      SharedPreferences.setMockInitialValues({'cbm_onboarding_done': true});
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      try {
        controller.updateMeta(
          lyricist: 'Manual Lyricist',
          composer: '',
          arranger: '',
        );
        controller.setOffset(180);

        await controller.importLrcText(
          lrc: '''
[00:01.00] 作词：LRC Lyricist
[00:02.00] 作曲：LRC Composer // 作曲：LRC Composer
[00:03.00] 编曲 : LRC Arranger
[00:12.00] 真实第一句歌词
[00:18.00] 真实第二句歌词
''',
        );

        // Undo stack was cleared by import, yet filtered credits stay recoverable.
        expect(controller.canUndo, isFalse);
        expect(controller.hasRestorableCreditLines, isTrue);
        expect(controller.restorableCreditLines.length, 3);

        // Existing manual lyricist is preserved; empty composer/arranger are filled.
        expect(controller.project.meta.lyricist, 'Manual Lyricist');
        expect(controller.project.meta.composer, 'LRC Composer');
        expect(controller.project.meta.arranger, 'LRC Arranger');

        // offsetMs and existing lyric timestamps were never altered.
        expect(controller.project.meta.offsetMs, 180);
        final firstLyricBeforeRestore = controller.sortedLines.firstWhere(
          (l) => l.text.original == '真实第一句歌词',
        );
        expect(firstLyricBeforeRestore.startTimeMs, 12000);
        expect(firstLyricBeforeRestore.endTimeMs, 18000);

        // Restore filtered credit lines cleanly even though Undo stack is empty.
        final restoredCount = controller.restoreFilteredCreditLines();
        expect(restoredCount, 3);
        expect(controller.hasRestorableCreditLines, isFalse);
        expect(controller.restorableCreditLines, isEmpty);
        expect(controller.project.meta.offsetMs, 180);

        final lyricsAfterRestore = controller.sortedLines
            .where((l) => !l.kind.isSection)
            .toList();
        expect(
          lyricsAfterRestore.map((l) => l.text.original).toList(),
          [
            '作词：LRC Lyricist',
            '作曲：LRC Composer',
            '编曲 : LRC Arranger',
            '真实第一句歌词',
            '真实第二句歌词',
          ],
        );
        expect(
          lyricsAfterRestore.firstWhere((l) => l.text.original == '真实第一句歌词').startTimeMs,
          12000,
        );

        // Turning filter off disables filtering on subsequent imports and persists.
        controller.setFilterLrcHeaderCredits(false);
        expect(controller.filterLrcHeaderCredits, isFalse);
        await controller.importLrcText(
          lrc: '''
[00:01.00] 作词：Should Keep
[00:08.00] Real lyric
''',
        );
        expect(controller.hasRestorableCreditLines, isFalse);
        expect(
          controller.sortedLines.any((l) => l.text.original == '作词：Should Keep'),
          isTrue,
        );
      } finally {
        controller.dispose();
      }
    });

    test('loadRemoteTrack respects filterLrcHeaderCredits, fills empty credits, and clears restorable lines on archive switch', () async {
      SharedPreferences.setMockInitialValues({'cbm_onboarding_done': true});
      final controller = CallbookController(
        apiClient: CallbookApiClient(
          baseUrl: 'http://127.0.0.1:8000',
          httpClient: MockClient((_) async => http.Response('offline', 503)),
        ),
        neteaseDirectClient: NeteaseDirectClient(
          httpClient: MockClient((_) async => http.Response('offline', 503)),
        ),
        lrclibDirectClient: LrclibDirectClient(
          httpClient: MockClient((req) async {
            if (req.url.path == '/api/get/9001') {
              return _jsonResp({
                'id': 9001,
                'trackName': 'Remote Test Song',
                'artistName': 'Test Unit',
                'duration': 90,
                'syncedLyrics': '''
[00:01.00] 作词：Remote Writer
[00:02.00] 作曲：Remote Composer
[00:10.00] 光を追い越して
[00:16.00] 走り出そう
''',
              });
            }
            return _jsonResp({});
          }),
        ),
        enableAudioOutput: false,
      );
      try {
        await controller.init();
        await controller.loadRemoteTrack(
          const TrackSummary(
            id: '9001',
            title: 'Remote Test Song',
            artist: 'Test Unit',
            platform: 'lrclib',
            provider: 'lrclib',
            durationMs: 90000,
          ),
        );

        expect(controller.hasRestorableCreditLines, isTrue);
        expect(controller.restorableCreditLines.length, 2);
        expect(controller.project.meta.lyricist, 'Remote Writer');
        expect(controller.project.meta.composer, 'Remote Composer');
        expect(
          controller.sortedLines.any((l) => l.text.original == '作词：Remote Writer'),
          isFalse,
        );

        // Switching to a default song / archive clears prior restorable credit lines.
        await controller.loadDefaultSong('sweets');
        expect(controller.hasRestorableCreditLines, isFalse);
      } finally {
        controller.dispose();
      }
    });

    testWidgets('AudioSourcePanel exposes filter toggle and one-click recovery at desktop and mobile viewports', (tester) async {
      for (final viewport in [const Size(1280, 820), const Size(390, 844)]) {
        SharedPreferences.setMockInitialValues({'cbm_onboarding_done': true});
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        final errors = <FlutterErrorDetails>[];
        final prevOnError = FlutterError.onError;
        FlutterError.onError = (details) => errors.add(details);
        var ownedByWidget = false;
        try {
          controller.setOffset(250);
          controller.saveCurrentToArchive(asNew: true);
          tester.view.physicalSize = viewport;
          tester.view.devicePixelRatio = 1.0;

          await tester.pumpWidget(
            prism.PrismApp(
              title: 'Step 05-A Test',
              theme: controller.buildPrismTheme(Brightness.light),
              darkTheme: controller.buildPrismTheme(Brightness.dark),
              themeMode: controller.themeMode,
              localizationsDelegates: const [
                _TestUiLocalizationsDelegate(),
                DefaultWidgetsLocalizations.delegate,
              ],
              supportedLocales: const [Locale('zh', 'CN'), Locale('zh')],
              home: prism.BannerHost(
                stacked: false,
                topInset: 0,
                child: SingleChildScrollView(
                  child: AudioSourcePanel(controller: controller),
                ),
              ),
            ),
          );
          ownedByWidget = true;
          await tester.pumpAndSettle();

          final panel = find.byType(AudioSourcePanel);
          final localTab = find.descendant(
            of: panel,
            matching: find.text('本地音轨 + LRC'),
          );
          await tester.ensureVisible(localTab);
          await tester.tap(localTab);
          await tester.pumpAndSettle();

          final filterSwitch = find.bySemanticsLabel('过滤片头制作信息');
          expect(filterSwitch, findsOneWidget);
          expect(controller.filterLrcHeaderCredits, isTrue);

          // Toggle off and back on via UI switch.
          await tester.ensureVisible(filterSwitch);
          await tester.tap(filterSwitch);
          await tester.pump();
          expect(controller.filterLrcHeaderCredits, isFalse);
          await tester.tap(filterSwitch);
          await tester.pump();
          expect(controller.filterLrcHeaderCredits, isTrue);

          final lrcInput = find.descendant(
            of: panel,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is prism.TextField &&
                  (w.decoration?.hintText?.contains('粘贴 LRC 歌词') ?? false),
            ),
          );
          await tester.enterText(
            lrcInput,
            '[00:01.00] 作词：Panel Writer\n[00:10.00] 真正的星光歌词',
          );
          await tester.pump();

          final parseBtn = find.descendant(
            of: panel,
            matching: find.text('解析并导入歌词'),
          );
          await tester.ensureVisible(parseBtn);
          await tester.tap(parseBtn);
          await tester.pumpAndSettle();

          expect(controller.hasRestorableCreditLines, isTrue);
          expect(controller.project.meta.offsetMs, 250);
          expect(
            controller.sortedLines.any((l) => l.text.original == '作词：Panel Writer'),
            isFalse,
          );

          final restoreChip = find.descendant(
            of: panel,
            matching: find.text('恢复被过滤的制作信息行'),
          );
          expect(restoreChip, findsOneWidget);
          await tester.ensureVisible(restoreChip);
          await tester.tap(restoreChip);
          await tester.pumpAndSettle();

          expect(controller.hasRestorableCreditLines, isFalse);
          expect(controller.project.meta.offsetMs, 250);
          expect(
            controller.sortedLines.any((l) => l.text.original == '作词：Panel Writer'),
            isTrue,
          );
          expect(errors, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          FlutterError.onError = prevOnError;
          if (ownedByWidget) {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          }
          controller.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      }
    });
  });
}
