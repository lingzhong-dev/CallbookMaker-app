import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/services/lrclib_direct_client.dart';
import 'package:live_call_studio/services/netease_direct_client.dart';
import 'package:live_call_studio/services/qqmusic_direct_client.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/ui/widgets/audio_source_panel.dart';
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
  bool shouldReload(
    covariant LocalizationsDelegate<prism.UiLocalizations> old,
  ) => false;
}

http.Response _jsonResp(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, Object?> _qqSearchPayload(List<Map<String, Object?>> songs) => {
  'code': 0,
  'req': {
    'code': 0,
    'data': {
      'body': {
        'song': {'list': songs},
      },
    },
  },
};

String _b64(String text) => base64Encode(utf8.encode(text));

CallbookController _makeController({
  required QqMusicDirectClient qqClient,
}) {
  return CallbookController(
    neteaseDirectClient: NeteaseDirectClient(
      httpClient: MockClient((_) async => http.Response('offline', 503)),
    ),
    lrclibDirectClient: LrclibDirectClient(
      httpClient: MockClient((_) async => _jsonResp([])),
    ),
    qqMusicDirectClient: qqClient,
    enableAudioOutput: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MockAudioplayersHarness().install();
  });

  group('Step 07: QQ Music Pure-Dart Lyrics Client & Controller Integration', () {
    test('QqMusicDirectClient distinguishes empty results, malformed JSON, invalid Base64, QRC XML, missing translation, missing lyrics, timeout & bounded retries', () async {
      // 1. Search mapping + interval seconds->ms conversion + empty results
      var searchCalls = 0;
      final client = QqMusicDirectClient(
        retryDelay: Duration.zero,
        maxRetries: 2,
        httpClient: MockClient((req) async {
          if (req.url.host == 'u.y.qq.com') {
            searchCalls++;
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            final query =
                ((body['req'] as Map)['param'] as Map)['query'] as String;
            if (query == 'empty') {
              return _jsonResp(_qqSearchPayload(const []));
            }
            if (query == 'bad_json') {
              return http.Response('{not-json', 200);
            }
            if (query == 'transient_recover') {
              if (searchCalls < 3) {
                return http.Response('busy', 503);
              }
              return _jsonResp(
                _qqSearchPayload([
                  {
                    'mid': '0039MnYb0qxYhV',
                    'id': 97773,
                    'name': '晴天',
                    'interval': 269,
                    'singer': [
                      {'name': '周杰伦'},
                    ],
                    'album': {'name': '叶惠美'},
                    'file': {'media_mid': '0039MnYb0qxYhV'},
                  },
                ]),
              );
            }
            if (query == 'timeout_fail') {
              throw TimeoutException('timed out');
            }
          }
          final mid = req.url.queryParameters['songmid'] ?? '';
          if (mid == 'bad_b64') {
            return _jsonResp({
              'retcode': 0,
              'lyric': '%%%not-valid-base64%%%',
              'trans': '',
            });
          }
          if (mid == 'qrc_xml') {
            return _jsonResp({
              'retcode': 0,
              'lyric': _b64(
                '<?xml version="1.0" encoding="utf-8"?><QrcInfos><Lyric_1 LyricContent="[0,200]word"/></QrcInfos>',
              ),
              'trans': '',
            });
          }
          if (mid == 'non_lrc') {
            return _jsonResp({
              'retcode': 0,
              'lyric': _b64('Just plain un-timestamped garbled string'),
              'trans': '',
            });
          }
          if (mid == 'no_lyric') {
            return _jsonResp({'retcode': -1901, 'lyric': '', 'trans': ''});
          }
          if (mid == 'no_trans') {
            return _jsonResp({
              'retcode': 0,
              'lyric': _b64('[00:05.00] First line\n[00:10.00] Second line'),
              'trans': '',
            });
          }
          return _jsonResp({
            'retcode': 0,
            'lyric': _b64('[00:05.00] 光る空へ\n[00:12.00] 走り出そう'),
            'trans': _b64('[00:05.00] 飞向闪耀天空\n[00:12.00] 奔跑吧'),
          });
        }),
      );

      try {
        expect(await client.searchTracks('empty'), isEmpty);

        // Bad JSON never masks as empty results & never retries.
        await expectLater(
          client.searchTracks('bad_json'),
          throwsA(
            isA<QqMusicApiException>().having(
              (e) => e.kind,
              'kind',
              QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
            ),
          ),
        );

        // Bounded retry on 503 recovers on 3rd attempt (1 initial + 2 retries).
        searchCalls = 0;
        final recovered = await client.searchTracks('transient_recover');
        expect(searchCalls, 3);
        expect(recovered.length, 1);
        expect(recovered.first.id, '0039MnYb0qxYhV');
        expect(recovered.first.platform, 'qqmusic');
        expect(recovered.first.provider, 'qqmusic_direct');
        expect(recovered.first.songmid, '0039MnYb0qxYhV');
        expect(recovered.first.songid, 97773);
        expect(recovered.first.mediaMid, '0039MnYb0qxYhV');
        expect(recovered.first.durationMs, 269000);

        // Timeout retries bounded (1 initial + 2 retries) then classifies networkOrServiceFailure.
        searchCalls = 0;
        await expectLater(
          client.searchTracks('timeout_fail'),
          throwsA(
            isA<QqMusicApiException>().having(
              (e) => e.kind,
              'kind',
              QqMusicErrorKind.networkOrServiceFailure,
            ),
          ),
        );
        expect(searchCalls, 3);

        // Corrupt Base64 -> badPayloadOrBase64OrNonLrc
        await expectLater(
          client.fetchTrackDetail('bad_b64'),
          throwsA(
            isA<QqMusicApiException>().having(
              (e) => e.kind,
              'kind',
              QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
            ),
          ),
        );

        // QRC XML -> badPayloadOrBase64OrNonLrc
        await expectLater(
          client.fetchTrackDetail('qrc_xml'),
          throwsA(
            isA<QqMusicApiException>().having(
              (e) => e.kind,
              'kind',
              QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
            ),
          ),
        );

        // Non-LRC text -> badPayloadOrBase64OrNonLrc
        await expectLater(
          client.fetchTrackDetail('non_lrc'),
          throwsA(
            isA<QqMusicApiException>().having(
              (e) => e.kind,
              'kind',
              QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
            ),
          ),
        );

        // -1901 -> noLyrics
        await expectLater(
          client.fetchTrackDetail('no_lyric'),
          throwsA(
            isA<QqMusicApiException>().having(
              (e) => e.kind,
              'kind',
              QqMusicErrorKind.noLyrics,
            ),
          ),
        );

        // Missing translation still loads LRC cleanly.
        final noTransDetail = await client.fetchTrackDetail('no_trans');
        expect(noTransDetail.lines.length, 2);
        expect(noTransDetail.translatedLrc, isEmpty);
      } finally {
        client.dispose();
      }
    });

    test('Controller rejects previewClip audio, keeps full-song duration & outro unpolluted, and exposes honest status without unimplemented swap promise', () async {
      SharedPreferences.setMockInitialValues({'live_call_studio_onboarding_v1': true});
      final qqClient = QqMusicDirectClient(
        retryDelay: Duration.zero,
        httpClient: MockClient((req) async {
          return _jsonResp({
            'retcode': 0,
            'audioUrl': 'https://cdn.example.invalid/30s_preview.m4a',
            'audioPlayability': 'previewClip',
            'lyric': _b64('[00:08.00] Line One\n[00:15.00] Line Two'),
            'trans': _b64('[00:08.00] 第一句\n[00:15.00] 第二句'),
          });
        }),
      );
      final controller = _makeController(qqClient: qqClient);
      try {
        await controller.init();
        await controller.loadRemoteTrack(
          const TrackSummary(
            id: '002PreviewMid',
            platform: 'qqmusic',
            provider: 'qqmusic_direct',
            title: 'Preview Song',
            artist: 'Tester',
            durationMs: 240000,
            songmid: '002PreviewMid',
            songid: 5566,
            mediaMid: '002PreviewMedia',
            audioPlayability: AudioPlayability.previewClip,
          ),
        );

        // Lyrics and Chinese translation import cleanly, yet preview audio is strictly excluded.
        expect(controller.hasExternalAudio, isFalse);
        expect(controller.project.meta.audioUrl, isEmpty);
        expect(controller.knownAudioDurationMs, 240000);
        expect(controller.durationMs, 240000);
        expect(
          controller.sortedLines.any((l) => l.text.translation == '第一句'),
          isTrue,
        );
        final outro = controller.sortedLines.firstWhere(
          (l) => l.kind == LyricLineKind.outro,
        );
        expect(outro.endTimeMs, 240000);
        expect(controller.statusMessage, contains('本地音频'));
        expect(controller.statusMessage, isNot(contains('一键换网易云音源')));
        expect(controller.lastTrackLoadErrorKind, QqMusicErrorKind.noAudio);
      } finally {
        controller.dispose();
      }
    });

    test('Archive save, JSON export/import, and archive reload preserve full QQ Music track identity', () async {
      SharedPreferences.setMockInitialValues({'live_call_studio_onboarding_v1': true});
      final qqClient = QqMusicDirectClient(
        retryDelay: Duration.zero,
        httpClient: MockClient((req) async {
          return _jsonResp({
            'retcode': 0,
            'lyric': _b64('[00:05.00] First line\n[00:10.00] Second line'),
            'trans': _b64('[00:05.00] 一行\n[00:10.00] 二行'),
          });
        }),
      );
      final controller = _makeController(qqClient: qqClient);
      try {
        await controller.init();
        await controller.loadRemoteTrack(
          const TrackSummary(
            id: '004ArchiveMid',
            platform: 'qqmusic',
            provider: 'qqmusic_direct',
            title: 'Archive Song',
            artist: 'Singer A',
            durationMs: 185000,
            songmid: '004ArchiveMid',
            songid: 889900,
            mediaMid: '004MediaMid',
          ),
        );

        final saved = controller.saveCurrentToArchive(
          asNew: true,
          customName: 'QQ Archive Check',
        );
        final exportedJson = controller.exportProjectJsonString();

        // Switch away to a default song, then import JSON and switch back to archive.
        await controller.loadDefaultSong('sweets');
        expect(controller.project.meta.platform, isNot('qqmusic'));

        expect(await controller.importProjectJson(exportedJson), isTrue);
        expect(controller.project.meta.platform, 'qqmusic');
        expect(controller.project.meta.sourceProvider, 'qqmusic_direct');
        expect(controller.project.meta.trackId, '004ArchiveMid');
        expect(controller.project.meta.songmid, '004ArchiveMid');
        expect(controller.project.meta.songid, 889900);
        expect(controller.project.meta.mediaMid, '004MediaMid');

        expect(await controller.switchToArchive(saved.id), isTrue);
        final restoredSummary = controller.restoreTrackSummaryFromMeta(
          controller.project.meta,
        );
        expect(restoredSummary, isNotNull);
        expect(restoredSummary!.platform, 'qqmusic');
        expect(restoredSummary.provider, 'qqmusic_direct');
        expect(restoredSummary.songmid, '004ArchiveMid');
        expect(restoredSummary.songid, 889900);
        expect(restoredSummary.mediaMid, '004MediaMid');
        expect(controller.hasExternalAudio, isFalse);
      } finally {
        controller.dispose();
      }
    });

    test('Race guard: rapid consecutive searchTracks & loadRemoteTrack keep only the latest selection', () async {
      SharedPreferences.setMockInitialValues({'live_call_studio_onboarding_v1': true});
      final searchCompleter1 = Completer<http.Response>();
      final trackCompleter1 = Completer<http.Response>();

      final qqClient = QqMusicDirectClient(
        retryDelay: Duration.zero,
        httpClient: MockClient((req) async {
          if (req.url.host == 'u.y.qq.com') {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            final q = ((body['req'] as Map)['param'] as Map)['query'] as String;
            if (q == 'slow_query') {
              return searchCompleter1.future;
            }
            return _jsonResp(
              _qqSearchPayload([
                {
                  'mid': '002FastMid',
                  'id': 202,
                  'name': 'Fast Result',
                  'interval': 190,
                  'singer': [
                    {'name': 'Fast Artist'},
                  ],
                },
              ]),
            );
          }

          final mid = req.url.queryParameters['songmid'] ?? '';
          if (mid == '001SlowMid') {
            return trackCompleter1.future;
          }
          return _jsonResp({
            'retcode': 0,
            'lyric': _b64('[00:05.00] Fast track wins'),
            'trans': _b64('[00:05.00] 后选胜出'),
          });
        }),
      );
      final controller = _makeController(qqClient: qqClient);
      try {
        await controller.init();

        // Search race: slow first, fast second.
        final fSearch1 = controller.searchTracks('slow_query', source: 'qqmusic');
        final fSearch2 = controller.searchTracks('fast_query', source: 'qqmusic');
        await fSearch2;
        expect(controller.searchResults.single.title, 'Fast Result');

        searchCompleter1.complete(
          _jsonResp(
            _qqSearchPayload([
              {
                'mid': '001SlowMid',
                'id': 101,
                'name': 'Slow Stale Result',
                'interval': 150,
                'singer': [
                  {'name': 'Slow Artist'},
                ],
              },
            ]),
          ),
        );
        await fSearch1;
        expect(controller.searchResults.single.title, 'Fast Result');

        // Load race: slow track A clicked first, fast track B clicked second.
        final slowTrack = const TrackSummary(
          id: '001SlowMid',
          platform: 'qqmusic',
          provider: 'qqmusic_direct',
          title: 'Slow Stale Track',
          artist: 'Artist 1',
          durationMs: 150000,
          songmid: '001SlowMid',
          songid: 101,
        );
        final fastTrack = const TrackSummary(
          id: '002FastMid',
          platform: 'qqmusic',
          provider: 'qqmusic_direct',
          title: 'Fast Winning Track',
          artist: 'Artist 2',
          durationMs: 190000,
          songmid: '002FastMid',
          songid: 202,
        );
        final fLoad1 = controller.loadRemoteTrack(slowTrack);
        final fLoad2 = controller.loadRemoteTrack(fastTrack);
        await fLoad2;
        expect(controller.project.meta.trackId, '002FastMid');
        expect(
          controller.sortedLines.any((l) => l.text.original == 'Fast track wins'),
          isTrue,
        );

        trackCompleter1.complete(
          _jsonResp({
            'retcode': 0,
            'lyric': _b64('[00:05.00] Stale slow track'),
            'trans': _b64('[00:05.00] 过期歌词'),
          }),
        );
        await fLoad1;
        expect(controller.project.meta.trackId, '002FastMid');
        expect(controller.project.meta.title, 'Fast Winning Track');
        expect(
          controller.sortedLines.any((l) => l.text.original == 'Stale slow track'),
          isFalse,
        );
      } finally {
        controller.dispose();
      }
    });

    testWidgets('AudioSourcePanel renders QQ 音乐 provider cleanly at 1280x820 & 390x844 and imports lyrics + translation', (tester) async {
      for (final viewport in [const Size(1280, 820), const Size(390, 844)]) {
        SharedPreferences.setMockInitialValues({'live_call_studio_onboarding_v1': true});
        final qqClient = QqMusicDirectClient(
          retryDelay: Duration.zero,
          httpClient: MockClient((req) async {
            if (req.url.host == 'u.y.qq.com') {
              return _jsonResp(
                _qqSearchPayload([
                  {
                    'mid': '001WidgetMid',
                    'id': 7777,
                    'name': 'QQ Test Track',
                    'interval': 200,
                    'singer': [
                      {'name': 'QQ Artist'},
                    ],
                    'file': {'media_mid': '001WidgetMedia'},
                  },
                ]),
              );
            }
            return _jsonResp({
              'retcode': 0,
              'lyric': _b64('[00:08.00] 星空の下で'),
              'trans': _b64('[00:08.00] 在星空之下'),
            });
          }),
        );
        final controller = _makeController(qqClient: qqClient);
        await controller.init();
        final errors = <FlutterErrorDetails>[];
        final prevOnError = FlutterError.onError;
        FlutterError.onError = (details) => errors.add(details);
        try {
          tester.view.physicalSize = viewport;
          tester.view.devicePixelRatio = 1.0;

          await tester.pumpWidget(
            prism.PrismApp(
              title: 'Step 07 Test',
              theme: controller.buildPrismTheme(Brightness.light),
              darkTheme: controller.buildPrismTheme(Brightness.dark),
              themeMode: controller.themeMode,
              localizationsDelegates: const [
                _TestUiLocalizationsDelegate(),
                DefaultWidgetsLocalizations.delegate,
              ],
              supportedLocales: const [Locale('zh', 'CN'), Locale('zh')],
              home: prism.BannerHost(
                stacked: false,
                topInset: 0,
                child: SingleChildScrollView(
                  child: AudioSourcePanel(controller: controller),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final qqChip = find.text('QQ 音乐');
          expect(qqChip, findsOneWidget);
          await tester.ensureVisible(qqChip);
          await tester.tap(qqChip);
          await tester.pumpAndSettle();

          final searchField = find.byWidgetPredicate(
            (w) =>
                w is prism.TextField &&
                w.decoration?.hintText == '输入歌名或歌手...',
          );
          await tester.enterText(searchField, '星空');
          await tester.pump();
          await tester.tap(find.text('搜索'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));

          expect(find.text('QQ Test Track'), findsOneWidget);
          await tester.tap(find.text('导入'));
          await tester.pump();
          await tester.runAsync(() async {
            final deadline = DateTime.now().add(const Duration(seconds: 5));
            while (controller.isFetchingLyrics &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          });
          await tester.pumpAndSettle();

          expect(controller.project.meta.platform, 'qqmusic');
          expect(controller.project.meta.sourceProvider, 'qqmusic_direct');
          expect(controller.project.meta.songmid, '001WidgetMid');
          expect(controller.project.meta.songid, 7777);
          expect(controller.hasExternalAudio, isFalse);
          expect(
            controller.sortedLines.any((l) => l.text.translation == '在星空之下'),
            isTrue,
          );
          expect(errors, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          FlutterError.onError = prevOnError;
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          controller.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      }
    });
  });
}
