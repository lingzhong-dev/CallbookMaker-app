import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data' show Endian;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_call_studio/constants/app_info.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/services/api_client.dart';
import 'package:live_call_studio/services/desktop_service_launcher.dart';
import 'package:live_call_studio/services/lrclib_direct_client.dart';
import 'package:live_call_studio/services/netease_direct_client.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/ui/archive_view.dart';
import 'package:live_call_studio/ui/export_view.dart';
import 'package:live_call_studio/ui/home_shell.dart';
import 'package:live_call_studio/ui/more_view.dart';
import 'package:live_call_studio/ui/practice_overlay.dart';
import 'package:live_call_studio/ui/theme_view.dart';
import 'package:live_call_studio/ui/widgets/archive_switcher_dialog.dart';
import 'package:live_call_studio/ui/widgets/gateway_config_panel.dart';
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
  http.Client? neteaseHttpClient,
  http.Client? lrclibHttpClient,
  Map<String, Object> initialPrefs = const {
    'live_call_studio_onboarding_v1': true,
  },
  bool enableAudioOutput = false,
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final client =
      httpClient ?? MockClient((req) async => http.Response('offline', 503));
  final api = CallbookApiClient(
    baseUrl: 'http://127.0.0.1:8000',
    httpClient: client,
  );
  final neteaseDirect = NeteaseDirectClient(
    httpClient:
        neteaseHttpClient ??
        MockClient((req) async => http.Response('offline', 503)),
  );
  final lrclibDirect = LrclibDirectClient(
    httpClient:
        lrclibHttpClient ??
        MockClient((req) async => http.Response('offline', 503)),
  );
  final controller = CallbookController(
    apiClient: api,
    neteaseDirectClient: neteaseDirect,
    lrclibDirectClient: lrclibDirect,
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

          await _scrollToAndTap(tester, find.text('4/4'));
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

  group('2. HomeShell 4-Tab Navigation, ArchiveView, MoreView & ThemeView Parity', () {
    testWidgets(
      'Desktop HomeShell renders 4-item nav (主页/导出/存档/更多), MoreView subpages & About layout with ZERO exceptions',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController();
        controller.setRoute(StudioRoute.more);
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

          final sidebar = find.byType(prism.NavigationSidebar);
          expect(sidebar, findsOneWidget);
          expect(find.descendant(of: sidebar, matching: find.text('主页')), findsOneWidget);
          expect(find.descendant(of: sidebar, matching: find.text('导出')), findsOneWidget);
          expect(find.descendant(of: sidebar, matching: find.text('存档')), findsOneWidget);
          expect(find.descendant(of: sidebar, matching: find.text('更多')), findsOneWidget);

          // Removed header archive chip & old Theme destination
          expect(find.text('外观主题'), findsNothing);
          expect(find.text('存档 0'), findsNothing);
          expect(find.text('Call 本存档'), findsNothing);
          expect(find.text('演练模式 F'), findsOneWidget);

          // MoreView root menu shows 3 options
          expect(find.byType(MoreView), findsOneWidget);
          expect(find.descendant(of: find.byType(MoreView), matching: find.text('网关配置')), findsOneWidget);
          expect(find.descendant(of: find.byType(MoreView), matching: find.text('主题')), findsOneWidget);
          expect(find.descendant(of: find.byType(MoreView), matching: find.text('关于')), findsOneWidget);

          // Switch route -> ArchiveView -> ExportView -> Dashboard -> MoreView cleanly
          await tester.tap(find.descendant(of: sidebar, matching: find.text('存档')));
          await tester.pump();
          expect(controller.route, StudioRoute.archive);
          expect(find.byType(ArchiveView), findsOneWidget);

          await tester.tap(find.descendant(of: sidebar, matching: find.text('导出')));
          await tester.pump();
          expect(controller.route, StudioRoute.export);
          expect(find.byType(ExportView), findsOneWidget);

          await tester.tap(find.descendant(of: sidebar, matching: find.text('更多')));
          await tester.pump();
          expect(controller.route, StudioRoute.more);
          expect(find.byType(MoreView), findsOneWidget);

          // 1) Enter Gateway Config subpage, verify GatewayConfigPanel & back chevron
          await tester.tap(find.descendant(of: find.byType(MoreView), matching: find.text('网关配置')));
          await tester.pump();
          expect(find.byType(GatewayConfigPanel), findsOneWidget);
          expect(find.text('网易云直连 & 可选后端服务'), findsOneWidget);
          expect(find.bySemanticsLabel('返回更多'), findsOneWidget);
          await tester.tap(find.bySemanticsLabel('返回更多'));
          await tester.pump();
          expect(find.byType(GatewayConfigPanel), findsNothing);
          expect(find.descendant(of: find.byType(MoreView), matching: find.text('主题')), findsOneWidget);

          // 2) Enter Theme subpage, then verify re-tapping '更多' nav resets subpage back to root
          await tester.tap(find.descendant(of: find.byType(MoreView), matching: find.text('主题')));
          await tester.pump();
          expect(find.byType(ThemeView), findsOneWidget);

          await tester.tap(find.descendant(of: sidebar, matching: find.text('更多')));
          await tester.pump();
          expect(find.byType(ThemeView), findsNothing);
          expect(find.descendant(of: find.byType(MoreView), matching: find.text('网关配置')), findsOneWidget);

          // 3) Re-enter ThemeView & exercise ThemeMode, ColorStyle, OLED, Glass, GoogleSans & Reset
          await tester.tap(find.descendant(of: find.byType(MoreView), matching: find.text('主题')));
          await tester.pump();
          expect(find.byType(ThemeView), findsOneWidget);

          await _scrollToAndTap(tester, find.text('深色 Dark'));
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
          expect(find.text('HCT 色相与明度滑块'), findsNothing);

          await tester.tap(find.bySemanticsLabel('返回更多'));
          await tester.pump();

          // 4) Enter About subpage & verify layout, version, developer GitHub & GPL license dialog
          await tester.tap(find.descendant(of: find.byType(MoreView), matching: find.text('关于')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(find.bySemanticsLabel('返回更多'), findsOneWidget);
          expect(find.text(kAppDisplayName), findsOneWidget);
          expect(find.text('Version $kAppVersion'), findsOneWidget);
          expect(find.text('开发者'), findsOneWidget);
          expect(find.text(kDeveloperGithubId), findsOneWidget);
          expect(find.text(kDeveloperGithubUrl), findsOneWidget);
          expect(
            find.text('当前版本 Version $kAppVersion · 遵循 $kAppLicenseName 开源协议'),
            findsOneWidget,
          );

          await tester.tap(find.text(kDeveloperGithubUrl));
          await tester.pump();
          expect(clipboardText, kDeveloperGithubUrl);

          await _scrollToAndTap(tester, find.text('《$kAppLicenseName 开源协议》'));
          expect(find.text('$kAppLicenseName 开源协议'), findsOneWidget);
          expect(find.textContaining('GNU GENERAL PUBLIC LICENSE'), findsOneWidget);
          await tester.tap(find.text('关闭'));
          await tester.pump();
          expect(find.text('$kAppLicenseName 开源协议'), findsNothing);

          expect(tester.takeException(), isNull);
        } finally {
          await _disposeTestTree(tester, controller);
        }
      },
    );

    testWidgets(
      'Mobile HomeShell renders 4-tab NavigationDock / anchored bar & MoreView About page cleanly without overflow',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController();
        controller.setRoute(StudioRoute.more);
        final launchedUrls = <String>[];
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
          final dock = find.byType(prism.NavigationDock);
          expect(dock, findsOneWidget);
          expect(find.descendant(of: dock, matching: find.text('主页')), findsOneWidget);
          expect(find.descendant(of: dock, matching: find.text('导出')), findsOneWidget);
          expect(find.descendant(of: dock, matching: find.text('存档')), findsOneWidget);
          expect(find.descendant(of: dock, matching: find.text('更多')), findsOneWidget);

          controller.setFloatingNavDock(false);
          await tester.pump();
          expect(find.byType(prism.NavigationDock), findsNothing);
          expect(find.text('主页'), findsOneWidget);
          expect(find.text('导出'), findsOneWidget);
          expect(find.text('存档'), findsOneWidget);
          expect(find.text('更多'), findsWidgets);

          // Standalone MoreView at mobile width verifies external URL launcher callback & zero overflow in About
          await _pumpWithViewport(
            tester,
            _wrapWithPrism(
              controller: controller,
              child: prism.BottomInsetScope(
                inset: 84,
                child: MoreView(
                  controller: controller,
                  onLaunchExternalUrl: (url) async => launchedUrls.add(url),
                ),
              ),
            ),
            viewport: const Size(390, 844),
          );
          await tester.tap(find.text('关于'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(find.text(kAppDisplayName), findsOneWidget);
          expect(find.text(kDeveloperGithubId), findsOneWidget);
          await tester.tap(find.text(kDeveloperGithubUrl));
          await tester.pump();
          expect(launchedUrls, [kDeveloperGithubUrl]);
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
          final lyricLines = controller.sortedLines
              .where((l) => l.kind == LyricLineKind.lyric)
              .toList();
          final lineA = lyricLines[0].id;
          final lineB = lyricLines[1].id;
          final lineC = lyricLines[2].id;
          final outro = controller.sortedLines.firstWhere(
            (l) => l.kind == LyricLineKind.outro,
          );
          expect(outro.calls, isEmpty);
          expect(controller.sortedAlerts, isEmpty);

          // Render HomeShell (starts on ExportView to bypass unrelated Dashboard layout),
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

          // Select lineA, test tag + suffix + tailUpdraft
          controller.selectLine(lineA);
          expect(controller.toggleLineCall(lineA, 'ppph'), isTrue);
          controller.setCallTagSuffix(lineA, 'ppph', '×4');
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == lineA)
                .calls
                .any((t) => t.presetId == 'ppph' && t.suffix == '×4'),
            isTrue,
          );

          expect(controller.toggleTailUpdraft(lineA), isTrue);
          final updatedLineA = controller.sortedLines.firstWhere(
            (l) => l.id == lineA,
          );
          expect(updatedLineA.tailUpdraft, isTrue);
          expect(updatedLineA.calls.isNotEmpty, isTrue);

          // Custom preset creation
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

          // GT alert creation, note update & PracticeOverlay rendering (flagging + highlight + note; no timing/countdown)
          controller.toggleLineGtAlert(lineId: lineC);
          controller.updateLineGtAlert(
            lineC,
            note: '加速推进',
          );
          final lineCAlert = controller.getAlertForLine(lineC)!;
          expect(lineCAlert.targetLineId, lineC);
          expect(lineCAlert.note, '加速推进');
          await controller.seek(lineCAlert.triggerTimeMs);
          await tester.pump();
          expect(controller.playingLineId, lineC);

          // Keyboard shortcut 'G' toggles GT alert, '1' toggles front-wave, 'F' & 'Escape' toggle PracticeOverlay
          controller.selectLine(lineB);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
          await tester.pump();
          expect(controller.getAlertForLine(lineB), isNotNull);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
          await tester.pump();
          expect(controller.getAlertForLine(lineB), isNull);

          final hadFront = controller.sortedLines
              .firstWhere((l) => l.id == lineB)
              .calls
              .any((t) => t.presetId == 'front-wave');
          await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
          await tester.pump();
          final nowHasFront = controller.sortedLines
              .firstWhere((l) => l.id == lineB)
              .calls
              .any((t) => t.presetId == 'front-wave');
          expect(nowHasFront, !hadFront);

          // Keep playhead on lineC (which has active GT alert & note) and verify PracticeOverlay shows GT badge + note
          await controller.seek(lineCAlert.triggerTimeMs);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
          await tester.pump();
          expect(controller.isPracticeMode, isTrue);
          expect(find.byType(PracticeOverlay), findsOneWidget);
          expect(find.textContaining('LIVE PRACTICE MODE'), findsOneWidget);
          expect(find.text('退出演练'), findsOneWidget);
          expect(find.text('GT 警报'), findsWidgets);
          expect(find.text('加速推进'), findsWidgets);
          expect(find.textContaining('倒数'), findsNothing);
          expect(find.textContaining('喊声时机'), findsNothing);

          await tester.tap(find.text('罗马音'));
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
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) => prism.BottomInsetScope(
                  inset: 0,
                  child: SingleChildScrollView(
                    child: TimelineEditorWidget(
                      controller: controller,
                      compact: true,
                    ),
                  ),
                ),
              ),
            ),
            viewport: const Size(1280, 820),
          );
          expect(tester.takeException(), isNull);
          expect(find.text('编写工作台'), findsOneWidget);
          expect(find.text('前/间/尾奏'), findsOneWidget);
          expect(find.text('加行'), findsOneWidget);
          expect(find.text('+ 自定义标签'), findsOneWidget);
          expect(find.text('跟随滚动'), findsOneWidget);
          expect(find.bySemanticsLabel('跟随播放滚动'), findsOneWidget);
          expect(find.text('GT 警报备注'), findsOneWidget);
          expect(find.text('加速推进'), findsOneWidget);
          expect(find.text('GT 前置警报音'), findsNothing);
          expect(find.textContaining('喊声时机'), findsNothing);

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

    testWidgets(
      'Sing-along (跟唱) prompts for custom lyrics, Clap (拍手) tags directly, and Custom Presets support right-click & long-press Edit / Delete with cascade',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController();
        final targetLineId = controller.sortedLines
            .firstWhere((l) => l.kind == LyricLineKind.lyric)
            .id;
        controller.selectLine(targetLineId);
        try {
          await _pumpWithViewport(
            tester,
            _wrapWithPrism(
              controller: controller,
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) => prism.BottomInsetScope(
                  inset: 0,
                  child: SingleChildScrollView(
                    child: TimelineEditorWidget(
                      controller: controller,
                      compact: true,
                    ),
                  ),
                ),
              ),
            ),
            viewport: const Size(1280, 820),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          // 1. Built-in '拍手' (clap) tags immediately without a dialog
          await _scrollToAndTap(tester, find.text('拍手').first);
          await tester.pump();
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == targetLineId)
                .calls
                .any((t) => t.presetId == 'clap'),
            isTrue,
          );

          // 2. Built-in '跟唱' (sing-along) opens '输入跟唱部分' dialog; canceling does not attach
          await tester.tap(find.text('跟唱').first);
          await tester.pumpAndSettle();
          expect(find.text('输入跟唱部分'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == targetLineId)
                .calls
                .any((t) => t.presetId == singAlongPresetId),
            isFalse,
          );

          // 3. Entering sing-along text and confirming attaches 'sing-along' with suffix
          await tester.tap(find.text('跟唱').first);
          await tester.pumpAndSettle();
          expect(find.text('输入跟唱部分'), findsOneWidget);
          await tester.enterText(
            find.widgetWithText(prism.TextField, '例如：La la la~ / 副歌跟唱句'),
            'La la la 一起唱!',
          );
          await tester.pump();
          await tester.tap(find.text('确认跟唱'));
          await tester.pumpAndSettle();

          final targetAfterSingAlong = controller.sortedLines.firstWhere(
            (l) => l.id == targetLineId,
          );
          expect(
            targetAfterSingAlong.calls.any(
              (t) =>
                  t.presetId == singAlongPresetId &&
                  t.suffix == 'La la la 一起唱!',
            ),
            isTrue,
          );
          expect(find.text('La la la 一起唱!'), findsOneWidget);

          // 4. Built-in presets do NOT open custom preset context menu on right-click
          await tester.tap(
            find.text('拍手').first,
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          expect(find.text('修改名称 / 颜色'), findsNothing);
          expect(find.text('删除自定义标签'), findsNothing);

          // 5. Add a custom preset, attach it to targetLineId, then right-click to edit name & color
          controller.addCustomPreset(
            label: '园长Call',
            colorHex: '#EC4899',
            category: CallCategory.compound,
            shortcut: 'Q',
          );
          await tester.pump();
          final customPreset = controller.customPresets.single;
          expect(customPreset.label, '园长Call');

          await tester.tap(find.text('园长Call').first);
          await tester.pump();
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == targetLineId)
                .calls
                .any((t) => t.presetId == customPreset.id),
            isTrue,
          );

          // Right-click custom preset pill -> opens context menu -> Edit
          await tester.tap(
            find.text('园长Call').first,
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          expect(find.text('修改名称 / 颜色'), findsOneWidget);
          expect(find.text('删除自定义标签'), findsOneWidget);

          await tester.tap(find.text('修改名称 / 颜色'));
          await tester.pumpAndSettle();
          expect(find.text('修改自定义标签'), findsOneWidget);

          await tester.enterText(
            find.widgetWithText(prism.TextField, '输入新的标签名称'),
            '超级园长',
          );
          await tester.enterText(
            find.widgetWithText(prism.TextField, '自定义色值（#RRGGBB）'),
            '#14B8A6',
          );
          await tester.pump();
          await tester.tap(find.text('保存修改'));
          await tester.pumpAndSettle();

          expect(controller.customPresets.single.label, '超级园长');
          expect(controller.customPresets.single.colorHex, '#14B8A6');
          expect(find.text('超级园长'), findsWidgets);

          // 6. Long-press custom preset pill -> opens context menu -> Delete with confirmation & cascade
          await tester.longPress(find.text('超级园长').first);
          await tester.pumpAndSettle();
          expect(find.text('删除自定义标签'), findsOneWidget);

          await tester.tap(find.text('删除自定义标签'));
          await tester.pumpAndSettle();
          expect(find.textContaining('当前已挂载于 1 句歌词'), findsOneWidget);

          await tester.tap(find.text('确认删除'));
          await tester.pumpAndSettle();
          expect(controller.customPresets, isEmpty);
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == targetLineId)
                .calls
                .any((t) => t.presetId == customPreset.id),
            isFalse,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await _disposeTestTree(tester, controller);
        }
      },
    );

    testWidgets(
      'Double-tapping timeline card opens edit dialog; word-accurate split dialog cuts runes & adopts current time with Undo',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController();
        await controller.importLrcText(
          lrc: '[00:05.00] 梦想的星光\n[00:12.00] 下一句歌词\n[00:18.00] 第三句歌词',
        );
        final firstLyric = controller.sortedLines.firstWhere(
          (l) => l.kind == LyricLineKind.lyric,
        );
        // Ensure a second line isn't initially focused onto firstLyric so double-tap selects AND edits it
        controller.selectLine(controller.sortedLines.last.id);
        try {
          await _pumpWithViewport(
            tester,
            _wrapWithPrism(
              controller: controller,
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) => prism.BottomInsetScope(
                  inset: 0,
                  child: SingleChildScrollView(
                    child: TimelineEditorWidget(
                      controller: controller,
                      compact: true,
                    ),
                  ),
                ),
              ),
            ),
            viewport: const Size(1280, 820),
          );
          expect(tester.takeException(), isNull);

          // 1. Double-tap timeline lyric card -> selects line & opens '编辑歌词与段落'
          await _scrollToAndTap(tester, find.text('梦想的星光'));
          await tester.pump(const Duration(milliseconds: 50));
          await tester.tap(find.text('梦想的星光'));
          await tester.pumpAndSettle();
          expect(find.text('编辑歌词与段落'), findsOneWidget);
          expect(find.text('按字拆分此句'), findsOneWidget);

          await tester.enterText(
            find.widgetWithText(prism.TextField, '歌词原文 / 段落标题'),
            '闪烁的星光',
          );
          await tester.tap(find.text('保存'));
          await tester.pumpAndSettle();

          final editedLine = controller.sortedLines.firstWhere(
            (l) => l.id == firstLyric.id,
          );
          expect(editedLine.text.original, '闪烁的星光');
          expect(controller.activeLineId, firstLyric.id);

          // 2. Selected splittable lyric card shows '拆分' chip; seek strictly inside line for '采用当前时刻'
          expect(find.text('拆分'), findsOneWidget);
          await controller.seek(7000);
          await tester.pump();

          await tester.tap(find.text('拆分'));
          await tester.pumpAndSettle();
          expect(find.text('按字拆分歌词'), findsOneWidget);
          expect(find.text('采用当前时刻 00:07.00'), findsOneWidget);

          // Clear default midpoint cut, then pick cuts after char 2 ('闪烁') and char 4 ('的星') -> 3 chunks
          await tester.tap(find.text('清空切分'));
          await tester.pump();
          expect(find.text('拆分预览（2 句）'), findsNothing);

          await tester.tap(find.bySemanticsLabel('在第 2 字后拆分'));
          await tester.pump();
          // Adopt current playback timestamp 00:07.00 on boundary 1
          await _scrollToAndTap(tester, find.text('采用当前时刻 00:07.00'));
          await tester.pump();
          await tester.tap(find.bySemanticsLabel('在第 4 字后拆分'));
          await tester.pump();
          expect(find.text('拆分预览（3 句）'), findsOneWidget);

          await _scrollToAndTap(tester, find.text('确认拆分'));
          await tester.pumpAndSettle();

          final splitTexts = [
            for (final l in controller.sortedLines)
              if (l.kind == LyricLineKind.lyric) l.text.original,
          ];
          expect(
            splitTexts,
            containsAllInOrder(['闪烁', '的星', '光', '下一句歌词', '第三句歌词']),
          );
          final chunk1 = controller.sortedLines.firstWhere(
            (l) => l.text.original == '闪烁',
          );
          final chunk2 = controller.sortedLines.firstWhere(
            (l) => l.text.original == '的星',
          );
          expect(chunk1.endTimeMs, 7000);
          expect(chunk2.startTimeMs, 7000);

          // Undo restores the unsplit '闪烁的星光' line cleanly
          expect(find.text('撤销'), findsOneWidget);
          await _scrollToAndTap(tester, find.text('撤销'));
          await tester.pump();
          expect(
            controller.sortedLines.any((l) => l.text.original == '闪烁的星光'),
            isTrue,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await _disposeTestTree(tester, controller);
        }
      },
    );
  });

  group('5. Archive Save Guard & Standalone ArchiveView', () {
    testWidgets(
      'Archive save guard prompts after external LRC import; ArchiveView lists, saves, renames, switches & deletes archives',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController();
        controller.setRoute(StudioRoute.archive);
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
          expect(find.byType(ArchiveView), findsOneWidget);
          expect(find.text('存档 0'), findsNothing);
          expect(find.text('暂无已保存的 Call 本存档'), findsOneWidget);
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
            actionLabel: '切换默认曲目',
            targetLabel: 'キズナミュージック♪（友谊的华章）',
          );
          await tester.pump();
          expect(find.text('保存当前 Call 本再切换默认曲目？'), findsOneWidget);
          await tester.tap(find.text('保存并继续'));
          await tester.pump();
          final ok = await promptFuture;
          expect(ok, isTrue);

          await controller.loadDefaultSong('default-kizuna-music');
          await tester.pump();
          expect(controller.archives.length, 1);
          expect(controller.archives.first.name, 'First Saved Song');
          expect(controller.needsSavePromptBeforeSwitch, isFalse);
          expect(find.text('存档 1'), findsNothing);
          expect(find.text('First Saved Song'), findsOneWidget);

          // Rename inline inside ArchiveView UI
          final archiveId = controller.archives.first.id;
          await _scrollToAndTap(tester, find.text('重命名'));
          await tester.enterText(
            find.widgetWithText(prism.TextField, '输入存档新名称...'),
            'Renamed Song #1',
          );
          await tester.tap(find.text('保存'));
          await tester.pump();
          expect(find.text('Renamed Song #1'), findsOneWidget);
          expect(controller.archives.first.name, 'Renamed Song #1');

          // Switch back to saved archive via UI button
          await _scrollToAndTap(tester, find.text('切换到此存档'));
          await tester.pump();
          expect(controller.project.meta.title, 'First Saved Song');
          expect(controller.activeArchiveId, archiveId);
          expect(find.text('已加载'), findsOneWidget);

          // Save-as duplicate via UI & delete via controller + UI state verification
          await _scrollToAndTap(tester, find.text('另存副本'));
          await tester.enterText(
            find.widgetWithText(prism.TextField, '输入新存档名称...'),
            'Duplicate Song',
          );
          await tester.tap(find.text('确定保存'));
          await tester.pump();
          expect(controller.archives.length, 2);
          expect(find.text('Duplicate Song'), findsWidgets);

          final dupId = controller.archives
              .firstWhere((a) => a.name == 'Duplicate Song')
              .id;
          expect(controller.deleteArchive(dupId), isTrue);
          await tester.pump();
          expect(controller.archives.length, 1);
          expect(tester.takeException(), isNull);
        } finally {
          await _disposeTestTree(tester, controller);
        }
      },
    );
  });

  group('6. ExportView, QuickRefSheet, File JSON, Markdown & XLSX', () {
    testWidgets(
      'ExportView renders QuickRefSheet, exports actual JSON project file without touching clipboard, copies Markdown & builds valid 2-sheet XLSX',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await _initController();
        controller.setRoute(StudioRoute.export);
        controller.updateMeta(
          composer: 'litterzy',
          lyricist: '冥凰',
          vocalist: '洛天依',
          tuner: 'Creuzer',
          showTuner: true,
        );
        controller.toggleTailUpdraft(controller.sortedLines.first.id);
        controller.toggleLineGtAlert(lineId: controller.sortedLines[1].id);
        controller.updateLineGtAlert(controller.sortedLines[1].id, note: '吉他前准备');
        try {
          String? exportedFileName;
          Uint8List? exportedJsonBytes;

          await _pumpWithViewport(
            tester,
            _wrapWithPrism(
              controller: controller,
              child: HomeShell(controller: controller),
            ),
            viewport: const Size(1280, 820),
          );
          expect(tester.takeException(), isNull);

          expect(find.text('导出当前Callbook'), findsOneWidget);
          expect(find.text('LIVE CALL QUICK-REF SHEET'), findsNothing);
          expect(find.textContaining('速查'), findsNothing);
          expect(find.text('生成 PNG 长图'), findsOneWidget);
          expect(find.text('导出 Excel (.xlsx)'), findsOneWidget);
          expect(find.text('复制 Markdown'), findsOneWidget);
          expect(find.text('分享文本'), findsOneWidget);
          expect(find.text('导出 JSON'), findsOneWidget);
          expect(find.text('导入工程'), findsOneWidget);
          expect(find.text('Generated by CallbookMaker · Material 3'), findsOneWidget);

          // Gap check: Print / PDF absent vs Web ExportPanel
          expect(find.textContaining('PDF'), findsNothing);

          // Mount ExportView with jsonFileExporter hook to verify actual JSON file export (no clipboard copy)
          controller.addCustomPreset(
            label: '专属高光',
            colorHex: '#14B8A6',
            shortcut: 'Q',
          );
          await _pumpWithViewport(
            tester,
            _wrapWithPrism(
              controller: controller,
              child: ExportView(
                controller: controller,
                jsonFileExporter: (fileName, bytes) async {
                  exportedFileName = fileName;
                  exportedJsonBytes = bytes;
                  return '/tmp/$fileName';
                },
              ),
            ),
            viewport: const Size(1280, 820),
          );

          await tester.tap(find.text('导出 JSON'));
          await tester.pumpAndSettle();
          expect(find.text('导出前确认编者与曲目署名'), findsOneWidget);
          await tester.enterText(
            find.widgetWithText(prism.TextField, '编者（你的圈名/cn）'),
            '澪终',
          );
          await tester.tap(find.text('确认并导出'));
          await tester.pumpAndSettle();

          expect(controller.project.meta.editorName, '澪终');
          expect(exportedFileName, '来自瓦纳海姆_callbook.json');
          expect(exportedJsonBytes, isNotNull);
          // JSON export MUST NOT overwrite clipboard with raw JSON text
          expect(clipboardText, isEmpty);

          final jsonText = utf8.decode(exportedJsonBytes!);
          final decodedJson = jsonDecode(jsonText) as Map<String, dynamic>;
          final roundtripped = CallProject.fromJson(decodedJson);
          expect(roundtripped.meta.editorName, '澪终');
          expect(roundtripped.lines.length, controller.project.lines.length);
          expect(decodedJson['customPresets'], isA<List<dynamic>>());

          // Delete custom preset then verify importProjectJson restores it from exported JSON file contents
          controller.deleteCustomPreset(controller.customPresets.single.id);
          expect(controller.customPresets, isEmpty);
          final imported = await controller.importProjectJson(
            jsonText,
            sourceName: exportedFileName!,
          );
          expect(imported, isTrue);
          expect(controller.project.meta.editorName, '澪终');
          expect(
            controller.customPresets.any(
              (p) => p.label == '专属高光' && p.colorHex == '#14B8A6',
            ),
            isTrue,
          );

          // Copy Markdown flow (note preserved, timing cue text removed)
          await tester.tap(find.text('复制 Markdown'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确认并导出'));
          await tester.pumpAndSettle();
          expect(clipboardText, contains('# 来自瓦纳海姆'));
          expect(clipboardText, contains('## 歌词与 Call 时间轴'));
          expect(clipboardText, contains('编者：澪终'));
          expect(clipboardText, contains('尾句上升气流'));
          expect(clipboardText, contains('GT 警报'));
          expect(clipboardText, contains('吉他前准备'));
          expect(clipboardText, isNot(contains('时机：')));

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
          expect(entries['xl/sharedStrings.xml'], isNot(contains('时机:')));
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
                'providers': ['custom_proxy', 'lrclib'],
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
                    'original': '主页',
                    'value': '工作台',
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
          expect(controller.siteText('主页'), '工作台');
          expect(find.text('工作台'), findsOneWidget);
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

  group('8. Merge Lines, Word-Aligned Calls & Auto-Advance Toggle Parity', () {
    testWidgets(
      'Controller & TimelineEditor support merging adjacent lines with GT alert retargeting',
      (tester) async {
        final controller = await _initController();
        try {
          await controller.importProjectJson(
            jsonEncode({
              'meta': {
                'title': 'Merge Parity Song',
                'artist': 'Unit Test',
                'bpm': 160,
                'timeSignature': '4/4',
              },
              'alerts': [
                {
                  'id': 'gt-a',
                  'triggerTimeMs': 1000,
                  'leadBeats': 4,
                  'note': 'Line A GT',
                  'targetLineId': 'l-a',
                },
                {
                  'id': 'gt-b',
                  'triggerTimeMs': 4000,
                  'leadBeats': 4,
                  'note': 'Line B GT',
                  'targetLineId': 'l-b',
                },
              ],
              'lines': [
                {
                  'id': 'sec-intro',
                  'startTimeMs': 0,
                  'endTimeMs': 1000,
                  'kind': 'intro',
                  'text': {'original': '【前奏】'},
                },
                {
                  'id': 'l-a',
                  'startTimeMs': 1000,
                  'endTimeMs': 4000,
                  'kind': 'lyric',
                  'calls': [{'presetId': 'front-wave'}],
                  'customShout': '高い',
                  'text': {
                    'original': '目指す場所は高い',
                    'ruby': '<ruby>目指<rt>めざ</rt></ruby>す<ruby>場所<rt>ばしょ</rt></ruby>は<ruby>高<rt>たか</rt></ruby>い',
                    'translation': '目标高远',
                  },
                },
                {
                  'id': 'l-b',
                  'startTimeMs': 4000,
                  'endTimeMs': 8000,
                  'kind': 'lyric',
                  'calls': [{'presetId': 'clap'}],
                  'tailUpdraft': true,
                  'alignedCalls': [
                    {'id': 'ac-b', 'start': 4, 'end': 8, 'text': 'どこまで'},
                  ],
                  'text': {
                    'original': 'いまよりどこまで',
                    'translation': '比现在去往何方',
                  },
                },
              ],
            }),
          );
          await tester.pump();

          // Section cannot merge with next lyric line
          expect(controller.mergeWithNextLine('sec-intro'), isFalse);

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
          expect(find.text('合并下句'), findsOneWidget);

          await tester.tap(find.text('合并下句'));
          await tester.pump();

          expect(controller.sortedLines.length, 2);
          final merged = controller.sortedLines.firstWhere((l) => l.id == 'l-a');
          expect(merged.text.original, '目指す場所は高い いまよりどこまで');
          expect(merged.tailUpdraft, isTrue);
          expect(merged.calls.length, 2);
          expect(merged.alignedCalls.length, 1);
          expect(merged.alignedCalls.first.start, 13);
          expect(merged.alignedCalls.first.end, 17);
          // Second GT alert was deduped leaving only gt-a on l-a
          expect(controller.sortedAlerts.length, 1);
          expect(controller.getAlertForLine('l-a')?.id, 'gt-a');
        } finally {
          await _disposeTestTree(tester, controller);
        }
      },
    );

    testWidgets(
      'Aligned Call picker adds/removes explicit cues & renders in ExportView & PracticeOverlay without overflow',
      (tester) async {
        final controller = await _initController();
        try {
          await controller.importProjectJson(
            jsonEncode({
              'meta': {
                'title': 'Align Visual Test',
                'artist': 'Singer',
                'bpm': 170,
              },
              'lines': [
                {
                  'id': 'al-1',
                  'startTimeMs': 1000,
                  'endTimeMs': 5000,
                  'kind': 'lyric',
                  'customShout': '高い / Hi-Call',
                  'text': {
                    'original': '目指す場所は高い',
                    'ruby': '<ruby>目指<rt>めざ</rt></ruby>す<ruby>場所<rt>ばしょ</rt></ruby>は<ruby>高<rt>たか</rt></ruby>い',
                    'translation': '目标高处',
                  },
                },
              ],
            }),
          );
          controller.selectLine('al-1');

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
          expect(find.text('CALL 词对位'), findsOneWidget);
          expect(find.text('+ 对位 Call'), findsOneWidget);
          // Auto-aligned '高い' removed from top badge strip, only 'Hi-Call' remains
          expect(find.text('Hi-Call'), findsOneWidget);

          // Open char-range picker dialog and add explicit cue
          await tester.tap(find.text('+ 对位 Call'));
          await tester.pump();
          expect(find.text('添加词对位 Call'), findsOneWidget);
          await tester.enterText(find.byType(prism.TextField).last, 'Hey!');
          await tester.pump();
          await tester.tap(find.text('确认对位'));
          await tester.pump();

          final updatedLine = controller.sortedLines.first;
          expect(updatedLine.alignedCalls.length, 1);
          expect(updatedLine.alignedCalls.first.text, 'Hey!');

          // ExportView renders cleanly with aligned Call pill & ZERO overflows
          final capturedErrors = <FlutterErrorDetails>[];
          final prevOnError = FlutterError.onError;
          FlutterError.onError = (d) => capturedErrors.add(d);
          try {
            await _pumpWithViewport(
              tester,
              _wrapWithPrism(
                controller: controller,
                child: ExportView(controller: controller),
              ),
              viewport: const Size(1280, 900),
            );
            expect(capturedErrors, isEmpty);
            expect(tester.takeException(), isNull);
            expect(find.text('Hi-Call'), findsOneWidget);

            // PracticeOverlay renders cleanly with aligned Call pill
            await _pumpWithViewport(
              tester,
              _wrapWithPrism(
                controller: controller,
                child: Stack(
                  fit: StackFit.expand,
                  children: [PracticeOverlay(controller: controller)],
                ),
              ),
              viewport: const Size(1280, 820),
            );
            expect(capturedErrors, isEmpty);
            expect(tester.takeException(), isNull);
            expect(find.text('Hey!'), findsOneWidget);
          } finally {
            FlutterError.onError = prevOnError;
          }
        } finally {
          await _disposeTestTree(tester, controller);
        }
      },
    );

    testWidgets(
      'autoAdvanceOnTag toggle persists, syncs across toolbar/mobile, and advances only on add',
      (tester) async {
        final controller = await _initController();
        try {
          expect(controller.autoAdvanceOnTag, isFalse);

          await _pumpWithViewport(
            tester,
            LiveCallStudioApp(controller: controller),
            viewport: const Size(1280, 820),
          );
          expect(find.text('自动跳下句'), findsOneWidget);

          // Toggle desktop switch ON
          await tester.tap(find.bySemanticsLabel('打标后自动跳转下一句'));
          await tester.pump();
          expect(controller.autoAdvanceOnTag, isTrue);

          final firstId = controller.sortedLines[0].id;
          final secondId = controller.sortedLines[1].id;
          final thirdId = controller.sortedLines[2].id;
          controller.selectLine(firstId);
          await tester.pump();

          // Ensure first line doesn't already have 'clap'
          if (controller.sortedLines[0].calls.any((c) => c.presetId == 'clap')) {
            controller.toggleLineCall(firstId, 'clap');
          }

          // Press keyboard shortcut '0' (clap) -> adds tag AND advances to second line
          await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
          await tester.pump();
          expect(controller.activeLineId, secondId);

          // Adding via quickTagActiveLine advances to third line; removing stays on third line
          if (controller.sortedLines[1].calls.any((c) => c.presetId == 'clap')) {
            controller.toggleLineCall(secondId, 'clap');
          }
          expect(controller.quickTagActiveLine('clap'), isTrue);
          expect(controller.activeLineId, thirdId);
          // Calling again on thirdId (if tagged) removes without advancing beyond or stays put
          if (!controller.sortedLines[2].calls.any((c) => c.presetId == 'clap')) {
            controller.toggleLineCall(thirdId, 'clap');
          }
          expect(controller.quickTagActiveLine('clap'), isFalse);
          expect(controller.activeLineId, thirdId);

          // Wait for async prefs persist and confirm SharedPreferences stored autoAdvanceOnTag: true
          await tester.pump(const Duration(milliseconds: 50));
          final prefs = await SharedPreferences.getInstance();
          final rawTheme = prefs.getString('live_call_studio_theme_v1');
          expect(rawTheme, isNotNull);
          final decodedTheme = jsonDecode(rawTheme!) as Map<String, dynamic>;
          expect(decodedTheme['autoAdvanceOnTag'], isTrue);

          // Resize to mobile (390x844) and confirm mobile quick-tray chip syncs & toggles controller.autoAdvanceOnTag
          await _pumpWithViewport(
            tester,
            LiveCallStudioApp(controller: controller),
            viewport: const Size(390, 844),
          );
          expect(find.text('打完跳下句'), findsOneWidget);
          await tester.tap(find.text('打完跳下句'));
          await tester.pump();
          expect(controller.autoAdvanceOnTag, isFalse);
        } finally {
          await _disposeTestTree(
            tester,
            controller,
            controllerOwnedByWidget: true,
          );
        }
      },
    );
  });

  group('9. Bug-Fix Regressions (Text Input, Spacebar, Archive Switch, Snap Guard, Undo & BPM)', () {
    testWidgets(
      'Bug #1, #3 & #7: TextField & BPM input block Space/digit shortcuts, blur commits BPM, and Space works reliably across Switch focus & modals',
      (tester) async {
        final controller = await _initController();
        try {
          await _pumpWithViewport(
            tester,
            LiveCallStudioApp(controller: controller),
            viewport: const Size(1280, 820),
          );
          expect(tester.takeException(), isNull);

          final firstLine = controller.sortedLines.first;
          controller.selectLine(firstLine.id);
          final hadFrontBefore = firstLine.calls.any(
            (c) => c.presetId == 'front-wave',
          );

          // 1. Focus composer TextField inside DashboardView and press Space / '1' / 'G' -> no playback toggle or Call tagging
          final composerField = find.byWidgetPredicate(
            (w) =>
                w is prism.TextField &&
                w.decoration?.hintText == '如：litterzy',
          ).first;
          expect(composerField, findsOneWidget);
          await _scrollToAndTap(tester, composerField);
          await tester.pump();

          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
          await tester.pump();

          expect(controller.isPlaying, isFalse);
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == firstLine.id)
                .calls
                .any((c) => c.presetId == 'front-wave'),
            hadFrontBefore,
          );

          // 2. Focus BPM TextField, type digits '180' (including '1' shortcut key) -> BPM updates, Call tags untouched
          final bpmField = find.byWidgetPredicate(
            (w) =>
                w is prism.TextField &&
                w.decoration?.hintText == '120',
          );
          expect(bpmField, findsOneWidget);
          await _scrollToAndTap(tester, bpmField);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
          await tester.pump();
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == firstLine.id)
                .calls
                .any((c) => c.presetId == 'front-wave'),
            hadFrontBefore,
          );

          await tester.enterText(bpmField, '182');
          await tester.pump();
          expect(controller.project.meta.bpm, 182);

          // Type out-of-range temporary '18', then unfocus -> blur listener commits clamped 30
          await tester.enterText(bpmField, '18');
          await tester.pump();
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump();
          expect(controller.project.meta.bpm, 30);

          await tester.enterText(bpmField, '190');
          await tester.pump();
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump();
          expect(controller.project.meta.bpm, 190);

          // 3. Bug #3: Focus on Switch ("开启节拍器"), then press Space -> STILL toggles playback reliably!
          final metroSwitch = find.bySemanticsLabel('开启节拍器');
          await _scrollToAndTap(tester, metroSwitch);
          await tester.pump();
          expect(controller.metronomeEnabled, isFalse);

          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pump();
          expect(controller.isPlaying, isTrue);

          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pump();
          expect(controller.isPlaying, isFalse);

          // Re-restore metronome & test modal dialog suppresses HomeShell Space shortcut
          await tester.tap(metroSwitch);
          await tester.pump();
          await _scrollToAndTap(tester, find.text('+ 自定义标签'));
          await tester.pump();
          expect(find.text('添加自定义 Call 标签'), findsOneWidget);

          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pump();
          expect(controller.isPlaying, isFalse);
          await tester.tap(find.text('取消'));
          await tester.pump();
        } finally {
          await _disposeTestTree(
            tester,
            controller,
            controllerOwnedByWidget: true,
          );
        }
      },
    );

    testWidgets(
      'Bug #4, #5 & #6: Single-tap archive switch, re-import line highlight, idle-0ms snap guard, and Ctrl+Z / button Undo',
      (tester) async {
        final mockClient = MockClient((req) async {
          if (req.url.path == '/health') {
            return http.Response('{"status":"ok","providers":["netease"]}', 200);
          }
          if (req.url.path == '/api/track/netease/777') {
            return http.Response(
              jsonEncode({
                'track': {
                  'id': '777',
                  'title': 'Reimported Track',
                  'artist': 'Singer',
                  'platform': 'netease',
                  'durationMs': 90000,
                },
                'audioUrl': '',
                'rawLrc': '[00:02.00] First\r[00:06.00] Second\r[00:12.00] Third',
                'translatedLrc': '',
                'lines': [],
              }),
              200,
            );
          }
          return http.Response('offline', 404);
        });
        final controller = await _initController(httpClient: mockClient);
        try {
          // Save two distinct archives
          controller.updateMeta(title: 'Archive Alpha');
          final alpha = controller.saveCurrentToArchive(customName: 'Archive Alpha');
          controller.updateMeta(title: 'Archive Beta');
          final beta = controller.saveCurrentToArchive(
            asNew: true,
            customName: 'Archive Beta',
          );
          expect(controller.activeArchiveId, beta.id);
          expect(controller.needsSavePromptBeforeSwitch, isFalse);

          await _pumpWithViewport(
            tester,
            LiveCallStudioApp(controller: controller),
            viewport: const Size(1280, 820),
          );

          // Single tap in standalone ArchiveView switches to Archive Alpha on first click!
          final sidebar = find.byType(prism.NavigationSidebar);
          await tester.tap(find.descendant(of: sidebar, matching: find.text('存档')));
          await tester.pump();
          expect(find.byType(ArchiveView), findsOneWidget);
          await _scrollToAndTap(tester, find.text('Archive Alpha').last);
          await tester.pump();
          expect(controller.activeArchiveId, alpha.id);
          expect(controller.project.meta.title, 'Archive Alpha');

          // Return to DashboardView for timeline snap & undo assertions
          await tester.tap(find.descendant(of: sidebar, matching: find.text('主页')));
          await tester.pump();

          // Bug #5: Idle at 00:00.00 -> clicking 校时 on a later line refuses to corrupt timeline!
          final lines = controller.sortedLines
              .where((l) => l.kind == LyricLineKind.lyric)
              .toList();
          final laterLine = lines[2];
          final originalStart = laterLine.startTimeMs;
          expect(controller.currentTimeMs, 0);
          controller.snapLineToCurrentTime(laterLine.id);
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == laterLine.id)
                .startTimeMs,
            originalStart,
          );
          expect(controller.statusMessage, contains('00:00.00'));

          // Seek to 15000ms -> 校时 succeeds and records undo
          await controller.seek(15000);
          controller.snapLineToCurrentTime(laterLine.id);
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == laterLine.id)
                .startTimeMs,
            15000,
          );
          expect(controller.canUndo, isTrue);

          // Bug #6: Undo via Ctrl+Z restores original startTimeMs
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          expect(
            controller.sortedLines
                .firstWhere((l) => l.id == laterLine.id)
                .startTimeMs,
            originalStart,
          );
          expect(controller.canUndo, isFalse);

          // Bug #6: Merge with next line -> Undo button restores exact original lines
          final countBeforeMerge = controller.project.lines.length;
          expect(controller.mergeWithNextLine(lines[0].id), isTrue);
          await tester.pump();
          expect(controller.project.lines.length, countBeforeMerge - 1);
          expect(find.text('撤销'), findsOneWidget);

          await _scrollToAndTap(tester, find.text('撤销'));
          await tester.pump();
          expect(controller.project.lines.length, countBeforeMerge);
          expect(controller.canUndo, isFalse);

          // Bug #4 re-import follow/highlight check: re-import remote track resets clock & updates playingLineId
          await controller.seek(18000);
          await controller.loadRemoteTrack(
            const TrackSummary(
              id: '777',
              title: 'Reimported Track',
              artist: 'Singer',
              platform: 'netease',
              provider: 'netease',
              durationMs: 90000,
            ),
          );
          await tester.pump();
          expect(controller.currentTimeMs, 0);
          expect(controller.sortedLines.any((l) => l.text.original == 'Second'), isTrue);

          await controller.seek(7000);
          await tester.pump();
          final playing = controller.sortedLines.firstWhere(
            (l) => l.id == controller.playingLineId,
          );
          expect(playing.text.original, 'Second');
        } finally {
          await _disposeTestTree(
            tester,
            controller,
            controllerOwnedByWidget: true,
          );
        }
      },
    );
  });
}
