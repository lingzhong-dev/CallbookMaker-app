import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/callbook_models.dart';
import '../utils/lrc_ruby_parser.dart';

/// Pure-Dart open lyrics client backed by LRCLIB (https://lrclib.net).
class LrclibDirectClient {
  LrclibDirectClient({
    String baseUrl = 'https://lrclib.net',
    http.Client? httpClient,
  }) : _baseUrl = _stripTrailingSlash(baseUrl),
       _http = httpClient ?? http.Client();

  static const String _userAgent =
      'CallbookMaker/1.0.2 (https://github.com/lingzhong-dev/CallbookMaker-app)';

  final String _baseUrl;
  final http.Client _http;

  static String _stripTrailingSlash(String raw) {
    final trimmed = raw.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  TrackSummary _toSummary(Map<String, dynamic> item) {
    final durationSec = (item['duration'] as num?)?.toDouble() ?? 0.0;
    final synced = (item['syncedLyrics']?.toString().trim().isNotEmpty) ?? false;
    final rawTitle = (item['trackName'] ?? item['name'])?.toString().trim() ?? '';
    final rawArtist = item['artistName']?.toString().trim() ?? '';
    return TrackSummary(
      id: item['id']?.toString() ?? '',
      platform: 'lrclib',
      title: rawTitle.isNotEmpty ? rawTitle : 'Untitled',
      artist: rawArtist.isNotEmpty ? rawArtist : 'Unknown Artist',
      album: item['albumName']?.toString() ?? '',
      durationMs: (durationSec * 1000).round(),
      bpm: null,
      hasSyncedLyrics: synced,
      hasAudioUrl: false,
      provider: 'lrclib',
    );
  }

  Future<List<TrackSummary>> searchTracks(
    String query, {
    int limit = 12,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final uri = Uri.parse('$_baseUrl/api/search').replace(
      queryParameters: <String, String>{'q': q},
    );
    final resp = await _http
        .get(uri, headers: const <String, String>{'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception('LRCLIB 搜索失败 (HTTP ${resp.statusCode})');
    }
    final payload = jsonDecode(utf8.decode(resp.bodyBytes));
    if (payload is! List<dynamic>) return const [];

    return [
      for (final item in payload.take(limit))
        if (item is Map<String, dynamic> &&
            (item['id']?.toString().isNotEmpty ?? false))
          _toSummary(item),
    ];
  }

  Future<TrackDetailResponse> fetchTrackDetail(String trackId) async {
    final cleanId = trackId.trim();
    if (cleanId.isEmpty) {
      throw Exception('LRCLIB 曲目 ID 不能为空');
    }
    final resp = await _http
        .get(
          Uri.parse('$_baseUrl/api/get/$cleanId'),
          headers: const <String, String>{'User-Agent': _userAgent},
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 404) {
      throw Exception('LRCLIB 未找到曲目 ($cleanId)');
    }
    if (resp.statusCode != 200) {
      throw Exception('LRCLIB 获取歌词失败 (HTTP ${resp.statusCode})');
    }
    final item = jsonDecode(utf8.decode(resp.bodyBytes));
    if (item is! Map<String, dynamic>) {
      throw Exception('LRCLIB 响应格式异常');
    }

    final summary = _toSummary(item);
    final rawLrc =
        (item['syncedLyrics'] ?? item['plainLyrics'])?.toString() ?? '';
    final lines = parseLrcOffline(rawLrc);

    return TrackDetailResponse(
      track: summary,
      audioUrl: '',
      audioPlayability: AudioPlayability.unplayable,
      rawLrc: rawLrc,
      translatedLrc: '',
      lines: lines,
    );
  }

  void dispose() {
    _http.close();
  }
}
