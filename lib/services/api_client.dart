import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../models/callbook_models.dart';

class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.label,
    required this.enabled,
  });

  final String id;
  final String label;
  final bool enabled;

  factory ProviderInfo.fromJson(Map<String, dynamic> json) => ProviderInfo(
    id: json['id']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
    enabled: json['enabled'] == true,
  );
}

class HealthInfo {
  const HealthInfo({
    required this.online,
    required this.customProxyEnabled,
    this.providers = const [],
  });

  final bool online;
  final bool customProxyEnabled;
  final List<String> providers;
}

class GatewayStatusInfo {
  const GatewayStatusInfo({
    this.gatewayUrl = 'http://127.0.0.1:3000',
    this.gatewayOnline = false,
    this.customProxyEnabled = false,
    this.cookieConfigured = false,
    this.cookieMasked = '',
    this.managedByBackend = false,
    this.pid,
    this.canSpawnLocal = false,
    this.nodeAvailable = false,
    this.packageAvailable = false,
    this.neteaseAccount,
    this.message = '未检测网关状态',
  });

  final String gatewayUrl;
  final bool gatewayOnline;
  final bool customProxyEnabled;
  final bool cookieConfigured;
  final String cookieMasked;
  final bool managedByBackend;
  final int? pid;
  final bool canSpawnLocal;
  final bool nodeAvailable;
  final bool packageAvailable;
  final String? neteaseAccount;
  final String message;

  GatewayStatusInfo copyWith({
    String? gatewayUrl,
    bool? gatewayOnline,
    bool? customProxyEnabled,
    bool? cookieConfigured,
    String? cookieMasked,
    bool? managedByBackend,
    int? pid,
    bool? canSpawnLocal,
    bool? nodeAvailable,
    bool? packageAvailable,
    String? neteaseAccount,
    String? message,
  }) => GatewayStatusInfo(
    gatewayUrl: gatewayUrl ?? this.gatewayUrl,
    gatewayOnline: gatewayOnline ?? this.gatewayOnline,
    customProxyEnabled: customProxyEnabled ?? this.customProxyEnabled,
    cookieConfigured: cookieConfigured ?? this.cookieConfigured,
    cookieMasked: cookieMasked ?? this.cookieMasked,
    managedByBackend: managedByBackend ?? this.managedByBackend,
    pid: pid ?? this.pid,
    canSpawnLocal: canSpawnLocal ?? this.canSpawnLocal,
    nodeAvailable: nodeAvailable ?? this.nodeAvailable,
    packageAvailable: packageAvailable ?? this.packageAvailable,
    neteaseAccount: neteaseAccount ?? this.neteaseAccount,
    message: message ?? this.message,
  );

  factory GatewayStatusInfo.fromJson(Map<String, dynamic> json) =>
      GatewayStatusInfo(
        gatewayUrl: json['gatewayUrl']?.toString() ?? 'http://127.0.0.1:3000',
        gatewayOnline: json['gatewayOnline'] == true,
        customProxyEnabled: json['customProxyEnabled'] == true,
        cookieConfigured: json['cookieConfigured'] == true,
        cookieMasked: json['cookieMasked']?.toString() ?? '',
        managedByBackend: json['managedByBackend'] == true,
        pid: (json['pid'] as num?)?.toInt(),
        canSpawnLocal: json['canSpawnLocal'] == true,
        nodeAvailable: json['nodeAvailable'] == true,
        packageAvailable: json['packageAvailable'] == true,
        neteaseAccount: json['neteaseAccount']?.toString(),
        message: json['message']?.toString() ?? '',
      );
}

class CallbookApiClient {
  CallbookApiClient({String? baseUrl, http.Client? httpClient})
    : _baseUrl = _normalizeBaseUrl(baseUrl ?? defaultBaseUrl()),
      _http = httpClient ?? http.Client();

  String _baseUrl;
  final http.Client _http;

  String get baseUrl => _baseUrl;

  void setBaseUrl(String next) {
    _baseUrl = _normalizeBaseUrl(next);
  }

  /// Desktop (Windows/macOS/Linux) hits localhost; Android Emulator maps host loopback to 10.0.2.2.
  static String defaultBaseUrl() {
    if (!kIsWeb && Platform.isAndroid) {
      return 'http://10.0.2.2:8000';
    }
    return 'http://127.0.0.1:8000';
  }

