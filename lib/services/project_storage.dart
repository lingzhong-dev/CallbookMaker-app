import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/callbook_models.dart';

class ProjectStorage {
  static const _projectKey = 'live_call_studio_project_v1';
  static const _presetsKey = 'live_call_studio_custom_presets_v1';
  static const _layersKey = 'live_call_studio_display_layers_v1';
  static const _themeKey = 'live_call_studio_theme_v1';
  static const _backendUrlKey = 'live_call_studio_backend_url_v1';
  static const _gatewayUrlKey = 'live_call_studio_gateway_url_v1';
  static const _neteaseCookieKey = 'live_call_studio_netease_cookie_v1';
  static const _archivesKey = 'live_call_studio_archives_v1';
  static const _archiveSessionKey = 'live_call_studio_archive_session_v1';
  static const _onboardingKey = 'live_call_studio_onboarding_v1';
  static const _cueOutputCompensationMsKey =
      'live_call_studio_cue_output_offset_ms_v1';

  Future<int> loadCueOutputCompensationMs() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_cueOutputCompensationMsKey) ?? 0;
    return clampCueOutputCompensationMs(value);
  }

  Future<void> saveCueOutputCompensationMs(int ms) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _cueOutputCompensationMsKey,
      clampCueOutputCompensationMs(ms),
    );
  }

  Future<bool> hasSavedProjectKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_projectKey);
  }

  Future<bool> loadOnboardingCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_onboardingKey) ?? false;
  }

  Future<void> saveOnboardingCompleted(bool completed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingKey, completed);
  }

  Future<CallProject?> loadProject() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_projectKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return CallProject.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveProject(CallProject project) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_projectKey, jsonEncode(project.toJson()));
  }

  Future<List<CallPreset>> loadCustomPresets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_presetsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final item in list)
          if (item is Map<String, dynamic>) CallPreset.fromJson(item),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveCustomPresets(List<CallPreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _presetsKey,
      jsonEncode([for (final p in presets) p.toJson()]),
    );
  }

  Future<DisplayLayers> loadDisplayLayers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_layersKey);
    if (raw == null || raw.isEmpty) return const DisplayLayers();
    try {
      return DisplayLayers.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const DisplayLayers();
    }
  }

  Future<void> saveDisplayLayers(DisplayLayers layers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_layersKey, jsonEncode(layers.toJson()));
  }

  Future<Map<String, dynamic>?> loadThemePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_themeKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveThemePrefs(Map<String, dynamic> themeJson) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, jsonEncode(themeJson));
  }

  Future<String?> loadBackendUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_backendUrlKey);
  }

  Future<void> saveBackendUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_backendUrlKey, url);
  }

  Future<String?> loadGatewayUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_gatewayUrlKey);
  }

  Future<void> saveGatewayUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_gatewayUrlKey, url);
  }

  Future<String?> loadNeteaseCookie() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_neteaseCookieKey);
  }

  Future<void> saveNeteaseCookie(String cookie) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_neteaseCookieKey, cookie);
  }

  Future<List<CallbookArchiveEntry>> loadArchives() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_archivesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final item in list)
          if (item is Map<String, dynamic>) CallbookArchiveEntry.fromJson(item),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveArchives(List<CallbookArchiveEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _archivesKey,
      jsonEncode([for (final e in entries) e.toJson()]),
    );
  }

  Future<ArchiveSessionState?> loadArchiveSession() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_archiveSessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return ArchiveSessionState.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveArchiveSession(ArchiveSessionState session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_archiveSessionKey, jsonEncode(session.toJson()));
  }
}
