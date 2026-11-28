import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_call_studio/data/default_songs.dart';
import 'package:live_call_studio/services/audio_pcm_decoder.dart';
import 'package:live_call_studio/services/bounded_audio_fetcher.dart';
import 'package:live_call_studio/services/downbeat_analyzer.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/ui/dashboard_view.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mock_audioplayers_harness.dart';

class _TestUiLocalizations implements prism.UiLocalizations {
  const _TestUiLocalizations();
  @override
  String get back => 'Back';
  @override
  String get cancel => 'Cancel';
  @override
  String get clearSearch => 'Clear search';
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

Widget _wrapWithPrism(CallbookController controller, Widget child) {
  return AnimatedBuilder(
    animation: controller,
    builder: (context, _) => prism.PrismApp(
      title: 'Step 06 Test',
      theme: controller.buildPrismTheme(Brightness.light),
      darkTheme: controller.buildPrismTheme(Brightness.dark),
      themeMode: controller.themeMode,
      localizationsDelegates: const [
        _TestUiLocalizationsDelegate(),
        DefaultWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('zh')],
      home: prism.BottomInsetScope(inset: 24, child: child),
    ),
  );
}

/// Generates a RIFF/WAVE PCM16 file with an optional extra metadata chunk before `data`.
Uint8List _encodeWavPcm16(
  Float32List samples, {
  int sampleRate = 16000,
  bool includeExtraChunk = false,
}) {
  final pcmBytes = Uint8List(samples.length * 2);
  final pcmBd = ByteData.sublistView(pcmBytes);
  for (var i = 0; i < samples.length; i++) {
    final s = (samples[i].clamp(-1.0, 1.0) * 32767.0).round();
    pcmBd.setInt16(i * 2, s, Endian.little);
  }
  final junkChunk = includeExtraChunk
      ? <int>[
          0x4A, 0x55, 0x4E, 0x4B, // JUNK
          4, 0, 0, 0,
          1, 2, 3, 4,
        ]
      : const <int>[];
  final totalSize = 4 + 24 + junkChunk.length + 8 + pcmBytes.length;
  final out = BytesBuilder();
  final hdr = ByteData(12);
  out.add([0x52, 0x49, 0x46, 0x46]); // RIFF
  hdr.setUint32(0, totalSize, Endian.little);
  out.add(hdr.buffer.asUint8List(0, 4));
  out.add([0x57, 0x41, 0x56, 0x45]); // WAVE
  out.add([0x66, 0x6D, 0x74, 0x20]); // fmt
  final fmt = ByteData(20);
  fmt.setUint32(0, 16, Endian.little);
  fmt.setUint16(4, 1, Endian.little); // PCM
  fmt.setUint16(6, 1, Endian.little); // mono
  fmt.setUint32(8, sampleRate, Endian.little);
  fmt.setUint32(12, sampleRate * 2, Endian.little);
  fmt.setUint16(16, 2, Endian.little);
  fmt.setUint16(18, 16, Endian.little);
  out.add(fmt.buffer.asUint8List());
  if (junkChunk.isNotEmpty) {
    out.add(junkChunk);
  }
  out.add([0x64, 0x61, 0x74, 0x61]); // data
  final dataHdr = ByteData(4);
  dataHdr.setUint32(0, pcmBytes.length, Endian.little);
  out.add(dataHdr.buffer.asUint8List());
  out.add(pcmBytes);
  return out.toBytes();
}

Float32List _generateDrumTrackPcm({
  required int bpm,
  required int firstBeatMs,
  int durationMs = 10000,
  int sampleRate = 16000,
}) {
  final totalSamples = (durationMs * sampleRate) ~/ 1000;
  final out = Float32List(totalSamples);
  final beatMs = 60000.0 / bpm;
  var beatIdx = 0;
  while (true) {
    final tMs = firstBeatMs + beatIdx * beatMs;
    if (tMs >= durationMs - 60) break;
    final startSample = (tMs * sampleRate / 1000.0).round();
    final amp = beatIdx % 4 == 0 ? 0.92 : 0.65;
    for (var n = 0; n < (sampleRate * 0.045).round(); n++) {
      final idx = startSample + n;
      if (idx >= out.length) break;
      final env = math.exp(-n / (sampleRate * 0.012));
      final tone = math.sin(2.0 * math.pi * 110.0 * n / sampleRate);
      final click = (n < 120) ? 0.45 * math.sin(2.0 * math.pi * 1200.0 * n / sampleRate) : 0.0;
      out[idx] = (out[idx] + amp * env * (tone + click)).clamp(-1.0, 1.0);
    }
    beatIdx++;
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MockAudioplayersHarness().install();
  });

