import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/utils/file_export_helper.dart';
import 'package:live_call_studio/utils/shortcut_validator.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import 'support/mock_audioplayers_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PNG pixelRatio safety cap', () {
    test('keeps preferred ratio when within 4096x16384 budget', () {
      final ratio = computeSafePngPixelRatio(
        logicalWidth: 960,
        logicalHeight: 3200,
        preferredRatio: 2.5,
      );
      expect(ratio, closeTo(2.5, 0.0001));
    });

    test('reduces ratio when width exceeds 4096', () {
      final ratio = computeSafePngPixelRatio(
        logicalWidth: 2500,
        logicalHeight: 2000,
        preferredRatio: 2.5,
      );
      expect(ratio * 2500, lessThanOrEqualTo(4096.01));
      expect(ratio, lessThan(2.5));
    });

    test('reduces ratio when height exceeds 16384', () {
      final ratio = computeSafePngPixelRatio(
        logicalWidth: 1000,
        logicalHeight: 10000,
        preferredRatio: 2.5,
      );
      expect(ratio * 10000, lessThanOrEqualTo(16384.01));
      expect(ratio, lessThan(2.5));
    });
  });

  group('saveBytesToUserLocation', () {
    test('desktop appends extension and writes bytes to chosen path', () async {
      String? writtenPath;
      Uint8List? writtenBytes;
      final res = await saveBytesToUserLocation(
        bytes: Uint8List.fromList([1, 2, 3]),
        fileName: 'song_callbook.png',
        dialogTitle: '保存 PNG',
        allowedExtensions: const ['png'],
        isWebOverride: false,
        isMobileOverride: false,
        isDesktopOverride: true,
        isWidgetTestOverride: false,
        saveFilePicker: ({
          required dialogTitle,
          required fileName,
          required allowedExtensions,
          bytes,
          lockParentWindow = false,
        }) async {
          expect(lockParentWindow, isTrue);
          return r'C:\exports\my_sheet';
        },
        writeFile: (path, bytes) async {
          writtenPath = path;
          writtenBytes = bytes;
        },
      );

      expect(res.cancelled, isFalse);
      expect(res.usedFallback, isFalse);
      expect(res.savedPath, r'C:\exports\my_sheet.png');
      expect(writtenPath, r'C:\exports\my_sheet.png');
      expect(writtenBytes, [1, 2, 3]);
    });

    test('returns cancelled when user dismisses dialog', () async {
      final res = await saveBytesToUserLocation(
        bytes: Uint8List.fromList([9]),
        fileName: 'song_callbook.xlsx',
        dialogTitle: '保存 Excel',
        allowedExtensions: const ['xlsx'],
        isWebOverride: false,
        isMobileOverride: false,
        isDesktopOverride: true,
        isWidgetTestOverride: false,
        saveFilePicker: ({
          required dialogTitle,
          required fileName,
          required allowedExtensions,
          bytes,
          lockParentWindow = false,
        }) async => null,
      );

      expect(res.cancelled, isTrue);
      expect(res.savedPath, isNull);
    });

    test('falls back to temp directory and share when picker throws', () async {
      String? sharedPath;
      final res = await saveBytesToUserLocation(
        bytes: Uint8List.fromList([7, 8]),
        fileName: 'fallback.png',
        dialogTitle: '保存 PNG',
        allowedExtensions: const ['png'],
        shareText: 'Callbook',
        isWebOverride: false,
        isMobileOverride: true,
        isDesktopOverride: false,
        isWidgetTestOverride: false,
        saveFilePicker: ({
          required dialogTitle,
          required fileName,
          required allowedExtensions,
          bytes,
          lockParentWindow = false,
        }) async => throw StateError('picker unavailable'),
        getTempDirPath: () async => '/tmp/test_exports',
        writeFile: (path, bytes) async {},
        shareFile: (path, text) async {
          sharedPath = path;
        },
      );

      expect(res.cancelled, isFalse);
      expect(res.usedFallback, isTrue);
      expect(res.savedPath, contains('fallback.png'));
      expect(sharedPath, res.savedPath);
    });
  });

  group('validatePresetShortcut', () {
    test('rejects reserved global shortcuts', () {
      for (final key in const [
        'F',
        'f',
        'G',
        'g',
        ' ',
        'Space',
        'ArrowUp',
        '↑',
        'Z',
        'z',
        'Ctrl+Home',
      ]) {
        final res = validatePresetShortcut(key);
        expect(res.isValid, isFalse, reason: 'Expected $key to be rejected');
        expect(res.errorMessage, isNotEmpty);
      }
    });

    test('accepts unused single keys and empty string, optional duplicate check', () {
      final dup = validatePresetShortcut(
        '1',
        existingPresets: defaultCallPresets,
        checkDuplicates: true,
      );
      expect(dup.isValid, isFalse);

      final ok = validatePresetShortcut(
        'q',
        existingPresets: defaultCallPresets,
      );
      expect(ok.isValid, isTrue);
      expect(ok.normalized, 'Q');

      final empty = validatePresetShortcut('');
      expect(empty.isValid, isTrue);
      expect(empty.normalized, '');
    });
  });

  group('CallbookController syncPlaybackState & presetMap cache', () {
    test('syncPlaybackState force-notifies on play from 0 and handles pre-roll upcoming line', () async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      try {
        // Case 1: load Kizuna Music whose first line is an intro starting at 0ms.
        await controller.loadDefaultSong('default-kizuna-music');
        var syncCount = 0;
        controller.playbackSyncListenable.addListener(() => syncCount++);

        expect(controller.playingLineId, controller.sortedLines.first.id);
        final beforePlaySync = syncCount;
        await controller.togglePlay();
        expect(controller.isPlaying, isTrue);
        expect(syncCount, greaterThan(beforePlaySync));
        await controller.togglePlay();

        // Case 2: pre-roll before first line (first line starts at 5000ms).
        await controller.importLrcText(
          lrc: '''
[00:05.00] First lyric line
[00:10.00] Second lyric line
''',
        );
        expect(controller.currentTimeMs, 0);
        expect(controller.playingLineId, isNull);
        expect(controller.upcomingLineId, controller.sortedLines.first.id);
        expect(controller.followTargetLineId, controller.sortedLines.first.id);

        await controller.seek(5000);
        expect(controller.playingLineId, controller.sortedLines.first.id);
        expect(controller.upcomingLineId, isNull);

        // Entering practice mode forces sync notification.
        final beforePracticeSync = syncCount;
        controller.setPracticeMode(true);
        expect(syncCount, greaterThan(beforePracticeSync));
      } finally {
        controller.dispose();
      }
    });

    test('presetMap is cached and only rebuilt when presets change', () async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      try {
        final firstRef = controller.presetMap;
        expect(identical(firstRef, controller.presetMap), isTrue);

        // Conflicting shortcut is rejected without mutating presets.
        final rejected = controller.addCustomPreset(
          label: '冲突测试',
          colorHex: '#EC4899',
          shortcut: 'F',
        );
        expect(rejected, isFalse);
        expect(identical(firstRef, controller.presetMap), isTrue);

        final added = controller.addCustomPreset(
          label: '新标签',
          colorHex: '#EC4899',
          shortcut: 'Q',
        );
        expect(added, isTrue);
        expect(identical(firstRef, controller.presetMap), isFalse);
        expect(
          controller.presetMap.values.any((p) => p.label == '新标签'),
          isTrue,
        );
      } finally {
        controller.dispose();
      }
    });
  });

  group('Mobile theme button cycle', () {
    testWidgets('cycles system -> light -> dark -> system', (tester) async {
      final controller = await createTestCallbookController(
        enableAudioOutput: false,
      );
      controller.setThemeMode(prism.ThemeMode.system);
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;

      try {
        await tester.pumpWidget(LiveCallStudioApp(controller: controller));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(controller.themeMode, prism.ThemeMode.system);

        await tester.tap(find.bySemanticsLabel('主题：跟随系统（点击切换浅色）'));
        await tester.pump();
        expect(controller.themeMode, prism.ThemeMode.light);

        await tester.tap(find.bySemanticsLabel('主题：浅色（点击切换深色）'));
        await tester.pump();
        expect(controller.themeMode, prism.ThemeMode.dark);

        await tester.tap(find.bySemanticsLabel('主题：深色（点击跟随系统）'));
        await tester.pump();
        expect(controller.themeMode, prism.ThemeMode.system);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  });
}
