import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/ui/widgets/call_badge_pill.dart';
import 'package:live_call_studio/ui/widgets/scroll_to_top_button.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import 'support/mock_audioplayers_harness.dart';

double _wcagContrast(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  final hi = l1 > l2 ? l1 : l2;
  final lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MockAudioplayersHarness().install();
  });

  test('CallBadgePill picks foreground with at least 4.5:1 contrast', () {
    const backgrounds = [
      Color(0xFFFFFFFF),
      Color(0xFF000000),
      Color(0xFFFDE047),
      Color(0xFF38BDF8),
      Color(0xFF1E293B),
      Color(0xFFEC4899),
      Color(0xFF10B981),
    ];
    for (final bg in backgrounds) {
      final fg = CallBadgePill.contrastForegroundFor(bg);
      expect(_wcagContrast(bg, fg), greaterThanOrEqualTo(4.5));
    }
  });

  testWidgets(
    'ScrollToTopButton hysteresis, distance jump, and playback follow cooperation',
    timeout: const Timeout(Duration(seconds: 25)),
    (tester) async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      final sc = ScrollController();

      try {
        await tester.pumpWidget(
          prism.PrismApp(
            theme: controller.buildPrismTheme(Brightness.light),
            darkTheme: controller.buildPrismTheme(Brightness.dark),
            themeMode: controller.themeMode,
            home: Stack(
              children: [
                ListView.builder(
                  controller: sc,
                  itemCount: 80,
                  itemBuilder: (_, idx) => SizedBox(
                    height: 100,
                    child: Text('Row $idx'),
                  ),
                ),
                ScrollToTopButton(
                  scrollController: sc,
                  controller: controller,
                  isCurrentLineVisible: () => false,
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        // Viewport is 600px -> threshold 1.5x = 900px, hide <= 300px
        expect(find.bySemanticsLabel('回到顶部（Ctrl+Home）'), findsNothing);

        sc.jumpTo(950);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.bySemanticsLabel('回到顶部（Ctrl+Home）'), findsOneWidget);

        // Hysteresis: between 0.5x (300) and 1.5x (900) stays visible
        sc.jumpTo(450);
        await tester.pump();
        expect(find.bySemanticsLabel('回到顶部（Ctrl+Home）'), findsOneWidget);

        // Below 0.5x hides
        sc.jumpTo(200);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.bySemanticsLabel('回到顶部（Ctrl+Home）'), findsNothing);

        // Scroll far (> 3 viewports = 1800px) and start playing
        sc.jumpTo(2400);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.bySemanticsLabel('回到顶部（Ctrl+Home）'), findsOneWidget);

        await controller.togglePlay();
        await tester.pump();

        // Tap scroll-to-top while playing -> scrolls to 0, pauses auto-follow,
        // and switches to 回到当前行
        await tester.tap(find.bySemanticsLabel('回到顶部（Ctrl+Home）'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        expect(sc.offset, closeTo(0.0, 1.0));
        expect(controller.followPlayback, isFalse);
        expect(find.bySemanticsLabel('回到当前行'), findsOneWidget);

        // Tap 回到当前行 -> restores auto-follow and hides 回到当前行
        await tester.tap(find.bySemanticsLabel('回到当前行'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(controller.followPlayback, isTrue);
        expect(find.bySemanticsLabel('回到当前行'), findsNothing);
      } finally {
        if (controller.isPlaying) {
          await controller.togglePlay();
        }
        sc.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        controller.dispose();
      }
    },
  );

  testWidgets(
    'HomeShell breakpoints (<600 dock, 600-840 collapsed sidebar, >=840 expanded sidebar), ? shortcuts, and BannerHost notify',
    timeout: const Timeout(Duration(seconds: 25)),
    (tester) async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );

      Future<void> pumpAtWidth(double width) async {
        tester.view.physicalSize = Size(width, 840);
        tester.view.devicePixelRatio = 1.0;
        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
      }

      try {
        // <600 -> NavigationDock
        await pumpAtWidth(520);
        expect(find.byType(prism.NavigationDock), findsOneWidget);
        expect(find.byType(prism.NavigationSidebar), findsNothing);

        // 600-840 -> collapsed NavigationSidebar
        await pumpAtWidth(720);
        expect(find.byType(prism.NavigationDock), findsNothing);
        final collapsedSidebar = tester.widget<prism.NavigationSidebar>(
          find.byType(prism.NavigationSidebar),
        );
        expect(collapsedSidebar.expanded, isFalse);

        // >=840 -> expanded NavigationSidebar
        await pumpAtWidth(1024);
        final expandedSidebar = tester.widget<prism.NavigationSidebar>(
          find.byType(prism.NavigationSidebar),
        );
        expect(expandedSidebar.expanded, isTrue);

        // Global ? opens shortcuts panel with Ctrl+Home
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.slash,
          character: '?',
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(find.textContaining('Ctrl+Home 回到顶部'), findsOneWidget);

        // c.notify displays banner inside PrismApp BannerHost
        var tapped = false;
        controller.notify(
          'PNG 长图已导出（点击打开）',
          level: prism.BannerLevel.success,
          onAction: () => tapped = true,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.text('PNG 长图已导出（点击打开）'), findsOneWidget);
        await tester.tap(find.text('PNG 长图已导出（点击打开）'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tapped, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}
