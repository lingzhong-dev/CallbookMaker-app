import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data' show Endian;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/services/api_client.dart';
import 'package:live_call_studio/services/desktop_service_launcher.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/ui/export_view.dart';
import 'package:live_call_studio/ui/home_shell.dart';
import 'package:live_call_studio/ui/practice_overlay.dart';
import 'package:live_call_studio/ui/theme_view.dart';
import 'package:live_call_studio/ui/widgets/archive_switcher_dialog.dart';
import 'package:live_call_studio/ui/widgets/timeline_editor_widget.dart';
import 'package:live_call_studio/utils/xlsx_export.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';

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
  bool shouldReload(covariant LocalizationsDelegate<prism.UiLocalizations> old) =>
      false;
}

void _setupHeadlessPluginMocks({
  ValueSetter<String>? onClipboardWrite,
  String Function()? onClipboardRead,
}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final registeredEventChannels = <String>{};

  void ensureEventChannelMock(String channelName) {
    if (!registeredEventChannels.add(channelName)) return;
    messenger.setMockMessageHandler(channelName, (ByteData? message) async {
      if (message == null) return null;
      final decoded = const StandardMethodCodec().decodeMethodCall(message);
      if (decoded.method == 'listen' || decoded.method == 'cancel') {
        return const StandardMethodCodec().encodeSuccessEnvelope(null);
      }
      return null;
    });
  }

  ensureEventChannelMock('xyz.luan/audioplayers.global/events');

  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (MethodCall call) async => null,
  );

  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (MethodCall call) async {
      final args = call.arguments;
      if (args is Map) {
        final playerId = args['playerId']?.toString();
        if (playerId != null && playerId.isNotEmpty) {
          ensureEventChannelMock('xyz.luan/audioplayers/events/$playerId');
        }
      }
      switch (call.method) {
        case 'getCurrentPosition':
        case 'getDuration':
          return 0;
        default:
          return null;
      }
    },
  );

  messenger.setMockMethodCallHandler(
    const MethodChannel('miguelruivo.flutter.plugins.filepicker'),
    (MethodCall call) async => null,
  );

  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/share'),
    (MethodCall call) async => 'dev.fluttercommunity.plus/share/unavailable',
  );

  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/url_launcher'),
    (MethodCall call) async => true,
  );

  messenger.setMockMethodCallHandler(SystemChannels.platform, (
    MethodCall call,
  ) async {
    if (call.method == 'Clipboard.setData') {
      final args = call.arguments as Map?;
      final text = args?['text']?.toString() ?? '';
      onClipboardWrite?.call(text);
      return null;
    }
    if (call.method == 'Clipboard.getData') {
      return <String, dynamic>{'text': onClipboardRead?.call() ?? ''};
    }
    return null;
  });
}

