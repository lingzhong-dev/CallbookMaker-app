import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/ui/archive_view.dart';
import 'package:live_call_studio/ui/dashboard_view.dart';
import 'package:live_call_studio/ui/theme_view.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import 'support/mock_audioplayers_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MockAudioplayersHarness().install();
  });

  group('Stage 5: Copy, Theme Grouping, Archive Status/Time & Platform', () {
    test('ArchiveView.formatSavedTime formats same-year and cross-year dates', () {
      final now = DateTime(2026, 11, 21, 14, 30);
      final sameYearMs = DateTime(2026, 3, 5, 9, 4).millisecondsSinceEpoch;
      final crossYearMs = DateTime(2025, 12, 31, 23, 59).millisecondsSinceEpoch;

      expect(
        ArchiveView.formatSavedTime(sameYearMs, now: now),
        '03-05 09:04',
      );
      expect(
        ArchiveView.formatSavedTime(crossYearMs, now: now),
        '2025-12-31 23:59',
      );
    });

    test('ArchiveView.statusBadgeColors distinguishes all 4 archive states', () {
      final scheme = prism.ColorScheme.fromSeed(
        seedColor: const Color(0xFF0068FF),
      );

      final synced = ArchiveView.statusBadgeColors(
        scheme,
        isSynced: true,
        hasActiveArchive: true,
        needsSavePromptBeforeSwitch: false,
      );
      final unsaved = ArchiveView.statusBadgeColors(
        scheme,
        isSynced: false,
        hasActiveArchive: true,
        needsSavePromptBeforeSwitch: true,
      );
      final pending = ArchiveView.statusBadgeColors(
        scheme,
        isSynced: false,
        hasActiveArchive: false,
        needsSavePromptBeforeSwitch: true,
      );
      final example = ArchiveView.statusBadgeColors(
        scheme,
        isSynced: false,
        hasActiveArchive: false,
        needsSavePromptBeforeSwitch: false,
      );

      expect(synced.background, scheme.successContainer);
      expect(unsaved.background, scheme.warningContainer);
      expect(example.background, scheme.surfaceContainerHigh);

      final distinctBackgrounds = {
        synced.background.toARGB32(),
        unsaved.background.toARGB32(),
        pending.background.toARGB32(),
        example.background.toARGB32(),
      };
      expect(distinctBackgrounds, hasLength(4));
    });

    testWidgets(
      'PrismApp keeps only Chinese supportedLocales and ThemeView renders 3 cards (颜色 / 外观 / 文字)',
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

        final prismApp = tester.widget<prism.PrismApp>(
          find.byType(prism.PrismApp),
        );
        expect(
          prismApp.supportedLocales.map((l) => l.languageCode).toSet(),
          equals({'zh'}),
        );
        expect(
          prismApp.supportedLocales.any((l) => l.languageCode == 'en'),
          isFalse,
        );

        controller.setRoute(StudioRoute.more);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        await tester.tap(find.text('主题'));
        await tester.pumpAndSettle();

        expect(find.byType(ThemeView), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(ThemeView),
            matching: find.byType(prism.Card),
          ),
          findsNWidgets(3),
        );
        expect(
          find.descendant(
            of: find.byType(ThemeView),
            matching: find.text('颜色'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(ThemeView),
            matching: find.text('外观'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(ThemeView),
            matching: find.text('文字'),
          ),
          findsOneWidget,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    test(
      'Stage 5 UI copy passes through siteText and platform branches are isolated in lib/platform',
      () {
        final homeShellSrc = File('lib/ui/home_shell.dart').readAsStringSync();
        for (final copy in [
          "c.siteText('收起速标')",
          "c.siteText('速标栏')",
          "c.siteText('+ GT 警报')",
          "c.siteText('取消 GT')",
          "c.siteText('暂无歌词行')",
          "c.siteText('为你的偶像写下Callbook吧！')",
        ]) {
          expect(homeShellSrc, contains(copy));
        }

        final practiceSrc = File(
          'lib/ui/practice_overlay.dart',
        ).readAsStringSync();
        expect(practiceSrc, contains("c.siteText('当前曲目暂无歌词行')"));
        expect(practiceSrc, contains("c.siteText('LIVE PRACTICE MODE')"));

        final scrollTopSrc = File(
          'lib/ui/widgets/scroll_to_top_button.dart',
        ).readAsStringSync();
        expect(scrollTopSrc, contains("c?.siteText('回到当前行')"));
        expect(scrollTopSrc, contains("c?.siteText('回到顶部')"));

        final readme = File('README.md').readAsStringSync();
        expect(readme, contains('Android'));
        expect(readme, contains('Windows'));

        final libDir = Directory('lib');
        final dartFiles = libDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList();
        for (final file in dartFiles) {
          final normalized = file.path.replaceAll('\\', '/');
          if (normalized.endsWith('lib/platform/app_platform.dart')) continue;
          final text = file.readAsStringSync();
          expect(
            RegExp(r'\b(kIsWeb|Platform\.is\w+)\b').hasMatch(text),
            isFalse,
            reason: '$normalized should delegate platform checks to lib/platform/app_platform.dart',
          );
        }
      },
    );

    testWidgets(
      'DashboardView preserves 4:8 / single-column layout and 7-card order across 1280x820, 900x800 and 420x800',
      timeout: const Timeout(Duration(seconds: 25)),
      (tester) async {
        final controller = await createTestCallbookController(
          enableAudioOutput: false,
        );

        Future<void> checkViewport(Size size, {required bool expectTwoCols}) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpWidget(LiveCallStudioApp(controller: controller));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));

          expect(find.byType(DashboardView), findsOneWidget);
          expect(tester.takeException(), isNull);

          final rowFinder = find.descendant(
            of: find.byType(DashboardView),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Row &&
                  w.children.length == 3 &&
                  w.children[0] is Expanded &&
                  (w.children[0] as Expanded).flex == 4 &&
                  w.children[2] is Expanded &&
                  (w.children[2] as Expanded).flex == 8,
            ),
          );
          expect(rowFinder, expectTwoCols ? findsOneWidget : findsNothing);
        }

        await checkViewport(const Size(1280, 820), expectTwoCols: true);
        await checkViewport(const Size(900, 800), expectTwoCols: false);
        await checkViewport(const Size(420, 800), expectTwoCols: false);

        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });
}
