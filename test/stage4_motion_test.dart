import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/ui/archive_view.dart';
import 'package:live_call_studio/ui/dashboard_view.dart';
import 'package:live_call_studio/ui/home_shell.dart';
import 'package:live_call_studio/ui/onboarding_overlay.dart';
import 'package:live_call_studio/ui/practice_overlay.dart';
import 'package:live_call_studio/ui/theme/app_motion.dart';
import 'package:live_call_studio/ui/theme_view.dart';
import 'package:live_call_studio/ui/widgets/beat_dots_indicator.dart';
import 'package:live_call_studio/ui/widgets/continuous_auto_scroller.dart';
import 'package:live_call_studio/ui/widgets/line_sparkline.dart';
import 'package:live_call_studio/ui/widgets/scalloped_orb_button.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mock_audioplayers_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MockAudioplayersHarness().install();
  });

  group('Stage 4: Liquid Glass degradation & reduceMotion', () {
    test('resolveLiquidGlassQuality defaults to standard and honors rules', () {
      expect(
        AppMotion.resolveLiquidGlassQuality(
          userEnabled: true,
          reduceMotion: false,
          platform: TargetPlatform.windows,
          devicePixelRatio: 1.5,
          logicalSize: const Size(1280, 820),
        ),
        prism.LiquidGlassQuality.standard,
      );

      expect(
        AppMotion.resolveLiquidGlassQuality(
          userEnabled: true,
          reduceMotion: true,
          platform: TargetPlatform.windows,
          devicePixelRatio: 1.5,
          logicalSize: const Size(1280, 820),
        ),
        isNull,
      );

      expect(
        AppMotion.resolveLiquidGlassQuality(
          userEnabled: true,
          reduceMotion: false,
          platform: TargetPlatform.android,
          devicePixelRatio: 1.0,
          logicalSize: const Size(320, 640),
        ),
        isNull,
      );

      expect(
        AppMotion.resolveLiquidGlassQuality(
          userEnabled: true,
          reduceMotion: false,
          platform: TargetPlatform.android,
          devicePixelRatio: 3.5,
          logicalSize: const Size(480, 1100),
        ),
        isNull,
      );

      // Custom policy override works for device tuning
      expect(
        AppMotion.resolveLiquidGlassQuality(
          userEnabled: true,
          reduceMotion: false,
          platform: TargetPlatform.android,
          devicePixelRatio: 1.0,
          logicalSize: const Size(320, 640),
          policyOverride: ({
            required userEnabled,
            required reduceMotion,
            required platform,
            required devicePixelRatio,
            required logicalSize,
          }) => prism.LiquidGlassQuality.ultra,
        ),
        prism.LiquidGlassQuality.ultra,
      );
    });

    testWidgets(
      'reduceMotion overrides MediaQuery.disableAnimations outside PrismApp and disables LiquidGlass',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        expect(controller.reduceMotion, isFalse);

        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();

        final shellCtx = tester.element(find.byType(HomeShell));
        expect(MediaQuery.disableAnimationsOf(shellCtx), isFalse);
        expect(prism.LiquidGlassScope.of(shellCtx), isTrue);
        expect(
          prism.LiquidGlassScope.qualityOf(shellCtx),
          prism.LiquidGlassQuality.standard,
        );

        controller.setReduceMotion(true);
        await tester.pump();

        final shellCtxAfter = tester.element(find.byType(HomeShell));
        expect(MediaQuery.disableAnimationsOf(shellCtxAfter), isTrue);
        expect(prism.LiquidGlassScope.of(shellCtxAfter), isFalse);

        // Verify persistence across SharedPreferences
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          final prefs = await SharedPreferences.getInstance();
          final storedThemeJson = prefs
              .getKeys()
              .map((k) => prefs.get(k)?.toString() ?? '')
              .join('\n');
          expect(storedThemeJson, contains('"reduceMotion":true'));
        });

        controller.resetTheme();
        await tester.pump();
        expect(controller.reduceMotion, isFalse);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });

  group('Stage 4: Widgets, Overlays & Motion', () {
    testWidgets(
      'BeatDotsIndicator uses RepaintBoundary and disables scale pulsation under reduceMotion',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        try {
          await tester.pumpWidget(
            prism.PrismApp(
              theme: controller.buildPrismTheme(Brightness.light),
              home: BeatDotsIndicator(
                controller: controller,
                downbeatColor: const Color(0xFFFF0000),
                beatColor: const Color(0xFF0068FF),
                inactiveColor: const Color(0xFFCCCCCC),
                showBarBeatLabel: true,
              ),
            ),
          );
          await tester.pump();

          expect(
            find.descendant(
              of: find.byType(BeatDotsIndicator),
              matching: find.byType(RepaintBoundary),
            ),
            findsOneWidget,
          );
          expect(find.byType(AnimatedContainer), findsNothing);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
        }
      },
    );

    testWidgets(
      'ScallopedOrbButton uses dropletSpring simulation and AnimatedSwitcher icon transition',
      (tester) async {
        var running = false;
        await tester.pumpWidget(
          prism.PrismApp(
            theme: prism.ThemeData(
              colorScheme: prism.ColorScheme.fromSeed(
                seedColor: const Color(0xFF0068FF),
              ),
            ),
            home: StatefulBuilder(
              builder: (context, setState) => Center(
                child: ScallopedOrbButton(
                  running: running,
                  onToggle: () => setState(() => running = !running),
                ),
              ),
            ),
          ),
        );

        expect(
          find.descendant(
            of: find.byType(ScallopedOrbButton),
            matching: find.byType(AnimatedSwitcher),
          ),
          findsOneWidget,
        );
        expect(find.byType(prism.ElasticPress), findsOneWidget);

        await tester.tap(find.byType(ScallopedOrbButton));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(running, isTrue);
      },
    );

    testWidgets(
      'SparklineMetricFooter interpolates smoothly on data updates via TweenAnimationBuilder',
      (tester) async {
        var values = <double>[0.2, 0.3, 0.4, 0.5];
        var rev = 1;
        await tester.pumpWidget(
          prism.PrismApp(
            theme: prism.ThemeData(
              colorScheme: prism.ColorScheme.fromSeed(
                seedColor: const Color(0xFF0068FF),
              ),
            ),
            home: StatefulBuilder(
              builder: (context, setState) => Center(
                child: SparklineMetricFooter(values: values, revision: rev),
              ),
            ),
          ),
        );

        expect(
          find.descendant(
            of: find.byType(SparklineMetricFooter),
            matching: find.byType(TweenAnimationBuilder<double>),
          ),
          findsOneWidget,
        );

        values = <double>[0.8, 0.9, 0.6, 1.0];
        rev = 2;
        await tester.pumpWidget(
          prism.PrismApp(
            theme: prism.ThemeData(
              colorScheme: prism.ColorScheme.fromSeed(
                seedColor: const Color(0xFF0068FF),
              ),
            ),
            home: Center(
              child: SparklineMetricFooter(values: values, revision: rev),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'PracticeOverlay applies 1.0/0.4/0.7 opacity, 1.04 scale (1.0 in reduceMotion) and AnimatedSize',
      timeout: const Timeout(Duration(seconds: 25)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();

        final lines = controller.sortedLines;
        expect(lines.length, greaterThanOrEqualTo(3));

        // Seek to second line so line 0 is past, line 1 is playing, line 2 is future
        await controller.seek(lines[1].startTimeMs + 50);
        controller.setPracticeMode(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(find.byType(PracticeOverlay), findsOneWidget);

        final opacities = tester
            .widgetList<AnimatedOpacity>(
              find.descendant(
                of: find.byType(PracticeOverlay),
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .map((w) => w.opacity)
            .toList();
        expect(opacities, contains(1.0));
        expect(opacities, contains(0.4));
        expect(opacities, contains(0.7));

        final scalesNormal = tester
            .widgetList<AnimatedScale>(
              find.descendant(
                of: find.byType(PracticeOverlay),
                matching: find.byType(AnimatedScale),
              ),
            )
            .map((w) => w.scale)
            .toList();
        expect(scalesNormal, contains(1.04));

        // Enable reduceMotion: playing line scale drops back to 1.0
        controller.setReduceMotion(true);
        await tester.pump();
        final scalesReduced = tester
            .widgetList<AnimatedScale>(
              find.descendant(
                of: find.byType(PracticeOverlay),
                matching: find.byType(AnimatedScale),
              ),
            )
            .map((w) => w.scale)
            .toList();
        expect(scalesReduced.every((s) => s == 1.0), isTrue);

        expect(
          find.descendant(
            of: find.byType(PracticeOverlay),
            matching: find.byType(AnimatedSize),
          ),
          findsWidgets,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    testWidgets(
      'ArchiveView uses KeyedAnimatedList, ContextMenuRegion and AnimatedSize; ThemeView toggles reduceMotion',
      timeout: const Timeout(Duration(seconds: 25)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        controller.saveCurrentToArchive(asNew: true, customName: 'Stage 4 Archive');

        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();

        // Tab switch uses PageTransitionSwitcher
        expect(find.byType(prism.PageTransitionSwitcher), findsOneWidget);

        controller.setRoute(StudioRoute.archive);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));

        expect(find.byType(ArchiveView), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(ArchiveView),
            matching: find.byType(prism.ContextMenuRegion),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(ArchiveView),
            matching: find.byType(AnimatedSize),
          ),
          findsOneWidget,
        );

        // Open ThemeView via MoreView and verify reduceMotion switch + SelectionBadge
        controller.setRoute(StudioRoute.more);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        await tester.tap(find.text('主题'));
        await tester.pumpAndSettle();

        expect(find.byType(ThemeView), findsOneWidget);
        expect(find.text('减少动效'), findsOneWidget);
        expect(find.byType(prism.SelectionBadge), findsWidgets);

        final reduceMotionSwitch = find.descendant(
          of: find
              .ancestor(
                of: find.text('减少动效'),
                matching: find.byType(Row),
              )
              .first,
          matching: find.byType(prism.Switch),
        );
        await tester.ensureVisible(reduceMotionSwitch);
        await tester.pumpAndSettle();
        await tester.tap(reduceMotionSwitch);
        await tester.pump();
        expect(controller.reduceMotion, isTrue);

        // Reopen OnboardingOverlay and verify PageTransitionSwitcher step change
        controller.reopenOnboarding();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(OnboardingOverlay), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(OnboardingOverlay),
            matching: find.byType(prism.PageTransitionSwitcher),
          ),
          findsOneWidget,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    testWidgets(
      'GT flash emits forward/reverse events and ContinuousAutoScroller pauses 3s on manual scroll',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );
        try {
          final firstLineId = controller.sortedLines.first.id;
          controller.toggleLineGtAlert(lineId: firstLineId);
          expect(controller.gtFlashListenable.value?.lineId, firstLineId);
          expect(controller.gtFlashListenable.value?.reverse, isFalse);

          controller.toggleLineGtAlert(lineId: firstLineId);
          expect(controller.gtFlashListenable.value?.lineId, firstLineId);
          expect(controller.gtFlashListenable.value?.reverse, isTrue);

          // Verify ContinuousAutoScroller manual-scroll 3s pause & scroll-to-top lock
          var resumeCount = 0;
          final scroller = ContinuousAutoScroller(
            vsync: const TestVSync(),
            onResumeAutoFollow: () => resumeCount++,
          );
          addTearDown(scroller.dispose);

          final metrics = FixedScrollMetrics(
            minScrollExtent: 0,
            maxScrollExtent: 2000,
            pixels: 200,
            viewportDimension: 600,
            axisDirection: AxisDirection.down,
            devicePixelRatio: 1.0,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          final ctx = tester.element(find.byType(SizedBox));

          scroller.handleScrollNotification(
            UserScrollNotification(
              metrics: metrics,
              context: ctx,
              direction: ScrollDirection.reverse,
            ),
            controller,
          );
          expect(scroller.isManualPauseActive, isTrue);

          scroller.handleScrollNotification(
            UserScrollNotification(
              metrics: metrics,
              context: ctx,
              direction: ScrollDirection.idle,
            ),
            controller,
          );

          await tester.pump(const Duration(seconds: 2));
          expect(scroller.isManualPauseActive, isTrue);
          expect(resumeCount, 0);

          await tester.pump(const Duration(seconds: 2));
          expect(scroller.isManualPauseActive, isFalse);
          expect(resumeCount, 1);

          // When paused by ScrollToTopButton during playback, 3s timer must NOT auto-resume
          await controller.togglePlay();
          controller.pauseFollowFromScrollToTop();
          expect(controller.followPausedByScrollTop, isTrue);

          scroller.handleScrollNotification(
            UserScrollNotification(
              metrics: metrics,
              context: ctx,
              direction: ScrollDirection.forward,
            ),
            controller,
          );
          scroller.handleScrollNotification(
            UserScrollNotification(
              metrics: metrics,
              context: ctx,
              direction: ScrollDirection.idle,
            ),
            controller,
          );
          await tester.pump(const Duration(seconds: 4));
          expect(resumeCount, 1);
          expect(controller.followPausedByScrollTop, isTrue);

          // Pause playback before dispose
          await controller.togglePlay();
        } finally {
          controller.dispose();
        }
      },
    );

    test(
      'Scrollable.ensureVisible is removed from dashboard, timeline and practice overlay; press_surface guards disableAnimations',
      () {
        for (final path in [
          'lib/ui/dashboard_view.dart',
          'lib/ui/practice_overlay.dart',
          'lib/ui/widgets/timeline_editor_widget.dart',
        ]) {
          final content = File(path).readAsStringSync();
          expect(
            content.contains('Scrollable.ensureVisible'),
            isFalse,
            reason: '$path should use ContinuousAutoScroller instead of Scrollable.ensureVisible',
          );
        }
        final pressSurface = File(
          'packages/prism_ui/lib/press_surface.dart',
        ).readAsStringSync();
        expect(pressSurface, contains('!context.disableAnimations'));
        expect(find.byType(DashboardView), isNotNull);
      },
    );
  });
}
