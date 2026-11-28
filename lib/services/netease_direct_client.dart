import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

import '../models/callbook_models.dart';
import '../utils/lrc_ruby_parser.dart';
import '../utils/netease_cookie_utils.dart';

class NeteaseAccountProbeResult {
  const NeteaseAccountProbeResult({
    required this.reachable,
    required this.loggedIn,
    required this.cookieConfigured,
    required this.cookieMasked,
    this.nickname,
    required this.message,
  });

  final bool reachable;
  final bool loggedIn;
  final bool cookieConfigured;
  final String cookieMasked;
  final String? nickname;
  final String message;
}

/// Pure-Dart direct client for Netease Cloud Music EAPI endpoints.
///
/// Requires zero Node.js runtime or local Python proxy server, enabling direct
/// search, synced/translated LRC lyrics, free-tier audio streaming URLs, and
/// optional `MUSIC_U` cookie account verification across Desktop and Mobile.
class NeteaseDirectClient {
  NeteaseDirectClient({
    String baseUrl = 'https://interface.music.163.com',
    http.Client? httpClient,
  }) : _baseUrl = _stripTrailingSlash(baseUrl),
       _http = httpClient ?? http.Client();

  static const String _eapiKey = 'e82ckenh8dichen8';
  static final Uint8List _eapiKeyBytes = Uint8List.fromList(
    utf8.encode(_eapiKey),
  );
  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final String _baseUrl;
  final http.Client _http;

