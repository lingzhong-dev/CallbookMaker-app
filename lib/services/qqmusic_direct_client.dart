import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/callbook_models.dart';
import '../utils/lrc_ruby_parser.dart';

/// Strict error/status classifications for QQ Music pure-Dart requests.
enum QqMusicErrorKind {
  noResults,
  networkOrServiceFailure,
  badPayloadOrBase64OrNonLrc,
  noLyrics,
  noTranslation,
  noAudio,
}

class QqMusicApiException implements Exception {
  const QqMusicApiException(
    this.kind,
    this.message, {
    this.retryable = false,
  });

  final QqMusicErrorKind kind;
  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

/// Pure-Dart QQ Music client for explicitly requested song search, normal LRC
/// lyrics, and Chinese translation without preview clip audio pollution.
class QqMusicDirectClient {
  QqMusicDirectClient({
    String searchUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg',
    String lyricUrl =
        'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg',
    http.Client? httpClient,
    int maxRetries = 2,
    Duration requestTimeout = const Duration(seconds: 8),
    Duration retryDelay = const Duration(milliseconds: 120),
  }) : _searchUrl = searchUrl.trim(),
       _lyricUrl = lyricUrl.trim(),
       _http = httpClient ?? http.Client(),
       _maxRetries = maxRetries < 0 ? 0 : maxRetries,
       _requestTimeout = requestTimeout,
       _retryDelay = retryDelay;

  static const String platformId = 'qqmusic';
  static const String providerId = 'qqmusic_direct';

  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const Map<String, String> _defaultHeaders = <String, String>{
    'User-Agent': _defaultUserAgent,
    'Referer': 'https://y.qq.com/',
    'Origin': 'https://y.qq.com',
  };

  static final RegExp _lrcTimestampPattern = RegExp(
    r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]',
  );
  static final RegExp _qrcWordTimingPattern = RegExp(r'\[\d+,\d+\]');
  static const Set<int> _transientUpstreamCodes = <int>{-1, 100001, 500001};
  static const Set<int> _noLyricsCodes = <int>{-1901, 1310};

  final String _searchUrl;
  final String _lyricUrl;
  final http.Client _http;
  final int _maxRetries;
  final Duration _requestTimeout;
  final Duration _retryDelay;
  bool _disposed = false;

  /// Converts QQ Music interval duration in seconds to integer milliseconds.
  static int secondsToDurationMs(num? seconds) =>
      seconds == null ? 0 : math.max(0, (seconds * 1000).round());

  static String? _nonEmptyTrimmed(Object? raw) {
    final value = raw?.toString().trim() ?? '';
    return value.isEmpty ? null : value;
  }

