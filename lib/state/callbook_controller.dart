import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../models/callbook_models.dart';
import '../services/api_client.dart';
import '../services/audio_metronome_service.dart';
import '../services/desktop_service_launcher.dart';
import '../services/lrclib_direct_client.dart';
import '../services/mock_catalog_provider.dart';
import '../services/netease_direct_client.dart';
import '../services/project_storage.dart';
import '../utils/lrc_ruby_parser.dart';
import '../utils/section_detector.dart';

enum StudioRoute { dashboard, export, theme }

class CuratedThemePreset {
  const CuratedThemePreset({
    required this.id,
    required this.name,
    required this.description,
    required this.seedColor,
    required this.mode,
    required this.style,
    this.pureBlack = false,
  });

  final String id;
  final String name;
  final String description;
  final Color seedColor;
  final prism.ThemeMode mode;
  final prism.ColorStyle style;
  final bool pureBlack;
}

const List<CuratedThemePreset> curatedThemePresets = [
  CuratedThemePreset(
    id: 'flclash-azure',
    name: '蔚蓝仪表',
    description: 'Classic #0068FF Vivid',
    seedColor: Color(0xFF0068FF),
    mode: prism.ThemeMode.light,
    style: prism.ColorStyle.vivid,
  ),
  CuratedThemePreset(
    id: 'amber-dark',
    name: '琥珀暗黑',
    description: 'OLED 暗夜打 Call Stage Amber',
    seedColor: Color(0xFFFF9800),
    mode: prism.ThemeMode.dark,
    style: prism.ColorStyle.vivid,
  ),
  CuratedThemePreset(
    id: 'prism-violet',
    name: 'Prism 紫域',
    description: 'M3 Expressive Violet Tinted',
    seedColor: Color(0xFF8B5CF6),
    mode: prism.ThemeMode.light,
    style: prism.ColorStyle.tinted,
  ),
  CuratedThemePreset(
    id: 'emerald-call',
    name: '翡翠应援',
    description: 'Emerald Live Stage',
    seedColor: Color(0xFF009B72),
    mode: prism.ThemeMode.light,
    style: prism.ColorStyle.vivid,
  ),
  CuratedThemePreset(
    id: 'sakura-live',
    name: '樱粉舞台',
    description: 'Sakura Concert Glow',
    seedColor: Color(0xFFEC4899),
    mode: prism.ThemeMode.dark,
    style: prism.ColorStyle.tinted,
    pureBlack: true,
  ),
];

const List<Color> savedSwatchSeeds = [
  Color(0xFF0068FF),
  Color(0xFFFF9800),
  Color(0xFF8B5CF6),
  Color(0xFF009B72),
  Color(0xFFEC4899),
  Color(0xFF06B6D4),
];

class ActiveGtAlertStatus {
  const ActiveGtAlertStatus({
    required this.alert,
    required this.remainingBeats,
    required this.remainingMs,
    required this.isTriggered,
    required this.progress,
    this.targetLineId,
  });

  final GtAlert alert;
  final int remainingBeats;
  final int remainingMs;
  final bool isTriggered;
  final double progress;
  final String? targetLineId;
}

sealed class TimelineItem {
  const TimelineItem(this.sortMs);
  final int sortMs;
}

class TimelineLineItem extends TimelineItem {
  TimelineLineItem(this.line) : super(line.startTimeMs);
  final LyricLine line;
}

class CallbookController extends ChangeNotifier {
  CallbookController({
    CallbookApiClient? apiClient,
    ProjectStorage? storage,
    NeteaseDirectClient? neteaseDirectClient,
    LrclibDirectClient? lrclibDirectClient,
    MockCatalogProvider? mockCatalogProvider,
    DesktopServiceLauncher? desktopLauncher,
    bool enableAudioOutput = true,
  }) : _api = apiClient ?? CallbookApiClient(),
       _storage = storage ?? ProjectStorage(),
       _neteaseDirect = neteaseDirectClient ?? NeteaseDirectClient(),
       _lrclibDirect = lrclibDirectClient ?? LrclibDirectClient(),
       _mockCatalog = mockCatalogProvider ?? const MockCatalogProvider(),
       _desktopLauncher = desktopLauncher ?? DesktopServiceLauncher() {
    _audio = AudioMetronomeService(
      enablePlatformAudio: enableAudioOutput,
      onTimeUpdate: _handleTimeUpdate,
      onBeatTrigger: _handleBeatTrigger,
      onGtAlertBeep: (alertId) => _setStatusInternal(
        'GT 警报提前提示 (${alertId.substring(0, math.min(6, alertId.length))})',
      ),
      onDurationChanged: (durMs) {
        if (_disposed) return;
        if (durMs > 1000 && durMs != _durationMs) {
          _durationMs = durMs;
          _knownAudioDurationMs = durMs;
          detectSections(onlyOutro: true, silent: true);
          _playbackNotifier.notifyListeners();
          notifyListeners();
        }
      },
      onEnded: () {
        if (_disposed) return;
        _isPlaying = false;
        _playbackNotifier.notifyListeners();
        notifyListeners();
      },
    );
    _rebuildProjectCaches();
  }

  late final CallbookApiClient _api;
  late final ProjectStorage _storage;
  late final NeteaseDirectClient _neteaseDirect;
  late final LrclibDirectClient _lrclibDirect;
  late final MockCatalogProvider _mockCatalog;
  late final DesktopServiceLauncher _desktopLauncher;
  late final AudioMetronomeService _audio;

  // Scoped sub-notifiers to keep high-frequency playback/status updates from
  // rebuilding PrismApp, ThemeCrossFade, HomeShell, or the timeline card list.
  final ChangeNotifier _themeNotifier = ChangeNotifier();
  final ChangeNotifier _playbackNotifier = ChangeNotifier();
  final ChangeNotifier _beatNotifier = ChangeNotifier();
  final ValueNotifier<String?> _playingLineIdNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<String?> _activeGtTargetLineIdNotifier =
      ValueNotifier<String?>(null);
  final ValueNotifier<String> _statusNotifier =
      ValueNotifier<String>('已就绪 · CallbookMaker');

  bool _disposed = false;

  CallProject _project = CallProject.demo();
  List<LyricLine> _sortedLinesCache = const [];
  List<GtAlert> _sortedAlertsCache = const [];
  Map<String, GtAlert> _alertByLineIdCache = const {};
  Map<String, String> _alertTargetByIdCache = const {};
  List<TimelineLineItem> _timelineItemsCache = const [];
  String? _playingLineIdCache;
  ActiveGtAlertStatus? _activeGtAlertStatusCache;

  List<CallPreset> _customPresets = const [];
  DisplayLayers _displayLayers = const DisplayLayers();
  String? _activeLineId;
  StudioRoute _route = StudioRoute.dashboard;
  bool _sidebarExpanded = true;

  // Theme State (`FlClashThemeManager` equivalent)
  prism.ThemeMode _themeMode = prism.ThemeMode.system;
  Color _seedColor = const Color(0xFF0068FF);
  prism.ColorStyle _colorStyle = prism.ColorStyle.vivid;
  bool _pureBlack = false;
  bool _liquidGlass = true;
  bool _floatingNavDock = true;
  bool _useGoogleSans = true;
  double _textScale = 1.0;
  prism.ThemeData? _cachedLightTheme;
  prism.ThemeData? _cachedDarkTheme;

  // Audio / Clock State
  bool _isPlaying = false;
  bool _isPracticeMode = false;
  bool _followPlayback = true;
  bool _metronomeEnabled = true;
  bool _gtBeepEnabled = true;
  double _metronomeVolume = 0.95;
  double _playbackRate = 1.0;
  int _currentTimeMs = 0;
  int _durationMs = 48000;
  int _knownAudioDurationMs = 48000;
  SectionDetectThresholds _sectionThresholds = const SectionDetectThresholds();
  int _currentBar = 1;
  int _currentBeatInBar = 1;
  bool _backendOnline = false;
  bool _customProxyEnabled = false;
  bool _isSearching = false;
  bool _isConfiguringGateway = false;
  bool _isLaunchingBackend = false;
  GatewayStatusInfo _gatewayStatus = const GatewayStatusInfo();
  String _savedGatewayUrl = 'http://127.0.0.1:3000';
  String _savedNeteaseCookie = '';
  String _statusMessage = '已就绪 · CallbookMaker';
  List<TrackSummary> _searchResults = const [];
  Map<String, String> _siteCopyByOriginal = const {};
  List<CallbookArchiveEntry> _archives = const [];
  String? _activeArchiveId;
  bool _hasUnsavedChanges = false;
  bool _hasFetchedExternalLyrics = false;

  // Sparkline Histories (`LineChart` data)
  final List<double> _beatPulseSeries = List<double>.filled(24, 0.24, growable: true);
  int _beatSeriesRevision = 0;
  final List<double> _callDensitySeries = List<double>.filled(16, 0.2, growable: true);
  int _callDensityRevision = 0;

  Timer? _persistTimer;

  // Scoped listenables
  Listenable get themeListenable => _themeNotifier;
  Listenable get playbackListenable => _playbackNotifier;
  Listenable get beatListenable => _beatNotifier;
  ValueListenable<String?> get playingLineIdListenable => _playingLineIdNotifier;
  ValueListenable<String?> get activeGtTargetLineIdListenable =>
      _activeGtTargetLineIdNotifier;
  ValueListenable<String> get statusListenable => _statusNotifier;