  static String _stripTrailingSlash(String raw) {
    final trimmed = raw.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  /// Encrypts an EAPI payload using MD5 + AES-128-ECB (PKCS7), returning UPPERCASE hex.
  static String eapiEncrypt(String apiPath, Object payload) {
    final text = payload is String ? payload : jsonEncode(payload);
    final message = 'nobody${apiPath}use${text}md5forencrypt';
    final digest = md5.convert(utf8.encode(message)).toString();
    final raw = utf8.encode('$apiPath-36cd479b6b5-$text-36cd479b6b5-$digest');

    const blockSize = 16;
    final padLen = blockSize - (raw.length % blockSize);
    final padded = Uint8List(raw.length + padLen);
    padded.setRange(0, raw.length, raw);
    for (var i = raw.length; i < padded.length; i++) {
      padded[i] = padLen;
    }

    final cipher = ECBBlockCipher(AESEngine())
      ..init(true, KeyParameter(_eapiKeyBytes));
    final out = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += blockSize) {
      cipher.processBlock(padded, offset, out, offset);
    }

    final buf = StringBuffer();
    for (final byte in out) {
      buf.write(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return buf.toString();
  }

  static String _buildCookieHeader(String rawCookie) {
    final norm = normalizeNeteaseCookie(rawCookie);
    if (norm.isEmpty) {
      return 'os=pc; appver=2.9.7';
    }
    final parts = [
      for (final seg in norm.split(';'))
        if (seg.trim().isNotEmpty) seg.trim(),
    ];
    final hasAppver = parts.any((seg) {
      final eq = seg.indexOf('=');
      return eq > 0 && seg.substring(0, eq).trim().toLowerCase() == 'appver';
    });
    if (!hasAppver) {
      parts.add('appver=2.9.7');
    }
    return parts.join('; ');
  }

  Future<Map<String, dynamic>> _postEapi(
    String eapiPath,
    String apiPath,
    Map<String, Object?> payload, {
    String cookie = '',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final fullPayload = <String, Object?>{
      ...payload,
      if (!payload.containsKey('header'))
        'header': jsonEncode(<String, String>{
          'os': 'pc',
          'appver': '2.9.7',
          'channel': 'netease',
          'requestId': '${DateTime.now().millisecondsSinceEpoch}',
        }),
    };
    final encrypted = eapiEncrypt(apiPath, fullPayload);
    final resp = await _http
        .post(
          Uri.parse('$_baseUrl$eapiPath'),
          headers: <String, String>{
            'Content-Type': 'application/x-www-form-urlencoded',
            'Referer': 'https://music.163.com',
            'User-Agent': _defaultUserAgent,
            'Cookie': _buildCookieHeader(cookie),
          },
          body: 'params=$encrypted',
        )
        .timeout(timeout);
    if (resp.statusCode != 200) {
      throw Exception('网易云接口返回 HTTP ${resp.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw Exception('网易云响应格式异常');
    }
    return decoded;
  }

  Future<NeteaseAccountProbeResult> probeAccount({String cookie = ''}) async {
    final normCookie = normalizeNeteaseCookie(cookie);
    final cookieConfigured = normCookie.isNotEmpty;
    final masked = maskNeteaseCookie(normCookie);
    try {
      final res = await _postEapi(
        '/eapi/w/nuser/account/get',
        '/api/w/nuser/account/get',
        const <String, Object?>{},
        cookie: normCookie,
        timeout: const Duration(seconds: 8),
      );
      final code = (res['code'] as num?)?.toInt() ?? 0;
      if (code != 200) {
        return NeteaseAccountProbeResult(
          reachable: false,
          loggedIn: false,
          cookieConfigured: cookieConfigured,
          cookieMasked: masked,
          message: '纯 Dart 网易云检测返回异常状态 (code $code)',
        );
      }

      String? nickname;
      final profile = res['profile'];
      if (profile is Map<String, dynamic>) {
        final rawNick = profile['nickname']?.toString().trim() ?? '';
        if (rawNick.isNotEmpty) nickname = rawNick;
      }
      if (nickname == null) {
        final account = res['account'];
        if (account is Map<String, dynamic>) {
          final rawName = account['userName']?.toString().trim() ?? '';
          if (rawName.isNotEmpty) nickname = rawName;
        }
      }

      if (!cookieConfigured) {
        return const NeteaseAccountProbeResult(
          reachable: true,
          loggedIn: false,
          cookieConfigured: false,
          cookieMasked: '',
          message: '纯 Dart 网易云直连就绪（免登录游客模式 · 可直接搜歌与歌词）',
        );
      }
      if (nickname != null) {
        return NeteaseAccountProbeResult(
          reachable: true,
          loggedIn: true,
          cookieConfigured: true,
          cookieMasked: masked,
          nickname: nickname,
          message: '纯 Dart 直连已验证 · 已登录网易云：$nickname',
        );
      }
      return NeteaseAccountProbeResult(
        reachable: true,
        loggedIn: false,
        cookieConfigured: true,
        cookieMasked: masked,
        message: '纯 Dart 直连已保存 Cookie，但账号未登录（仍可使用游客公开检索）',
      );
    } catch (err) {
      return NeteaseAccountProbeResult(
        reachable: false,
        loggedIn: false,
        cookieConfigured: cookieConfigured,
        cookieMasked: masked,
        message: cookieConfigured
            ? 'Cookie 已保存本地，但检测网易云直连失败：$err'
            : '检测网易云直连失败：$err',
      );
    }
  }

  String _extractArtists(Map<String, dynamic> item) {
    final rawArtists = item['ar'] ?? item['artists'];
    if (rawArtists is List<dynamic> && rawArtists.isNotEmpty) {
      final names = <String>[];
      for (final a in rawArtists) {
        if (a is Map<String, dynamic>) {
          final name = a['name']?.toString().trim() ?? '';
          if (name.isNotEmpty) names.add(name);
        }
      }
      if (names.isNotEmpty) return names.join(' / ');
    }
    final fallback = item['artist']?.toString().trim() ?? '';
    return fallback.isNotEmpty ? fallback : 'Unknown Artist';
  }

  String _extractAlbum(Map<String, dynamic> item) {
    final rawAlbum = item['al'] ?? item['album'];
    if (rawAlbum is Map<String, dynamic>) {
      return rawAlbum['name']?.toString() ?? '';
    }
    return rawAlbum?.toString() ?? '';
  }

  TrackSummary _songToSummary(Map<String, dynamic> item) {
    final durationMs =
        ((item['dt'] ?? item['duration'] ?? item['durationMs']) as num?)
            ?.round() ??
        0;
    return TrackSummary(
      id: item['id']?.toString() ?? '',
      platform: 'netease',
      title: (item['name'] ?? item['title'])?.toString() ?? 'Untitled',
      artist: _extractArtists(item),
      album: _extractAlbum(item),
      durationMs: durationMs,
      bpm: (item['bpm'] as num?)?.round(),
      hasSyncedLyrics: true,
      hasAudioUrl: true,
      provider: 'netease_direct',
    );
  }

  Future<List<TrackSummary>> searchTracks(
    String query, {
    String cookie = '',
    int limit = 12,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final data = await _postEapi(
      '/eapi/cloudsearch/pc',
      '/api/cloudsearch/pc',
      <String, Object?>{
        's': q,
        'type': 1,
        'limit': limit,
        'offset': 0,
        'total': true,
      },
      cookie: cookie,
    );
    final code = (data['code'] as num?)?.toInt() ?? 200;
    if (code != 200) {
      throw Exception('网易云搜索失败 (code $code)');
    }
    final result = data['result'];
    if (result is! Map<String, dynamic>) return const [];
    final songs = result['songs'];
    if (songs is! List<dynamic>) return const [];

    return [
      for (final item in songs.take(limit))
        if (item is Map<String, dynamic> &&
            (item['id']?.toString().isNotEmpty ?? false))
          _songToSummary(item),
    ];
  }

  String _extractLyricField(Map<String, dynamic> data, String key) {
    final section = data[key];
    if (section is Map<String, dynamic>) {
      return section['lyric']?.toString() ?? '';
    }
    return section?.toString() ?? '';
  }

  String _extractAudioUrl(Map<String, dynamic> data) {
    final list = data['data'];
    if (list is List<dynamic> && list.isNotEmpty) {
      final first = list.first;
      if (first is Map<String, dynamic>) {
        final u = first['url']?.toString().trim() ?? '';
        if (u.isNotEmpty) return u;
      }
    }
    return data['url']?.toString().trim() ?? '';
  }

  Future<TrackDetailResponse> fetchTrackDetail(
    String trackId, {
    String cookie = '',
    TrackSummary? fallbackSummary,
  }) async {
    final cleanId = trackId.trim();
    if (cleanId.isEmpty) {
      throw Exception('歌曲 ID 不能为空');
    }

    final numericId = int.tryParse(cleanId);
    final idElement = numericId ?? cleanId;

    final lyricFuture = _postEapi(
      '/eapi/song/lyric/v1',
      '/api/song/lyric/v1',
      <String, Object?>{
        'id': cleanId,
        'cp': false,
        'tv': 0,
        'lv': 0,
        'rv': 0,
        'kv': 0,
        'yv': 0,
        'ytv': 0,
        'yrv': 0,
      },
      cookie: cookie,
    );

    final detailFuture = _postEapi(
          '/eapi/v3/song/detail',
          '/api/v3/song/detail',
          <String, Object?>{
            'c': jsonEncode([
              <String, Object>{'id': idElement},
            ]),
          },
          cookie: cookie,
        )
        .then<Map<String, dynamic>?>((v) => v)
        .catchError((Object _) => null);

    final urlV1Future = _postEapi(
          '/eapi/song/enhance/player/url/v1',
          '/api/song/enhance/player/url/v1',
          <String, Object?>{
            'ids': jsonEncode([cleanId]),
            'level': 'standard',
            'encodeType': 'mp3',
          },
          cookie: cookie,
        )
        .then<Map<String, dynamic>?>((v) => v)
        .catchError((Object _) => null);

    final results = await Future.wait<dynamic>([
      lyricFuture,
      detailFuture,
      urlV1Future,
    ]);

    final lyricData = results[0] as Map<String, dynamic>;
    final detailData = results[1] as Map<String, dynamic>?;
    final urlV1Data = results[2] as Map<String, dynamic>?;

    final rawLrc = _extractLyricField(lyricData, 'lrc');
    final translatedLrc = _extractLyricField(lyricData, 'tlyric');
    final romaLrc = _extractLyricField(lyricData, 'romalrc');

    var audioUrl = urlV1Data != null ? _extractAudioUrl(urlV1Data) : '';
    if (audioUrl.isEmpty) {
      try {
        final urlV0 = await _postEapi(
          '/eapi/song/enhance/player/url',
          '/api/song/enhance/player/url',
          <String, Object?>{
            'ids': jsonEncode([cleanId]),
            'br': 320000,
          },
          cookie: cookie,
        );
        audioUrl = _extractAudioUrl(urlV0);
      } catch (_) {}
    }

    var title = fallbackSummary?.title ?? '';
    var artist = fallbackSummary?.artist ?? '';
    var album = fallbackSummary?.album ?? '';
    var durationMs = fallbackSummary?.durationMs ?? 0;

    final songs = detailData?['songs'];
    if (songs is List<dynamic> && songs.isNotEmpty) {
      final first = songs.first;
      if (first is Map<String, dynamic>) {
        final parsed = _songToSummary(first);
        if (parsed.title.isNotEmpty && parsed.title != 'Untitled') {
          title = parsed.title;
        }
        if (parsed.artist.isNotEmpty && parsed.artist != 'Unknown Artist') {
          artist = parsed.artist;
        }
        if (parsed.album.isNotEmpty) {
          album = parsed.album;
        }
        if (parsed.durationMs > 0) {
          durationMs = parsed.durationMs;
        }
      }
    }

    final lines = parseLrcOffline(
      rawLrc,
      translationLrc: translatedLrc,
      romaLrc: romaLrc,
    );
    final summary = TrackSummary(
      id: cleanId,
      platform: 'netease',
      title: title.isNotEmpty ? title : 'Track $cleanId',
      artist: artist.isNotEmpty ? artist : 'Netease Cloud Music',
      album: album,
      durationMs: durationMs,
      bpm: fallbackSummary?.bpm,
      hasSyncedLyrics: rawLrc.trim().isNotEmpty,
      hasAudioUrl: audioUrl.isNotEmpty,
      provider: 'netease_direct',
    );

    return TrackDetailResponse(
      track: summary,
      audioUrl: audioUrl,
      audioPlayability: audioUrl.isNotEmpty
          ? AudioPlayability.full
          : AudioPlayability.unplayable,
      rawLrc: rawLrc,
      translatedLrc: translatedLrc,
      romaLrc: romaLrc,
      lines: lines,
    );
  }

  void dispose() {
    _http.close();
  }
}