  static String _normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return defaultBaseUrl();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  Future<HealthInfo> checkHealth() async {
    try {
      final resp = await _http
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) {
        return const HealthInfo(online: false, customProxyEnabled: false);
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final rawProviders = body['providers'] as List<dynamic>? ?? const [];
      return HealthInfo(
        online: body['status'] == 'ok',
        customProxyEnabled: body['customProxyEnabled'] == true,
        providers: [for (final p in rawProviders) p.toString()],
      );
    } catch (_) {
      return const HealthInfo(online: false, customProxyEnabled: false);
    }
  }

  Future<List<ProviderInfo>> fetchProviders() async {
    final resp = await _http
        .get(Uri.parse('$_baseUrl/api/providers'))
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) {
      throw Exception('Failed to fetch providers (${resp.statusCode})');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = body['providers'] as List<dynamic>? ?? const [];
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) ProviderInfo.fromJson(item),
    ];
  }

  Future<GatewayStatusInfo?> fetchGatewayStatus() async {
    try {
      final resp = await _http
          .get(Uri.parse('$_baseUrl/api/gateway/status'))
          .timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return null;
      return GatewayStatusInfo.fromJson(
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<GatewayStatusInfo> configureAndStartGateway({
    required String neteaseCookie,
    String gatewayUrl = 'http://127.0.0.1:3000',
    bool autoStart = true,
    bool clearCookie = false,
  }) async {
    final resp = await _http
        .post(
          Uri.parse('$_baseUrl/api/gateway/configure'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'neteaseCookie': neteaseCookie,
            'gatewayUrl': gatewayUrl,
            'autoStart': autoStart,
            'clearCookie': clearCookie,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw Exception('网关配置失败 (${resp.statusCode}): ${resp.body}');
    }
    return GatewayStatusInfo.fromJson(
      jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>,
    );
  }

  Future<GatewayStatusInfo> stopGateway() async {
    final resp = await _http
        .post(Uri.parse('$_baseUrl/api/gateway/stop'))
        .timeout(const Duration(seconds: 6));
    if (resp.statusCode != 200) {
      throw Exception('停止网关失败 (${resp.statusCode})');
    }
    return GatewayStatusInfo.fromJson(
      jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>,
    );
  }

  Future<SearchResponse> searchTracks(
    String query, {
    String source = 'auto',
    int limit = 12,
  }) async {
    final uri = Uri.parse('$_baseUrl/api/search').replace(
      queryParameters: {
        'q': query.trim(),
        'source': source,
        'limit': '$limit',
      },
    );
    final resp = await _http.get(uri).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception('Search failed (${resp.statusCode})');
    }
    return SearchResponse.fromJson(
      jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>,
    );
  }

  Future<TrackDetailResponse> fetchTrackDetail(
    String provider,
    String trackId,
  ) async {
    final resp = await _http
        .get(Uri.parse('$_baseUrl/api/track/$provider/$trackId'))
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) {
      throw Exception('Fetch track detail failed (${resp.statusCode})');
    }
    return TrackDetailResponse.fromJson(
      jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>,
    );
  }

  Future<List<LyricLine>> parseLyricsWithRuby({
    required String lrc,
    String translationLrc = '',
    bool enableRuby = true,
    bool forceJapaneseRuby = false,
  }) async {
    final resp = await _http
        .post(
          Uri.parse('$_baseUrl/api/lyrics/parse'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'lrc': lrc,
            'translationLrc': translationLrc,
            'enableRuby': enableRuby,
            'forceJapaneseRuby': forceJapaneseRuby,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception('Parse lyrics failed (${resp.statusCode})');
    }
    final data =
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final rawLines = data['lines'] as List<dynamic>? ?? const [];
    return [
      for (final item in rawLines)
        if (item is Map<String, dynamic>) LyricLine.fromJson(item),
    ];
  }

  /// Fetch persisted website text overrides keyed by original copy for cross-client sync.
  Future<Map<String, String>> fetchSiteCopyOverrides() async {
    try {
      final resp = await _http
          .get(Uri.parse('$_baseUrl/api/site-copy'))
          .timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return const {};
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final entries = data['entries'];
      if (entries is! Map) return const {};
      final out = <String, String>{};
      for (final rawEntry in entries.values) {
        if (rawEntry is Map) {
          final original = rawEntry['original']?.toString().trim() ?? '';
          final value = rawEntry['value']?.toString().trim() ?? '';
          if (original.isNotEmpty && value.isNotEmpty && value != original) {
            out[original] = value;
          }
        }
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  void dispose() {
    _http.close();
  }
}