  // Getters
  CallProject get project => _project;
  List<CallbookArchiveEntry> get archives => List.unmodifiable(_archives);
  List<CallbookArchiveEntry> get sortedArchives {
    final copy = [..._archives]
      ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return copy;
  }
  String? get activeArchiveId => _activeArchiveId;
  CallbookArchiveEntry? get activeArchiveEntry {
    final id = _activeArchiveId;
    if (id == null) return null;
    for (final entry in _archives) {
      if (entry.id == id) return entry;
    }
    return null;
  }
  bool get hasUnsavedChanges => _hasUnsavedChanges;
  bool get hasFetchedExternalLyrics => _hasFetchedExternalLyrics;
  bool get needsSavePromptBeforeSwitch => _activeArchiveId != null
      ? _hasUnsavedChanges
      : (_hasFetchedExternalLyrics || _hasUnsavedChanges);
  List<CallPreset> get allPresets => [...defaultCallPresets, ..._customPresets];
  List<CallPreset> get customPresets => _customPresets;
  DisplayLayers get displayLayers => _displayLayers;
  String? get activeLineId => _activeLineId;
  StudioRoute get route => _route;
  bool get sidebarExpanded => _sidebarExpanded;

  prism.ThemeMode get themeMode => _themeMode;
  Color get seedColor => _seedColor;
  prism.ColorStyle get colorStyle => _colorStyle;
  bool get pureBlack => _pureBlack;
  bool get liquidGlass => _liquidGlass;
  bool get floatingNavDock => _floatingNavDock;
  bool get useGoogleSans => _useGoogleSans;
  double get textScale => _textScale;

  bool get isPlaying => _isPlaying;
  bool get isPracticeMode => _isPracticeMode;
  bool get followPlayback => _followPlayback;
  bool get metronomeEnabled => _metronomeEnabled;
  bool get gtBeepEnabled => _gtBeepEnabled;
  double get metronomeVolume => _metronomeVolume;
  double get playbackRate => _playbackRate;
  int get currentTimeMs => _currentTimeMs;
  int get durationMs => _durationMs;
  int get knownAudioDurationMs => _knownAudioDurationMs;
  SectionDetectThresholds get sectionThresholds => _sectionThresholds;
  ({int intro, int interlude, int outro, int total}) get sectionStats {
    var intro = 0;
    var interlude = 0;
    var outro = 0;
    for (final l in _project.lines) {
      if (l.kind == LyricLineKind.intro) intro++;
      if (l.kind == LyricLineKind.interlude) interlude++;
      if (l.kind == LyricLineKind.outro) outro++;
    }
    return (
      intro: intro,
      interlude: interlude,
      outro: outro,
      total: intro + interlude + outro,
    );
  }
  int get currentBar => _currentBar;
  int get currentBeatInBar => _currentBeatInBar;
  bool get backendOnline => _backendOnline;
  bool get customProxyEnabled => _customProxyEnabled;
  bool get isSearching => _isSearching;
  bool get isConfiguringGateway => _isConfiguringGateway;
  bool get isLaunchingBackend => _isLaunchingBackend;
  bool get isDesktopHost => _desktopLauncher.isDesktop;
  GatewayStatusInfo get gatewayStatus => _gatewayStatus;
  String get savedGatewayUrl => _savedGatewayUrl;
  String get savedNeteaseCookie => _savedNeteaseCookie;
  String get statusMessage => _statusMessage;
  String get backendUrl => _api.baseUrl;
  List<TrackSummary> get searchResults => _searchResults;
  String siteText(String defaultText) => _siteCopyByOriginal[defaultText] ?? defaultText;
  List<double> get beatPulseSeries => List.unmodifiable(_beatPulseSeries);
  int get beatSeriesRevision => _beatSeriesRevision;
  List<double> get callDensitySeries => List.unmodifiable(_callDensitySeries);
  int get callDensityRevision => _callDensityRevision;

  List<LyricLine> get sortedLines => _sortedLinesCache;

  List<GtAlert> get sortedAlerts => _sortedAlertsCache;

  List<TimelineLineItem> get timelineItems => _timelineItemsCache;

  String? get playingLineId => _playingLineIdCache;

  int get taggedLineCount => _project.lines
      .where(
        (l) =>
            l.calls.isNotEmpty ||
            l.customShout.trim().isNotEmpty ||
            l.tailUpdraft,
      )
      .length;

  GtAlert? getAlertForLine(String lineId) => _alertByLineIdCache[lineId];

  ActiveGtAlertStatus? get activeGtAlertStatus => _activeGtAlertStatusCache;

  void _setProject(CallProject next) {
    final linesOrAlertsChanged =
        !identical(next.lines, _project.lines) ||
        !identical(next.alerts, _project.alerts);
    final bpmChanged = next.meta.bpm != _project.meta.bpm;
    _project = next;
    if (linesOrAlertsChanged) {
      _rebuildProjectCaches();
    } else if (bpmChanged) {
      _recomputePlaybackDerivedStates();
    }
  }

  void _rebuildProjectCaches() {
    final lines = [..._project.lines]
      ..sort((a, b) => a.startTimeMs.compareTo(b.startTimeMs));
    final alerts = [..._project.alerts]
      ..sort((a, b) => a.triggerTimeMs.compareTo(b.triggerTimeMs));
    final alertByLine = <String, GtAlert>{};
    final targetByAlertId = <String, String>{};
    for (final alert in alerts) {
      final targetId = resolveGtAlertTargetLineId(alert, lines);
      if (targetId != null) {
        targetByAlertId[alert.id] = targetId;
        alertByLine.putIfAbsent(targetId, () => alert);
      }
    }
    _sortedLinesCache = List.unmodifiable(lines);
    _sortedAlertsCache = List.unmodifiable(alerts);
    _alertByLineIdCache = Map.unmodifiable(alertByLine);
    _alertTargetByIdCache = Map.unmodifiable(targetByAlertId);
    _timelineItemsCache = List.unmodifiable([
      for (final l in lines) TimelineLineItem(l),
    ]);
    _recomputePlaybackDerivedStates();
  }

  void _recomputePlaybackDerivedStates() {
    final t = _currentTimeMs;
    String? nextPlayingId;
    for (final line in _sortedLinesCache) {
      if (t >= line.startTimeMs && t < line.endTimeMs) {
        nextPlayingId = line.id;
        break;
      }
    }
    _playingLineIdCache = nextPlayingId;
    if (!_disposed && _playingLineIdNotifier.value != nextPlayingId) {
      _playingLineIdNotifier.value = nextPlayingId;
    }

    ActiveGtAlertStatus? nextActiveAlert;
    if (_sortedAlertsCache.isNotEmpty) {
      final beatMs = 60000.0 / math.max(30, _project.meta.bpm);
      const holdAfterMs = 1800;
      for (final alert in _sortedAlertsCache) {
        final leadMs = (alert.leadBeats * beatMs).round();
        final warnStart = alert.triggerTimeMs - leadMs;
        if (t >= warnStart && t <= alert.triggerTimeMs + holdAfterMs) {
          final remainingMs = math.max(0, alert.triggerTimeMs - t);
          final remainingBeats =
              remainingMs == 0 ? 0 : (remainingMs / beatMs).ceil();
          final progress =
              ((t - warnStart) / math.max(1, leadMs)).clamp(0.0, 1.0);
          nextActiveAlert = ActiveGtAlertStatus(
            alert: alert,
            remainingBeats: remainingBeats,
            remainingMs: remainingMs,
            isTriggered: remainingMs == 0,
            progress: progress,
            targetLineId: _alertTargetByIdCache[alert.id],
          );
          break;
        }
      }
    }
    _activeGtAlertStatusCache = nextActiveAlert;
    final nextGtTarget = nextActiveAlert?.targetLineId;
    if (!_disposed && _activeGtTargetLineIdNotifier.value != nextGtTarget) {
      _activeGtTargetLineIdNotifier.value = nextGtTarget;
    }
  }

  void _invalidateThemeCache() {
    _cachedLightTheme = null;
    _cachedDarkTheme = null;
  }

  void _notifyThemeChanged() {
    _invalidateThemeCache();
    if (!_disposed) {
      _themeNotifier.notifyListeners();
      notifyListeners();
    }
  }

  prism.ThemeData buildPrismTheme(Brightness brightness) {
    final cached = brightness == Brightness.dark
        ? _cachedDarkTheme
        : _cachedLightTheme;
    if (cached != null) return cached;

    final raw = prism.seededColorScheme(
      seedColor: _seedColor,
      brightness: brightness,
      style: _colorStyle,
    );
    final scheme = brightness == Brightness.dark
        ? raw.toPureBlack(_pureBlack)
        : raw;
    final built = prism.ThemeData(
      colorScheme: scheme,
      fontFamily: _useGoogleSans ? 'GoogleSans' : null,
      fontFamilyFallback: _useGoogleSans
          ? prism.appFontFamilyFallback(
              platform: defaultTargetPlatform,
              locales: WidgetsBinding.instance.platformDispatcher.locales,
              fontFamily: 'GoogleSans',
            )
          : null,
    );
    if (brightness == Brightness.dark) {
      _cachedDarkTheme = built;
    } else {
      _cachedLightTheme = built;
    }
    return built;
  }

  CallProject _normalizeProjectAlerts(CallProject proj) {
    if (proj.alerts.isEmpty || proj.lines.isEmpty) return proj;
    final ordered = [...proj.lines]
      ..sort((a, b) => a.startTimeMs.compareTo(b.startTimeMs));
    final seenTargets = <String>{};
    final normalized = <GtAlert>[];
    for (final alert in proj.alerts) {
      final targetId = resolveGtAlertTargetLineId(alert, ordered);
      if (targetId == null || seenTargets.contains(targetId)) continue;
      seenTargets.add(targetId);
      normalized.add(
        alert.targetLineId == targetId
            ? alert
            : alert.copyWith(targetLineId: targetId),
      );
    }
    return proj.copyWith(alerts: normalized);
  }

