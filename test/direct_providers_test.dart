import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_call_studio/main.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/services/api_client.dart';
import 'package:live_call_studio/services/desktop_service_launcher.dart';
import 'package:live_call_studio/services/lrclib_direct_client.dart';
import 'package:live_call_studio/services/mock_catalog_provider.dart';
import 'package:live_call_studio/services/netease_direct_client.dart';
import 'package:live_call_studio/state/callbook_controller.dart';
import 'package:live_call_studio/utils/lrc_ruby_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _jsonResp(Object data, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

void _setupPluginMocks() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final registered = <String>{};

  void ensureEvent(String channel) {
    if (!registered.add(channel)) return;
    messenger.setMockMessageHandler(channel, (ByteData? message) async {
      if (message == null) return null;
      final call = const StandardMethodCodec().decodeMethodCall(message);
      if (call.method == 'listen' || call.method == 'cancel') {
        return const StandardMethodCodec().encodeSuccessEnvelope(null);
      }
      return null;
    });
  }

  ensureEvent('xyz.luan/audioplayers.global/events');
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (MethodCall call) async {
      final args = call.arguments;
      if (args is Map && args['playerId'] != null) {
        ensureEvent('xyz.luan/audioplayers/events/${args['playerId']}');
      }
      if (call.method == 'getCurrentPosition' ||
          call.method == 'getDuration') {
        return 0;
      }
      return null;
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
    _setupPluginMocks();
  });

  group('Pure-Dart EAPI & LRC Helpers', () {
    test('NeteaseDirectClient.eapiEncrypt matches verified AES-128-ECB vector', () {
      const expectedHex =
          '2B5D64177AA6460FBAA3DCB1285E28954BBB4F7556E09B0FB25750F12398BB50'
          '565A7F460E7CE78A1AF430E027FBE879C4A9F27F2EB9646649834AF9158B1E0F'
          'EBFA3964E919E351E2A3C14BF6D237BCDC6D9CB0EDF0E411235E1DD89CCE6DCF'
          '1592EFDBED2FA4BB612DD34C3BE69C1C8669C1DCE2A45A7DACAFA0C320D13BB2'
          '539E9CA7FE3CE92B53D71E422E5857E4CC5E19F54C3EB44853D579745ED5DBA8'
          '6FFF22C6A90DB73B53A7BFC2E2E4B85ED10A53692FD5606225E2CDCC0DB70646'
          '60013F1CF221119F2F8BA038A692DE56A08921FCE489C33866E45B24AD51DD4F'
          '5B4D7727666CA77EF901A839B3F4ADEBB6A27106D6C6223DBCC49EC284E67DBB';

      final actualHex = NeteaseDirectClient.eapiEncrypt(
        '/api/cloudsearch/pc',
        <String, Object?>{
          's': 'Starlight',
          'type': 1,
          'limit': 2,
          'offset': 0,
          'total': true,
          'header':
              '{"os":"pc","appver":"2.9.7","channel":"netease","requestId":"1700000000000"}',
        },
      );
      expect(actualHex, expectedHex);
      expect(actualHex.length % 32, 0);
    });

    test('DesktopServiceLauncher.maskNeteaseCookie masks MUSIC_U safely', () {
      expect(DesktopServiceLauncher.maskNeteaseCookie(''), '');
      expect(
        DesktopServiceLauncher.maskNeteaseCookie('MUSIC_U=short; os=pc'),
        'MUSIC_U=***',
      );
      expect(
        DesktopServiceLauncher.maskNeteaseCookie('abcd12345678wxyz'),
        'MUSIC_U=abcd***wxyz',
      );
    });

    test('parseLrcOffline skips Netease JSON credits and parses inline bilingual lines', () {
      const lrc = '''
{"t":0,"c":[{"tx":"作词 : SAWTOWNE"}]}
[ti:Test]
[00:05.00] 夜空を見上げて // 仰望夜空
[00:10.00] 夢の中へ || 去往梦中
''';
      final lines = parseLrcOffline(lrc);
      expect(lines.length, 2);
      expect(lines[0].startTimeMs, 5000);
      expect(lines[0].text.original, '夜空を見上げて');
      expect(lines[0].text.translation, '仰望夜空');
      expect(lines[1].text.original, '夢の中へ');
      expect(lines[1].text.translation, '去往梦中');
    });
  });

  group('Pure-Dart Music Providers', () {
    test('NeteaseDirectClient searches, probes cookie, and fetches lyrics + v0 fallback audio URL', () async {
      final seenRequests = <http.Request>[];
      final mockHttp = MockClient((req) async {
        seenRequests.add(req);
        final path = req.url.path;
        if (path == '/eapi/w/nuser/account/get') {
          final cookie = req.headers['Cookie'] ?? '';
          final hasToken = cookie.contains('MUSIC_U=validtoken12345');
          return _jsonResp({
            'code': 200,
            'profile': hasToken ? {'nickname': 'MikuStageUser'} : null,
          });
        }
        if (path == '/eapi/cloudsearch/pc') {
          return _jsonResp({
            'code': 200,
            'result': {
              'songs': [
                {
                  'id': 2127806975,
                  'name': 'M@GICAL☆CURE!',
                  'ar': [
                    {'name': 'SAWTOWNE'},
                    {'name': '初音ミク'},
                  ],
                  'al': {'name': 'MIKU EXPO'},
                  'dt': 201875,
                },
              ],
            },
          });
        }
        if (path == '/eapi/song/lyric/v1') {
          return _jsonResp({
            'code': 200,
            'lrc': {'lyric': '[00:09.00] Ready Miku\n[00:13.00] One Two Three'},
            'tlyric': {'lyric': '[00:09.00] 准备好了吗'},
          });
        }
        if (path == '/eapi/v3/song/detail') {
          return _jsonResp({
            'code': 200,
            'songs': [
              {
                'id': 2127806975,
                'name': 'M@GICAL☆CURE!',
                'ar': [
                  {'name': 'SAWTOWNE'},
                ],
                'al': {'name': 'MIKU EXPO 2024'},
                'dt': 201875,
              },
            ],
          });
        }
        if (path == '/eapi/song/enhance/player/url/v1') {
          return _jsonResp({
            'code': 200,
            'data': [
              {'id': 2127806975, 'url': null, 'code': 404},
            ],
          });
        }
        if (path == '/eapi/song/enhance/player/url') {
          return _jsonResp({
            'code': 200,
            'data': [
              {
                'id': 2127806975,
                'url': 'https://m8.music.126.net/demo-track.mp3',
                'code': 200,
              },
            ],
          });
        }
        return http.Response('Not found', 404);
      });

      final client = NeteaseDirectClient(httpClient: mockHttp);
      try {
        final guest = await client.probeAccount();
        expect(guest.reachable, isTrue);
        expect(guest.loggedIn, isFalse);
        expect(guest.cookieConfigured, isFalse);

        final authed = await client.probeAccount(cookie: 'validtoken12345');
        expect(authed.reachable, isTrue);
        expect(authed.loggedIn, isTrue);
        expect(authed.nickname, 'MikuStageUser');
        expect(authed.cookieMasked, 'MUSIC_U=vali***2345');

        final tracks = await client.searchTracks('M@GICAL', cookie: 'validtoken12345');
        expect(tracks.length, 1);
        expect(tracks.first.provider, 'netease_direct');
        expect(tracks.first.artist, 'SAWTOWNE / 初音ミク');
        expect(tracks.first.durationMs, 201875);

        final detail = await client.fetchTrackDetail(
          '2127806975',
          cookie: 'validtoken12345',
        );
        expect(detail.audioUrl, 'https://m8.music.126.net/demo-track.mp3');
        expect(detail.lines.length, 2);
        expect(detail.lines.first.text.translation, '准备好了吗');
        expect(detail.track.album, 'MIKU EXPO 2024');
        expect(
          seenRequests.every(
            (r) =>
                r.headers['Referer'] == 'https://music.163.com' &&
                r.body.startsWith('params='),
          ),
          isTrue,
        );
      } finally {
        client.dispose();
      }
    });

    test('LrclibDirectClient searches & fetches track detail and handles 404', () async {
      final mockHttp = MockClient((req) async {
        if (req.url.path == '/api/search') {
          return _jsonResp([
            {
              'id': 42,
              'trackName': 'Starlight Anthem',
              'artistName': 'Stage Unit',
              'albumName': 'Live Vol.1',
              'duration': 185.5,
              'syncedLyrics': '[00:05.00] Shine bright',
            },
          ]);
        }
        if (req.url.path == '/api/get/42') {
          return _jsonResp({
            'id': 42,
            'trackName': 'Starlight Anthem',
            'artistName': 'Stage Unit',
            'albumName': 'Live Vol.1',
            'duration': 185.5,
            'syncedLyrics': '[00:05.00] Shine bright\n[00:10.00] Call together',
          });
        }
        return http.Response('Not found', 404);
      });

      final client = LrclibDirectClient(httpClient: mockHttp);
      try {
        final results = await client.searchTracks('Starlight');
        expect(results.length, 1);
        expect(results.first.provider, 'lrclib');
        expect(results.first.durationMs, 185500);
        expect(results.first.hasSyncedLyrics, isTrue);

        final detail = await client.fetchTrackDetail('42');
        expect(detail.lines.length, 2);
        expect(detail.audioUrl, isEmpty);

        await expectLater(client.fetchTrackDetail('999999'), throwsException);
      } finally {
        client.dispose();
      }
    });

    test('MockCatalogProvider returns offline copyright-free demos', () {
      const mock = MockCatalogProvider();
      final results = mock.searchTracks('unmatched-keyword');
      expect(results.length, 3);
      expect(results.first.id, 'mock-starlight-175');

      final detail = mock.fetchTrackDetail('mock-starlight-175');
      expect(detail, isNotNull);
      expect(detail!.lines.length, 8);
      expect(detail.lines.first.text.translation, '仰望夜空 让旋律回响吧');
    });
  });

  group('CallbookController Pure-Dart & Hybrid Mode Integration', () {
    test('Standalone no-Node/no-backend mode searches, falls back, validates Cookie, and loads track cleanly', () async {
      final offlineBackend = MockClient((_) async => http.Response('offline', 503));
      final neteaseHttp = MockClient((req) async {
        final path = req.url.path;
        if (path == '/eapi/w/nuser/account/get') {
          return _jsonResp({
            'code': 200,
            'profile': {'nickname': 'DirectTester'},
          });
        }
        if (path == '/eapi/cloudsearch/pc') {
          return _jsonResp({
            'code': 200,
            'result': {
              'songs': [
                {
                  'id': 778899,
                  'name': 'Direct Live Song',
                  'ar': [
                    {'name': 'Direct Idol'},
                  ],
                  'al': {'name': 'Stage Direct'},
                  'dt': 60000,
                },
              ],
            },
          });
        }
        if (path == '/eapi/song/lyric/v1') {
          return _jsonResp({
            'code': 200,
            'lrc': {'lyric': '[00:10.00] 声を出して\n[00:14.00] 盛り上がろう'},
            'tlyric': {'lyric': '[00:10.00] 发出声音吧'},
          });
        }
        if (path == '/eapi/v3/song/detail') {
          return _jsonResp({
            'code': 200,
            'songs': [
              {
                'id': 778899,
                'name': 'Direct Live Song',
                'ar': [
                  {'name': 'Direct Idol'},
                ],
                'dt': 60000,
              },
            ],
          });
        }
        if (path == '/eapi/song/enhance/player/url/v1') {
          return _jsonResp({
            'code': 200,
            'data': [
              {'url': 'https://cdn.example.com/direct.mp3'},
            ],
          });
        }
        return http.Response('err', 500);
      });

      final controller = CallbookController(
        apiClient: CallbookApiClient(
          baseUrl: 'http://127.0.0.1:8000',
          httpClient: offlineBackend,
        ),
        neteaseDirectClient: NeteaseDirectClient(httpClient: neteaseHttp),
        lrclibDirectClient: LrclibDirectClient(
          httpClient: MockClient((_) async => _jsonResp([])),
        ),
        enableAudioOutput: false,
      );
      try {
        await controller.init();
        expect(controller.backendOnline, isFalse);
        expect(controller.gatewayStatus.nodeAvailable, isFalse);

        final verified = await controller.oneClickConfigureAndStartGateway(
          cookie: 'directcookie123456',
        );
        expect(verified, isTrue);
        expect(controller.gatewayStatus.gatewayOnline, isTrue);
        expect(controller.gatewayStatus.neteaseAccount, 'DirectTester');
        expect(controller.gatewayStatus.cookieMasked, 'MUSIC_U=dire***3456');

        await controller.searchTracks('Direct', source: 'custom_proxy');
        expect(controller.searchResults.length, 1);
        expect(controller.searchResults.first.provider, 'netease_direct');

        await controller.loadRemoteTrack(controller.searchResults.first);
        expect(controller.project.meta.title, 'Direct Live Song');
        expect(controller.project.meta.audioUrl, 'https://cdn.example.com/direct.mp3');
        expect(controller.sortedLines.any((l) => l.kind == LyricLineKind.intro), isTrue);
        expect(controller.sortedLines.any((l) => l.kind == LyricLineKind.outro), isTrue);

        // Mock search without backend or external network
        await controller.searchTracks('', source: 'mock');
        expect(controller.searchResults.length, 3);
        expect(controller.searchResults.first.provider, 'mock');
      } finally {
        controller.dispose();
      }
    });

    test('Auto search falls back cleanly from Netease -> LRCLIB -> Mock offline', () async {
      final controller = CallbookController(
        apiClient: CallbookApiClient(
          baseUrl: 'http://127.0.0.1:8000',
          httpClient: MockClient((_) async => http.Response('offline', 503)),
        ),
        neteaseDirectClient: NeteaseDirectClient(
          httpClient: MockClient((_) async => http.Response('error', 502)),
        ),
        lrclibDirectClient: LrclibDirectClient(
          httpClient: MockClient((_) async => _jsonResp([])),
        ),
        enableAudioOutput: false,
      );
      try {
        await controller.init();
        await controller.searchTracks('anything', source: 'auto');
        expect(controller.searchResults.length, 3);
        expect(controller.searchResults.every((t) => t.provider == 'mock'), isTrue);
      } finally {
        controller.dispose();
      }
    });

    test('Hybrid mode: FastAPI backend without Node still uses NeteaseDirectClient + enriches Ruby via /api/lyrics/parse', () async {
      var rubyCalled = false;
      final hybridBackend = MockClient((req) async {
        final path = req.url.path;
        if (path == '/health') {
          return _jsonResp({
            'status': 'ok',
            'customProxyEnabled': false,
            'providers': ['lrclib', 'mock'],
          });
        }
        if (path == '/api/site-copy') {
          return _jsonResp({'entries': {}});
        }
        if (path == '/api/gateway/status') {
          return _jsonResp({
            'gatewayUrl': 'http://127.0.0.1:3000',
            'gatewayOnline': false,
            'customProxyEnabled': false,
            'nodeAvailable': false,
            'packageAvailable': false,
            'message': 'No Node.js installed',
          });
        }
        if (path == '/api/gateway/configure') {
          return _jsonResp({
            'gatewayUrl': 'http://127.0.0.1:3000',
            'gatewayOnline': false,
            'customProxyEnabled': false,
            'nodeAvailable': false,
            'packageAvailable': false,
            'message': 'No Node.js',
          });
        }
        if (path == '/api/lyrics/parse') {
          rubyCalled = true;
          return _jsonResp({
            'lines': [
              {
                'id': 'ruby-1',
                'startTimeMs': 8000,
                'endTimeMs': 14000,
                'kind': 'lyric',
                'text': {
                  'original': '星空を見上げて',
                  'ruby': '<ruby>星空<rt>ほしぞら</rt></ruby>を<ruby>見上<rt>みあ</rt></ruby>げて',
                  'romaji': 'hoshizora wo miagete',
                  'translation': '仰望星空',
                },
              },
            ],
          });
        }
        return http.Response('Not found', 404);
      });

      final neteaseHttp = MockClient((req) async {
        final path = req.url.path;
        if (path == '/eapi/w/nuser/account/get') {
          return _jsonResp({'code': 200, 'profile': {'nickname': 'HybridUser'}});
        }
        if (path == '/eapi/cloudsearch/pc') {
          return _jsonResp({
            'code': 200,
            'result': {
              'songs': [
                {
                  'id': 556677,
                  'name': 'Hybrid Ruby Track',
                  'ar': [
                    {'name': 'Ruby Unit'},
                  ],
                  'dt': 40000,
                },
              ],
            },
          });
        }
        if (path == '/eapi/song/lyric/v1') {
          return _jsonResp({
            'code': 200,
            'lrc': {'lyric': '[00:08.00] 星空を見上げて'},
            'tlyric': {'lyric': '[00:08.00] 仰望星空'},
          });
        }
        if (path == '/eapi/v3/song/detail') {
          return _jsonResp({
            'code': 200,
            'songs': [
              {'id': 556677, 'name': 'Hybrid Ruby Track', 'dt': 40000},
            ],
          });
        }
        if (path == '/eapi/song/enhance/player/url/v1') {
          return _jsonResp({'code': 200, 'data': []});
        }
        return http.Response('Not found', 404);
      });

      final controller = CallbookController(
        apiClient: CallbookApiClient(
          baseUrl: 'http://127.0.0.1:8000',
          httpClient: hybridBackend,
        ),
        neteaseDirectClient: NeteaseDirectClient(httpClient: neteaseHttp),
        lrclibDirectClient: LrclibDirectClient(
          httpClient: MockClient((_) async => _jsonResp([])),
        ),
        enableAudioOutput: false,
      );
      try {
        await controller.init();
        expect(controller.backendOnline, isTrue);

        final ok = await controller.oneClickConfigureAndStartGateway(
          cookie: 'hybridcookie999999',
        );
        expect(ok, isTrue);
        expect(controller.gatewayStatus.neteaseAccount, 'HybridUser');

        await controller.searchTracks('Ruby', source: 'custom_proxy');
        expect(controller.searchResults.length, 1);
        expect(controller.searchResults.first.provider, 'netease_direct');

        await controller.loadRemoteTrack(controller.searchResults.first);
        expect(rubyCalled, isTrue);
        final lyric = controller.sortedLines.firstWhere(
          (l) => l.kind == LyricLineKind.lyric,
        );
        expect(lyric.text.ruby, contains('<ruby>'));
        expect(lyric.text.romaji, 'hoshizora wo miagete');
      } finally {
        controller.dispose();
      }
    });

    testWidgets(
      'Dashboard UI shows pure-Dart direct labels and hides legacy Node-required errors',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = CallbookController(
          apiClient: CallbookApiClient(
            baseUrl: 'http://127.0.0.1:8000',
            httpClient: MockClient((_) async => http.Response('offline', 503)),
          ),
          neteaseDirectClient: NeteaseDirectClient(
            httpClient: MockClient((_) async => _jsonResp({'code': 200})),
          ),
          lrclibDirectClient: LrclibDirectClient(
            httpClient: MockClient((_) async => _jsonResp([])),
          ),
          enableAudioOutput: false,
        );
        await controller.init();
        final captured = <FlutterErrorDetails>[];
        final prevOnError = FlutterError.onError;
        FlutterError.onError = (details) => captured.add(details);
        try {
          tester.view.physicalSize = const Size(1280, 820);
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpWidget(LiveCallStudioApp(controller: controller));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));

          expect(captured, isEmpty);
          expect(tester.takeException(), isNull);
          expect(find.text('纯 Dart 直连'), findsAtLeastNWidgets(1));
          expect(find.text('网易云直连'), findsOneWidget);
          expect(find.text('验证并保存 Cookie（纯 Dart 直连）'), findsOneWidget);
          expect(find.textContaining('未检测到 Node.js'), findsNothing);
        } finally {
          FlutterError.onError = prevOnError;
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );

    testWidgets(
      'Mobile 390x844 DashboardView direct Netease card renders with ZERO overflows even when Cookie & Chips are present',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final controller = CallbookController(
          apiClient: CallbookApiClient(
            baseUrl: 'http://127.0.0.1:8000',
            httpClient: MockClient((_) async => http.Response('offline', 503)),
          ),
          neteaseDirectClient: NeteaseDirectClient(
            httpClient: MockClient((req) async {
              if (req.url.path == '/eapi/w/nuser/account/get') {
                return _jsonResp({
                  'code': 200,
                  'profile': {'nickname': 'MobileMikuTester'},
                });
              }
              return _jsonResp({'code': 200});
            }),
          ),
          lrclibDirectClient: LrclibDirectClient(
            httpClient: MockClient((_) async => _jsonResp([])),
          ),
          enableAudioOutput: false,
        );
        await controller.init();
        await controller.oneClickConfigureAndStartGateway(
          cookie: 'mobilecookie9876543210',
        );

        final captured = <FlutterErrorDetails>[];
        final prevOnError = FlutterError.onError;
        FlutterError.onError = (details) => captured.add(details);
        try {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpWidget(LiveCallStudioApp(controller: controller));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));

          final target = find.text('验证并保存 Cookie（纯 Dart 直连）');
          await tester.scrollUntilVisible(
            target,
            240,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pump();

          expect(captured, isEmpty);
          expect(tester.takeException(), isNull);
          expect(find.text('网易云直连 & 可选后端服务'), findsOneWidget);
          expect(find.text('已登录: MobileMikuTester'), findsOneWidget);
          expect(find.text('检测直连状态'), findsOneWidget);
          expect(target, findsOneWidget);
        } finally {
          FlutterError.onError = prevOnError;
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );
  });
}