Future<CallbookController> _initController({
  http.Client? httpClient,
  Map<String, Object> initialPrefs = const {},
  bool enableAudioOutput = false,
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final client =
      httpClient ?? MockClient((req) async => http.Response('offline', 503));
  final api = CallbookApiClient(
    baseUrl: 'http://127.0.0.1:8000',
    httpClient: client,
  );
  final controller = CallbookController(
    apiClient: api,
    enableAudioOutput: enableAudioOutput,
  );
  await controller.init();
  return controller;
}

Widget _wrapWithPrism({
  required CallbookController controller,
  required Widget child,
}) {
  return AnimatedBuilder(
    animation: controller,
    builder: (context, _) => prism.PrismApp(
      title: 'Live Call Studio Test',
      theme: controller.buildPrismTheme(Brightness.light),
      darkTheme: controller.buildPrismTheme(Brightness.dark),
      themeMode: controller.themeMode,
      localizationsDelegates: const [
        _TestUiLocalizationsDelegate(),
        DefaultWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en', 'US'), Locale('zh', 'CN')],
      liquidGlass: controller.liquidGlass
          ? prism.LiquidGlassQuality.standard
          : null,
      home: child,
    ),
  );
}

Future<void> _pumpWithViewport(
  WidgetTester tester,
  Widget widget, {
  Size viewport = const Size(1280, 820),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(widget);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _disposeTestTree(
  WidgetTester tester,
  CallbookController controller, {
  bool controllerOwnedByWidget = false,
}) async {
  if (controller.isPlaying) {
    await controller.togglePlay();
  }
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  if (!controllerOwnedByWidget) {
    controller.dispose();
  }
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

Future<void> _scrollToAndTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

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

  String clipboardText = '';

  setUp(() {
    clipboardText = '';
    _setupHeadlessPluginMocks(
      onClipboardWrite: (text) => clipboardText = text,
      onClipboardRead: () => clipboardText,
    );
  });

  group('1. Raw LiveCallStudioApp Rendering & Fixed Bugs (Desktop & Mobile)', () {
    testWidgets(
      'Raw Desktop (1280x820) renders NavigationSidebar + DashboardView with ZERO exceptions and supports 4/4|3/4 and 1.1x rate',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController(enableAudioOutput: true);
        final captured = <FlutterErrorDetails>[];
        final prevOnError = FlutterError.onError;
        FlutterError.onError = (details) => captured.add(details);
        try {
          await _pumpWithViewport(
            tester,
            LiveCallStudioApp(controller: controller),
            viewport: const Size(1280, 820),
          );
          expect(captured, isEmpty);
          expect(tester.takeException(), isNull);
          expect(find.byType(prism.NavigationSidebar), findsOneWidget);
          expect(find.text('1.1×'), findsOneWidget);

          await _scrollToAndTap(tester, find.text('3/4'));
          expect(controller.project.meta.timeSignature, '3/4');

          await _scrollToAndTap(tester, find.text('1.1×'));
          expect(controller.playbackRate, 1.1);
          expect(captured, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          FlutterError.onError = prevOnError;
          await _disposeTestTree(
            tester,
            controller,
            controllerOwnedByWidget: true,
          );
        }
      },
    );

    testWidgets(
      'Raw Mobile (390x844) renders NavigationDock & quick-tag tray and DashboardView with ZERO layout exceptions',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController();
        final captured = <FlutterErrorDetails>[];
        final prevOnError = FlutterError.onError;
        FlutterError.onError = (details) => captured.add(details);
        try {
          await _pumpWithViewport(
            tester,
            LiveCallStudioApp(controller: controller),
            viewport: const Size(390, 844),
          );

          expect(captured, isEmpty);
          expect(tester.takeException(), isNull);
          expect(find.byType(prism.NavigationDock), findsOneWidget);
          expect(find.byType(prism.NavigationSidebar), findsNothing);
          expect(find.text('收起速标'), findsOneWidget);
          expect(find.text('打完跳下句'), findsOneWidget);
          final tailUpdraftBefore = find
              .text('+ 尾句上升气流')
              .evaluate()
              .length;
          expect(tailUpdraftBefore, greaterThanOrEqualTo(1));
          expect(find.text('‹ 上一句'), findsOneWidget);
          expect(find.text('下一句 ›'), findsOneWidget);

          // Toggle quick tray collapse / reopen works cleanly
          await tester.tap(find.text('收起速标'));
          await tester.pump();
          expect(find.text('速标栏'), findsOneWidget);
          expect(find.text('打完跳下句'), findsNothing);
          expect(
            find.text('+ 尾句上升气流').evaluate().length,
            tailUpdraftBefore - 1,
          );

          await tester.tap(find.text('速标栏'));
          await tester.pump();
          expect(find.text('收起速标'), findsOneWidget);
          expect(find.text('打完跳下句'), findsOneWidget);
          expect(
            find.text('+ 尾句上升气流').evaluate().length,
            tailUpdraftBefore,
          );

          // AppBar dedicated theme toggle works cleanly on Mobile
          await tester.tap(find.bySemanticsLabel('切换深色主题'));
          await tester.pump();
          expect(controller.themeMode, prism.ThemeMode.dark);
          expect(captured, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          FlutterError.onError = prevOnError;
          await _disposeTestTree(
            tester,
            controller,
            controllerOwnedByWidget: true,
          );
        }
      },
    );
  });

  group('2. HomeShell Navigation & ThemeView Parity (Isolated from Dashboard Bug)', () {
    testWidgets(
      'Desktop HomeShell + ThemeView render with ZERO exceptions; ThemeMode, ColorStyle, OLED, Glass, GoogleSans & Reset work',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController();
        controller.setRoute(StudioRoute.theme);
        try {
          await _pumpWithViewport(
            tester,
            _wrapWithPrism(
              controller: controller,
              child: HomeShell(controller: controller),
            ),
            viewport: const Size(1280, 820),
          );
          expect(tester.takeException(), isNull);

          expect(find.byType(prism.NavigationSidebar), findsOneWidget);
          expect(find.text('控制台'), findsOneWidget);
          expect(find.text('速查卡导出'), findsOneWidget);
          expect(find.text('外观主题'), findsOneWidget);
          expect(find.text('存档 0'), findsOneWidget);
          expect(find.text('演练'), findsOneWidget);
          expect(find.byType(ThemeView), findsOneWidget);

          // Switch route -> Export -> Theme cleanly (skipping buggy DashboardView)
          await tester.tap(find.text('速查卡导出'));
          await tester.pump();
          expect(controller.route, StudioRoute.export);
          expect(find.byType(ExportView), findsOneWidget);

          await tester.tap(find.text('外观主题'));
          await tester.pump();
          expect(controller.route, StudioRoute.theme);

          await tester.tap(find.text('深色 Dark'));
          await tester.pump();
          expect(controller.themeMode, prism.ThemeMode.dark);

          await _scrollToAndTap(tester, find.text('柔和 Soft'));
          expect(controller.colorStyle, prism.ColorStyle.soft);

          await _scrollToAndTap(
            tester,
            find.bySemanticsLabel('纯黑暗色模式 (OLED Pure Black)'),
          );
          expect(controller.pureBlack, isTrue);

          await _scrollToAndTap(
            tester,
            find.bySemanticsLabel('Liquid Glass 液态玻璃质感'),
          );
          expect(controller.liquidGlass, isFalse);

          await _scrollToAndTap(
            tester,
            find.bySemanticsLabel('Floating NavigationDock 悬浮胶囊'),
          );
          expect(controller.floatingNavDock, isFalse);

          await _scrollToAndTap(
            tester,
            find.bySemanticsLabel('全局启用 Google Sans 字体'),
          );
          expect(controller.useGoogleSans, isFalse);

          await _scrollToAndTap(tester, find.text('恢复默认'));
          expect(controller.themeMode, prism.ThemeMode.light);
          expect(controller.colorStyle, prism.ColorStyle.vivid);
          expect(controller.pureBlack, isFalse);
          expect(controller.liquidGlass, isTrue);
          expect(controller.floatingNavDock, isTrue);
          expect(controller.useGoogleSans, isTrue);
          expect(controller.textScale, 1.0);

          // Gap vs Web: no HCT Hue/Chroma/Tone slider toggle or custom saved swatches UI
          expect(find.text('HCT 色相与明度滑块'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await _disposeTestTree(tester, controller);
        }
      },
    );

    testWidgets(
      'Mobile HomeShell toggles between floating NavigationDock and anchored bottom bar via floatingNavDock',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController();
        controller.setRoute(StudioRoute.theme);
        try {
          await _pumpWithViewport(
            tester,
            _wrapWithPrism(
              controller: controller,
              child: HomeShell(controller: controller),
            ),
            viewport: const Size(390, 844),
          );
          expect(tester.takeException(), isNull);
          expect(find.byType(prism.NavigationDock), findsOneWidget);

          controller.setFloatingNavDock(false);
          await tester.pump();
          expect(find.byType(prism.NavigationDock), findsNothing);
          expect(find.text('导出'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await _disposeTestTree(tester, controller);
        }
      },
    );
  });

  group('3. Metadata, Credits, LRC Parsing & Section Detection Logic', () {
    test(
      'Controller handles credits, showTuner, BPM, offset, playbackRate, offline LRC + translation & section CRUD',
      () async {
        final controller = await _initController();
        try {
          controller.updateMeta(
            title: 'Test Anthem',
            artist: 'Test Unit',
            composer: 'Composer A',
            lyricist: 'Lyricist B',
            vocalist: 'Vocalist C',
            showTuner: true,
            tuner: 'Tuner D',
            editorName: 'TesterCN',
            editorNote: '高潮注意跟喊',
          );
          expect(controller.project.meta.title, 'Test Anthem');
          expect(controller.project.meta.showTuner, isTrue);
          expect(controller.project.meta.tuner, 'Tuner D');
          expect(controller.project.meta.editorName, 'TesterCN');

          controller.setBpm(182);
          controller.setTimeSignature('3/4');
          controller.adjustOffset(40);
          controller.setPlaybackRate(1.25);
          expect(controller.project.meta.bpm, 182);
          expect(controller.project.meta.timeSignature, '3/4');
          expect(controller.project.meta.beatsPerBar, 3);
          expect(controller.project.meta.offsetMs, 40);
          expect(controller.playbackRate, 1.25);

          controller.updateDisplayLayers(
            showRuby: false,
            showRomaji: true,
            showTranslation: false,
          );
          expect(controller.displayLayers.showRuby, isFalse);
          expect(controller.displayLayers.showRomaji, isTrue);
          expect(controller.displayLayers.showTranslation, isFalse);

          const lrcSample = '''
[00:10.00] 最初の星を見上げて
[00:14.00] 鼓動が高鳴る瞬間
[00:26.00] もう一度飛び立とう
''';
          const transSample = '''
[00:10.00] 仰望最初的星辰
[00:14.00] 心跳加速的瞬间
[00:26.00] 再一次展翅高飞
''';
          await controller.importLrcText(
            lrc: lrcSample,
            translationLrc: transSample,
          );
          expect(controller.hasFetchedExternalLyrics, isTrue);
          expect(
            controller.sortedLines.any((l) => l.kind == LyricLineKind.intro),
            isTrue,
          );
          expect(
            controller.sortedLines.any(
              (l) => l.kind == LyricLineKind.interlude,
            ),
            isTrue,
          );

          final firstLyric = controller.sortedLines.firstWhere(
            (l) => l.kind == LyricLineKind.lyric,
          );
          expect(firstLyric.text.translation, '仰望最初的星辰');

          controller.updateLineDetails(
            lineId: firstLyric.id,
            customShout: 'Tiga Fire!',
            original: '最初の星へ',
          );
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == firstLyric.id)
                .customShout,
            'Tiga Fire!',
          );

          final countBefore = controller.project.lines.length;
          controller.addEmptyLine();
          expect(controller.project.lines.length, countBefore + 1);

          await controller.seek(22000);
          controller.snapLineToCurrentTime(firstLyric.id);
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == firstLyric.id)
                .startTimeMs,
            22000,
          );

          controller.deleteLine(firstLyric.id);
          expect(controller.project.lines.length, countBefore);

          controller.setSectionThresholds(
            const SectionDetectThresholds(
              introThresholdMs: 3000,
              interludeThresholdMs: 4000,
              outroThresholdMs: 4000,
            ),
            redetect: true,
          );
          expect(controller.sectionThresholds.introThresholdMs, 3000);
        } finally {
          controller.dispose();
        }
      },
    );
  });

  group('4. TimelineEditor, Call/tailUpdraft, GT Alerts, Shortcuts & PracticeOverlay', () {
    testWidgets(
      'TimelineEditorWidget & PracticeOverlay render cleanly and support Call tagging, tailUpdraft, GT alerts & shortcuts',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController();
        controller.setRoute(StudioRoute.export);
        try {
          // Verify demo-outro-1 uses valid front-wave x4 preset matching Web demoProject.ts
          final outro = controller.project.lines.firstWhere(
            (l) => l.id == 'demo-outro-1',
          );
          expect(
            outro.calls.any(
              (c) => c.presetId == 'front-wave' && c.suffix == '×4',
            ),
            isTrue,
          );
          expect(
            outro.calls.every(
              (c) => defaultCallPresets.any((p) => p.id == c.presetId),
            ),
            isTrue,
          );

          // Render HomeShell (starts on ExportView to bypass buggy DashboardView Wrap->SegmentedControl),
          // enabling full HomeShell keyboard shortcut & PracticeOverlay testing!
          await _pumpWithViewport(
            tester,
            _wrapWithPrism(
              controller: controller,
              child: HomeShell(controller: controller),
            ),
            viewport: const Size(1280, 820),
          );
          expect(tester.takeException(), isNull);

          // Select demo-2, test tag + suffix + tailUpdraft
          controller.selectLine('demo-2');
          expect(controller.toggleLineCall('demo-2', 'ppph'), isTrue);
          controller.setCallTagSuffix('demo-2', 'ppph', '×4');
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == 'demo-2')
                .calls
                .any((t) => t.presetId == 'ppph' && t.suffix == '×4'),
            isTrue,
          );

          expect(controller.toggleTailUpdraft('demo-2'), isTrue);
          final updatedDemo2 = controller.sortedLines.firstWhere(
            (l) => l.id == 'demo-2',
          );
          expect(updatedDemo2.tailUpdraft, isTrue);
          expect(updatedDemo2.calls.isNotEmpty, isTrue);

          // Custom preset creation (no delete method exists in Flutter vs Web)
          controller.addCustomPreset(
            label: '园长',
            colorHex: '#EC4899',
            category: CallCategory.compound,
            shortcut: '9',
          );
          expect(
            controller.customPresets.any((p) => p.label == '园长'),
            isTrue,
          );

          // GT alert update & active countdown computation
          controller.updateLineGtAlert(
            'demo-4',
            callTimingCue: 'hi hi',
            leadBeats: 4,
            note: '加速推进',
          );
          final demo4Alert = controller.getAlertForLine('demo-4')!;
          await controller.seek(demo4Alert.triggerTimeMs - 500);
          await tester.pump();
          final countdown = controller.activeGtAlertStatus;
          expect(countdown, isNotNull);
          expect(countdown!.targetLineId, 'demo-4');
          expect(countdown.isTriggered, isFalse);
          expect(countdown.remainingBeats, greaterThan(0));

          // Keyboard shortcut 'G' toggles GT alert, '1' toggles front-wave, 'F' & 'Escape' toggle PracticeOverlay
          controller.selectLine('demo-3');
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
          await tester.pump();
          expect(controller.getAlertForLine('demo-3'), isNotNull);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
          await tester.pump();
          expect(controller.getAlertForLine('demo-3'), isNull);

          final hadFront = controller.sortedLines
              .firstWhere((l) => l.id == 'demo-3')
              .calls
              .any((t) => t.presetId == 'front-wave');
          await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
          await tester.pump();
          final nowHasFront = controller.sortedLines
              .firstWhere((l) => l.id == 'demo-3')
              .calls
              .any((t) => t.presetId == 'front-wave');
          expect(nowHasFront, !hadFront);

          await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
          await tester.pump();
          expect(controller.isPracticeMode, isTrue);
          expect(find.byType(PracticeOverlay), findsOneWidget);
          expect(find.text('退出演练'), findsOneWidget);

          await tester.tap(find.text('Romaji'));
          await tester.pump();
          expect(controller.displayLayers.showRomaji, isTrue);

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          expect(controller.isPracticeMode, isFalse);
          expect(find.byType(PracticeOverlay), findsNothing);

          // Now mount TimelineEditorWidget standalone inside BottomInsetScope & verify zero layout issues
          await _pumpWithViewport(
            tester,
            _wrapWithPrism(
              controller: controller,
              child: prism.BottomInsetScope(
                inset: 0,
                child: SingleChildScrollView(
                  child: TimelineEditorWidget(
                    controller: controller,
                    compact: true,
                  ),
                ),
              ),
            ),
            viewport: const Size(1280, 820),
          );
          expect(tester.takeException(), isNull);
          expect(find.text('打标时间轴'), findsOneWidget);
          expect(find.text('+ 前/间/尾奏'), findsOneWidget);
          expect(find.text('+ 加行'), findsOneWidget);
          expect(find.text('+ 自定义标签'), findsOneWidget);
          expect(find.text('跟随'), findsOneWidget);
          expect(find.bySemanticsLabel('跟随播放滚动'), findsOneWidget);

          // Toggle followPlayback via UI Switch and controller cleanly
          await _scrollToAndTap(tester, find.bySemanticsLabel('跟随播放滚动'));
          expect(controller.followPlayback, isFalse);
          controller.setFollowPlayback(true);
          expect(controller.followPlayback, isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          await _disposeTestTree(tester, controller);
        }
      },
    );
  });

  group('5. Archive Save Guard & Quick Switcher Dialog', () {
    testWidgets(
      'Archive save guard prompts on switching/demo after external LRC import; ArchiveQuickSwitcher creates, renames, switches & deletes',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController();
        controller.setRoute(StudioRoute.export);
        try {
          await _pumpWithViewport(
            tester,
            _wrapWithPrism(
              controller: controller,
              child: HomeShell(controller: controller),
            ),
            viewport: const Size(1280, 820),
          );
          expect(tester.takeException(), isNull);
          expect(controller.archives, isEmpty);
          expect(controller.needsSavePromptBeforeSwitch, isFalse);

          await controller.importLrcText(lrc: '[00:05.00] First Song Line');
          controller.updateMeta(title: 'First Saved Song');
          await tester.pump();
          expect(controller.needsSavePromptBeforeSwitch, isTrue);

          // Exercise confirmArchiveSaveIfNeeded using HomeShell context
          final ctx = tester.element(find.byType(HomeShell));
          final promptFuture = confirmArchiveSaveIfNeeded(
            ctx,
            controller,
            actionLabel: '加载演练 Demo',
            targetLabel: '175 BPM 合成 Demo',
          );
          await tester.pump();
          expect(find.text('保存当前 Call 本再加载演练 Demo？'), findsOneWidget);
          await tester.tap(find.text('保存并继续'));
          await tester.pump();
          final ok = await promptFuture;
          expect(ok, isTrue);

          await controller.loadDemoProject();
          await tester.pump();
          expect(controller.archives.length, 1);
          expect(controller.archives.first.name, 'First Saved Song');
          expect(controller.needsSavePromptBeforeSwitch, isFalse);
          expect(find.text('存档 1'), findsOneWidget);

          // Open ArchiveQuickSwitcher from HomeShell header chip
          await tester.tap(find.text('存档 1'));
          await tester.pump();
          expect(find.text('Call 本存档快捷切换'), findsOneWidget);
          expect(find.text('First Saved Song'), findsOneWidget);

          final archiveId = controller.archives.first.id;
          expect(controller.renameArchive(archiveId, 'Renamed Song #1'), isTrue);
          await tester.pump();
          expect(find.text('Renamed Song #1'), findsOneWidget);

          await tester.tap(find.text('关闭'));
          await tester.pump();

          expect(await controller.switchToArchive(archiveId), isTrue);
          expect(controller.project.meta.title, 'First Saved Song');
          expect(controller.activeArchiveId, archiveId);

          final dup = controller.saveCurrentToArchive(
            asNew: true,
            customName: 'Duplicate Song',
          );
          expect(controller.archives.length, 2);
          expect(controller.deleteArchive(dup.id), isTrue);
          expect(controller.archives.length, 1);
          expect(tester.takeException(), isNull);
        } finally {
          await _disposeTestTree(tester, controller);
        }
      },
    );
  });

  group('6. ExportView, QuickRefSheet, Clipboard JSON/Markdown & XLSX', () {
    testWidgets(
      'ExportView renders QuickRefSheet, prompts editor info on export, copies JSON/Markdown & builds valid 2-sheet XLSX',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController();
        controller.setRoute(StudioRoute.export);
        controller.updateMeta(
          composer: 'SAWTOWNE',
          lyricist: 'SAWTOWNE',
          vocalist: '初音ミク',
          tuner: 'MixMaster',
          showTuner: true,
        );
        controller.toggleTailUpdraft(controller.sortedLines.first.id);
        try {
          await _pumpWithViewport(
            tester,
            _wrapWithPrism(
              controller: controller,
              child: HomeShell(controller: controller),
            ),
            viewport: const Size(1280, 820),
          );
          expect(tester.takeException(), isNull);

          expect(find.text('演出现场速查卡 · 多格式导出中心'), findsOneWidget);
          expect(find.text('LIVE CALL QUICK-REF SHEET'), findsOneWidget);
          expect(find.text('导出 / 分享高清 PNG'), findsOneWidget);
          expect(find.text('导出 Excel (.xlsx)'), findsOneWidget);
          expect(find.text('复制 Markdown'), findsOneWidget);
          expect(find.text('分享文本'), findsOneWidget);
          expect(find.text('复制 JSON 工程'), findsOneWidget);

          // Gap check: Print / PDF & Import JSON absent vs Web ExportPanel
          expect(find.textContaining('PDF'), findsNothing);
          expect(find.textContaining('导入工程'), findsNothing);

          // Copy JSON flow with pre-export editor modal
          await tester.tap(find.text('复制 JSON 工程'));
          await tester.pump();
          expect(find.text('确认编者与编者语'), findsOneWidget);
          await tester.enterText(
            find.widgetWithText(prism.TextField, '编者（你的圈名/cn）'),
            '澪终',
          );
          await tester.tap(find.text('确认并导出'));
          await tester.pump();

          expect(controller.project.meta.editorName, '澪终');
          final decodedJson = jsonDecode(clipboardText) as Map<String, dynamic>;
          final roundtripped = CallProject.fromJson(decodedJson);
          expect(roundtripped.meta.editorName, '澪终');
          expect(roundtripped.lines.length, controller.project.lines.length);

          // Copy Markdown flow
          await tester.tap(find.text('复制 Markdown'));
          await tester.pump();
          await tester.tap(find.text('确认并导出'));
          await tester.pump();
          expect(clipboardText, contains('# Starlight Overdrive'));
          expect(clipboardText, contains('## 歌词与 Call 速查时间轴'));
          expect(clipboardText, contains('编者：澪终'));
          expect(clipboardText, contains('尾句上升气流'));
          expect(clipboardText, contains('GT 警报'));

          // Real XLSX export XML verification
          final xlsxBytes = buildCallBookXlsxBytes(
            controller.project,
            controller.allPresets,
            displayLayers: controller.displayLayers,
          );
          expect(xlsxBytes.length, greaterThan(500));
          expect(xlsxBytes[0], 0x50);
          expect(xlsxBytes[1], 0x4B);
          final entries = _unzipXmlEntries(xlsxBytes);
          expect(entries['xl/workbook.xml'], contains('Callbook'));
          expect(entries['xl/workbook.xml'], contains('详细版'));
          expect(entries['xl/sharedStrings.xml'], contains('（尾句上升气流）'));
          expect(entries['xl/sharedStrings.xml'], contains('（GT警报）'));
          expect(tester.takeException(), isNull);
        } finally {
          await _disposeTestTree(tester, controller);
        }
      },
    );
  });

  group('7. Mocked Backend API, SiteCopy & NetEase Gateway Service', () {
    testWidgets(
      'Hydrates backend & site copy, searches/loads remote track, configures & stops NetEase Gateway cleanly',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        bool gatewayRunning = false;
        String storedCookieMasked = '';

        final mockHttp = MockClient((req) async {
          final path = req.url.path;
          if (path == '/health') {
            return http.Response(
              jsonEncode({
                'status': 'ok',
                'customProxyEnabled': gatewayRunning,
                'providers': ['custom_proxy', 'lrclib', 'mock'],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (path == '/api/site-copy') {
            return http.Response(
              jsonEncode({
                'entries': {
                  'sidebar_dashboard': {
                    'original': '控制台',
                    'value': '控制台',
                  },
                  'header_practice': {
                    'original': '演练',
                    'value': '舞台模式',
                  },
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (path == '/api/gateway/status') {
            return http.Response(
              jsonEncode({
                'gatewayUrl': 'http://127.0.0.1:3000',
                'gatewayOnline': gatewayRunning,
                'customProxyEnabled': gatewayRunning,
                'cookieConfigured': storedCookieMasked.isNotEmpty,
                'cookieMasked': storedCookieMasked,
                'managedByBackend': gatewayRunning,
                'pid': gatewayRunning ? 43210 : null,
                'canSpawnLocal': true,
                'nodeAvailable': true,
                'packageAvailable': true,
                'neteaseAccount': gatewayRunning ? 'TestUserCN' : null,
                'message': gatewayRunning ? '网关在线运行中' : '网关未启动',
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (path == '/api/gateway/configure') {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            final cookie = body['neteaseCookie']?.toString() ?? '';
            gatewayRunning = cookie.contains('MUSIC_U=');
            storedCookieMasked = 'MUSIC_U=***test';
            return http.Response(
              jsonEncode({
                'gatewayUrl': body['gatewayUrl'] ?? 'http://127.0.0.1:3000',
                'gatewayOnline': gatewayRunning,
                'customProxyEnabled': gatewayRunning,
                'cookieConfigured': true,
                'cookieMasked': storedCookieMasked,
                'managedByBackend': true,
                'pid': 43210,
                'canSpawnLocal': true,
                'nodeAvailable': true,
                'packageAvailable': true,
                'neteaseAccount': 'TestUserCN',
                'message': '网关已启动并登录成功',
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (path == '/api/gateway/stop') {
            gatewayRunning = false;
            return http.Response(
              jsonEncode({
                'gatewayUrl': 'http://127.0.0.1:3000',
                'gatewayOnline': false,
                'customProxyEnabled': false,
                'cookieConfigured': true,
                'cookieMasked': storedCookieMasked,
                'managedByBackend': false,
                'canSpawnLocal': true,
                'nodeAvailable': true,
                'packageAvailable': true,
                'message': '网关已停止',
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (path == '/api/search') {
            return http.Response(
              jsonEncode({
                'query': req.url.queryParameters['q'] ?? '',
                'providerUsed': 'custom_proxy',
                'fallbackTriggered': false,
                'results': [
                  {
                    'id': '998877',
                    'platform': 'netease',
                    'title': 'Remote Mirage',
                    'artist': 'Unit X',
                    'album': 'Single 1',
                    'durationMs': 42000,
                    'bpm': 168,
                    'hasSyncedLyrics': true,
                    'hasAudioUrl': true,
                    'provider': 'custom_proxy',
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (path == '/api/track/custom_proxy/998877') {
            return http.Response(
              jsonEncode({
                'track': {
                  'id': '998877',
                  'platform': 'netease',
                  'title': 'Remote Mirage',
                  'artist': 'Unit X',
                  'durationMs': 42000,
                  'bpm': 168,
                  'hasSyncedLyrics': true,
                  'hasAudioUrl': true,
                  'provider': 'custom_proxy',
                },
                'audioUrl': 'http://127.0.0.1:3000/song.mp3',
                'rawLrc': '[00:08.00] 夢を追いかけよう',
                'translatedLrc': '[00:08.00] 去追逐梦想吧',
                'lines': [
                  {
                    'id': 'rem-1',
                    'startTimeMs': 8000,
                    'endTimeMs': 15000,
                    'kind': 'lyric',
                    'text': {
                      'original': '夢を追いかけよう',
                      'ruby':
                          '<ruby>夢<rt>ゆめ</rt></ruby>を<ruby>追<rt>お</rt></ruby>いかけよう',
                      'romaji': 'yume wo oikakeyou',
                      'translation': '去追逐梦想吧',
                    },
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('Not found', 404);
        });

        final controller = await _initController(httpClient: mockHttp);
        controller.setRoute(StudioRoute.export);
        try {
          await _pumpWithViewport(
            tester,
            _wrapWithPrism(
              controller: controller,
              child: HomeShell(controller: controller),
            ),
            viewport: const Size(1280, 820),
          );
          expect(tester.takeException(), isNull);

          expect(controller.backendOnline, isTrue);
          expect(controller.siteText('演练'), '舞台模式');
          expect(find.text('舞台模式'), findsOneWidget);
          // Gap vs Web: no SiteEditOverlay / '文字编辑' trigger in Flutter
          expect(find.text('文字编辑'), findsNothing);

          // Cookie normalization + one-click gateway configure & start
          expect(
            DesktopServiceLauncher.normalizeNeteaseCookie('abc123token456'),
            'MUSIC_U=abc123token456; os=pc',
          );
          final gwOk = await controller.oneClickConfigureAndStartGateway(
            cookie: 'abc123token456',
            gatewayUrl: 'http://127.0.0.1:3000',
          );
          expect(gwOk, isTrue);
          expect(controller.gatewayStatus.gatewayOnline, isTrue);
          expect(controller.gatewayStatus.neteaseAccount, 'TestUserCN');
          expect(
            controller.savedNeteaseCookie,
            'MUSIC_U=abc123token456; os=pc',
          );

          // Remote search & load track
          await controller.searchTracks('Mirage', source: 'custom_proxy');
          expect(controller.searchResults.length, 1);
          expect(controller.searchResults.first.title, 'Remote Mirage');

          await controller.loadRemoteTrack(controller.searchResults.first);
          expect(controller.project.meta.title, 'Remote Mirage');
          expect(controller.project.meta.bpm, 168);
          expect(controller.hasFetchedExternalLyrics, isTrue);
          expect(
            controller.sortedLines.any((l) => l.kind == LyricLineKind.intro),
            isTrue,
          );
          expect(
            controller.sortedLines.any((l) => l.kind == LyricLineKind.outro),
            isTrue,
          );

          // Stop managed gateway
          await controller.stopManagedGateway();
          expect(controller.gatewayStatus.gatewayOnline, isFalse);
          expect(tester.takeException(), isNull);
        } finally {
          await _disposeTestTree(tester, controller);
        }
      },
    );
  });
}