  Future<void> init() async {
    await _audio.init();
    final savedUrl = await _storage.loadBackendUrl();
    if (savedUrl != null && savedUrl.isNotEmpty) {
      _api.setBaseUrl(savedUrl);
    }
    final savedGatewayUrl = await _storage.loadGatewayUrl();
    if (savedGatewayUrl != null && savedGatewayUrl.trim().isNotEmpty) {
      _savedGatewayUrl = savedGatewayUrl.trim();
      _gatewayStatus = _gatewayStatus.copyWith(gatewayUrl: _savedGatewayUrl);
    }
    final savedCookie = await _storage.loadNeteaseCookie();
    if (savedCookie != null && savedCookie.trim().isNotEmpty) {
      _savedNeteaseCookie = savedCookie;
    }
    final savedTheme = await _storage.loadThemePrefs();
    if (savedTheme != null) {
      _applySavedThemeMap(savedTheme);
      _invalidateThemeCache();
    }
    final savedProj = await _storage.loadProject();
    if (savedProj != null && savedProj.lines.isNotEmpty) {
      _setProject(_normalizeProjectAlerts(savedProj));
      _knownAudioDurationMs =
          savedProj.meta.platform == 'synthetic' ? 48000 : 0;
    } else {
      _setProject(_normalizeProjectAlerts(_project));
      _knownAudioDurationMs = 48000;
    }
    _customPresets = await _storage.loadCustomPresets();
    _displayLayers = await _storage.loadDisplayLayers();
    _archives = await _storage.loadArchives();
    final savedSession = await _storage.loadArchiveSession();
    if (savedSession != null) {
      final stillExists = savedSession.activeArchiveId != null &&
          _archives.any((a) => a.id == savedSession.activeArchiveId);
      _activeArchiveId = stillExists ? savedSession.activeArchiveId : null;
      _hasUnsavedChanges = savedSession.hasUnsavedChanges;
      _hasFetchedExternalLyrics = savedSession.hasFetchedExternalLyrics;
    } else if (savedProj != null && savedProj.meta.platform != 'synthetic') {
      _hasFetchedExternalLyrics = true;
      _hasUnsavedChanges = true;
    }
    if (sortedLines.isNotEmpty) {
      _activeLineId = sortedLines.first.id;
    }
    _refreshCallDensitySeries();
    _syncEngine();
    await checkBackendHealth();
    _themeNotifier.notifyListeners();
    notifyListeners();
  }

  void _applySavedThemeMap(Map<String, dynamic> map) {
    final modeIdx = map['themeMode'] as int?;
    if (modeIdx != null && modeIdx >= 0 && modeIdx < prism.ThemeMode.values.length) {
      _themeMode = prism.ThemeMode.values[modeIdx];
    }
    final seedInt = map['seedColor'] as int?;
    if (seedInt != null) _seedColor = Color(seedInt);
    final styleIdx = map['colorStyle'] as int?;
    if (styleIdx != null && styleIdx >= 0 && styleIdx < prism.ColorStyle.values.length) {
      _colorStyle = prism.ColorStyle.values[styleIdx];
    }
    _pureBlack = map['pureBlack'] == true;
    _liquidGlass = map['liquidGlass'] != false;
    _floatingNavDock = map['floatingNavDock'] != false;
    _useGoogleSans = map['useGoogleSans'] != false;
    _textScale = ((map['textScale'] as num?)?.toDouble() ?? 1.0).clamp(0.85, 1.25);
  }

  Future<void> checkBackendHealth() async {
    final health = await _api.checkHealth();
    _backendOnline = health.online;
    _customProxyEnabled = health.customProxyEnabled;
    if (health.online) {
      _siteCopyByOriginal = await _api.fetchSiteCopyOverrides();
      final gw = await _api.fetchGatewayStatus();
      if (gw != null) {
        _gatewayStatus = gw;
        if (gw.gatewayUrl.isNotEmpty) {
          _savedGatewayUrl = gw.gatewayUrl;
        }
      }
      _setStatusInternal('已连接后端 (${_api.baseUrl}) · ${health.providers.join(", ")}');
    } else {
      final hasCookie = _savedNeteaseCookie.trim().isNotEmpty;
      final masked = hasCookie
          ? DesktopServiceLauncher.maskNeteaseCookie(_savedNeteaseCookie)
          : '';
      final prevAccount = (hasCookie && _gatewayStatus.cookieConfigured)
          ? _gatewayStatus.neteaseAccount
          : null;
      _gatewayStatus = GatewayStatusInfo(
        gatewayUrl: _savedGatewayUrl,
        gatewayOnline: false,
        customProxyEnabled: false,
        cookieConfigured: hasCookie,
        cookieMasked: masked,
        managedByBackend: false,
        pid: null,
        canSpawnLocal: false,
        nodeAvailable: false,
        packageAvailable: false,
        neteaseAccount: prevAccount,
        message: hasCookie
            ? '纯 Dart 直连就绪（免 Node · 已加载本地 Cookie${prevAccount != null && prevAccount.isNotEmpty ? " · $prevAccount" : ""}）'
            : '纯 Dart 直连就绪（免 Node · 支持网易云游客直连 / LRCLIB / 演示库）',
      );
      _setStatusInternal('纯 Dart 直连模式 · 免 Node/后端直接搜歌演练');
    }
    notifyListeners();
  }

  Future<bool> _verifyDirectNetease({
    required String cookie,
    required String cleanUrl,
  }) async {
    final probe = await _neteaseDirect.probeAccount(cookie: cookie);
    _gatewayStatus = GatewayStatusInfo(
      gatewayUrl: cleanUrl,
      gatewayOnline: probe.reachable,
      customProxyEnabled: false,
      cookieConfigured: probe.cookieConfigured,
      cookieMasked: probe.cookieMasked,
      managedByBackend: false,
      pid: null,
      canSpawnLocal: false,
      nodeAvailable: false,
      packageAvailable: false,
      neteaseAccount: probe.nickname,
      message: probe.message,
    );
    setStatus(probe.message);
    return probe.reachable;
  }

  Future<void> refreshGatewayStatus({bool probeDirect = false}) async {
    await checkBackendHealth();
    if (probeDirect &&
        (!_backendOnline ||
            (!_gatewayStatus.gatewayOnline &&
                (!_gatewayStatus.nodeAvailable ||
                    !_gatewayStatus.packageAvailable)))) {
      await _verifyDirectNetease(
        cookie: _savedNeteaseCookie,
        cleanUrl: _savedGatewayUrl,
      );
      notifyListeners();
    }
  }

  Future<void> launchLocalBackendOnDesktop() async {
    if (_isLaunchingBackend) return;
    _isLaunchingBackend = true;
    setStatus('正在启动可选 FastAPI 后端 (${_api.baseUrl})...');
    notifyListeners();
    try {
      final res = await _desktopLauncher.ensureBackendRunning(_api.baseUrl);
      setStatus(res.message);
      await checkBackendHealth();
    } finally {
      _isLaunchingBackend = false;
      notifyListeners();
    }
  }

  Future<bool> oneClickConfigureAndStartGateway({
    required String cookie,
    String? gatewayUrl,
  }) async {
    if (_isConfiguringGateway) return false;
    _isConfiguringGateway = true;
    final cleanUrl = DesktopServiceLauncher.normalizeGatewayUrl(
      gatewayUrl ?? _savedGatewayUrl,
    );
    final normCookie = DesktopServiceLauncher.normalizeNeteaseCookie(cookie);
    _savedGatewayUrl = cleanUrl;
    if (normCookie.isNotEmpty) {
      _savedNeteaseCookie = normCookie;
      await _storage.saveNeteaseCookie(normCookie);
    } else if (cookie.trim().isEmpty) {
      _savedNeteaseCookie = '';
      await _storage.saveNeteaseCookie('');
    }
    await _storage.saveGatewayUrl(cleanUrl);
    setStatus(
      _backendOnline
          ? '正在写入网易云 Cookie 并配置服务...'
          : '正在保存 Cookie 并验证网易云纯 Dart 直连...',
    );
    notifyListeners();

    try {
      if (_backendOnline) {
        final status = await _api.configureAndStartGateway(
          neteaseCookie: normCookie,
          gatewayUrl: cleanUrl,
          autoStart: true,
        );
        _gatewayStatus = status;
        await checkBackendHealth();
        if (status.gatewayOnline) {
          if (status.message.isNotEmpty) {
            setStatus(status.message);
          }
          return true;
        }
        // FastAPI backend connected without Node/gateway package: verify pure-Dart direct mode seamlessly.
        if (!status.nodeAvailable || !status.packageAvailable) {
          return await _verifyDirectNetease(
            cookie: normCookie,
            cleanUrl: cleanUrl,
          );
        }
        if (status.message.isNotEmpty) {
          setStatus(status.message);
        }
        return false;
      }

      // Standalone pure-Dart mode: validate account/connection directly via EAPI (no Node or Python required).
      return await _verifyDirectNetease(
        cookie: normCookie,
        cleanUrl: cleanUrl,
      );
    } catch (err) {
      setStatus('配置网易云直连失败：$err');
      return false;
    } finally {
      _isConfiguringGateway = false;
      notifyListeners();
    }
  }

  Future<void> stopManagedGateway() async {
    if (!_backendOnline) return;
    try {
      final status = await _api.stopGateway();
      _gatewayStatus = status;
      setStatus(status.message);
      notifyListeners();
    } catch (err) {
      setStatus('停止网关失败：$err');
    }
  }

  void setRoute(StudioRoute next) {
    if (_route == next) return;
    _route = next;
    notifyListeners();
  }

  void toggleSidebarExpanded() {
    _sidebarExpanded = !_sidebarExpanded;
    notifyListeners();
  }