  static int? _parseInt(Object? raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString().trim() ?? '');
  }

  Future<T> _executeWithRetry<T>(Future<T> Function() action) async {
    var attempt = 0;
    while (true) {
      try {
        return await action();
      } on QqMusicApiException catch (err) {
        if (err.retryable &&
            attempt < _maxRetries &&
            !_disposed) {
          attempt++;
          if (_retryDelay > Duration.zero) {
            await Future<void>.delayed(_retryDelay);
          }
          continue;
        }
        rethrow;
      } on TimeoutException {
        if (attempt < _maxRetries && !_disposed) {
          attempt++;
          if (_retryDelay > Duration.zero) {
            await Future<void>.delayed(_retryDelay);
          }
          continue;
        }
        throw const QqMusicApiException(
          QqMusicErrorKind.networkOrServiceFailure,
          'QQ 音乐请求超时',
        );
      } on http.ClientException catch (err) {
        if (attempt < _maxRetries && !_disposed) {
          attempt++;
          if (_retryDelay > Duration.zero) {
            await Future<void>.delayed(_retryDelay);
          }
          continue;
        }
        throw QqMusicApiException(
          QqMusicErrorKind.networkOrServiceFailure,
          'QQ 音乐网络连接失败：${err.message}',
        );
      }
    }
  }

  TrackSummary? _mapSongItemToSummary(Object? rawItem) {
    if (rawItem is! Map<dynamic, dynamic>) return null;
    final item = Map<String, dynamic>.from(rawItem);
    final songmid =
        _nonEmptyTrimmed(item['mid']) ?? _nonEmptyTrimmed(item['songmid']);
    final songid = _parseInt(item['id']) ?? _parseInt(item['songid']);
    final fileMap = item['file'] is Map
        ? Map<String, dynamic>.from(item['file'] as Map)
        : null;
    final mediaMid =
        _nonEmptyTrimmed(fileMap?['media_mid']) ??
        _nonEmptyTrimmed(item['media_mid']) ??
        _nonEmptyTrimmed(item['strMediaMid']);

    final primaryId = songmid ?? (songid?.toString() ?? '');
    if (primaryId.isEmpty) return null;

    final rawTitle =
        _nonEmptyTrimmed(item['title']) ??
        _nonEmptyTrimmed(item['name']) ??
        _nonEmptyTrimmed(item['songname']);

    final singerList = item['singer'];
    final artistNames = <String>[];
    if (singerList is List) {
      for (final s in singerList) {
        if (s is Map) {
          final name = _nonEmptyTrimmed(s['name']);
          if (name != null) artistNames.add(name);
        }
      }
    }
    final artist = artistNames.isNotEmpty
        ? artistNames.join(' / ')
        : (_nonEmptyTrimmed(item['artist']) ?? 'Unknown Artist');

    final albumObj = item['album'];
    final album = albumObj is Map
        ? (_nonEmptyTrimmed(albumObj['name']) ?? '')
        : (_nonEmptyTrimmed(item['albumname']) ?? '');

    final intervalNum =
        (item['interval'] as num?) ?? num.tryParse('${item['interval'] ?? ''}');
    final durationMs = secondsToDurationMs(intervalNum);

    final tryEnd = _parseInt(item['try_end']) ?? 0;
    final playability = tryEnd > 0
        ? AudioPlayability.previewClip
        : AudioPlayability.unknown;

    return TrackSummary(
      id: primaryId,
      platform: platformId,
      title: rawTitle ?? 'Untitled',
      artist: artist,
      album: album,
      durationMs: durationMs,
      bpm: null,
      hasSyncedLyrics: true,
      hasAudioUrl: false,
      provider: providerId,
      songmid: songmid,
      songid: songid,
      mediaMid: mediaMid,
      audioPlayability: playability,
    );
  }

  /// Searches QQ Music catalog explicitly without triggering preview audio.
  Future<List<TrackSummary>> searchTracks(
    String query, {
    int limit = 12,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return const [];

    return _executeWithRetry<List<TrackSummary>>(() async {
      final body = jsonEncode(<String, Object?>{
        'comm': const <String, Object?>{'ct': 24, 'cv': 0},
        'req': <String, Object?>{
          'module': 'music.search.SearchCgiService',
          'method': 'DoSearchForQQMusicDesktop',
          'param': <String, Object?>{
            'query': cleanQuery,
            'page_num': 1,
            'num_per_page': limit,
            'search_type': 0,
          },
        },
      });
      final resp = await _http
          .post(
            Uri.parse(_searchUrl),
            headers: <String, String>{
              ..._defaultHeaders,
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: body,
          )
          .timeout(_requestTimeout);

      if (resp.statusCode == 429 || resp.statusCode >= 500) {
        throw QqMusicApiException(
          QqMusicErrorKind.networkOrServiceFailure,
          'QQ 音乐搜索服务暂不可用 (HTTP ${resp.statusCode})',
          retryable: true,
        );
      }
      if (resp.statusCode != 200) {
        throw QqMusicApiException(
          QqMusicErrorKind.networkOrServiceFailure,
          'QQ 音乐搜索失败 (HTTP ${resp.statusCode})',
        );
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      } on FormatException {
        throw const QqMusicApiException(
          QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
          'QQ 音乐搜索返回了无效 JSON',
        );
      }
      if (decoded is! Map<dynamic, dynamic>) {
        throw const QqMusicApiException(
          QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
          'QQ 音乐搜索响应结构异常',
        );
      }

      final topCode = _parseInt(decoded['code']) ?? 0;
      if (topCode != 0) {
        throw QqMusicApiException(
          QqMusicErrorKind.networkOrServiceFailure,
          'QQ 音乐搜索接口错误 (code=$topCode)',
          retryable: _transientUpstreamCodes.contains(topCode),
        );
      }

      final reqNode = decoded['req'];
      List<dynamic>? songList;
      if (reqNode is Map) {
        final reqCode = _parseInt(reqNode['code']) ?? 0;
        if (reqCode != 0) {
          throw QqMusicApiException(
            QqMusicErrorKind.networkOrServiceFailure,
            'QQ 音乐搜索子请求错误 (code=$reqCode)',
            retryable: _transientUpstreamCodes.contains(reqCode),
          );
        }
        final dataNode = reqNode['data'];
        if (dataNode is! Map) {
          throw const QqMusicApiException(
            QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
            'QQ 音乐搜索缺少 data 字段',
          );
        }
        final bodyNode = dataNode['body'];
        if (bodyNode is! Map) {
          throw const QqMusicApiException(
            QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
            'QQ 音乐搜索缺少 body 字段',
          );
        }
        final songNode = bodyNode['song'];
        if (songNode == null) {
          songList = const [];
        } else if (songNode is! Map || songNode['list'] is! List) {
          throw const QqMusicApiException(
            QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
            'QQ 音乐搜索歌曲列表结构异常',
          );
        } else {
          songList = songNode['list'] as List<dynamic>;
        }
      } else if (decoded['data'] is Map &&
          (decoded['data'] as Map)['song'] is Map &&
          ((decoded['data'] as Map)['song'] as Map)['list'] is List) {
        songList =
            ((decoded['data'] as Map)['song'] as Map)['list'] as List<dynamic>;
      } else {
        throw const QqMusicApiException(
          QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
          'QQ 音乐搜索响应缺少结果节点',
        );
      }

      final mapped = <TrackSummary>[];
      for (final item in songList.take(limit)) {
        final summary = _mapSongItemToSummary(item);
        if (summary != null) {
          mapped.add(summary);
        }
      }
      return mapped;
    });
  }

  static String _decodeStrictBase64Utf8(
    String raw, {
    required String label,
  }) {
    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return '';
    try {
      final bytes = base64.decode(compact);
      return utf8.decode(bytes);
    } on FormatException {
      throw QqMusicApiException(
        QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
        'QQ 音乐$label Base64/UTF-8 解码失败',
      );
    }
  }

  static void _validateNormalLrcFormat(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const QqMusicApiException(
        QqMusicErrorKind.noLyrics,
        '该曲目在 QQ 音乐暂无歌词',
      );
    }
    if (trimmed.contains('<?xml') ||
        trimmed.contains('<QrcInfos') ||
        trimmed.contains('<LyricInfo') ||
        trimmed.contains('<Lyric_') ||
        trimmed.contains('LyricContent=')) {
      throw const QqMusicApiException(
        QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
        'QQ 音乐返回了 QRC/XML 非普通 LRC 格式，首版暂不支持',
      );
    }
    final hasStandardLrcTimestamp = _lrcTimestampPattern.hasMatch(trimmed);
    if (!hasStandardLrcTimestamp) {
      if (_qrcWordTimingPattern.hasMatch(trimmed)) {
        throw const QqMusicApiException(
          QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
          'QQ 音乐返回了逐字 QRC 格式，首版仅支持普通 LRC',
        );
      }
      throw const QqMusicApiException(
        QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
        'QQ 音乐返回内容不是标准时间戳 LRC 格式',
      );
    }
  }

  /// Fetches normal LRC lyrics and optional Chinese translation for a QQ Music track.
  Future<TrackDetailResponse> fetchTrackDetail(
    String trackId, {
    String? songmid,
    int? songid,
    String? mediaMid,
    TrackSummary? fallbackSummary,
  }) async {
    final resolvedMid =
        _nonEmptyTrimmed(songmid) ??
        _nonEmptyTrimmed(fallbackSummary?.songmid) ??
        trackId.trim();
    final resolvedSongId = songid ?? fallbackSummary?.songid;
    final resolvedMediaMid =
        _nonEmptyTrimmed(mediaMid) ?? _nonEmptyTrimmed(fallbackSummary?.mediaMid);

    if (resolvedMid.isEmpty && resolvedSongId == null) {
      throw const QqMusicApiException(
        QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
        'QQ 音乐曲目标识缺失',
      );
    }

    return _executeWithRetry<TrackDetailResponse>(() async {
      final queryParams = <String, String>{
        if (resolvedMid.isNotEmpty) 'songmid': resolvedMid,
        if (resolvedSongId != null) 'musicid': '$resolvedSongId',
        'format': 'json',
        'nobase64': '0',
        'g_tk': '5381',
        'inCharset': 'utf8',
        'outCharset': 'utf-8',
      };
      final uri = Uri.parse(_lyricUrl).replace(queryParameters: queryParams);
      final resp = await _http
          .get(uri, headers: _defaultHeaders)
          .timeout(_requestTimeout);

      if (resp.statusCode == 429 || resp.statusCode >= 500) {
        throw QqMusicApiException(
          QqMusicErrorKind.networkOrServiceFailure,
          'QQ 音乐歌词服务暂不可用 (HTTP ${resp.statusCode})',
          retryable: true,
        );
      }
      if (resp.statusCode != 200) {
        throw QqMusicApiException(
          QqMusicErrorKind.networkOrServiceFailure,
          'QQ 音乐获取歌词失败 (HTTP ${resp.statusCode})',
        );
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      } on FormatException {
        throw const QqMusicApiException(
          QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
          'QQ 音乐歌词返回了无效 JSON',
        );
      }
      if (decoded is! Map<dynamic, dynamic>) {
        throw const QqMusicApiException(
          QqMusicErrorKind.badPayloadOrBase64OrNonLrc,
          'QQ 音乐歌词响应结构异常',
        );
      }

      final retcode =
          _parseInt(decoded['retcode']) ?? _parseInt(decoded['code']) ?? 0;
      if (_noLyricsCodes.contains(retcode)) {
        throw const QqMusicApiException(
          QqMusicErrorKind.noLyrics,
          '该曲目在 QQ 音乐暂无歌词',
        );
      }
      if (retcode != 0) {
        final transient = _transientUpstreamCodes.contains(retcode);
        throw QqMusicApiException(
          QqMusicErrorKind.networkOrServiceFailure,
          transient
              ? 'QQ 音乐歌词服务繁忙 (code=$retcode)'
              : 'QQ 音乐歌词接口错误 (code=$retcode)',
          retryable: transient,
        );
      }

      final rawBase64Lyric = decoded['lyric']?.toString() ?? '';
      if (rawBase64Lyric.trim().isEmpty) {
        throw const QqMusicApiException(
          QqMusicErrorKind.noLyrics,
          '该曲目在 QQ 音乐暂无歌词',
        );
      }

      final rawLrc = _decodeStrictBase64Utf8(rawBase64Lyric, label: '原词');
      _validateNormalLrcFormat(rawLrc);

      final rawBase64Trans = decoded['trans']?.toString() ?? '';
      final translatedLrc = rawBase64Trans.trim().isEmpty
          ? ''
          : _decodeStrictBase64Utf8(rawBase64Trans, label: '译文');

      final rawAudioUrl = _nonEmptyTrimmed(decoded['audioUrl']) ?? '';
      final rawPlayability = decoded['audioPlayability']?.toString();
      final playability = rawPlayability != null
          ? AudioPlayability.fromJson(rawPlayability)
          : AudioPlayability.unplayable;

      final lines = parseLrcOffline(rawLrc, translationLrc: translatedLrc);
      final summary = TrackSummary(
        id: resolvedMid.isNotEmpty ? resolvedMid : '${resolvedSongId ?? ''}',
        platform: platformId,
        title: fallbackSummary?.title ?? 'QQ Music Track',
        artist: fallbackSummary?.artist ?? 'Unknown Artist',
        album: fallbackSummary?.album ?? '',
        durationMs: fallbackSummary?.durationMs ?? 0,
        bpm: fallbackSummary?.bpm,
        hasSyncedLyrics: true,
        hasAudioUrl:
            rawAudioUrl.isNotEmpty && playability == AudioPlayability.full,
        provider: providerId,
        songmid: resolvedMid.isNotEmpty ? resolvedMid : null,
        songid: resolvedSongId,
        mediaMid: resolvedMediaMid,
        audioPlayability: playability,
      );

      return TrackDetailResponse(
        track: summary,
        audioUrl: playability == AudioPlayability.full ? rawAudioUrl : '',
        audioPlayability: playability,
        rawLrc: rawLrc,
        translatedLrc: translatedLrc,
        lines: lines,
      );
    });
  }

  void dispose() {
    _disposed = true;
    _http.close();
  }
}