  group('Step 06 BoundedAudioFetcher & WAV/PCM DSP', () {
    test('HTTP Range 206 valid, invalid Content-Range, 200 byte-cap, 416, and timeout guards', () async {
      // 1) Valid 206 Partial Content
      final validFetcher = BoundedAudioFetcher(
        defaultMaxBytes: 4096,
        httpClient: MockClient.streaming((req, _) async {
          expect(req.headers['Range'], 'bytes=0-4095');
          final body = List<int>.filled(4096, 7);
          return http.StreamedResponse(
            Stream.value(body),
            206,
            headers: {'content-range': 'bytes 0-4095/16384'},
          );
        }),
      );
      final ok206 = await validFetcher.fetchPrefix('https://cdn.example.com/a.mp3');
      expect(ok206.statusCode, 206);
      expect(ok206.partialRangeUsed, isTrue);
      expect(ok206.fetchedBytes, 4096);
      expect(ok206.totalBytes, 16384);

      // 2) Invalid Content-Range (missing or non-zero start)
      final badRangeFetcher = BoundedAudioFetcher(
        defaultMaxBytes: 4096,
        httpClient: MockClient.streaming((_, __) async {
          return http.StreamedResponse(
            Stream.value(List<int>.filled(512, 1)),
            206,
            headers: {'content-range': 'bytes 100-611/2000'},
          );
        }),
      );
      await expectLater(
        badRangeFetcher.fetchPrefix('https://cdn.example.com/bad.mp3'),
        throwsA(
          isA<BoundedAudioFetchException>().having(
            (e) => e.kind,
            'kind',
            BoundedFetchErrorKind.invalidContentRange,
          ),
        ),
      );

      // 3) HTTP 200 (server ignored Range): caps strictly at maxBytes without buffering unbounded stream
      final cap200Fetcher = BoundedAudioFetcher(
        defaultMaxBytes: 4096,
        httpClient: MockClient.streaming((_, __) async {
          Stream<List<int>> bigStream() async* {
            for (var i = 0; i < 64; i++) {
              yield List<int>.filled(1024, i & 0xFF);
            }
          }
          return http.StreamedResponse(bigStream(), 200);
        }),
      );
      final capped200 = await cap200Fetcher.fetchPrefix('https://cdn.example.com/full.mp3');
      expect(capped200.statusCode, 200);
      expect(capped200.partialRangeUsed, isFalse);
      expect(capped200.fetchedBytes, 4096);

      // 4) HTTP 416 Range Not Satisfiable
      final fetcher416 = BoundedAudioFetcher(
        httpClient: MockClient.streaming((_, __) async {
          return http.StreamedResponse(const Stream.empty(), 416);
        }),
      );
      await expectLater(
        fetcher416.fetchPrefix('https://cdn.example.com/416.mp3'),
        throwsA(
          isA<BoundedAudioFetchException>().having(
            (e) => e.kind,
            'kind',
            BoundedFetchErrorKind.rangeNotSatisfiable,
          ),
        ),
      );

      // 5) Timeout
      final timeoutFetcher = BoundedAudioFetcher(
        timeout: const Duration(milliseconds: 50),
        httpClient: MockClient.streaming((_, __) async {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          return http.StreamedResponse(const Stream.empty(), 200);
        }),
      );
      await expectLater(
        timeoutFetcher.fetchPrefix('https://cdn.example.com/slow.mp3'),
        throwsA(
          isA<BoundedAudioFetchException>().having(
            (e) => e.kind,
            'kind',
            BoundedFetchErrorKind.timeout,
          ),
        ),
      );
    });

    test('Pure-Dart WAV decoder + known-BPM phase detection finds audible start, downbeat candidate & telemetry', () async {
      final samples = _generateDrumTrackPcm(
        bpm: 120,
        firstBeatMs: 360,
        durationMs: 9000,
      );
      final wavBytes = _encodeWavPcm16(samples, includeExtraChunk: true);
      final decoded = decodeWavBytesToMonoFloat(wavBytes);
      expect(decoded.sampleRate, 16000);
      expect(decoded.durationMs, 9000);

      final result = await analyzeKnownBpmPcmInIsolate(
        samples: decoded.samples,
        sampleRate: decoded.sampleRate,
        knownBpm: 120,
        beatsPerBar: 4,
        requestId: 1,
        sourceFingerprint: 'test-drum',
        fetchMs: 12,
        decodeMs: decoded.decodeMs,
        fetchedBytes: wavBytes.length,
        decodePeakBytes: decoded.estimatedPeakBytes,
      );
      expect(result.reliable, isTrue);
      expect(result.audibleStartMs, isNotNull);
      expect(result.audibleStartMs!, inInclusiveRange(310, 410));
      expect(result.candidates, isNotEmpty);
      expect((result.candidates.first.offsetMs - 360).abs(), lessThanOrEqualTo(35));
      expect(result.candidates.first.confidence, greaterThanOrEqualTo(0.45));
      expect(result.telemetry.analyzedDurationMs, 9000);
      expect(result.telemetry.fetchMs, 12);
      expect(result.telemetry.estimatedPeakBytes, greaterThan(0));
    });

    test('Silence, steady pure tone, and non-periodic acapella/random hits explicitly report 无法可靠判断', () async {
      const rate = 16000;
      const len = rate * 6;

      // 1) Pure silence
      final silenceRes = await analyzeKnownBpmPcmInIsolate(
        samples: Float32List(len),
        sampleRate: rate,
        knownBpm: 120,
        beatsPerBar: 4,
        requestId: 1,
        sourceFingerprint: 'silence',
        fetchMs: 0,
        decodeMs: 1,
        fetchedBytes: 0,
        decodePeakBytes: len * 4,
      );
      expect(silenceRes.reliable, isFalse);
      expect(silenceRes.statusMessage, contains('无法可靠判断'));
      expect(silenceRes.candidates, isEmpty);

      // 2) Steady 440Hz sine tone (no beat transients)
      final tone = Float32List(len);
      for (var i = 0; i < len; i++) {
        tone[i] = 0.4 * math.sin(2.0 * math.pi * 440.0 * i / rate);
      }
      final toneRes = await analyzeKnownBpmPcmInIsolate(
        samples: tone,
        sampleRate: rate,
        knownBpm: 120,
        beatsPerBar: 4,
        requestId: 2,
        sourceFingerprint: 'tone',
        fetchMs: 0,
        decodeMs: 1,
        fetchedBytes: 0,
        decodePeakBytes: len * 4,
      );
      expect(toneRes.reliable, isFalse);
      expect(toneRes.statusMessage, contains('无法可靠判断'));

      // 3) Irregular non-periodic clicks (mismatched / rubato vs 120 BPM)
      final irregular = Float32List(len);
      for (final ms in const [200, 610, 1180, 1490, 2330, 2940, 3670, 4120, 4890, 5510]) {
        final s0 = (ms * rate) ~/ 1000;
        for (var n = 0; n < 350 && s0 + n < irregular.length; n++) {
          irregular[s0 + n] = 0.8 * math.exp(-n / 90.0);
        }
      }
      final irregularRes = await analyzeKnownBpmPcmInIsolate(
        samples: irregular,
        sampleRate: rate,
        knownBpm: 120,
        beatsPerBar: 4,
        requestId: 3,
        sourceFingerprint: 'irregular',
        fetchMs: 0,
        decodeMs: 1,
        fetchedBytes: 0,
        decodePeakBytes: len * 4,
      );
      expect(irregularRes.reliable, isFalse);
      expect(irregularRes.statusMessage, contains('无法可靠判断'));
    });
  });