  void setPracticeMode(bool value) {
    _isPracticeMode = value;
    notifyListeners();
  }

  void setFollowPlayback(bool value) {
    _followPlayback = value;
    notifyListeners();
  }

  // Theme setters
  void setThemeMode(prism.ThemeMode mode) {
    _themeMode = mode;
    _saveThemePrefs();
    _notifyThemeChanged();
  }

  void setSeedColor(Color color) {
    _seedColor = color;
    _saveThemePrefs();
    _notifyThemeChanged();
  }

  void setColorStyle(prism.ColorStyle style) {
    _colorStyle = style;
    _saveThemePrefs();
    _notifyThemeChanged();
  }

  void setPureBlack(bool v) {
    _pureBlack = v;
    _saveThemePrefs();
    _notifyThemeChanged();
  }

  void setLiquidGlass(bool v) {
    _liquidGlass = v;
    _saveThemePrefs();
    _notifyThemeChanged();
  }

  void setFloatingNavDock(bool v) {
    _floatingNavDock = v;
    _saveThemePrefs();
    notifyListeners();
  }

  void setUseGoogleSans(bool v) {
    _useGoogleSans = v;
    _saveThemePrefs();
    _notifyThemeChanged();
  }

  void setTextScale(double v) {
    _textScale = v.clamp(0.85, 1.25);
    _saveThemePrefs();
    _notifyThemeChanged();
  }

  void applyThemePreset(CuratedThemePreset preset) {
    _seedColor = preset.seedColor;
    _themeMode = preset.mode;
    _colorStyle = preset.style;
    _pureBlack = preset.pureBlack;
    _saveThemePrefs();
    _notifyThemeChanged();
  }

  void resetTheme() {
    _seedColor = curatedThemePresets.first.seedColor;
    _themeMode = curatedThemePresets.first.mode;
    _colorStyle = curatedThemePresets.first.style;
    _pureBlack = curatedThemePresets.first.pureBlack;
    _liquidGlass = true;
    _floatingNavDock = true;
    _useGoogleSans = true;
    _textScale = 1.0;
    _saveThemePrefs();
    _notifyThemeChanged();
  }

  void _saveThemePrefs() {
    unawaited(
      _storage.saveThemePrefs({
        'themeMode': _themeMode.index,
        'seedColor': _seedColor.toARGB32(),
        'colorStyle': _colorStyle.index,
        'pureBlack': _pureBlack,
        'liquidGlass': _liquidGlass,
        'floatingNavDock': _floatingNavDock,
        'useGoogleSans': _useGoogleSans,
        'textScale': _textScale,
      }),
    );
  }

