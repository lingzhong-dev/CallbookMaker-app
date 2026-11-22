import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kuromoji_dart/kuromoji_dart.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/services/api_client.dart';
import 'package:live_call_studio/services/japanese_ruby_annotator.dart';
import 'package:live_call_studio/services/lrclib_direct_client.dart';
import 'package:live_call_studio/services/netease_direct_client.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/ui/export_view.dart';
import 'package:live_call_studio/ui/widgets/ruby_lyric_text.dart';
import 'package:live_call_studio/utils/aligned_calls.dart';
import 'package:live_call_studio/utils/lrc_ruby_parser.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';

http.Response _jsonResp(Object data) => http.Response.bytes(
  utf8.encode(jsonEncode(data)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  const dictDir = 'packages/kuromoji_dart/assets/dict';

  group('Built-in offline Japanese Ruby & Romaji annotator (kuromoji_dart)', () {
    late Tokenizer tokenizer;
    late JapaneseRubyAnnotator annotator;

    setUpAll(() async {
      // Also verifies Isolate.run transfer of Tokenizer works cleanly.
      final loaded = DictionaryLoader.readDirectorySync(dictDir);
      tokenizer = await Isolate.run(
        () => Tokenizer.fromCompressedAssets(
          compressedFiles: loaded.compressed,
          charDef: loaded.charDef,
        ),
      );
      annotator = JapaneseRubyAnnotator(tokenizer: tokenizer);
    });

    test('annotates Japanese lyrics with okurigana-stripped <ruby> and Hepburn romaji', () {
      final wim = JapaneseRubyAnnotator.annotateText(
        tokenizer,
        '世界で一番おひめさま',
      );
      expect(wim.hasRuby, isTrue);
      expect(wim.rubyHtml, contains('<ruby>世界<rt>せかい</rt></ruby>'));
      expect(wim.rubyHtml, contains('<ruby>一番<rt>いちばん</rt></ruby>'));
      expect(
        parseRubySegments(wim.rubyHtml, '世界で一番おひめさま')
            .map((s) => s.base)
            .join(),
        '世界で一番おひめさま',
      );
      expect(wim.romaji.toLowerCase(), contains('sekai de ichiban'));
      expect(
        wim.romaji.toLowerCase().replaceAll(' ', ''),
        contains('ohimesama'),
      );

      final wimKanji = JapaneseRubyAnnotator.annotateText(
        tokenizer,
        '世界で一番お姫様',
      );
      expect(wimKanji.rubyHtml, contains('お<ruby>姫様<rt>ひめさま</rt></ruby>'));
      expect(wimKanji.romaji.toLowerCase(), contains('ohimesama'));

      // Okurigana should stay outside <ruby> tags
      final verb = JapaneseRubyAnnotator.annotateText(tokenizer, '食べる');
      expect(verb.rubyHtml, '<ruby>食<rt>た</rt></ruby>べる');

      // Particles は -> wa, へ -> e, を -> wo
      final particles = JapaneseRubyAnnotator.annotateText(
        tokenizer,
        '私は君へ歌を届ける',
      );
      expect(particles.romaji.toLowerCase(), contains('watashi wa'));
      expect(particles.romaji.toLowerCase(), contains('kimi e'));
      expect(particles.romaji.toLowerCase(), contains('uta wo'));

      // Emoji / ASCII mixed lines must not throw
      final mixed = JapaneseRubyAnnotator.annotateText(
        tokenizer,
        '✨Forever 未来へ！🎵',
      );
      expect(mixed.rubyHtml, contains('<ruby>未来<rt>みらい</rt></ruby>'));
      expect(mixed.romaji, contains('Forever'));
    });

    test('automatically skips Chinese-only songs without mis-annotating kanji', () async {
      final chineseLines = parseLrcOffline('''
[00:01.00]棉花糖甜到爆炸嘴巴停不掉
[00:05.00]带我捕捉那道光芒向更远远方
''');
      final out = await annotator.annotateLines(chineseLines);
      expect(out.every((l) => l.text.ruby == null), isTrue);
      expect(out.every((l) => l.text.romaji == null), isTrue);
    });

    test('Netease romalrc preference blends official romaji with offline <ruby> and fills gaps', () async {
      SharedPreferences.setMockInitialValues({
        'live_call_studio_onboarding_v1': true,
      });

      final neteaseClient = NeteaseDirectClient(
        httpClient: MockClient((req) async {
          if (req.url.path == '/eapi/song/lyric/v1') {
            return _jsonResp({
              'code': 200,
              'lrc': {
                'lyric': '[00:01.00]世界で一番おひめさま\n[00:06.00]君の笑顔が好きだよ\n',
              },
              'tlyric': {
                'lyric': '[00:01.00]世界上最可爱的公主殿下\n[00:06.00]喜欢你的笑容\n',
              },
              'romalrc': {
                // Only line 1 has official Netease romalrc; line 2 is missing
                'lyric': '[00:01.00]Se ka i de i chi ba n o hi me sa ma\n',
              },
            });
          }
          if (req.url.path == '/eapi/v3/song/detail') {
            return _jsonResp({
              'code': 200,
              'songs': [
                {
                  'id': 424242,
                  'name': 'ワールドイズマイン',
                  'dt': 250000,
                  'ar': [{'name': 'ryo'}],
                  'al': {'name': 'supercell'},
                },
              ],
            });
          }
          return _jsonResp({'code': 200, 'data': []});
        }),
      );

      final controller = CallbookController(
        apiClient: CallbookApiClient(
          httpClient: MockClient((_) async => http.Response('offline', 503)),
        ),
        neteaseDirectClient: neteaseClient,
        lrclibDirectClient: LrclibDirectClient(
          httpClient: MockClient((_) async => _jsonResp([])),
        ),
        rubyAnnotator: annotator,
        enableAudioOutput: false,
      );
      await controller.init(awaitBackgroundSync: false);

      const summary = TrackSummary(
        id: '424242',
        platform: 'netease',
        title: 'ワールドイズマイン',
        artist: 'ryo',
        durationMs: 250000,
        provider: 'netease_direct',
      );

      // 1) Default preferNeteaseRomaLrc = true: line 1 keeps Netease romalrc + offline ruby;
      //    line 2 fills romaji via offline annotator.
      expect(controller.offlineRubyEnabled, isTrue);
      expect(controller.preferNeteaseRomaLrc, isTrue);
      await controller.loadRemoteTrack(summary);
      var lyrics = controller.sortedLines.where((l) => !l.kind.isSection).toList();
      expect(lyrics.length, 2);
      expect(lyrics[0].text.ruby, contains('<ruby>世界<rt>せかい</rt></ruby>'));
      expect(lyrics[0].text.romaji, 'Se ka i de i chi ba n o hi me sa ma');
      expect(lyrics[1].text.ruby, contains('<ruby>笑顔<rt>えがお</rt></ruby>'));
      expect((lyrics[1].text.romaji ?? '').toLowerCase(), contains('egao'));

      // 2) Turn off preferNeteaseRomaLrc: line 1 switches to offline Hepburn romaji.
      controller.setPreferNeteaseRomaLrc(false);
      await controller.loadRemoteTrack(summary);
      lyrics = controller.sortedLines.where((l) => !l.kind.isSection).toList();
      expect(lyrics[0].text.romaji, isNot('Se ka i de i chi ba n o hi me sa ma'));
      expect((lyrics[0].text.romaji ?? '').toLowerCase(), contains('sekai'));

      controller.dispose();
    });
  });

  group('Simplified GatewayConfigPanel & Mobile Quick-Tag Floating Card', () {
    testWidgets('Mobile dark & light quick-tag floating tray renders cleanly with elevated border and zero overflow', (tester) async {
      SharedPreferences.setMockInitialValues({
        'live_call_studio_onboarding_v1': true,
      });
      final controller = CallbookController(
        apiClient: CallbookApiClient(
          httpClient: MockClient((_) async => http.Response('offline', 503)),
        ),
        enableAudioOutput: false,
      );
      await controller.init(awaitBackgroundSync: false);
      controller.setThemeMode(prism.ThemeMode.dark);

      final captured = <FlutterErrorDetails>[];
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (d) => captured.add(d);

      try {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 280));

        expect(find.text('打完跳下句'), findsOneWidget);
        expect(find.text('收起速标'), findsOneWidget);
        expect(captured, isEmpty);
        expect(tester.takeException(), isNull);

        // Switch to light theme too
        controller.setThemeMode(prism.ThemeMode.light);
        await tester.pumpAndSettle();
        expect(find.text('打完跳下句'), findsOneWidget);
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

  group('Aligned Call Romaji & Export Layer Toggles (Scheme C)', () {
    late Tokenizer tokenizer;

    setUpAll(() async {
      final loaded = DictionaryLoader.readDirectorySync(dictDir);
      tokenizer = await Isolate.run(
        () => Tokenizer.fromCompressedAssets(
          compressedFiles: loaded.compressed,
          charDef: loaded.charDef,
        ),
      );
    });

    test('AlignedCallCue preserves cue romaji through JSON, normalize, merge & split, and aligns word romaji slices', () {
      const cue = AlignedCallCue(
        id: 'c1',
        start: 3,
        end: 5,
        text: '大好き',
        colorHex: '#FF6699',
        romaji: 'Daisuki',
      );
      final roundtrip = AlignedCallCue.fromJson(cue.toJson());
      expect(roundtrip.romaji, 'Daisuki');

      const line = LyricLine(
        id: 'l1',
        startTimeMs: 1000,
        endTimeMs: 5000,
        alignedCalls: [cue],
        text: LyricText(
          original: '世界で一番おひめさま',
          ruby: '<ruby>世界<rt>せかい</rt></ruby>で<ruby>一番<rt>いちばん</rt></ruby>おひめさま',
          romaji: 'Sekai de ichiban ohimesama',
        ),
      );

      final sliced = JapaneseRubyAnnotator.sliceRomajiForRange(
        line,
        3,
        5,
        tokenizer: tokenizer,
      );
      expect(sliced.toLowerCase(), 'ichiban');

      // Synchronous <ruby> fallback without tokenizer also maps cleanly
      final syncSliced = JapaneseRubyAnnotator.sliceRomajiForRange(line, 3, 5);
      expect(syncSliced.toLowerCase(), 'ichiban');

      final wordRuns = buildAlignedWordRunsForRomaji(
        line,
        showRuby: true,
        tokenizer: tokenizer,
      );
      final alignedRun = wordRuns.firstWhere((r) => r.call != null);
      expect(alignedRun.call!.cue.romaji, 'Daisuki');
      expect((alignedRun.romaji ?? '').toLowerCase(), 'ichiban');
      expect(
        wordRuns.any((r) => r.call == null && (r.romaji ?? '').contains('sekai')),
        isTrue,
      );

      // Split & merge preserve aligned cue romaji
      final split = sliceLyricLineForSplit(
        line,
        [5],
        boundaryTimesMs: [3000],
        idFactory: (k) => 'l1-split-$k',
      );
      expect(split.first.alignedCalls.single.romaji, 'Daisuki');
      final merged = mergeAdjacentLyricLines(split[0], split[1]);
      expect(merged.alignedCalls.single.romaji, 'Daisuki');
    });

    testWidgets('Aligned Call picker previews word romaji & optional shout romaji; ExportView toggles showRomaji and renders aligned romaji cleanly', (tester) async {
      SharedPreferences.setMockInitialValues({
        'live_call_studio_onboarding_v1': true,
      });
      final controller = CallbookController(
        apiClient: CallbookApiClient(
          httpClient: MockClient((_) async => http.Response('offline', 503)),
        ),
        rubyAnnotator: JapaneseRubyAnnotator(tokenizer: tokenizer),
        enableAudioOutput: false,
      );
      await controller.init(awaitBackgroundSync: false);

      await controller.importProjectJson(
        jsonEncode({
          'meta': {'title': 'Aligned Romaji Export Test', 'artist': 'Miku', 'bpm': 160},
          'lines': [
            {
              'id': 'r-1',
              'startTimeMs': 1000,
              'endTimeMs': 5000,
              'kind': 'lyric',
              'text': {
                'original': '世界で一番おひめさま',
                'ruby': '<ruby>世界<rt>せかい</rt></ruby>で<ruby>一番<rt>いちばん</rt></ruby>おひめさま',
                'romaji': 'Sekai de ichiban ohimesama',
                'translation': '世界上第一的公主殿下',
              },
            },
          ],
        }),
      );
      controller.selectLine('r-1');

      final captured = <FlutterErrorDetails>[];
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (d) {
        captured.add(d);
        prevOnError?.call(d);
      };

      try {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pumpAndSettle();

        final addAlignedBtn = find.text('+ 对位 Call');
        await tester.ensureVisible(addAlignedBtn);
        await tester.pumpAndSettle();

        // Open picker dialog -> verify romaji reference & extend selection to 世界 -> verify live slice 'sekai'
        await tester.tap(addAlignedBtn);
        await tester.pumpAndSettle();
        expect(find.textContaining('整行罗马音参考：'), findsOneWidget);
        expect(find.text('对位词罗马音'), findsOneWidget);

        await tester.tap(find.text('界'));
        await tester.pumpAndSettle();
        expect(find.text('sekai'), findsOneWidget);

        await tester.enterText(find.byType(prism.TextField).last, 'せーの');
        await tester.tap(find.text('+ 附带喊声罗马音（可选）'));
        await tester.pumpAndSettle();
        expect(find.text('按日语生成罗马音'), findsOneWidget);
        await tester.tap(find.text('确认对位'));
        await tester.pumpAndSettle();

        final line = controller.sortedLines.first;
        expect(line.alignedCalls.single.start, 0);
        expect(line.alignedCalls.single.end, 2);
        expect(line.alignedCalls.single.text, 'せーの');
        expect(line.alignedCalls.single.romaji, isNotEmpty);

        // Switch to Export route -> toggle 罗马音 (Romaji) chip directly on Export page
        controller.setRoute(StudioRoute.export);
        await tester.pumpAndSettle();
        expect(controller.displayLayers.showRomaji, isFalse);

        final romajiChip = find.descendant(
          of: find.byType(ExportView),
          matching: find.text('罗马音 (Romaji)'),
        );
        expect(romajiChip, findsOneWidget);
        await tester.tap(romajiChip);
        await tester.pumpAndSettle();
        expect(controller.displayLayers.showRomaji, isTrue);

        // RubyLyricText renders aligned romaji inline cleanly with zero overflows
        expect(
          RubyLyricText.willRenderInlineRomaji(
            original: line.text.original,
            rubyHtml: line.text.ruby,
            lineRomaji: line.text.romaji,
            showRomaji: true,
            alignedCalls: line.alignedCalls,
            customShout: line.customShout,
          ),
          isTrue,
        );
        expect(find.textContaining('sekai'), findsWidgets);

        // Switch to PracticeOverlay -> verify aligned romaji renders cleanly too
        controller.setPracticeMode(true);
        await tester.pumpAndSettle();
        expect(find.textContaining('sekai'), findsWidgets);

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
