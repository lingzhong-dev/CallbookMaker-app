import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'state/callbook_controller.dart';
import 'ui/home_shell.dart';
import 'ui/theme/app_motion.dart';

final RegExp _emojiPattern = RegExp(
  // ignore: valid_regexps
  r'\p{RI}\p{RI}'
  r'|[#*0-9]\uFE0F?\u20E3'
  r'|\p{Emoji}(?<![#*0-9])'
  r'(?:\p{EMod}|\uFE0F\u20E3?|[\u{E0020}-\u{E007E}]+\u{E007F})?'
  r'(?:\u200D\p{Emoji}(?:\p{EMod}|\uFE0F\u20E3?|[\u{E0020}-\u{E007E}]+\u{E007F})?)*',
  unicode: true,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1280, 820),
      minimumSize: Size(420, 620),
      center: true,
      title: 'CallbookMaker',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  final controller = CallbookController();
  await controller.init();
  runApp(LiveCallStudioApp(controller: controller));
}

class LiveCallStudioApp extends StatefulWidget {
  const LiveCallStudioApp({super.key, required this.controller});

  final CallbookController controller;

  @override
  State<LiveCallStudioApp> createState() => _LiveCallStudioAppState();
}

class _LiveCallStudioAppState extends State<LiveCallStudioApp> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  Widget _buildApp(BuildContext mqContext) {
    final c = widget.controller;
    final mq = MediaQuery.of(mqContext);
    final effectiveDisableAnimations = c.reduceMotion || mq.disableAnimations;
    final effectiveLiquidGlass = AppMotion.resolveLiquidGlassQuality(
      userEnabled: c.liquidGlass,
      reduceMotion: effectiveDisableAnimations,
      platform: defaultTargetPlatform,
      devicePixelRatio: mq.devicePixelRatio,
      logicalSize: mq.size,
    );

    return MediaQuery(
      data: mq.copyWith(disableAnimations: effectiveDisableAnimations),
      child: PrismApp(
        title: 'CallbookMaker',
        debugShowCheckedModeBanner: false,
        localizationsDelegates: const [
          _CallbookUiLocalizationsDelegate(),
          DefaultWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('zh', 'CN'),
          Locale('zh'),
          Locale('en', 'US'),
          Locale('en'),
        ],
        theme: c.buildPrismTheme(Brightness.light),
        darkTheme: c.buildPrismTheme(Brightness.dark),
        themeMode: c.themeMode,
        liquidGlass: effectiveLiquidGlass,
        emojiFont: (family: 'Twemoji', pattern: _emojiPattern),
        home: Builder(
          builder: (innerContext) {
            final innerMq = MediaQuery.of(innerContext);
            final systemScale = innerMq.textScaler.scale(1.0);
            return MediaQuery(
              data: innerMq.copyWith(
                textScaler: TextScaler.linear(systemScale * c.textScale),
              ),
              child: DefaultTextStyle(
                style: AppTextStyle.body.of(innerContext),
                child: HomeShell(controller: c),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final hasAncestorMediaQuery = MediaQuery.maybeOf(context) != null;
    final view = View.maybeOf(context);
    return ListenableBuilder(
      listenable: c.themeListenable,
      builder: (context, _) {
        if (hasAncestorMediaQuery || view == null) {
          return Builder(builder: _buildApp);
        }
        return MediaQuery.fromView(
          view: view,
          child: Builder(builder: _buildApp),
        );
      },
    );
  }
}

class _CallbookUiLocalizationsDelegate
    extends LocalizationsDelegate<UiLocalizations> {
  const _CallbookUiLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<UiLocalizations> load(Locale locale) =>
      SynchronousFuture<_CallbookUiLocalizations>(
        const _CallbookUiLocalizations(),
      );

  @override
  bool shouldReload(covariant LocalizationsDelegate<UiLocalizations> old) =>
      false;
}

class _CallbookUiLocalizations implements UiLocalizations {
  const _CallbookUiLocalizations();

  @override
  String get back => '返回';
  @override
  String get cancel => '取消';
  @override
  String get clearSearch => '清除搜索';
  @override
  String get close => '关闭';
  @override
  String get copy => '复制';
  @override
  String get cut => '剪切';
  @override
  String get dialog => '对话框';
  @override
  String get hidePassword => '隐藏密码';
  @override
  String get more => '更多';
  @override
  String get noSearchResults => '无搜索结果';
  @override
  String get paste => '粘贴';
  @override
  String get reset => '重置';
  @override
  String get select => '选择';
  @override
  String get search => '搜索';
  @override
  String get selectAll => '全选';
  @override
  String get showLess => '收起';
  @override
  String get showMore => '展开';
  @override
  String get showPassword => '显示密码';
  @override
  String get sort => '排序';
  @override
  String get submit => '提交';
}
