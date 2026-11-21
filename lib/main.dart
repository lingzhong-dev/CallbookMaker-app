import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'platform/app_platform.dart';
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

  final controller = CallbookController();

  if (AppPlatform.isWindows) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1280, 820),
      minimumSize: Size(420, 620),
      center: true,
      title: 'CallbookMaker',
      backgroundColor: Color(0xFFF3F4F6),
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(
    LiveCallStudioApp(
      controller: controller,
      showStartupSplash: true,
    ),
  );
}

class LiveCallStudioApp extends StatefulWidget {
  const LiveCallStudioApp({
    super.key,
    required this.controller,
    this.showStartupSplash = false,
  });

  final CallbookController controller;
  final bool showStartupSplash;

  @override
  State<LiveCallStudioApp> createState() => _LiveCallStudioAppState();
}

class _LiveCallStudioAppState extends State<LiveCallStudioApp> {
  late bool _splashVisible = widget.showStartupSplash;
  late bool _splashFadingOut = false;
  late bool _minSplashElapsed = !widget.showStartupSplash;
  Timer? _minSplashTimer;
  Timer? _fadeOutTimer;

  @override
  void initState() {
    super.initState();
    if (widget.showStartupSplash) {
      widget.controller.initListenable.addListener(_handleInitProgress);
      if (!widget.controller.isLocalInitDone) {
        unawaited(widget.controller.init(awaitBackgroundSync: false));
      }
      _minSplashTimer = Timer(const Duration(milliseconds: 420), () {
        _minSplashElapsed = true;
        _tryDismissSplash();
      });
    }
  }

  void _handleInitProgress() {
    if (!mounted) return;
    setState(() {});
    _tryDismissSplash();
  }

  void _tryDismissSplash() {
    if (!mounted ||
        !_splashVisible ||
        _splashFadingOut ||
        !_minSplashElapsed ||
        !widget.controller.isLocalInitDone) {
      return;
    }
    if (widget.controller.reduceMotion) {
      setState(() {
        _splashVisible = false;
      });
      return;
    }
    setState(() {
      _splashFadingOut = true;
    });
    _fadeOutTimer?.cancel();
    _fadeOutTimer = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      setState(() {
        _splashVisible = false;
      });
    });
  }

  @override
  void dispose() {
    _minSplashTimer?.cancel();
    _fadeOutTimer?.cancel();
    if (widget.showStartupSplash) {
      widget.controller.initListenable.removeListener(_handleInitProgress);
    }
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
            final shellReady = !widget.showStartupSplash || c.isLocalInitDone;
            return MediaQuery(
              data: innerMq.copyWith(
                textScaler: TextScaler.linear(systemScale * c.textScale),
              ),
              child: DefaultTextStyle(
                style: AppTextStyle.body.of(innerContext),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (shellReady) HomeShell(controller: c),
                    if (_splashVisible)
                      AnimatedOpacity(
                        opacity: _splashFadingOut ? 0.0 : 1.0,
                        duration: AppMotion.d(
                          innerContext,
                          const Duration(milliseconds: 260),
                        ),
                        curve: Curves.easeOutCubic,
                        child: _StartupSplashOverlay(
                          reduceMotion: effectiveDisableAnimations,
                        ),
                      ),
                  ],
                ),
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

class _StartupSplashOverlay extends StatefulWidget {
  const _StartupSplashOverlay({required this.reduceMotion});

  final bool reduceMotion;

  @override
  State<_StartupSplashOverlay> createState() => _StartupSplashOverlayState();
}

class _StartupSplashOverlayState extends State<_StartupSplashOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.reduceMotion) {
      _pulseCtrl.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _StartupSplashOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduceMotion && _pulseCtrl.isAnimating) {
      _pulseCtrl.stop();
    } else if (!widget.reduceMotion && !_pulseCtrl.isAnimating) {
      _pulseCtrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final bg = SurfaceLevel.page.colorOf(scheme);
    return ColoredBox(
      color: bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (context, child) {
                final t = widget.reduceMotion
                    ? 0.4
                    : Curves.easeInOut.transform(_pulseCtrl.value);
                final scale = 1.0 + t * 0.08;
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    Transform.scale(
                      scale: scale + 0.12,
                      child: Container(
                        width: 108,
                        height: 108,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.primary.withValues(alpha: 0.10 + 0.08 * t),
                        ),
                      ),
                    ),
                    Container(
                      width: 86,
                      height: 86,
                      padding: const EdgeInsets.all(10),
                      decoration: ShapeDecoration(
                        color: SurfaceLevel.card.colorOf(scheme),
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(24),
                          side: BorderSide(
                            color: scheme.outlineVariant.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.asset(
                          'assets/images/icon.png',
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            Text(
              'CallbookMaker',
              style: AppTextStyle.title3
                  .of(context, emphasized: true)
                  .copyWith(color: scheme.onSurface),
            ),
            const SizedBox(height: 6),
            Text(
              '正在准备演练工作台…',
              style: AppTextStyle.caption1.of(context).copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 120,
              height: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (context, _) {
                    final t = widget.reduceMotion ? 0.5 : _pulseCtrl.value;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(color: scheme.surfaceContainerHighest),
                        FractionallySizedBox(
                          alignment: Alignment(t * 2.0 - 1.0, 0),
                          widthFactor: 0.45,
                          child: DecoratedBox(
                            decoration: ShapeDecoration(
                              color: scheme.primary,
                              shape: AppShape.full,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
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