  group('Step 06 Controller Concurrency, Undo & DashboardView UI', () {
    test('Concurrent track switch, cancel, and manual BPM/offset edits discard stale analysis results', () async {
      SharedPreferences.setMockInitialValues({'live_call_studio_onboarding_v1': true});
      final wavBytes = _encodeWavPcm16(
        _generateDrumTrackPcm(bpm: 120, firstBeatMs: 400, durationMs: 6000),
      );

      Completer<void>? fetchGate;
      final fetcher = BoundedAudioFetcher(
        httpClient: MockClient.streaming((req, _) async {
          final gate = fetchGate;
          if (gate != null && !gate.isCompleted) {
            await gate.future;
          }
          return http.StreamedResponse(
            Stream.value(wavBytes),
            206,
            headers: {'content-range': 'bytes 0-${wavBytes.length - 1}/${wavBytes.length}'},
          );
        }),
      );

      final controller = CallbookController(
        audioFetcher: fetcher,
        enableAudioOutput: false,
      );
      await controller.init(awaitBackgroundSync: false);
      try {
        await controller.importProjectJson(
          jsonEncode({
            'meta': {
              'title': 'Slow Stream Track',
              'artist': 'Unit',
              'platform': 'netease',
              'trackId': '1001',
              'audioUrl': 'https://cdn.example.com/slow.wav',
              'bpm': 120,
              'timeSignature': '4/4',
            },
            'lines': [
              {
                'id': 's1',
                'startTimeMs': 1000,
                'endTimeMs': 5000,
                'kind': 'lyric',
                'text': {'original': 'Line 1'},
              },
            ],
          }),
        );

        // 1) Manual offset edit during in-flight analysis discards stale result
        fetchGate = Completer<void>();
        final future1 = controller.analyzeDownbeatForCurrentTrack();
        await Future<void>.delayed(Duration.zero);
        expect(controller.downbeatState.isAnalyzing, isTrue);

        controller.setOffset(777);
        fetchGate.complete();
        await future1;
        expect(controller.project.meta.offsetMs, 777);
        expect(controller.downbeatState.result, isNull);

        // 2) Cancel during in-flight analysis discards stale result
        fetchGate = Completer<void>();
        final future2 = controller.analyzeDownbeatForCurrentTrack();
        await Future<void>.delayed(Duration.zero);
        controller.cancelDownbeatAnalysis();
        fetchGate.complete();
        await future2;
        expect(controller.downbeatState.isAnalyzing, isFalse);
        expect(controller.downbeatState.result, isNull);
        expect(controller.project.meta.offsetMs, 777);

        // 3) Manual BPM edit during in-flight analysis discards stale result
        fetchGate = Completer<void>();
        final future3 = controller.analyzeDownbeatForCurrentTrack();
        await Future<void>.delayed(Duration.zero);
        controller.setBpm(140);
        fetchGate.complete();
        await future3;
        expect(controller.project.meta.bpm, 140);
        expect(controller.downbeatState.result, isNull);

        // 4) Switching track during in-flight analysis discards stale result
        controller.setBpm(120);
        fetchGate = Completer<void>();
        final future4 = controller.analyzeDownbeatForCurrentTrack();
        await Future<void>.delayed(Duration.zero);
        await controller.loadDefaultSong(defaultSongs.last.id);
        fetchGate.complete();
        await future4;
        expect(controller.downbeatState.result, isNull);
      } finally {
        controller.dispose();
      }
    });

    test('Applying candidate offset is a single undoable operation that leaves lines and alerts untouched', () async {
      SharedPreferences.setMockInitialValues({'live_call_studio_onboarding_v1': true});
      final controller = CallbookController(enableAudioOutput: false);
      await controller.init(awaitBackgroundSync: false);
      try {
        final lineCountBefore = controller.project.lines.length;
        controller.setOffset(120);
        controller.applyDownbeatCandidateOffset(360);
        expect(controller.project.meta.offsetMs, 360);
        expect(controller.canUndo, isTrue);

        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(controller.project.meta.offsetMs, 120);
        expect(controller.project.lines.length, lineCountBefore);
      } finally {
        controller.dispose();
      }
    });

    test('previewDownbeatCandidate temporarily previews candidate beat phase and clearDownbeatPreviewOffset restores project offset', () async {
      SharedPreferences.setMockInitialValues({'live_call_studio_onboarding_v1': true});
      final controller = CallbookController(enableAudioOutput: false);
      await controller.init(awaitBackgroundSync: false);
      try {
        controller.setBpm(120); // 500ms per beat
        controller.setOffset(0);
        expect(controller.project.meta.offsetMs, 0);

        // Preview candidate at 350ms -> seeks to 350ms, beat 1 starts at 350ms (beatInBar == 1),
        // without mutating project.meta.offsetMs!
        await controller.previewDownbeatCandidate(350);
        expect(controller.previewDownbeatOffsetMs, 350);
        expect(controller.project.meta.offsetMs, 0);
        expect(controller.currentTimeMs, 350);
        expect(controller.currentBar, 1);
        expect(controller.currentBeatInBar, 1);

        // Pause and clear preview -> restores beat grid to project offsetMs = 0 (at 350ms -> beat 1, still 1, wait seek(600ms) -> beat 2!)
        await controller.togglePlay();
        controller.clearDownbeatPreviewOffset();
        expect(controller.previewDownbeatOffsetMs, isNull);
        await controller.seek(600);
        expect(controller.currentBeatInBar, 2);
      } finally {
        controller.dispose();
      }
    });

    testWidgets(
      'DashboardView 首拍辅助分析 runs local WAV analysis, supports preview/fine-tune/apply & undo without overflow',
      timeout: const Timeout(Duration(seconds: 25)),
      (tester) async {
        SharedPreferences.setMockInitialValues({'live_call_studio_onboarding_v1': true});
        final tempDir = Directory.systemTemp.createTempSync('cbm_step6_ui_');
        final wavFile = File('${tempDir.path}${Platform.pathSeparator}beat120.wav');
        wavFile.writeAsBytesSync(
          _encodeWavPcm16(
            _generateDrumTrackPcm(bpm: 120, firstBeatMs: 350, durationMs: 8000),
          ),
        );

        final controller = CallbookController(enableAudioOutput: false);
        await controller.init(awaitBackgroundSync: false);
        controller.setBpm(120);
        controller.setOffset(50);
        await controller.loadLocalAudioFile(wavFile.path, 'beat120.wav');

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        try {
          await tester.pumpWidget(
            _wrapWithPrism(controller, DashboardView(controller: controller)),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));

          await tester.ensureVisible(find.textContaining('首拍 '));
          await tester.tap(find.textContaining('首拍 '));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));

          await tester.ensureVisible(find.text('首拍辅助分析'));
          await tester.tap(find.text('首拍辅助分析'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          // Allow Isolate.run() WAV decode + DSP to finish and flush FakeAsync continuations
          for (var i = 0; i < 60; i++) {
            if (!controller.downbeatState.isAnalyzing &&
                (controller.downbeatState.result != null ||
                    controller.downbeatState.errorMessage != null)) {
              break;
            }
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump();
          }
          await tester.pump(const Duration(milliseconds: 250));

          expect(controller.downbeatState.errorMessage, isNull);
          expect(controller.downbeatState.result?.reliable, isTrue);
          expect(find.textContaining('有声起点：'), findsOneWidget);
          expect(find.text('试听预览'), findsOneWidget);
          expect(find.text('应用到首拍'), findsOneWidget);
          expect(tester.takeException(), isNull);

          // Preview candidate seeks and starts playback cleanly
          await tester.ensureVisible(find.text('试听预览'));
          await tester.tap(find.text('试听预览'));
          await tester.pump();
          expect(controller.isPlaying, isTrue);
          await controller.togglePlay();
          await tester.pump();

          // Fine-tune by +10ms and apply
          await tester.ensureVisible(find.text('+10').last);
          await tester.tap(find.text('+10').last);
          await tester.pump();

          await tester.ensureVisible(find.text('应用到首拍'));
          await tester.tap(find.text('应用到首拍'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));

          final expectedApplied =
              controller.downbeatState.result!.candidates.first.offsetMs + 10;
          expect(controller.project.meta.offsetMs, expectedApplied);
          expect(controller.undoLastTimelineEdit(), isTrue);
          expect(controller.project.meta.offsetMs, 50);
          expect(tester.takeException(), isNull);
        } finally {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          controller.dispose();
          try {
            tempDir.deleteSync(recursive: true);
          } catch (_) {}
        }
      },
    );
  });
}