  // Playback & Metronome controls
  Future<void> togglePlay() async {
    if (_isPlaying) {
      await _audio.pause();
      _isPlaying = false;
    } else {
      final started = await _audio.play();
      _isPlaying = started;
      if (!started) {
        _setStatusInternal('音频播放失败，请检查音源或系统音频设备');
      }
    }
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  Future<void> seek(int ms) async {
    await _audio.seek(ms);
  }

  void setBpm(int bpm) {
    final clamped = bpm.clamp(30, 300);
    _setProject(_project.copyWith(meta: _project.meta.copyWith(bpm: clamped)));
    _syncEngine();
    schedulePersist();
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  void setTimeSignature(String sig) {
    final normalized = sig == '3/4' ? '3/4' : '4/4';
    _setProject(
      _project.copyWith(
        meta: _project.meta.copyWith(timeSignature: normalized),
      ),
    );
    _syncEngine();
    schedulePersist();
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  void adjustOffset(int deltaMs) {
    _setProject(
      _project.copyWith(
        meta: _project.meta.copyWith(offsetMs: _project.meta.offsetMs + deltaMs),
      ),
    );
    _syncEngine();
    schedulePersist();
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  void setOffset(int ms) {
    _setProject(_project.copyWith(meta: _project.meta.copyWith(offsetMs: ms)));
    _syncEngine();
    schedulePersist();
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  void setPlaybackRate(double rate) {
    _playbackRate = rate.clamp(0.5, 2.0);
    _syncEngine();
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  void setMetronomeEnabled(bool enabled) {
    _metronomeEnabled = enabled;
    _syncEngine();
    notifyListeners();
  }

  void setMetronomeVolume(double volume) {
    _metronomeVolume = volume.clamp(0.2, 1.5);
    _syncEngine();
    notifyListeners();
  }

  void setGtBeepEnabled(bool enabled) {
    _gtBeepEnabled = enabled;
    _syncEngine();
    notifyListeners();
  }

  Future<void> testMetronomeClick() async {
    await _audio.testMetronomeClick(accent: true);
    setStatus('试听节拍器强拍 (${(_metronomeVolume * 100).round()}%)');
  }

  void tapTempo() {
    final detected = _audio.tapTempo();
    if (detected != null) {
      setBpm(detected);
      setStatus('Tap 测速：$detected BPM');
    } else {
      setStatus('继续连按 Tap 2 次以上计算 BPM...');
    }
  }

  void updateMeta({
    String? title,
    String? artist,
    String? composer,
    String? lyricist,
    String? vocalist,
    String? tuner,
    bool? showTuner,
    String? editorName,
    String? editorNote,
  }) {
    _setProject(
      _project.copyWith(
        meta: _project.meta.copyWith(
          title: title,
          artist: artist,
          composer: composer,
          lyricist: lyricist,
          vocalist: vocalist,
          tuner: tuner,
          showTuner: showTuner,
          editorName: editorName,
          editorNote: editorNote,
        ),
      ),
    );
    schedulePersist();
    notifyListeners();
  }

  void updateDisplayLayers({
    bool? showRuby,
    bool? showRomaji,
    bool? showTranslation,
  }) {
    _displayLayers = _displayLayers.copyWith(
      showRuby: showRuby,
      showRomaji: showRomaji,
      showTranslation: showTranslation,
    );
    unawaited(_storage.saveDisplayLayers(_displayLayers));
    notifyListeners();
  }

  // Timeline editing
  void selectLine(String id, {bool seekToLine = false}) {
    _activeLineId = id;
    if (seekToLine) {
      final found = _project.lines.where((l) => l.id == id);
      if (found.isNotEmpty) {
        unawaited(_audio.seek(found.first.startTimeMs));
      }
    }
    notifyListeners();
  }

  void stepActiveLine(int delta) {
    final ordered = sortedLines;
    if (ordered.isEmpty) return;
    final idx = ordered.indexWhere((l) => l.id == _activeLineId);
    final nextIdx = idx < 0
        ? 0
        : (idx + delta).clamp(0, ordered.length - 1);
    _activeLineId = ordered[nextIdx].id;
    notifyListeners();
  }

  LyricLine? resolveLineForQuickTag() {
    final ordered = sortedLines;
    if (ordered.isEmpty) return null;
    final candidateId = _activeLineId ?? playingLineId;
    if (candidateId != null) {
      final idx = ordered.indexWhere((l) => l.id == candidateId);
      if (idx >= 0) return ordered[idx];
    }
    return ordered.first;
  }

  bool toggleLineCall(String lineId, String presetId, {String? suffix}) {
    final lines = [..._project.lines];
    final idx = lines.indexWhere((l) => l.id == lineId);
    if (idx < 0) return false;
    final line = lines[idx];
    final exists = line.calls.any((c) => c.presetId == presetId);
    final trimmedSuffix = suffix?.trim();
    final nextCalls = exists
        ? line.calls.where((c) => c.presetId != presetId).toList()
        : [
            ...line.calls,
            LineCallTag(
              presetId: presetId,
              suffix: (trimmedSuffix != null && trimmedSuffix.isNotEmpty)
                  ? trimmedSuffix
                  : null,
            ),
          ];
    lines[idx] = line.copyWith(calls: nextCalls);
    _setProject(_project.copyWith(lines: lines));
    _refreshCallDensitySeries();
    schedulePersist();
    notifyListeners();
    return !exists;
  }

  /// 开启或关闭指定行的「尾句上升气流」标记（与行首 Call 独立共存）。
  bool toggleTailUpdraft(String lineId) {
    final idx = _project.lines.indexWhere((l) => l.id == lineId);
    if (idx < 0) return false;
    final next = !_project.lines[idx].tailUpdraft;
    setTailUpdraft(lineId, next);
    return next;
  }

  /// 设置指定行的「尾句上升气流」状态。
  void setTailUpdraft(String lineId, bool enabled) {
    final lines = [..._project.lines];
    final idx = lines.indexWhere((l) => l.id == lineId);
    if (idx < 0) return;
    if (lines[idx].tailUpdraft == enabled) return;
    lines[idx] = lines[idx].copyWith(tailUpdraft: enabled);
    _setProject(_project.copyWith(lines: lines));
    _refreshCallDensitySeries();
    schedulePersist();
    setStatus(
      enabled
          ? '已标记尾句上升气流 · ${lines[idx].text.original}'
          : '已取消尾句上升气流 · ${lines[idx].text.original}',
    );
  }

  bool quickTagActiveLine(
    String presetId, {
    bool autoAdvance = false,
    String? suffix,
  }) {
    final target = resolveLineForQuickTag();
    if (target == null) {
      setStatus('暂无可打标的歌词行');
      return false;
    }
    _activeLineId = target.id;
    final added = toggleLineCall(target.id, presetId, suffix: suffix);
    if (added && autoAdvance) {
      stepActiveLine(1);
    }
    return added;
  }

  void setCallTagSuffix(String lineId, String presetId, String suffix) {
    final lines = [..._project.lines];
    final idx = lines.indexWhere((l) => l.id == lineId);
    if (idx < 0) return;
    final line = lines[idx];
    final nextCalls = [
      for (final c in line.calls)
        if (c.presetId == presetId)
          LineCallTag(
            presetId: c.presetId,
            suffix: suffix.trim().isEmpty ? null : suffix.trim(),
          )
        else
          c,
    ];
    lines[idx] = line.copyWith(calls: nextCalls);
    _setProject(_project.copyWith(lines: lines));
    schedulePersist();
    notifyListeners();
  }

  void updateLineDetails({
    required String lineId,
    int? startTimeMs,
    int? endTimeMs,
    LyricLineKind? kind,
    String? original,
    String? translation,
    String? customShout,
  }) {
    final orderedBefore = sortedLines;
    final lines = [..._project.lines];
    final idx = lines.indexWhere((l) => l.id == lineId);
    if (idx < 0) return;
    final current = lines[idx];
    final effectiveStart = startTimeMs ?? current.startTimeMs;
    lines[idx] = current.copyWith(
      startTimeMs: startTimeMs,
      endTimeMs: endTimeMs,
      kind: kind,
      autoGenerated:
          kind != null && kind != current.kind ? false : current.autoGenerated,
      customShout: customShout,
      text: current.text.copyWith(
        original: original,
        translation: translation,
      ),
    );
    final nextAlerts = startTimeMs != null
        ? [
            for (final a in _project.alerts)
              if (resolveGtAlertTargetLineId(a, orderedBefore) == lineId)
                a.copyWith(targetLineId: lineId, triggerTimeMs: effectiveStart)
              else
                a,
          ]
        : _project.alerts;
    _setProject(_project.copyWith(lines: lines, alerts: nextAlerts));
    _refreshCallDensitySeries();
    if (startTimeMs != null) {
      _syncEngine();
    }
    schedulePersist();
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  void snapLineToCurrentTime(String lineId) {
    final orderedBefore = sortedLines;
    final lines = [..._project.lines];
    final idx = lines.indexWhere((l) => l.id == lineId);
    if (idx < 0) return;
    final current = lines[idx];
    final dur = math.max(1200, current.endTimeMs - current.startTimeMs);
    lines[idx] = current.copyWith(
      startTimeMs: _currentTimeMs,
      endTimeMs: _currentTimeMs + dur,
    );
    final nextAlerts = [
      for (final a in _project.alerts)
        if (resolveGtAlertTargetLineId(a, orderedBefore) == lineId)
          a.copyWith(targetLineId: lineId, triggerTimeMs: _currentTimeMs)
        else
          a,
    ];
    _setProject(_project.copyWith(lines: lines, alerts: nextAlerts));
    _syncEngine();
    schedulePersist();
    _setStatusInternal('已对齐当前时间 ${formatMsToClock(_currentTimeMs)}');
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  void addEmptyLine() {
    final start = _currentTimeMs;
    final newLine = LyricLine(
      id: 'line-${DateTime.now().millisecondsSinceEpoch}',
      startTimeMs: start,
      endTimeMs: start + 3000,
      text: const LyricText(original: '新歌词行（点击编辑）', translation: ''),
    );
    _setProject(_project.copyWith(lines: [..._project.lines, newLine]));
    _activeLineId = newLine.id;
    _refreshCallDensitySeries();
    schedulePersist();
    notifyListeners();
  }

  Set<String> _getProtectedSectionLineIds() {
    final ordered = sortedLines;
    final protectedIds = <String>{};
    for (final alert in _project.alerts) {
      final targetId = resolveGtAlertTargetLineId(alert, ordered);
      if (targetId != null) {
        protectedIds.add(targetId);
      }
    }
    return protectedIds;
  }

  DetectSectionsStats detectSections({
    bool onlyOutro = false,
    bool silent = false,
    int? explicitDurationMs,
  }) {
    final totalDur = explicitDurationMs ??
        (_knownAudioDurationMs > 0
            ? _knownAudioDurationMs
            : (_project.meta.platform != 'synthetic' && _durationMs > 1000
                  ? _durationMs
                  : null));
    final prevLines = _project.lines;
    final result = detectAndMergeSections(
      prevLines,
      thresholds: _sectionThresholds,
      totalDurationMs: totalDur,
      protectedLineIds: _getProtectedSectionLineIds(),
      onlyOutro: onlyOutro,
    );
    var linesChanged = result.lines.length != prevLines.length;
    if (!linesChanged) {
      for (var i = 0; i < result.lines.length; i++) {
        if (result.lines[i].id != prevLines[i].id ||
            result.lines[i].startTimeMs != prevLines[i].startTimeMs ||
            result.lines[i].endTimeMs != prevLines[i].endTimeMs) {
          linesChanged = true;
          break;
        }
      }
    }
    if (linesChanged) {
      _setProject(_project.copyWith(lines: result.lines));
      if (_activeLineId != null &&
          !_project.lines.any((l) => l.id == _activeLineId)) {
        _activeLineId =
            result.lines.isNotEmpty ? result.lines.first.id : null;
      }
      _refreshCallDensitySeries();
      _syncEngine();
      schedulePersist();
    }
    if (!silent) {
      _setStatusInternal(
        '段落识别完成：前奏 ${result.stats.intro} / 间奏 ${result.stats.interlude} / 尾奏 ${result.stats.outro}',
      );
    }
    notifyListeners();
    return result.stats;
  }

  void setSectionThresholds(
    SectionDetectThresholds next, {
    bool redetect = false,
  }) {
    _sectionThresholds = SectionDetectThresholds(
      introThresholdMs: next.introThresholdMs.clamp(2000, 60000),
      interludeThresholdMs: next.interludeThresholdMs.clamp(2000, 60000),
      outroThresholdMs: next.outroThresholdMs.clamp(2000, 60000),
    );
    if (redetect) {
      detectSections();
    } else {
      notifyListeners();
    }
  }

  void addSectionLine({
    required LyricLineKind kind,
    required int startTimeMs,
    required int endTimeMs,
    String? title,
    String? note,
  }) {
    final safeKind = kind == LyricLineKind.lyric ? LyricLineKind.interlude : kind;
    final safeStart = math.max(0, startTimeMs);
    final safeEnd = math.max(safeStart + 1000, endTimeMs);
    final gap = safeEnd - safeStart;
    final effectiveTitle =
        (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : safeKind.bracketTitle;
    final effectiveNote =
        (note != null && note.trim().isNotEmpty)
            ? note.trim()
            : buildSectionSummary(safeKind, gap);

    final newSection = LyricLine(
      id: 'sec-manual-${safeKind.name}-${DateTime.now().millisecondsSinceEpoch}',
      startTimeMs: safeStart,
      endTimeMs: safeEnd,
      kind: safeKind,
      autoGenerated: false,
      text: LyricText(
        original: effectiveTitle,
        translation: effectiveNote,
      ),
    );

    final nextLines = [
      for (final line in _project.lines)
        if (!line.kind.isSection &&
            safeKind == LyricLineKind.interlude &&
            line.startTimeMs < safeStart &&
            line.endTimeMs > safeStart)
          line.copyWith(endTimeMs: safeStart)
        else
          line,
      newSection,
    ]..sort((a, b) => a.startTimeMs.compareTo(b.startTimeMs));

    _setProject(_project.copyWith(lines: nextLines));
    _activeLineId = newSection.id;
    _refreshCallDensitySeries();
    _syncEngine();
    schedulePersist();
    _setStatusInternal('已添加${safeKind.zhLabel}段落（${formatGapSec(gap)}）');
    notifyListeners();
  }

  void deleteLine(String lineId) {
    final orderedBefore = sortedLines;
    _setProject(
      _project.copyWith(
        lines: _project.lines.where((l) => l.id != lineId).toList(),
        alerts: _project.alerts
            .where((a) => resolveGtAlertTargetLineId(a, orderedBefore) != lineId)
            .toList(),
      ),
    );
    if (_activeLineId == lineId) {
      _activeLineId = sortedLines.isNotEmpty ? sortedLines.first.id : null;
    }
    _refreshCallDensitySeries();
    _syncEngine();
    schedulePersist();
    notifyListeners();
  }

  String? _pickTargetLineForGt() {
    final ordered = sortedLines;
    if (ordered.isEmpty) return null;
    if (_activeLineId != null && ordered.any((l) => l.id == _activeLineId)) {
      return _activeLineId;
    }
    final playing = playingLineId;
    if (playing != null && ordered.any((l) => l.id == playing)) {
      return playing;
    }
    var best = ordered.first;
    var bestDist = (best.startTimeMs - _currentTimeMs).abs();
    for (final line in ordered.skip(1)) {
      final dist = (line.startTimeMs - _currentTimeMs).abs();
      if (dist < bestDist) {
        best = line;
        bestDist = dist;
      }
    }
    return best.id;
  }

  void toggleLineGtAlert({String? lineId, String? callTimingCue}) {
    final ordered = sortedLines;
    final targetId = lineId ?? _pickTargetLineForGt();
    if (targetId == null) {
      setStatus('请先添加或选择一句歌词，再开启 GT 警报');
      return;
    }
    LyricLine? targetLine;
    for (final line in ordered) {
      if (line.id == targetId) {
        targetLine = line;
        break;
      }
    }
    if (targetLine == null) return;
    _activeLineId = targetId;

    final existing = getAlertForLine(targetId);
    if (existing != null) {
      _setProject(
        _project.copyWith(
          alerts: _project.alerts
              .where((a) => resolveGtAlertTargetLineId(a, ordered) != targetId)
              .toList(),
        ),
      );
      _syncEngine();
      schedulePersist();
      _setStatusInternal('已取消该句的 GT 警报');
      _playbackNotifier.notifyListeners();
      notifyListeners();
      return;
    }

    final trimmedCue = callTimingCue?.trim();
    final alert = GtAlert(
      id: 'gt-${DateTime.now().millisecondsSinceEpoch}',
      triggerTimeMs: targetLine.startTimeMs,
      leadBeats: 4,
      note: '吉他进场，准备衔接 Call',
      targetLineId: targetId,
      callTimingCue:
          (trimmedCue != null && trimmedCue.isNotEmpty) ? trimmedCue : 'se-no',
    );
    _setProject(_project.copyWith(alerts: [..._project.alerts, alert]));
    _syncEngine();
    schedulePersist();
    _setStatusInternal('已为歌词行开启 GT 警报 · ${targetLine.text.original}');
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  void updateLineGtAlert(
    String lineId, {
    String? callTimingCue,
    int? leadBeats,
    String? note,
    int? triggerTimeMs,
  }) {
    final existing = getAlertForLine(lineId);
    if (existing == null) return;
    final ordered = sortedLines;
    _setProject(
      _project.copyWith(
        alerts: [
          for (final a in _project.alerts)
            if (a.id == existing.id ||
                resolveGtAlertTargetLineId(a, ordered) == lineId)
              a.copyWith(
                targetLineId: lineId,
                callTimingCue: callTimingCue ?? a.callTimingCue,
                leadBeats: leadBeats ?? a.leadBeats,
                note: note ?? a.note,
                triggerTimeMs: triggerTimeMs ?? a.triggerTimeMs,
              )
            else
              a,
        ],
      ),
    );
    _syncEngine();
    schedulePersist();
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  void insertGtAlert({String? lineId, String? callTimingCue}) {
    toggleLineGtAlert(lineId: lineId, callTimingCue: callTimingCue);
  }

  void addCustomPreset({
    required String label,
    required String colorHex,
    CallCategory category = CallCategory.compound,
    String shortcut = '',
  }) {
    final clean = label.trim();
    if (clean.isEmpty) return;
    final normalizedColor =
        RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(colorHex.trim())
            ? colorHex.trim().toUpperCase()
            : '#EC4899';
    final preset = CallPreset(
      id: 'custom-${DateTime.now().millisecondsSinceEpoch}',
      label: clean,
      colorHex: normalizedColor,
      category: category,
      shortcut: shortcut.trim().toUpperCase(),
    );
    _customPresets = [..._customPresets, preset];
    unawaited(_storage.saveCustomPresets(_customPresets));
    _setStatusInternal('已添加自定义 Call 标签：$clean');
    schedulePersist();
    notifyListeners();
  }

  bool updateCustomPreset({
    required String presetId,
    required String label,
    required String colorHex,
    CallCategory? category,
    String? shortcut,
  }) {
    if (defaultCallPresets.any((p) => p.id == presetId)) return false;
    final idx = _customPresets.indexWhere((p) => p.id == presetId);
    if (idx < 0) return false;
    final cleanLabel = label.trim();
    if (cleanLabel.isEmpty) return false;
    final current = _customPresets[idx];
    final normalizedColor =
        RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(colorHex.trim())
            ? colorHex.trim().toUpperCase()
            : current.colorHex;
    final updated = current.copyWith(
      label: cleanLabel,
      colorHex: normalizedColor,
      category: category,
      shortcut: shortcut?.trim().toUpperCase(),
      builtIn: false,
    );
    final nextPresets = [..._customPresets];
    nextPresets[idx] = updated;
    _customPresets = nextPresets;
    unawaited(_storage.saveCustomPresets(_customPresets));
    _setStatusInternal('已更新自定义标签：${updated.label}');
    schedulePersist();
    notifyListeners();
    return true;
  }

  bool deleteCustomPreset(String presetId) {
    if (defaultCallPresets.any((p) => p.id == presetId)) return false;
    final idx = _customPresets.indexWhere((p) => p.id == presetId);
    if (idx < 0) return false;
    final removed = _customPresets[idx];
    _customPresets = [
      for (final p in _customPresets)
        if (p.id != presetId) p,
    ];
    unawaited(_storage.saveCustomPresets(_customPresets));

    var linesChanged = false;
    final nextLines = [
      for (final line in _project.lines)
        if (line.calls.any((c) => c.presetId == presetId))
          (() {
            linesChanged = true;
            return line.copyWith(
              calls: line.calls.where((c) => c.presetId != presetId).toList(),
            );
          })()
        else
          line,
    ];
    if (linesChanged) {
      _setProject(_project.copyWith(lines: nextLines));
      _refreshCallDensitySeries();
    }
    _setStatusInternal('已删除自定义标签：${removed.label}');
    schedulePersist();
    notifyListeners();
    return true;
  }

  // Backend search, LRC import & local audio
  Future<void> setBackendUrl(String url) async {
    _api.setBaseUrl(url);
    await _storage.saveBackendUrl(_api.baseUrl);
    await checkBackendHealth();
  }

  Future<void> searchTracks(String query, {String source = 'auto'}) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty && source != 'mock') return;
    _isSearching = true;
    notifyListeners();
    try {
      final useBackendProxy =
          _backendOnline &&
          (_customProxyEnabled ||
              _gatewayStatus.managedByBackend ||
              (_gatewayStatus.gatewayOnline && _gatewayStatus.nodeAvailable));

      if (source == 'mock') {
        List<TrackSummary> results;
        if (_backendOnline) {
          try {
            final resp = await _api.searchTracks(cleanQuery, source: 'mock');
            results = resp.results;
          } catch (_) {
            results = _mockCatalog.searchTracks(cleanQuery);
          }
        } else {
          results = _mockCatalog.searchTracks(cleanQuery);
        }
        _searchResults = results;
        setStatus('搜索完成 (演示曲库) · ${results.length} 首');
        return;
      }

      if (source == 'lrclib') {
        List<TrackSummary> results;
        String used = 'lrclib';
        if (_backendOnline) {
          try {
            final resp = await _api.searchTracks(cleanQuery, source: 'lrclib');
            results = resp.results;
            used = resp.providerUsed.isNotEmpty ? resp.providerUsed : 'lrclib';
          } catch (_) {
            results = await _lrclibDirect.searchTracks(cleanQuery);
            used = 'lrclib 直连';
          }
        } else {
          results = await _lrclibDirect.searchTracks(cleanQuery);
          used = 'lrclib 直连';
        }
        _searchResults = results;
        setStatus('搜索完成 ($used) · ${results.length} 首');
        return;
      }

      if (source == 'custom_proxy') {
        if (useBackendProxy) {
          try {
            final resp = await _api.searchTracks(
              cleanQuery,
              source: 'custom_proxy',
            );
            _searchResults = resp.results;
            setStatus('搜索完成 (${resp.providerUsed}) · ${resp.results.length} 首');
            return;
          } catch (_) {
            // Fall through to pure-Dart Netease direct engine
          }
        }
        final directResults = await _neteaseDirect.searchTracks(
          cleanQuery,
          cookie: _savedNeteaseCookie,
        );
        _searchResults = directResults;
        setStatus('搜索完成 (网易云纯 Dart 直连) · ${directResults.length} 首');
        return;
      }

      // source == 'auto'
      if (useBackendProxy) {
        try {
          final resp = await _api.searchTracks(cleanQuery, source: 'auto');
          _searchResults = resp.results;
          setStatus('搜索完成 (${resp.providerUsed}) · ${resp.results.length} 首');
          return;
        } catch (_) {
          // Fall through to pure-Dart multi-source chain
        }
      }

      try {
        final neteaseResults = await _neteaseDirect.searchTracks(
          cleanQuery,
          cookie: _savedNeteaseCookie,
        );
        if (neteaseResults.isNotEmpty) {
          _searchResults = neteaseResults;
          setStatus('搜索完成 (网易云纯 Dart 直连) · ${neteaseResults.length} 首');
          return;
        }
      } catch (_) {
        // Fallback to LRCLIB
      }

      try {
        final lrclibResults = _backendOnline
            ? (await _api.searchTracks(cleanQuery, source: 'lrclib')).results
            : await _lrclibDirect.searchTracks(cleanQuery);
        if (lrclibResults.isNotEmpty) {
          _searchResults = lrclibResults;
          setStatus('搜索完成 (LRCLIB 直连) · ${lrclibResults.length} 首');
          return;
        }
      } catch (_) {
        // Fallback to built-in offline mock catalog
      }

      final mockResults = _mockCatalog.searchTracks(cleanQuery);
      _searchResults = mockResults;
      setStatus('外网曲库暂不可达或无匹配，已自动切换至演示曲库 (mock) · ${mockResults.length} 首');
    } catch (err) {
      setStatus('搜索失败：$err');
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  Future<void> loadRemoteTrack(TrackSummary summary) async {
    try {
      final providerName =
          summary.provider.isNotEmpty ? summary.provider : summary.platform;
      TrackDetailResponse detail;

      if (providerName == 'netease_direct') {
        detail = await _neteaseDirect.fetchTrackDetail(
          summary.id,
          cookie: _savedNeteaseCookie,
          fallbackSummary: summary,
        );
      } else if (providerName == 'lrclib') {
        if (_backendOnline) {
          try {
            detail = await _api.fetchTrackDetail('lrclib', summary.id);
          } catch (_) {
            detail = await _lrclibDirect.fetchTrackDetail(summary.id);
          }
        } else {
          detail = await _lrclibDirect.fetchTrackDetail(summary.id);
        }
      } else if (providerName == 'mock') {
        if (_backendOnline) {
          try {
            detail = await _api.fetchTrackDetail('mock', summary.id);
          } catch (_) {
            detail =
                _mockCatalog.fetchTrackDetail(summary.id) ??
                (throw Exception('未找到内置演示曲目 (${summary.id})'));
          }
        } else {
          detail =
              _mockCatalog.fetchTrackDetail(summary.id) ??
              (throw Exception('未找到内置演示曲目 (${summary.id})'));
        }
      } else {
        if (_backendOnline) {
          try {
            detail = await _api.fetchTrackDetail(providerName, summary.id);
          } catch (_) {
            if (summary.platform == 'netease') {
              detail = await _neteaseDirect.fetchTrackDetail(
                summary.id,
                cookie: _savedNeteaseCookie,
                fallbackSummary: summary,
              );
            } else {
              rethrow;
            }
          }
        } else if (summary.platform == 'netease') {
          detail = await _neteaseDirect.fetchTrackDetail(
            summary.id,
            cookie: _savedNeteaseCookie,
            fallbackSummary: summary,
          );
        } else {
          throw Exception('后端离线且暂不支持直连该来源 ($providerName)');
        }
      }

      // Hybrid mode: if optional FastAPI backend is online & track came from direct mode
      // (or lacks Ruby markup), annotate Japanese kanji with furigana & romaji.
      var rawLines = detail.lines;
      if (_backendOnline &&
          detail.rawLrc.trim().isNotEmpty &&
          (providerName == 'netease_direct' ||
              rawLines.every((l) => l.text.ruby == null))) {
        try {
          final rubyLines = await _api.parseLyricsWithRuby(
            lrc: detail.rawLrc,
            translationLrc: detail.translatedLrc,
            enableRuby: true,
          );
          if (rubyLines.isNotEmpty) {
            rawLines = rubyLines;
          }
        } catch (_) {
          // Keep offline LRC lines when backend parser is unavailable
        }
      }

      final resolvedDurationMs = detail.track.durationMs > 0
          ? detail.track.durationMs
          : summary.durationMs;
      _knownAudioDurationMs = resolvedDurationMs > 0 ? resolvedDurationMs : 0;
      final detected = detectAndMergeSections(
        rawLines,
        thresholds: _sectionThresholds,
        totalDurationMs:
            _knownAudioDurationMs > 0 ? _knownAudioDurationMs : null,
      );
      _setProject(
        CallProject(
          meta: CallProjectMeta(
            title: detail.track.title,
            artist: detail.track.artist,
            vocalist: detail.track.artist,
            showTuner: false,
            platform: detail.track.platform,
            trackId: detail.track.id,
            audioUrl: detail.audioUrl,
            bpm: detail.track.bpm ?? _project.meta.bpm,
            timeSignature: _project.meta.timeSignature,
            offsetMs: 0,
          ),
          alerts: const [],
          lines: detected.lines,
        ),
      );
      _isPlaying = false;
      var audioFallbackNote = '';
      try {
        await _audio.setAudioSource(
          url: detail.audioUrl,
          fallbackDurationMs: resolvedDurationMs,
        );
      } catch (_) {
        await _audio.setAudioSource(fallbackDurationMs: resolvedDurationMs);
        audioFallbackNote = '（音源加载失败，已切换为节拍器演练）';
      }
      _activeLineId = sortedLines.isNotEmpty ? sortedLines.first.id : null;
      _activeArchiveId = null;
      _hasFetchedExternalLyrics = true;
      _hasUnsavedChanges = true;
      _refreshCallDensitySeries();
      _syncEngine();
      _persistArchiveSession();
      schedulePersist(markDirty: false);
      final totalDetected =
          detected.stats.intro +
          detected.stats.interlude +
          detected.stats.outro;
      final audioHint = audioFallbackNote.isNotEmpty
          ? audioFallbackNote
          : (detail.audioUrl.isEmpty && detail.track.platform == 'netease'
                ? '（该曲目暂无可用直链音源，可搭配本地音频或节拍器演练）'
                : '');
      _setStatusInternal(
        totalDetected > 0
            ? '已导入曲目：${detail.track.title}（自动识别前/间/尾奏：前${detected.stats.intro}·间${detected.stats.interlude}·尾${detected.stats.outro}）$audioHint'
            : '已导入曲目：${detail.track.title}$audioHint',
      );
    } catch (err) {
      _setStatusInternal('导入曲目失败：$err');
    }
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  Future<void> importLrcText({
    required String lrc,
    String translationLrc = '',
    bool enableRuby = true,
  }) async {
    List<LyricLine> lines;
    if (_backendOnline) {
      try {
        lines = await _api.parseLyricsWithRuby(
          lrc: lrc,
          translationLrc: translationLrc,
          enableRuby: enableRuby,
        );
      } catch (_) {
        lines = parseLrcOffline(lrc, translationLrc: translationLrc);
      }
    } else {
      lines = parseLrcOffline(lrc, translationLrc: translationLrc);
    }
    final durationForOutro =
        _project.meta.platform != 'synthetic' && _knownAudioDurationMs > 0
            ? _knownAudioDurationMs
            : null;
    final detected = detectAndMergeSections(
      lines,
      thresholds: _sectionThresholds,
      totalDurationMs: durationForOutro,
    );
    _setProject(_project.copyWith(lines: detected.lines, alerts: const []));
    _activeLineId = sortedLines.isNotEmpty ? sortedLines.first.id : null;
    _activeArchiveId = null;
    _hasFetchedExternalLyrics = true;
    _hasUnsavedChanges = true;
    _refreshCallDensitySeries();
    _syncEngine();
    _persistArchiveSession();
    schedulePersist(markDirty: false);
    final totalDetected =
        detected.stats.intro +
        detected.stats.interlude +
        detected.stats.outro;
    _setStatusInternal(
      totalDetected > 0
          ? '已解析 ${lines.length} 行 LRC · 自动识别前奏 ${detected.stats.intro} / 间奏 ${detected.stats.interlude}${detected.stats.outro > 0 ? ' / 尾奏 ${detected.stats.outro}' : ''}'
          : '已解析 ${lines.length} 行 LRC 歌词（未触发前/间/尾奏空档阈值）',
    );
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  Future<void> loadLocalAudioFile(String filePath, String fileName) async {
    _knownAudioDurationMs = 0;
    _isPlaying = false;
    try {
      await _audio.setAudioSource(localPath: filePath);
    } catch (err) {
      setStatus('载入本地音频失败：$err');
      _playbackNotifier.notifyListeners();
      return;
    }
    final strippedTitle = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    _setProject(
      _project.copyWith(
        meta: _project.meta.copyWith(
          title: strippedTitle.isEmpty ? fileName : strippedTitle,
          artist: '本地音频文件',
          platform: 'local',
          audioUrl: filePath,
        ),
      ),
    );
    schedulePersist();
    _setStatusInternal('已载入本地音频：$fileName');
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  Future<void> loadDemoProject() async {
    _knownAudioDurationMs = 48000;
    _isPlaying = false;
    _setProject(_normalizeProjectAlerts(CallProject.demo()));
    await _audio.setAudioSource(fallbackDurationMs: 48000);
    _activeLineId = sortedLines.isNotEmpty ? sortedLines.first.id : null;
    _activeArchiveId = null;
    _hasFetchedExternalLyrics = false;
    _hasUnsavedChanges = false;
    _refreshCallDensitySeries();
    _syncEngine();
    _persistArchiveSession();
    schedulePersist(markDirty: false);
    _setStatusInternal('已加载 175 BPM 内置演练工程');
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  String exportProjectJsonString() {
    final map = Map<String, dynamic>.from(_project.toJson());
    final metaMap = Map<String, dynamic>.from(
      map['meta'] as Map<dynamic, dynamic>? ?? const {},
    );
    final audioUrl = (metaMap['audioUrl'] ?? '').toString();
    if (audioUrl.startsWith('blob:')) {
      metaMap['audioUrl'] = '';
      map['meta'] = metaMap;
    }
    if (_customPresets.isNotEmpty) {
      map['customPresets'] = [for (final p in _customPresets) p.toJson()];
    }
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  Future<bool> importProjectJson(String rawJson, {String? sourceName}) async {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map<dynamic, dynamic>) {
        setStatus('JSON 工程格式无效：根节点必须是对象');
        return false;
      }
      final map = Map<String, dynamic>.from(decoded);
      final parsed = CallProject.fromJson(map);
      if (parsed.lines.isEmpty && parsed.meta.title.trim().isEmpty) {
        setStatus('JSON 工程格式无效：缺少曲目或歌词行');
        return false;
      }

      if (map['customPresets'] is List) {
        final rawPresets = map['customPresets'] as List<dynamic>;
        final builtInIds = {for (final b in defaultCallPresets) b.id};
        final existingById = {for (final p in _customPresets) p.id: p};
        for (final item in rawPresets) {
          if (item is Map) {
            final preset = CallPreset.fromJson(Map<String, dynamic>.from(item));
            if (preset.id.isNotEmpty &&
                preset.label.trim().isNotEmpty &&
                !builtInIds.contains(preset.id)) {
              existingById[preset.id] = preset.copyWith(builtIn: false);
            }
          }
        }
        _customPresets = existingById.values.toList();
        unawaited(_storage.saveCustomPresets(_customPresets));
      }

      final normalized = _normalizeProjectAlerts(parsed);
      _setProject(normalized);
      final maxEnd = normalized.lines.fold<int>(
        0,
        (prev, l) => math.max(prev, l.endTimeMs),
      );
      _knownAudioDurationMs =
          normalized.meta.platform == 'synthetic' ? 48000 : 0;
      _durationMs = math.max(48000, maxEnd + 4000);
      _currentTimeMs = 0;
      _isPlaying = false;
      _recomputePlaybackDerivedStates();

      if (normalized.meta.platform == 'local' &&
          normalized.meta.audioUrl.isNotEmpty) {
        await _audio.setAudioSource(
          localPath: normalized.meta.audioUrl,
          fallbackDurationMs: _durationMs,
        );
      } else if (normalized.meta.audioUrl.isNotEmpty &&
          !normalized.meta.audioUrl.startsWith('blob:')) {
        await _audio.setAudioSource(
          url: normalized.meta.audioUrl,
          fallbackDurationMs: _durationMs,
        );
      } else {
        await _audio.setAudioSource(fallbackDurationMs: _durationMs);
      }

      _activeLineId = sortedLines.isNotEmpty ? sortedLines.first.id : null;
      _activeArchiveId = null;
      _hasFetchedExternalLyrics = true;
      _hasUnsavedChanges = true;
      _refreshCallDensitySeries();
      _syncEngine();
      _persistArchiveSession();
      schedulePersist(markDirty: false);
      final suffix = sourceName != null && sourceName.trim().isNotEmpty
          ? ' ($sourceName)'
          : '';
      _setStatusInternal('已导入工程：${normalized.meta.title}$suffix');
      _playbackNotifier.notifyListeners();
      notifyListeners();
      return true;
    } catch (err) {
      setStatus('导入 JSON 工程失败：$err');
      return false;
    }
  }

  CallbookArchiveEntry saveCurrentToArchive({
    bool asNew = false,
    String? customName,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final clonedProject = _normalizeProjectAlerts(
      CallProject.fromJson(_project.toJson()),
    );
    final clonedPresets = [
      for (final p in _customPresets) CallPreset.fromJson(p.toJson()),
    ];

    CallbookArchiveEntry? existing;
    if (!asNew && _activeArchiveId != null) {
      for (final item in _archives) {
        if (item.id == _activeArchiveId) {
          existing = item;
          break;
        }
      }
    }

    final trimmedCustom = customName?.trim() ?? '';
    final resolvedName = trimmedCustom.isNotEmpty
        ? trimmedCustom
        : (existing != null
            ? existing.name
            : (clonedProject.meta.title.trim().isNotEmpty
                ? clonedProject.meta.title.trim()
                : '未命名 Call 本'));

    final entry = CallbookArchiveEntry(
      id: existing?.id ?? 'archive-$now-${math.Random().nextInt(9999)}',
      name: resolvedName,
      createdAt: existing?.createdAt ?? now,
      savedAt: now,
      project: clonedProject,
      customPresets: clonedPresets,
      lineCount: clonedProject.lines.length,
      taggedCount: CallbookArchiveEntry.computeTaggedCount(clonedProject),
      alertCount: clonedProject.alerts.length,
    );

    if (existing != null) {
      _archives = [
        for (final item in _archives)
          if (item.id == entry.id) entry else item,
      ];
    } else {
      _archives = [entry, ..._archives];
    }

    _activeArchiveId = entry.id;
    _hasUnsavedChanges = false;
    _hasFetchedExternalLyrics = false;
    unawaited(_storage.saveArchives(_archives));
    _persistArchiveSession();
    schedulePersist(markDirty: false);
    _setStatusInternal(
      existing != null
          ? '已更新存档「${entry.name}」'
          : '已保存至 Call 本存档「${entry.name}」',
    );
    notifyListeners();
    return entry;
  }

  Future<bool> switchToArchive(String archiveId) async {
    CallbookArchiveEntry? found;
    for (final item in _archives) {
      if (item.id == archiveId) {
        found = item;
        break;
      }
    }
    if (found == null) {
      setStatus('未找到对应的 Call 本存档');
      return false;
    }

    final restored = _normalizeProjectAlerts(
      CallProject.fromJson(found.project.toJson()),
    );
    _setProject(restored);
    _customPresets = [
      for (final p in found.customPresets) CallPreset.fromJson(p.toJson()),
    ];
    final maxEnd = restored.lines.fold<int>(
      0,
      (prev, l) => math.max(prev, l.endTimeMs),
    );
    _knownAudioDurationMs =
        restored.meta.platform == 'synthetic' ? 48000 : 0;
    _durationMs = math.max(48000, maxEnd + 4000);
    _currentTimeMs = 0;
    _isPlaying = false;

    try {
      if (restored.meta.platform == 'local' &&
          restored.meta.audioUrl.isNotEmpty) {
        await _audio.setAudioSource(
          localPath: restored.meta.audioUrl,
          fallbackDurationMs: _durationMs,
        );
      } else if (restored.meta.audioUrl.isNotEmpty &&
          !restored.meta.audioUrl.startsWith('blob:')) {
        await _audio.setAudioSource(
          url: restored.meta.audioUrl,
          fallbackDurationMs: _durationMs,
        );
      } else {
        await _audio.setAudioSource(fallbackDurationMs: _durationMs);
      }
    } catch (_) {
      await _audio.setAudioSource(fallbackDurationMs: _durationMs);
    }

    _activeLineId = sortedLines.isNotEmpty ? sortedLines.first.id : null;
    _activeArchiveId = found.id;
    _hasUnsavedChanges = false;
    _hasFetchedExternalLyrics = false;
    _refreshCallDensitySeries();
    _syncEngine();
    _persistArchiveSession();
    schedulePersist(markDirty: false);
    _setStatusInternal('已切换至存档「${found.name}」');
    _playbackNotifier.notifyListeners();
    notifyListeners();
    return true;
  }

  bool renameArchive(String archiveId, String nextName) {
    final trimmed = nextName.trim();
    if (trimmed.isEmpty) return false;
    var updated = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    _archives = [
      for (final item in _archives)
        if (item.id == archiveId)
          (() {
            updated = true;
            return item.copyWith(name: trimmed, savedAt: now);
          })()
        else
          item,
    ];
    if (!updated) return false;
    unawaited(_storage.saveArchives(_archives));
    _setStatusInternal('已将存档重命名为「$trimmed」');
    notifyListeners();
    return true;
  }

  bool deleteArchive(String archiveId) {
    CallbookArchiveEntry? target;
    for (final item in _archives) {
      if (item.id == archiveId) {
        target = item;
        break;
      }
    }
    if (target == null) return false;
    _archives = [
      for (final item in _archives)
        if (item.id != archiveId) item,
    ];
    if (_activeArchiveId == archiveId) {
      _activeArchiveId = null;
      _hasUnsavedChanges = _project.lines.isNotEmpty;
      _persistArchiveSession();
    }
    unawaited(_storage.saveArchives(_archives));
    _setStatusInternal('已删除存档「${target.name}」');
    notifyListeners();
    return true;
  }

  void _setStatusInternal(String message) {
    if (_statusMessage == message) return;
    _statusMessage = message;
    if (!_disposed) {
      _statusNotifier.value = message;
    }
  }

  void setStatus(String message) {
    _setStatusInternal(message);
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _persistArchiveSession() {
    unawaited(
      _storage.saveArchiveSession(
        ArchiveSessionState(
          activeArchiveId: _activeArchiveId,
          hasUnsavedChanges: _hasUnsavedChanges,
          hasFetchedExternalLyrics: _hasFetchedExternalLyrics,
        ),
      ),
    );
  }

  void schedulePersist({bool markDirty = true}) {
    if (markDirty && !_hasUnsavedChanges) {
      _hasUnsavedChanges = true;
      _persistArchiveSession();
    }
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(_storage.saveProject(_project));
      _persistArchiveSession();
    });
  }

  void _syncEngine() {
    _audio.configure(
      bpm: _project.meta.bpm,
      beatsPerBar: _project.meta.beatsPerBar,
      offsetMs: _project.meta.offsetMs,
      metronomeEnabled: _metronomeEnabled,
      metronomeVolume: _metronomeVolume,
      gtBeepEnabled: _gtBeepEnabled,
      playbackRate: _playbackRate,
    );
    _audio.setAlerts([
      for (final a in sortedAlerts)
        (id: a.id, triggerTimeMs: a.triggerTimeMs, leadBeats: a.leadBeats),
    ]);
  }

  void _handleTimeUpdate(int timeMs) {
    if (_disposed) return;
    if (_currentTimeMs == timeMs) return;
    _currentTimeMs = timeMs;
    _recomputePlaybackDerivedStates();
    _playbackNotifier.notifyListeners();
  }

  void _handleBeatTrigger(BeatSnapshot snap) {
    if (_disposed) return;
    _currentBar = snap.bar;
    _currentBeatInBar = snap.beatInBar;
    final energy = (snap.beatInBar == 1 ? 0.92 : 0.45) * (_project.meta.bpm / 200.0).clamp(0.4, 1.15);
    _beatPulseSeries.removeAt(0);
    _beatPulseSeries.add(energy.clamp(0.12, 1.0));
    _beatSeriesRevision++;
    _beatNotifier.notifyListeners();
    _playbackNotifier.notifyListeners();
  }

  void _refreshCallDensitySeries() {
    final counts = [
      for (final line in sortedLines)
        (line.calls.length + (line.customShout.trim().isNotEmpty ? 1 : 0))
            .clamp(0, 4),
    ];
    if (counts.isEmpty) {
      _callDensitySeries.fillRange(0, _callDensitySeries.length, 0.2);
    } else {
      for (var i = 0; i < _callDensitySeries.length; i++) {
        final idx = (i * counts.length / _callDensitySeries.length)
            .floor()
            .clamp(0, counts.length - 1);
        _callDensitySeries[i] = (0.18 + counts[idx] * 0.22).clamp(0.18, 1.0);
      }
    }
    _callDensityRevision++;
  }

  @override
  void dispose() {
    _disposed = true;
    _persistTimer?.cancel();
    unawaited(_audio.dispose());
    _api.dispose();
    _neteaseDirect.dispose();
    _lrclibDirect.dispose();
    _themeNotifier.dispose();
    _playbackNotifier.dispose();
    _beatNotifier.dispose();
    _playingLineIdNotifier.dispose();
    _activeGtTargetLineIdNotifier.dispose();
    _statusNotifier.dispose();
    super.dispose();
  }
}
