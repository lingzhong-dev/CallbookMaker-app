import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_call_studio/data/default_songs.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/services/api_client.dart';
import 'package:live_call_studio/services/lrclib_direct_client.dart';
import 'package:live_call_studio/services/netease_direct_client.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/ui/onboarding_overlay.dart';
import 'package:live_call_studio/ui/widgets/audio_source_panel.dart';
import 'package:live_call_studio/utils/color_parser.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mock_audioplayers_harness.dart';

http.Response _jsonResp(Object data, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<void> _pumpViewport(
  WidgetTester tester,
  Widget widget, {
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(widget);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
}

Future<void> _disposeApp(
  WidgetTester tester,
  CallbookController controller,
) async {
  if (controller.isPlaying) {
    await controller.togglePlay();
  }
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

Future<void> _scrollAndTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

CallbookController _buildOfflineController({
  http.Client? neteaseHttpClient,
  http.Client? lrclibHttpClient,
  bool enableAudioOutput = false,
}) {
  return CallbookController(
    apiClient: CallbookApiClient(
      baseUrl: 'http://127.0.0.1:8000',
      httpClient: MockClient((_) async => http.Response('offline', 503)),
    ),
    neteaseDirectClient: NeteaseDirectClient(
      httpClient:
          neteaseHttpClient ??
          MockClient((_) async => http.Response('offline', 503)),
    ),
    lrclibDirectClient: LrclibDirectClient(
      httpClient:
          lrclibHttpClient ??
          MockClient((_) async => http.Response('offline', 503)),
    ),
    enableAudioOutput: enableAudioOutput,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockAudioplayersHarness audioHarness;

  setUp(() {
    audioHarness = MockAudioplayersHarness()..install();
  });

  group('1. Support Color Parser & Default Songs Catalog', () {
    test('parseSupportColor, formatHexColor, and formatRgbColor handle Hex, RGB, full-width, and invalid inputs', () {
      expect(parseSupportColor('#66CCFF'), const Color(0xFF66CCFF));
      expect(parseSupportColor('66ccff'), const Color(0xFF66CCFF));
      expect(parseSupportColor('#6CF'), const Color(0xFF66CCFF));
      expect(parseSupportColor('39c5bb'), const Color(0xFF39C5BB));
      expect(parseSupportColor('102, 204, 255'), const Color(0xFF66CCFF));
      expect(parseSupportColor('102 204 255'), const Color(0xFF66CCFF));
      expect(parseSupportColor('rgb(102, 204, 255)'), const Color(0xFF66CCFF));
      expect(parseSupportColor('RGB(57, 197, 187)'), const Color(0xFF39C5BB));
      expect(parseSupportColor('102，204，255'), const Color(0xFF66CCFF));
      expect(parseSupportColor('rgb（102， 204， 255）'), const Color(0xFF66CCFF));

      expect(parseSupportColor('300, 0, 0'), isNull);
      expect(parseSupportColor('-1, 0, 0'), isNull);
      expect(parseSupportColor('102, 204'), isNull);
      expect(parseSupportColor('#12345'), isNull);
      expect(parseSupportColor('not-a-color'), isNull);
      expect(parseSupportColor(''), isNull);

      expect(formatHexColor(const Color(0xFF66CCFF)), '#66CCFF');
      expect(formatRgbColor(const Color(0xFF66CCFF)), '102, 204, 255');
    });

    test('All 3 defaultSongs have accurate metadata, clean Calls, section detection, Ruby, Romaji, and Simplified Chinese translations', () {
      expect(defaultSongs.length, 3);
      expect(defaultPrimarySong.id, 'default-vanaheim');

      final vanaheim = defaultSongs[0];
      expect(vanaheim.project.meta.title, '来自瓦纳海姆');
      expect(vanaheim.project.meta.artist, '洛天依');
      expect(vanaheim.project.meta.composer, 'litterzy');
      expect(vanaheim.project.meta.lyricist, '冥凰');
      expect(vanaheim.project.meta.tuner, 'Creuzer');
      expect(vanaheim.project.meta.showTuner, isTrue);
      expect(vanaheim.project.meta.bpm, 148);
      expect(vanaheim.durationMs, 234000);

      final kizuna = defaultSongs[1];
      expect(kizuna.project.meta.title, 'キズナミュージック♪（友谊的华章）');
      expect(kizuna.project.meta.artist, "Poppin'Party");
      expect(kizuna.project.meta.composer, '藤永龍太郎(Elements Garden)');
      expect(kizuna.project.meta.lyricist, '中村航');
      expect(kizuna.project.meta.tuner, '');
      expect(kizuna.project.meta.showTuner, isFalse);
      expect(kizuna.project.meta.bpm, 189);
      expect(kizuna.durationMs, 317000);

      final wim = defaultSongs[2];
      expect(wim.project.meta.title, 'ワールドイズマイン（世界第一的公主殿下）');
      expect(wim.project.meta.artist, 'supercell feat. 初音ミク');
      expect(wim.project.meta.composer, 'ryo (supercell)');
      expect(wim.project.meta.lyricist, 'ryo (supercell)');
      expect(wim.project.meta.tuner, '');
      expect(wim.project.meta.showTuner, isFalse);
      expect(wim.project.meta.bpm, 165);
      expect(wim.durationMs, 255000);

      for (var i = 0; i < defaultSongs.length; i++) {
        final spec = defaultSongs[i];
        final clean = spec.buildCleanProject();
        expect(clean.meta.platform, 'netease');
        expect(clean.meta.trackId, isNull);
        expect(clean.meta.audioUrl, isEmpty);
        expect(clean.alerts, isEmpty);

        for (final line in clean.lines) {
          expect(line.calls, isEmpty);
          expect(line.customShout, isEmpty);
          expect(line.tailUpdraft, isFalse);
          expect(line.alignedCalls, isEmpty);
        }

        if (i < 2) {
          final intro = clean.lines.firstWhere(
            (l) => l.kind == LyricLineKind.intro,
          );
          expect(intro.startTimeMs, 0);
        }
        expect(clean.lines.any((l) => l.kind == LyricLineKind.interlude), isTrue);
        final outro = clean.lines.lastWhere(
          (l) => l.kind == LyricLineKind.outro,
        );
        expect(outro.endTimeMs, spec.durationMs);

        if (i >= 1) {
          final lyricLines = clean.lines.where((l) => !l.kind.isSection).toList();
          expect(lyricLines, isNotEmpty);
          expect(
            lyricLines.every(
              (l) => (l.text.translation ?? '').trim().isNotEmpty,
            ),
            isTrue,
          );
          expect(
            lyricLines.any((l) => (l.text.ruby ?? '').contains('<ruby>')),
            isTrue,
          );
          expect(
            lyricLines.every((l) => (l.text.romaji ?? '').trim().isNotEmpty),
            isTrue,
          );
        }
      }

      final seeded = buildDefaultArchiveEntries(nowMs: 100000);
      expect(seeded.length, 3);
      expect(seeded.map((e) => e.name).toList(), [
        '来自瓦纳海姆',
        'キズナミュージック♪（友谊的华章）',
        'ワールドイズマイン（世界第一的公主殿下）',
      ]);
      expect(seeded.every((e) => e.taggedCount == 0 && e.alertCount == 0), isTrue);
      expect(seeded[0].savedAt, greaterThan(seeded[1].savedAt));
      expect(seeded[1].savedAt, greaterThan(seeded[2].savedAt));
    });
  });

  group('2. Fresh Install Seeding, Existing-User OOBE Bypass & Netease Auto-Restore', () {
    test('Genuine fresh install seeds 3 clean archives, activates primary song, and opens onboarding', () async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
        initialPrefs: const {},
      );
      try {
        expect(controller.showOnboarding, isTrue);
        expect(controller.onboardingReopened, isFalse);
        expect(controller.archives.length, 3);
        expect(controller.archives.map((a) => a.name).toList(), [
          '来自瓦纳海姆',
          'キズナミュージック♪（友谊的华章）',
          'ワールドイズマイン（世界第一的公主殿下）',
        ]);
        expect(controller.activeArchiveId, defaultPrimarySong.archiveId);
        expect(controller.project.meta.title, '来自瓦纳海姆');
        expect(controller.needsSavePromptBeforeSwitch, isFalse);
        expect(controller.sortedAlerts, isEmpty);
        expect(controller.taggedLineCount, 0);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('live_call_studio_onboarding_v1'), isNot(true));

        await controller.skipOnboarding();
        expect(controller.showOnboarding, isFalse);
        expect(prefs.getBool('live_call_studio_onboarding_v1'), isTrue);
      } finally {
        controller.dispose();
      }
    });

    test('Existing user with saved project and missing onboarding key bypasses OOBE while preserving project', () async {
      final customProj = const CallProject(
        meta: CallProjectMeta(
          title: 'Legacy Custom Song',
          artist: 'Veteran Idol',
          bpm: 172,
        ),
        lines: [
          LyricLine(
            id: 'leg-1',
            startTimeMs: 2000,
            endTimeMs: 6000,
            text: LyricText(original: 'Keep my calls safe'),
            calls: [LineCallTag(presetId: 'front-wave')],
          ),
        ],
      );
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
        initialPrefs: {
          'live_call_studio_project_v1': jsonEncode(customProj.toJson()),
        },
      );
      try {
        expect(controller.showOnboarding, isFalse);
        expect(controller.project.meta.title, 'Legacy Custom Song');
        expect(controller.sortedLines.first.calls.single.presetId, 'front-wave');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('live_call_studio_onboarding_v1'), isTrue);
      } finally {
        controller.dispose();
      }
    });

    test('Existing user with archives only (no project key) also bypasses OOBE cleanly', () async {
      final existingArchives = buildDefaultArchiveEntries(nowMs: 50000);
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
        initialPrefs: {
          'live_call_studio_archives_v1': jsonEncode([
            for (final e in existingArchives) e.toJson(),
          ]),
        },
      );
      try {
        expect(controller.showOnboarding, isFalse);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('live_call_studio_onboarding_v1'), isTrue);
      } finally {
        controller.dispose();
      }
    });

    test('Netease auto-restore fetches MP3 URL for default songs when online and falls back to metronome offline', () async {
      final neteaseMock = MockClient((req) async {
        final path = req.url.path;
        if (path == '/eapi/cloudsearch/pc') {
          return _jsonResp({
            'code': 200,
            'result': {
              'songs': [
                {
                  'id': 88001,
                  'name': '来自瓦纳海姆',
                  'ar': [
                    {'name': '洛天依'},
                  ],
                  'dt': 234000,
                },
              ],
            },
          });
        }
        if (path == '/eapi/song/lyric/v1') {
          return _jsonResp({
            'code': 200,
            'lrc': {'lyric': '[00:12.00] 歌词'},
          });
        }
        if (path == '/eapi/v3/song/detail') {
          return _jsonResp({
            'code': 200,
            'songs': [
              {
                'id': 88001,
                'name': '来自瓦纳海姆',
                'ar': [
                  {'name': '洛天依'},
                ],
                'dt': 234000,
              },
            ],
          });
        }
        if (path == '/eapi/song/enhance/player/url/v1') {
          return _jsonResp({
            'code': 200,
            'data': [
              {'url': 'https://cdn.example.com/vanaheim.mp3'},
            ],
          });
        }
        return http.Response('err', 500);
      });

      final controller = await createTestCallbookController(
        enableAudioOutput: true,
        initialPrefs: const {},
        neteaseHttpClient: neteaseMock,
      );
      try {
        expect(controller.project.meta.trackId, '88001');
        expect(
          controller.project.meta.audioUrl,
          'https://cdn.example.com/vanaheim.mp3',
        );
        expect(
          audioHarness.calls.any(
            (c) =>
                c.method == 'setSourceUrl' &&
                c.arguments['url'] == 'https://cdn.example.com/vanaheim.mp3',
          ),
          isTrue,
        );
      } finally {
        controller.dispose();
      }

      // Offline graceful fallback -> remains metronome mode without throwing
      final offlineCtrl = await createTestCallbookController(
        enableAudioOutput: true,
        initialPrefs: const {},
      );
      try {
        expect(offlineCtrl.hasExternalAudio, isFalse);
        await offlineCtrl.loadDefaultSong('default-world-is-mine');
        expect(offlineCtrl.project.meta.title, 'ワールドイズマイン（世界第一的公主殿下）');
        expect(offlineCtrl.hasExternalAudio, isFalse);
      } finally {
        offlineCtrl.dispose();
      }
    });
  });

  group('3. Onboarding 5-Step Flow, Shortcuts Blocking, Theme Persistence & Reopen Guard', () {
    testWidgets(
      '5-step wizard blocks shortcuts, previews/persists Hex & RGB & swatches, selects song & theme mode',
      timeout: const Timeout(Duration(seconds: 25)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
          initialPrefs: const {},
        );
        var ownedByApp = false;
        try {
          await _pumpViewport(
            tester,
            LiveCallStudioApp(controller: controller),
            size: const Size(1280, 820),
          );
          ownedByApp = true;

          // Step 1 visible
          expect(find.byType(OnboardingOverlay), findsOneWidget);
          expect(find.text('功能引导 · 1 / 5'), findsOneWidget);
          expect(
            find.text('欢迎来到 Callbook Maker · 为你的偶像写下专属 Call 本'),
            findsOneWidget,
          );

          // Hardware shortcuts must be blocked while onboarding modal is active
          final lyricLine = controller.sortedLines.firstWhere(
            (l) => !l.kind.isSection,
          );
          controller.selectLine(lyricLine.id);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
          await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
          await tester.pump();
          expect(controller.isPlaying, isFalse);
          expect(controller.isPracticeMode, isFalse);
          expect(controller.sortedAlerts, isEmpty);
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == lyricLine.id)
                .calls,
            isEmpty,
          );

          // Navigate Step 1 -> 2 -> 3 -> 4 -> 5, and verify Back works too
          await tester.tap(find.text('下一步'));
          await tester.pump();
          expect(find.text('功能引导 · 2 / 5'), findsOneWidget);
          expect(find.text('选歌导入，自动识别间奏分段'), findsOneWidget);

          await tester.tap(find.text('上一步'));
          await tester.pump();
          expect(find.text('功能引导 · 1 / 5'), findsOneWidget);

          await tester.tap(find.text('下一步'));
          await tester.pump();
          await tester.tap(find.text('下一步'));
          await tester.pump();
          expect(find.text('功能引导 · 3 / 5'), findsOneWidget);
          expect(find.text('Call词精准对位'), findsOneWidget);

          await tester.tap(find.text('下一步'));
          await tester.pump();
          expect(find.text('功能引导 · 4 / 5'), findsOneWidget);
          expect(find.text('演练模式与一键导出'), findsOneWidget);

          await tester.tap(find.text('下一步'));
          await tester.pump();
          expect(find.text('功能引导 · 5 / 5'), findsOneWidget);
          expect(find.text('选择你喜欢的主题，并选择一首歌曲'), findsOneWidget);

          // Swatch selection applies live seedColor
          await _scrollAndTap(
            tester,
            find.descendant(
              of: find.byType(OnboardingOverlay),
              matching: find.text('初音绿'),
            ),
          );
          expect(controller.seedColor, const Color(0xFF39C5BB));

          await _scrollAndTap(
            tester,
            find.descendant(
              of: find.byType(OnboardingOverlay),
              matching: find.text('香澄红'),
            ),
          );
          expect(controller.seedColor, const Color(0xFFFF5522));

          await _scrollAndTap(
            tester,
            find.descendant(
              of: find.byType(OnboardingOverlay),
              matching: find.text('天依蓝'),
            ),
          );
          expect(controller.seedColor, const Color(0xFF66CCFF));

          // Expand custom color box & validate invalid vs valid Hex / full-width RGB
          await _scrollAndTap(tester, find.text('或是输入其他应援色'));
          final colorField = find.byWidgetPredicate(
            (w) =>
                w is prism.TextField &&
                w.decoration?.hintText == '输入 Hex (#66CCFF) 或 RGB (102, 204, 255)',
          );
          expect(colorField, findsOneWidget);

          await tester.enterText(colorField, 'invalid-hex');
          await tester.pump();
          expect(
            find.text('格式无效：支持 #RRGGBB、#RGB 或 RGB (如 102, 204, 255)'),
            findsOneWidget,
          );
          expect(controller.seedColor, const Color(0xFF66CCFF));

          await tester.enterText(colorField, 'rgb（57， 197， 187）');
          await tester.pump();
          expect(
            find.text('格式无效：支持 #RRGGBB、#RGB 或 RGB (如 102, 204, 255)'),
            findsNothing,
          );
          expect(controller.seedColor, const Color(0xFF39C5BB));

          // Change ThemeMode inside Step 5
          await _scrollAndTap(
            tester,
            find.descendant(
              of: find.byType(OnboardingOverlay),
              matching: find.text('深色'),
            ),
          );
          expect(controller.themeMode, prism.ThemeMode.dark);

          // Pick second song & finish
          await _scrollAndTap(
            tester,
            find.descendant(
              of: find.byType(OnboardingOverlay),
              matching: find.text('キズナミュージック♪（友谊的华章）'),
            ),
          );
          await tester.tap(find.text('开始创作'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));

          expect(find.byType(OnboardingOverlay), findsNothing);
          expect(controller.showOnboarding, isFalse);
          expect(controller.project.meta.title, 'キズナミュージック♪（友谊的华章）');
          expect(controller.themeMode, prism.ThemeMode.dark);
          expect(controller.seedColor, const Color(0xFF39C5BB));
        } finally {
          if (ownedByApp) {
            await _disposeApp(tester, controller);
          } else {
            controller.dispose();
          }
        }

        // Verify persistence across relaunch without resetting SharedPreferences
        final relaunched = _buildOfflineController();
        try {
          await relaunched.init();
          expect(relaunched.showOnboarding, isFalse);
          expect(relaunched.themeMode, prism.ThemeMode.dark);
          expect(relaunched.seedColor, const Color(0xFF39C5BB));
          expect(relaunched.project.meta.title, 'キズナミュージック♪（友谊的华章）');
        } finally {
          relaunched.dispose();
        }
      },
    );

    testWidgets(
      'Reopening via ThemeView preserves unsaved edits on skip/keep-song and triggers save guard when switching song',
      timeout: const Timeout(Duration(seconds: 25)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
          initialPrefs: const {},
        );
        await controller.skipOnboarding();
        var ownedByApp = false;
        try {
          await _pumpViewport(
            tester,
            LiveCallStudioApp(controller: controller),
            size: const Size(1280, 820),
          );
          ownedByApp = true;

          // Make an unsaved Call edit on the first lyric line
          final firstLyric = controller.sortedLines.firstWhere(
            (l) => !l.kind.isSection,
          );
          controller.toggleLineCall(firstLyric.id, 'front-wave');
          expect(controller.needsSavePromptBeforeSwitch, isTrue);

          // Navigate to ThemeView via desktop sidebar & reopen onboarding
          await tester.tap(find.text('外观主题'));
          await tester.pump();
          await _scrollAndTap(tester, find.text('重新查看功能引导'));
          expect(controller.showOnboarding, isTrue);
          expect(controller.onboardingReopened, isTrue);
          expect(find.byType(OnboardingOverlay), findsOneWidget);

          // Scenario A: Skip onboarding preserves edits and current song
          await tester.tap(find.text('跳过引导'));
          await tester.pump();
          expect(controller.showOnboarding, isFalse);
          expect(controller.project.meta.title, '来自瓦纳海姆');
          expect(controller.needsSavePromptBeforeSwitch, isTrue);
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == firstLyric.id)
                .calls
                .any((c) => c.presetId == 'front-wave'),
            isTrue,
          );

          // Scenario B: Reopen, finish Step 5 WITHOUT picking another song -> preserves edits
          await _scrollAndTap(tester, find.text('重新查看功能引导'));
          for (var i = 0; i < 4; i++) {
            await tester.tap(find.text('下一步'));
            await tester.pump();
          }
          expect(find.text('功能引导 · 5 / 5'), findsOneWidget);
          await tester.tap(find.text('开始创作'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(controller.showOnboarding, isFalse);
          expect(controller.project.meta.title, '来自瓦纳海姆');
          expect(controller.needsSavePromptBeforeSwitch, isTrue);

          // Scenario C: Reopen, pick another song on Step 5 -> Save guard prompts & saves before switching
          await _scrollAndTap(tester, find.text('重新查看功能引导'));
          for (var i = 0; i < 4; i++) {
            await tester.tap(find.text('下一步'));
            await tester.pump();
          }
          await _scrollAndTap(
            tester,
            find.descendant(
              of: find.byType(OnboardingOverlay),
              matching: find.text('ワールドイズマイン（世界第一的公主殿下）'),
            ),
          );
          await tester.tap(find.text('开始创作'));
          await tester.pump();

          expect(find.text('保存当前 Call 本再切换默认曲目？'), findsOneWidget);
          await tester.tap(find.text('更新并继续'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));

          expect(controller.showOnboarding, isFalse);
          expect(controller.project.meta.title, 'ワールドイズマイン（世界第一的公主殿下）');
          final savedVanaheim = controller.archives.firstWhere(
            (a) => a.id == defaultSongs[0].archiveId,
          );
          expect(savedVanaheim.taggedCount, 1);
        } finally {
          if (ownedByApp) {
            await _disposeApp(tester, controller);
          } else {
            controller.dispose();
          }
        }
      },
    );
  });

  group('4. Responsive OOBE Rendering & AudioSourcePanel 默认曲库', () {
    for (final viewport in [const Size(1280, 820), const Size(390, 844)]) {
      testWidgets(
        'OnboardingOverlay renders all 5 steps (including expanded custom color error) at ${viewport.width.toInt()}x${viewport.height.toInt()} with ZERO overflows',
        timeout: const Timeout(Duration(seconds: 25)),
        (tester) async {
          final controller = await createTestCallbookController(
            enableAudioOutput: false,
            initialPrefs: const {},
          );
          final errors = <FlutterErrorDetails>[];
          final prevOnError = FlutterError.onError;
          FlutterError.onError = (details) => errors.add(details);
          var ownedByApp = false;
          try {
            await _pumpViewport(
              tester,
              LiveCallStudioApp(controller: controller),
              size: viewport,
            );
            ownedByApp = true;

            expect(find.text('功能引导 · 1 / 5'), findsOneWidget);
            for (var step = 2; step <= 5; step++) {
              await tester.tap(find.text('下一步'));
              await tester.pump();
              expect(find.text('功能引导 · $step / 5'), findsOneWidget);
            }

            await _scrollAndTap(tester, find.text('或是输入其他应援色'));
            final colorField = find.byWidgetPredicate(
              (w) =>
                  w is prism.TextField &&
                  w.decoration?.hintText ==
                      '输入 Hex (#66CCFF) 或 RGB (102, 204, 255)',
            );
            await tester.ensureVisible(colorField);
            await tester.enterText(colorField, 'not-color');
            await tester.pump();
            expect(
              find.text('格式无效：支持 #RRGGBB、#RGB 或 RGB (如 102, 204, 255)'),
              findsOneWidget,
            );

            expect(errors, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            FlutterError.onError = prevOnError;
            if (ownedByApp) {
              await _disposeApp(tester, controller);
            } else {
              controller.dispose();
            }
          }
        },
      );
    }

    testWidgets(
      'AudioSourcePanel search box starts empty, shows 3 songs under 默认曲库, switches cleanly, and hides legacy strings',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        var ownedByApp = false;
        try {
          await _pumpViewport(
            tester,
            LiveCallStudioApp(controller: controller),
            size: const Size(1280, 820),
          );
          ownedByApp = true;

          // Verify legacy labels do not appear anywhere in app UI
          expect(find.textContaining('内置' ' Demo'), findsNothing);
          expect(find.textContaining('演示' '库'), findsNothing);
          expect(find.textContaining('Star' 'light'), findsNothing);
          expect(find.textContaining('SAW' 'TOWNE'), findsNothing);

          // Search box inside AudioSourcePanel starts empty
          final searchFieldFinder = find.byWidgetPredicate(
            (w) =>
                w is prism.TextField &&
                w.decoration?.hintText == '输入歌名或歌手...',
          );
          await tester.ensureVisible(searchFieldFinder);
          await tester.pump();
          final searchField = tester.widget<prism.TextField>(searchFieldFinder);
          expect(searchField.controller?.text ?? '', isEmpty);

          // Switch to 默认曲库 tab and verify all 3 clean default songs render
          final panelFinder = find.byType(AudioSourcePanel);
          await _scrollAndTap(
            tester,
            find.descendant(of: panelFinder, matching: find.text('默认曲库')),
          );
          for (final spec in defaultSongs) {
            expect(
              find.descendant(
                of: panelFinder,
                matching: find.text(spec.project.meta.title),
              ),
              findsOneWidget,
            );
          }

          // Load 2nd default song from 默认曲库
          final loadButtons = find.descendant(
            of: panelFinder,
            matching: find.text('载入曲目'),
          );
          expect(loadButtons, findsNWidgets(2));
          await _scrollAndTap(tester, loadButtons.first);
          await tester.pump(const Duration(milliseconds: 500));

          expect(controller.project.meta.title, 'キズナミュージック♪（友谊的华章）');
          expect(controller.taggedLineCount, 0);
          expect(controller.sortedAlerts, isEmpty);
        } finally {
          if (ownedByApp) {
            await _disposeApp(tester, controller);
          } else {
            controller.dispose();
          }
        }
      },
    );
  });
}
