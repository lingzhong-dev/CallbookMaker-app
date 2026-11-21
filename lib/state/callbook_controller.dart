import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../data/default_songs.dart';
import '../models/callbook_models.dart';
import '../services/api_client.dart';
import '../services/audio_metronome_service.dart';
import '../services/desktop_service_launcher.dart';
import '../services/lrclib_direct_client.dart';
import '../services/netease_direct_client.dart';
import '../services/project_storage.dart';
import '../utils/aligned_calls.dart';
import '../utils/lrc_ruby_parser.dart';
import '../utils/section_detector.dart';
import '../utils/shortcut_validator.dart';

enum StudioRoute { dashboard, export, archive, more }

class AppBannerEvent {
  const AppBannerEvent({
    required this.id,
    required this.text,
    this.level = prism.BannerLevel.info,
    this.actionLabel,
    this.onAction,
  });

  final int id;
  final String text;
  final prism.BannerLevel level;
  final String? actionLabel;
  final VoidCallback? onAction;
}

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
    id: 'tiyi-blue',
    name: '天依蓝',
    description: '#66CCFF · 洛天依经典应援色',
    seedColor: Color(0xFF66CCFF),
    mode: prism.ThemeMode.system,
    style: prism.ColorStyle.vivid,
  ),
  CuratedThemePreset(
    id: 'miku-green',
    name: '初音绿',
    description: '#39C5BB · 初音未来苍绿应援色',
    seedColor: Color(0xFF39C5BB),
    mode: prism.ThemeMode.system,
    style: prism.ColorStyle.vivid,
  ),
  CuratedThemePreset(
    id: 'kasumi-red',
    name: '香澄红',
    description: '#FF5522 · BanG Dream! Poppin\'Party',
    seedColor: Color(0xFFFF5522),
    mode: prism.ThemeMode.system,
    style: prism.ColorStyle.vivid,
  ),
];

const List<Color> savedSwatchSeeds = [
  Color(0xFF66CCFF),
  Color(0xFF39C5BB),
  Color(0xFFFF5522),
];

sealed class TimelineItem {
  const TimelineItem(this.sortMs);
  final int sortMs;
}

class GtFlashEvent {
  const GtFlashEvent({
    required this.lineId,
    required this.reverse,
    required this.seq,
  });

  final String lineId;
  final bool reverse;
  final int seq;
}

class TimelineLineItem extends TimelineItem {
  TimelineLineItem(this.line) : super(line.startTimeMs);
  final LyricLine line;
}

class _TimelineUndoEntry {
  const _TimelineUndoEntry({
    required this.project,
    required this.activeLineId,
    required this.currentTimeMs,
    required this.label,
  });

  final CallProject project;
  final String? activeLineId;
  final int currentTimeMs;
  final String label;
}

class CallbookController extends ChangeNotifier {
  CallbookController({
    CallbookApiClient? apiClient,
    ProjectStorage? storage,
    NeteaseDirectClient? neteaseDirectClient,
    LrclibDirectClient? lrclibDirectClient,
    DesktopServiceLauncher? desktopLauncher,
    bool enableAudioOutput = true,
  }) : _api = apiClient ?? CallbookApiClient(),
       _storage = storage ?? ProjectStorage(),
       _neteaseDirect = neteaseDirectClient ?? NeteaseDirectClient(),
       _lrclibDirect = lrclibDirectClient ?? LrclibDirectClient(),
       _desktopLauncher = desktopLauncher ?? DesktopServiceLauncher() {
    _audio = AudioMetronomeService(
      enablePlatformAudio: enableAudioOutput,
      onTimeUpdate: _handleTimeUpdate,
      onBeatTrigger: _handleBeatTrigger,
      onGtAlertBeep: (_) {},
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
        _setPlayingState(false);
        _followPausedByScrollTop = false;
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
  late final DesktopServiceLauncher _desktopLauncher;
  late final AudioMetronomeService _audio;

  // Scoped sub-notifiers to keep high-frequency playback/status updates from
  // rebuilding PrismApp, ThemeCrossFade, HomeShell, or the timeline card list.
  final ChangeNotifier _themeNotifier = ChangeNotifier();
  final ChangeNotifier _routeNotifier = ChangeNotifier();
  final ChangeNotifier _projectNotifier = ChangeNotifier();
  final ChangeNotifier _archiveNotifier = ChangeNotifier();
  final ChangeNotifier _gatewayNotifier = ChangeNotifier();
  final ChangeNotifier _playbackNotifier = ChangeNotifier();
  final ChangeNotifier _playbackSyncNotifier = ChangeNotifier();
  final ChangeNotifier _beatNotifier = ChangeNotifier();
  final ValueNotifier<String?> _playingLineIdNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<String?> _upcomingLineIdNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<String> _statusNotifier =
      ValueNotifier<String>('已就绪 · CallbookMaker');
  final ValueNotifier<AppBannerEvent?> _bannerNotifier =
      ValueNotifier<AppBannerEvent?>(null);
  final ValueNotifier<GtFlashEvent?> _gtFlashNotifier =
      ValueNotifier<GtFlashEvent?>(null);
  final ValueNotifier<int> _jumpToCurrentLineSignal = ValueNotifier<int>(0);
  final ValueNotifier<int> _scrollToTopSignal = ValueNotifier<int>(0);
  final ValueNotifier<bool> shortcutsVisibleNotifier =
      ValueNotifier<bool>(false);
  int _bannerSeq = 0;
  int _gtFlashSeq = 0;

  bool _disposed = false;

  CallProject _project = defaultPrimarySong.buildCleanProject();
  List<LyricLine> _sortedLinesCache = const [];
  List<GtAlert> _sortedAlertsCache = const [];
  Map<String, GtAlert> _alertByLineIdCache = const {};
  List<TimelineLineItem> _timelineItemsCache = const [];
  String? _playingLineIdCache;
  String? _upcomingLineIdCache;

  List<CallPreset> _customPresets = const [];
  List<CallPreset> _allPresetsCache = List<CallPreset>.unmodifiable(
    defaultCallPresets,
  );
  Map<String, CallPreset> _presetMapCache = Map<String, CallPreset>.unmodifiable({
    for (final p in defaultCallPresets) p.id: p,
  });
  DisplayLayers _displayLayers = const DisplayLayers();
  String? _activeLineId;
  StudioRoute _route = StudioRoute.dashboard;
  int _moreRootResetNonce = 0;
  bool _sidebarExpanded = true;
  bool _showOnboarding = false;
  bool _onboardingReopened = false;

  // Theme State (`FlClashThemeManager` equivalent)
  prism.ThemeMode _themeMode = prism.ThemeMode.system;
  Color _seedColor = const Color(0xFF66CCFF);
  prism.ColorStyle _colorStyle = prism.ColorStyle.vivid;
  bool _pureBlack = false;
  bool _liquidGlass = true;
  bool _reduceMotion = false;
  bool _floatingNavDock = true;
  bool _useGoogleSans = true;
  double _textScale = 1.0;
  prism.ThemeData? _cachedLightTheme;
  prism.ThemeData? _cachedDarkTheme;

  // Audio / Clock State
  bool _isPlaying = false;
  bool _togglePlayInFlight = false;
  int _sourceSwitchSeq = 0;
  bool _isPracticeMode = false;
  bool _followPlayback = true;
  bool _followPausedByScrollTop = false;
  bool _autoAdvanceOnTag = false;
  bool _metronomeEnabled = true;
  double _metronomeVolume = 0.95;
  double _playbackRate = 1.0;
  int _currentTimeMs = 0;
  int _durationMs = defaultPrimarySong.durationMs;
  int _knownAudioDurationMs = defaultPrimarySong.durationMs;
  SectionDetectThresholds _sectionThresholds = const SectionDetectThresholds();
  int _currentBar = 1;
  int _currentBeatInBar = 1;
  bool _backendOnline = false;
  bool _customProxyEnabled = false;
  bool _isSearching = false;
  bool _isFetchingLyrics = false;
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
  final List<_TimelineUndoEntry> _undoHistory = <_TimelineUndoEntry>[];

  // Sparkline Histories (`LineChart` data)
  final List<double> _beatPulseSeries = List<double>.filled(24, 0.24, growable: true);
  int _beatSeriesRevision = 0;
  final List<double> _callDensitySeries = List<double>.filled(16, 0.2, growable: true);
  int _callDensityRevision = 0;

  Timer? _persistTimer;

  // Scoped listenables
  Listenable get themeListenable => _themeNotifier;
  Listenable get routeListenable => _routeNotifier;
  Listenable get projectListenable => _projectNotifier;
  Listenable get archiveListenable => _archiveNotifier;
  Listenable get gatewayListenable => _gatewayNotifier;
  Listenable get playbackListenable => _playbackNotifier;
  Listenable get playbackSyncListenable => _playbackSyncNotifier;
  Listenable get beatListenable => _beatNotifier;
  ValueListenable<String?> get playingLineIdListenable => _playingLineIdNotifier;
  ValueListenable<String?> get upcomingLineIdListenable => _upcomingLineIdNotifier;
  ValueListenable<bool> get isPlayingListenable => _isPlayingNotifier;
  ValueListenable<String> get statusListenable => _statusNotifier;
  ValueListenable<AppBannerEvent?> get bannerListenable => _bannerNotifier;
  ValueListenable<GtFlashEvent?> get gtFlashListenable => _gtFlashNotifier;
  ValueListenable<int> get jumpToCurrentLineSignal => _jumpToCurrentLineSignal;
  ValueListenable<int> get scrollToTopSignal => _scrollToTopSignal;

  // Getters
  bool get isFetchingLyrics => _isFetchingLyrics;
  bool get followPausedByScrollTop => _followPausedByScrollTop;
  CallProject get project => _project;
  bool get canUndo => _undoHistory.isNotEmpty;
  String? get lastUndoLabel =>
      _undoHistory.isEmpty ? null : _undoHistory.last.label;
  bool get hasExternalAudio => _audio.hasExternalAudio;
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
  List<CallPreset> get allPresets => _allPresetsCache;
  Map<String, CallPreset> get presetMap => _presetMapCache;
  List<CallPreset> get customPresets => _customPresets;
  DisplayLayers get displayLayers => _displayLayers;
  String? get activeLineId => _activeLineId;
  StudioRoute get route => _route;
  int get moreRootResetNonce => _moreRootResetNonce;
  bool get sidebarExpanded => _sidebarExpanded;
  bool get showOnboarding => _showOnboarding;
  bool get onboardingReopened => _onboardingReopened;

  prism.ThemeMode get themeMode => _themeMode;
  Color get seedColor => _seedColor;
  prism.ColorStyle get colorStyle => _colorStyle;
  bool get pureBlack => _pureBlack;
  bool get liquidGlass => _liquidGlass;
  bool get reduceMotion => _reduceMotion;
  bool get floatingNavDock => _floatingNavDock;
  bool get useGoogleSans => _useGoogleSans;
  double get textScale => _textScale;

  bool get isPlaying => _isPlaying;
  bool get isPracticeMode => _isPracticeMode;
  bool get followPlayback => _followPlayback;
  bool get autoAdvanceOnTag => _autoAdvanceOnTag;
  bool get metronomeEnabled => _metronomeEnabled;
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

  String? get upcomingLineId => _upcomingLineIdCache;

  String? get followTargetLineId => _playingLineIdCache ?? _upcomingLineIdCache;

  int get taggedLineCount => _project.lines
      .where(
        (l) =>
            l.calls.isNotEmpty ||
            l.customShout.trim().isNotEmpty ||
            l.tailUpdraft ||
            l.alignedCalls.isNotEmpty,
      )
      .length;

  GtAlert? getAlertForLine(String lineId) => _alertByLineIdCache[lineId];

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
    for (final alert in alerts) {
      final targetId = resolveGtAlertTargetLineId(alert, lines);
      if (targetId != null) {
        alertByLine.putIfAbsent(targetId, () => alert);
      }
    }
    _sortedLinesCache = List.unmodifiable(lines);
    _sortedAlertsCache = List.unmodifiable(alerts);
    _alertByLineIdCache = Map.unmodifiable(alertByLine);
    _timelineItemsCache = List.unmodifiable([
      for (final l in lines) TimelineLineItem(l),
    ]);
    _recomputePlaybackDerivedStates();
  }

  void _rebuildPresetCaches() {
    final merged = <CallPreset>[...defaultCallPresets, ..._customPresets];
    _allPresetsCache = List<CallPreset>.unmodifiable(merged);
    _presetMapCache = Map<String, CallPreset>.unmodifiable({
      for (final p in merged) p.id: p,
    });
  }

  void _recomputePlaybackDerivedStates({bool forceNotify = false}) {
    final t = _currentTimeMs;
    String? nextPlayingId;
    for (final line in _sortedLinesCache) {
      if (t >= line.startTimeMs && t < line.endTimeMs) {
        nextPlayingId = line.id;
        break;
      }
    }
    String? nextUpcomingId;
    if (nextPlayingId == null &&
        _sortedLinesCache.isNotEmpty &&
        t < _sortedLinesCache.first.startTimeMs) {
      nextUpcomingId = _sortedLinesCache.first.id;
    }

    final playingChanged = _playingLineIdCache != nextPlayingId;
    final upcomingChanged = _upcomingLineIdCache != nextUpcomingId;
    _playingLineIdCache = nextPlayingId;
    _upcomingLineIdCache = nextUpcomingId;

    if (!_disposed) {
      if (_playingLineIdNotifier.value != nextPlayingId) {
        _playingLineIdNotifier.value = nextPlayingId;
      }
      if (_upcomingLineIdNotifier.value != nextUpcomingId) {
        _upcomingLineIdNotifier.value = nextUpcomingId;
      }
      if (forceNotify || playingChanged || upcomingChanged) {
        _playbackSyncNotifier.notifyListeners();
      }
    }
  }

  void _setPlayingState(bool value) {
    _isPlaying = value;
    if (!_disposed && _isPlayingNotifier.value != value) {
      _isPlayingNotifier.value = value;
    }
  }

  /// Recomputes playback-derived line targets from the current clock position
  /// and forces a sync notification even when the resolved line id is unchanged.
  void syncPlaybackState({bool forceNotify = true}) {
    _recomputePlaybackDerivedStates(forceNotify: forceNotify);
    if (!_disposed) {
      _playbackNotifier.notifyListeners();
    }
  }

  void _notifyRouteChanged() {
    if (!_disposed) {
      _routeNotifier.notifyListeners();
      notifyListeners();
    }
  }

  void _notifyProjectChanged() {
    if (!_disposed) {
      _projectNotifier.notifyListeners();
      notifyListeners();
    }
  }

  void _notifyArchiveChanged() {
    if (!_disposed) {
      _archiveNotifier.notifyListeners();
      notifyListeners();
    }
  }

  void _notifyGatewayChanged() {
    if (!_disposed) {
      _gatewayNotifier.notifyListeners();
      notifyListeners();
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

  int _resolveKnownDurationMs(CallProject proj) {
    final defaultSpec = findDefaultSongByProject(proj);
    if (defaultSpec != null) {
      return defaultSpec.durationMs;
    }
    if (proj.meta.platform == 'synthetic') {
      return 48000;
    }
    return 0;
  }

  int _computeProjectDurationMs(
    CallProject proj, {
    int knownAudioDurationMs = 0,
  }) {
    final maxEnd = proj.lines.fold<int>(
      0,
      (prev, l) => math.max(prev, l.endTimeMs),
    );
    final hasOutro = proj.lines.any((l) => l.kind == LyricLineKind.outro);
    if (knownAudioDurationMs > 0 || hasOutro) {
      return math.max(48000, math.max(knownAudioDurationMs, maxEnd));
    }
    return math.max(48000, maxEnd + 4000);
  }

  Future<void> _restoreAudioSourceForProject(
    CallProject proj, {
    required int durationMs,
    int? switchToken,
    bool refreshExpiredRemoteUrl = false,
  }) async {
    bool isStale() =>
        _disposed || (switchToken != null && switchToken != _sourceSwitchSeq);

    final meta = proj.meta;
    final url = meta.audioUrl.trim();
    if (meta.platform == 'local' && url.isNotEmpty) {
      try {
        await _audio.setAudioSource(
          localPath: url,
          fallbackDurationMs: durationMs,
        );
        return;
      } catch (_) {
        if (isStale()) return;
        try {
          await _audio.setAudioSource(fallbackDurationMs: durationMs);
        } catch (_) {}
        return;
      }
    }

    if (url.isNotEmpty && !url.startsWith('blob:')) {
      try {
        await _audio.setAudioSource(
          url: url,
          fallbackDurationMs: durationMs,
        );
        return;
      } catch (_) {
        if (isStale()) return;
      }
    }

    var trackId = (meta.trackId ?? '').trim();
    if (refreshExpiredRemoteUrl && meta.platform == 'netease') {
      try {
        TrackDetailResponse? refreshed;
        if (trackId.isEmpty) {
          final defaultSpec = findDefaultSongByProject(proj);
          final query = defaultSpec != null
              ? defaultSpec.neteaseSearchQuery
              : '${meta.title} ${meta.artist}'.trim();
          if (query.isNotEmpty) {
            List<TrackSummary> matches = const [];
            if (_backendOnline &&
                (_customProxyEnabled || _gatewayStatus.gatewayOnline)) {
              try {
                final resp = await _api
                    .searchTracks(query, source: 'custom_proxy')
                    .timeout(const Duration(seconds: 5));
                matches = resp.results;
              } catch (_) {
                matches = const [];
              }
            }
            if (matches.isEmpty) {
              try {
                matches = await _neteaseDirect
                    .searchTracks(
                      query,
                      limit: 5,
                      cookie: _savedNeteaseCookie,
                    )
                    .timeout(const Duration(seconds: 5));
              } catch (_) {
                matches = const [];
              }
            }
            if (isStale()) return;
            if (matches.isNotEmpty) {
              final shortTitle = meta.title.split('（').first.toLowerCase();
              final picked = matches.firstWhere(
                (t) {
                  final candidate = t.title.toLowerCase();
                  return candidate.contains(shortTitle) ||
                      shortTitle.contains(candidate);
                },
                orElse: () => matches.first,
              );
              trackId = picked.id.trim();
            }
          }
        }

        if (trackId.isNotEmpty) {
          if (_backendOnline) {
            try {
              refreshed = await _api
                  .fetchTrackDetail('netease', trackId)
                  .timeout(const Duration(seconds: 6));
            } catch (_) {
              refreshed = null;
            }
          }
          refreshed ??= await _neteaseDirect
              .fetchTrackDetail(
                trackId,
                cookie: _savedNeteaseCookie,
              )
              .timeout(const Duration(seconds: 6));
          if (isStale()) return;
          final freshUrl = refreshed.audioUrl.trim();
          if (freshUrl.isNotEmpty && !freshUrl.startsWith('blob:')) {
            if (_project.meta.title == proj.meta.title &&
                _project.meta.platform == proj.meta.platform) {
              _setProject(
                _project.copyWith(
                  meta: _project.meta.copyWith(
                    trackId: trackId,
                    audioUrl: freshUrl,
                  ),
                ),
              );
            }
            try {
              await _audio.setAudioSource(
                url: freshUrl,
                fallbackDurationMs: durationMs,
              );
              schedulePersist(markDirty: false);
              return;
            } catch (_) {
              if (isStale()) return;
            }
          }
        }
      } catch (_) {
        if (isStale()) return;
      }
    }

    try {
      await _audio.setAudioSource(fallbackDurationMs: durationMs);
    } catch (_) {}
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

    final hasRawSavedProject = await _storage.hasSavedProjectKey();
    final savedProj = await _storage.loadProject();
    _customPresets = await _storage.loadCustomPresets();
    _rebuildPresetCaches();
    _displayLayers = await _storage.loadDisplayLayers();
    _archives = await _storage.loadArchives();
    final onboardingCompleted = await _storage.loadOnboardingCompleted();
    final isFreshInstall =
        !onboardingCompleted && !hasRawSavedProject && _archives.isEmpty;

    if (isFreshInstall) {
      final seeded = buildDefaultArchiveEntries();
      _archives = seeded;
      _setProject(_normalizeProjectAlerts(seeded.first.project));
      _knownAudioDurationMs = _resolveKnownDurationMs(_project);
      _durationMs = _computeProjectDurationMs(
        _project,
        knownAudioDurationMs: _knownAudioDurationMs,
      );
      _activeArchiveId = seeded.first.id;
      _hasUnsavedChanges = false;
      _hasFetchedExternalLyrics = false;
      _showOnboarding = true;
      _onboardingReopened = false;
      await _storage.saveArchives(_archives);
      await _storage.saveProject(_project);
      await _storage.saveArchiveSession(
        ArchiveSessionState(
          activeArchiveId: _activeArchiveId,
          hasUnsavedChanges: false,
          hasFetchedExternalLyrics: false,
        ),
      );
    } else {
      if (!onboardingCompleted) {
        await _storage.saveOnboardingCompleted(true);
      }
      _showOnboarding = false;
      _onboardingReopened = false;
      if (savedProj != null && savedProj.lines.isNotEmpty) {
        _setProject(_normalizeProjectAlerts(savedProj));
      } else {
        _setProject(
          _normalizeProjectAlerts(defaultPrimarySong.buildCleanProject()),
        );
      }
      _knownAudioDurationMs = _resolveKnownDurationMs(_project);
      _durationMs = _computeProjectDurationMs(
        _project,
        knownAudioDurationMs: _knownAudioDurationMs,
      );
      final savedSession = await _storage.loadArchiveSession();
      if (savedSession != null) {
        final stillExists = savedSession.activeArchiveId != null &&
            _archives.any((a) => a.id == savedSession.activeArchiveId);
        _activeArchiveId = stillExists ? savedSession.activeArchiveId : null;
        _hasUnsavedChanges = savedSession.hasUnsavedChanges;
        _hasFetchedExternalLyrics = savedSession.hasFetchedExternalLyrics;
      } else if (savedProj != null &&
          savedProj.meta.platform != 'synthetic' &&
          findDefaultSongByProject(savedProj) == null) {
        _hasFetchedExternalLyrics = true;
        _hasUnsavedChanges = true;
      }
    }

    _currentTimeMs = 0;
    if (sortedLines.isNotEmpty) {
      _activeLineId = sortedLines.first.id;
    }
    _recomputePlaybackDerivedStates(forceNotify: true);
    _refreshCallDensitySeries();
    _syncEngine();
    _themeNotifier.notifyListeners();
    _routeNotifier.notifyListeners();
    _projectNotifier.notifyListeners();
    _archiveNotifier.notifyListeners();
    _gatewayNotifier.notifyListeners();
    notifyListeners();

    final initSeq = ++_sourceSwitchSeq;
    await checkBackendHealth();
    if (_disposed || initSeq != _sourceSwitchSeq) return;
    await _restoreAudioSourceForProject(
      _project,
      durationMs: _durationMs,
      switchToken: initSeq,
      refreshExpiredRemoteUrl: true,
    );
    if (!_disposed && initSeq == _sourceSwitchSeq) {
      _playbackNotifier.notifyListeners();
      notifyListeners();
    }
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
    _reduceMotion = map['reduceMotion'] == true;
    _floatingNavDock = map['floatingNavDock'] != false;
    _useGoogleSans = map['useGoogleSans'] != false;
    _autoAdvanceOnTag = map['autoAdvanceOnTag'] == true;
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
            : '纯 Dart 直连就绪（免 Node · 支持网易云游客直连 / LRCLIB / 默认曲库）',
      );
      _setStatusInternal('纯 Dart 直连模式 · 免 Node/后端直接搜歌演练');
    }
    _notifyGatewayChanged();
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
    _setStatusInternal(probe.message);
    _notifyGatewayChanged();
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
    }
  }

  Future<void> launchLocalBackendOnDesktop() async {
    if (_isLaunchingBackend) return;
    _isLaunchingBackend = true;
    _setStatusInternal('正在启动可选 FastAPI 后端 (${_api.baseUrl})...');
    _notifyGatewayChanged();
    try {
      final res = await _desktopLauncher.ensureBackendRunning(_api.baseUrl);
      _setStatusInternal(res.message);
      await checkBackendHealth();
    } finally {
      _isLaunchingBackend = false;
      _notifyGatewayChanged();
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
    _setStatusInternal(
      _backendOnline
          ? '正在写入网易云 Cookie 并配置服务...'
          : '正在保存 Cookie 并验证网易云纯 Dart 直连...',
    );
    _notifyGatewayChanged();

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
            _setStatusInternal(status.message);
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
          _setStatusInternal(status.message);
        }
        return false;
      }

      // Standalone pure-Dart mode: validate account/connection directly via EAPI (no Node or Python required).
      return await _verifyDirectNetease(
        cookie: normCookie,
        cleanUrl: cleanUrl,
      );
    } catch (err) {
      _setStatusInternal('配置网易云直连失败：$err');
      return false;
    } finally {
      _isConfiguringGateway = false;
      _notifyGatewayChanged();
    }
  }

  Future<void> stopManagedGateway() async {
    if (!_backendOnline) return;
    try {
      final status = await _api.stopGateway();
      _gatewayStatus = status;
      _setStatusInternal(status.message);
      _notifyGatewayChanged();
    } catch (err) {
      _setStatusInternal('停止网关失败：$err');
      _notifyGatewayChanged();
    }
  }

  void setRoute(StudioRoute next) {
    if (_route == next && next != StudioRoute.more) return;
    _route = next;
    if (next == StudioRoute.more) {
      _moreRootResetNonce++;
    }
    _notifyRouteChanged();
  }

  void toggleSidebarExpanded() {
    _sidebarExpanded = !_sidebarExpanded;
    _notifyRouteChanged();
  }

  void setPracticeMode(bool value) {
    _isPracticeMode = value;
    if (value) {
      syncPlaybackState(forceNotify: true);
    }
    _notifyRouteChanged();
  }

  void setFollowPlayback(bool value) {
    final wasFollowing = _followPlayback;
    _followPlayback = value;
    if (value) {
      _followPausedByScrollTop = false;
    }
    if (value && !wasFollowing) {
      syncPlaybackState(forceNotify: true);
      _jumpToCurrentLineSignal.value++;
    }
    _notifyProjectChanged();
  }

  /// Pauses automatic playback following when the user taps "Back to Top"
  /// during active playback, allowing a one-tap return to the current line.
  void pauseFollowFromScrollToTop() {
    if (!_isPlaying) return;
    _followPausedByScrollTop = true;
    _followPlayback = false;
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
  }

  /// Restores automatic playback following and triggers a scroll back to the
  /// active/upcoming playback line.
  void resumeFollowFromScrollToTop() {
    _followPausedByScrollTop = false;
    _followPlayback = true;
    syncPlaybackState(forceNotify: true);
    _jumpToCurrentLineSignal.value++;
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
  }

  void toggleShortcutsPanel([bool? visible]) {
    shortcutsVisibleNotifier.value =
        visible ?? !shortcutsVisibleNotifier.value;
  }

  void triggerScrollToTop() {
    _scrollToTopSignal.value++;
  }

  void notify(
    String text, {
    prism.BannerLevel level = prism.BannerLevel.info,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    if (_disposed) return;
    _bannerSeq++;
    _bannerNotifier.value = AppBannerEvent(
      id: _bannerSeq,
      text: text,
      level: level,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  void setAutoAdvanceOnTag(bool value) {
    if (_autoAdvanceOnTag == value) return;
    _autoAdvanceOnTag = value;
    _saveThemePrefs();
    _notifyProjectChanged();
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

  void setReduceMotion(bool v) {
    if (_reduceMotion == v) return;
    _reduceMotion = v;
    _saveThemePrefs();
    _notifyThemeChanged();
  }

  void setFloatingNavDock(bool v) {
    _floatingNavDock = v;
    _saveThemePrefs();
    _notifyRouteChanged();
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
    _saveThemePrefs();
    _notifyThemeChanged();
  }

  void resetTheme() {
    _seedColor = curatedThemePresets.first.seedColor;
    _themeMode = curatedThemePresets.first.mode;
    _colorStyle = curatedThemePresets.first.style;
    _pureBlack = curatedThemePresets.first.pureBlack;
    _liquidGlass = true;
    _reduceMotion = false;
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
        'reduceMotion': _reduceMotion,
        'floatingNavDock': _floatingNavDock,
        'useGoogleSans': _useGoogleSans,
        'autoAdvanceOnTag': _autoAdvanceOnTag,
        'textScale': _textScale,
      }),
    );
  }

  // Playback & Metronome controls
  Future<void> togglePlay() async {
    if (_togglePlayInFlight) return;
    _togglePlayInFlight = true;
    try {
      if (_isPlaying) {
        await _audio.pause();
        _setPlayingState(false);
        _followPausedByScrollTop = false;
        _playbackNotifier.notifyListeners();
      } else {
        final started = await _audio.play();
        _setPlayingState(started);
        if (!started) {
          _setStatusInternal('音频播放失败，请检查音源或系统音频设备');
          _playbackNotifier.notifyListeners();
        } else {
          syncPlaybackState(forceNotify: true);
        }
      }
      notifyListeners();
    } finally {
      _togglePlayInFlight = false;
    }
  }

  Future<void> seek(int ms) async {
    await _audio.seek(ms);
    if (!_disposed) {
      syncPlaybackState(forceNotify: true);
      if (_followPlayback) {
        _jumpToCurrentLineSignal.value++;
      }
    }
  }

  void setBpm(int bpm) {
    final clamped = bpm.clamp(30, 300);
    _setProject(_project.copyWith(meta: _project.meta.copyWith(bpm: clamped)));
    _syncEngine();
    schedulePersist();
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
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
    _notifyProjectChanged();
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
    _notifyProjectChanged();
  }

  void setOffset(int ms) {
    _setProject(_project.copyWith(meta: _project.meta.copyWith(offsetMs: ms)));
    _syncEngine();
    schedulePersist();
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
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
    _notifyProjectChanged();
  }

  void setMetronomeVolume(double volume) {
    _metronomeVolume = volume.clamp(0.2, 1.5);
    _syncEngine();
    _notifyProjectChanged();
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
    _notifyProjectChanged();
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
    _notifyProjectChanged();
  }

  // Timeline editing
  void selectLine(String id, {bool seekToLine = false}) {
    _activeLineId = id;
    if (seekToLine) {
      final found = _project.lines.where((l) => l.id == id);
      if (found.isNotEmpty) {
        unawaited(seek(found.first.startTimeMs));
      }
    }
    _notifyProjectChanged();
  }

  void stepActiveLine(int delta) {
    final ordered = sortedLines;
    if (ordered.isEmpty) return;
    final idx = ordered.indexWhere((l) => l.id == _activeLineId);
    final nextIdx = idx < 0
        ? 0
        : (idx + delta).clamp(0, ordered.length - 1);
    _activeLineId = ordered[nextIdx].id;
    _notifyProjectChanged();
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
    _notifyProjectChanged();
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
    _setStatusInternal(
      enabled
          ? '已标记尾句上升气流 · ${lines[idx].text.original}'
          : '已取消尾句上升气流 · ${lines[idx].text.original}',
    );
    _notifyProjectChanged();
  }

  bool quickTagActiveLine(
    String presetId, {
    bool? autoAdvance,
    String? suffix,
  }) {
    final target = resolveLineForQuickTag();
    if (target == null) {
      setStatus('暂无可打标的歌词行');
      return false;
    }
    _activeLineId = target.id;
    final added = toggleLineCall(target.id, presetId, suffix: suffix);
    if (added && (autoAdvance ?? _autoAdvanceOnTag)) {
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
    _notifyProjectChanged();
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
    final nextOriginal = original ?? current.text.original;
    final nextAligned = original != null
        ? (nextOriginal.trim().isEmpty
            ? const <AlignedCallCue>[]
            : normalizeAlignedCalls(current.alignedCalls, nextOriginal.length))
        : current.alignedCalls;
    lines[idx] = current.copyWith(
      startTimeMs: startTimeMs,
      endTimeMs: endTimeMs,
      kind: kind,
      autoGenerated:
          kind != null && kind != current.kind ? false : current.autoGenerated,
      customShout: customShout,
      alignedCalls: nextAligned,
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
    _notifyProjectChanged();
  }

  void _clearUndoHistory() {
    _undoHistory.clear();
  }

  void _pushUndo(String label) {
    final snapshot = _normalizeProjectAlerts(
      CallProject.fromJson(_project.toJson()),
    );
    _undoHistory.add(
      _TimelineUndoEntry(
        project: snapshot,
        activeLineId: _activeLineId,
        currentTimeMs: _currentTimeMs,
        label: label,
      ),
    );
    if (_undoHistory.length > 25) {
      _undoHistory.removeAt(0);
    }
  }

  bool undoLastTimelineEdit() {
    if (_undoHistory.isEmpty) return false;
    final prevAlertLineIds = _alertByLineIdCache.keys.toSet();
    final entry = _undoHistory.removeLast();
    _setProject(_normalizeProjectAlerts(entry.project));
    final nextAlertLineIds = _alertByLineIdCache.keys.toSet();
    final removedGtLines = prevAlertLineIds.difference(nextAlertLineIds);
    final addedGtLines = nextAlertLineIds.difference(prevAlertLineIds);
    if (removedGtLines.isNotEmpty) {
      _emitGtFlash(removedGtLines.first, reverse: true);
    } else if (addedGtLines.isNotEmpty) {
      _emitGtFlash(addedGtLines.first, reverse: false);
    }
    final fallbackId = sortedLines.isNotEmpty ? sortedLines.first.id : null;
    if (entry.activeLineId != null &&
        _project.lines.any((l) => l.id == entry.activeLineId)) {
      _activeLineId = entry.activeLineId;
    } else {
      _activeLineId = fallbackId;
    }
    _refreshCallDensitySeries();
    _syncEngine();
    schedulePersist();
    _setStatusInternal('已撤销「${entry.label}」');
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
    return true;
  }

  bool mergeWithNextLine(String lineId) {
    final ordered = sortedLines;
    final idx = ordered.indexWhere((l) => l.id == lineId);
    if (idx < 0 || idx + 1 >= ordered.length) return false;
    final first = ordered[idx];
    final second = ordered[idx + 1];
    if (first.kind.isSection || second.kind.isSection) {
      setStatus('段落标题行不能与歌词直接合并');
      return false;
    }

    _pushUndo('合并下句');
    final merged = mergeAdjacentLyricLines(first, second);
    final nextLines = [
      for (final l in _project.lines)
        if (l.id == first.id)
          merged
        else if (l.id != second.id)
          l,
    ];

    final firstAlert = getAlertForLine(first.id);
    final secondAlert = getAlertForLine(second.id);
    List<GtAlert> nextAlerts;
    if (firstAlert != null &&
        secondAlert != null &&
        firstAlert.id != secondAlert.id) {
      nextAlerts = [
        for (final a in _project.alerts)
          if (a.id == firstAlert.id)
            a.copyWith(targetLineId: first.id, triggerTimeMs: merged.startTimeMs)
          else if (a.id != secondAlert.id)
            a,
      ];
    } else if (firstAlert == null && secondAlert != null) {
      nextAlerts = [
        for (final a in _project.alerts)
          if (a.id == secondAlert.id)
            a.copyWith(targetLineId: first.id, triggerTimeMs: merged.startTimeMs)
          else
            a,
      ];
    } else if (firstAlert != null) {
      nextAlerts = [
        for (final a in _project.alerts)
          if (a.id == firstAlert.id)
            a.copyWith(targetLineId: first.id, triggerTimeMs: merged.startTimeMs)
          else
            a,
      ];
    } else {
      nextAlerts = _project.alerts;
    }

    _activeLineId = first.id;
    _setProject(_project.copyWith(lines: nextLines, alerts: nextAlerts));
    _refreshCallDensitySeries();
    _syncEngine();
    schedulePersist();
    _setStatusInternal('已合并相邻两句歌词（可点击「撤销」恢复）');
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
    return true;
  }

  bool splitLineAtRunes(
    String lineId,
    List<int> splitRuneIndices, {
    List<int>? boundaryTimesMs,
  }) {
    final ordered = sortedLines;
    final idx = ordered.indexWhere((l) => l.id == lineId);
    if (idx < 0) return false;
    final target = ordered[idx];
    if (target.kind.isSection) {
      setStatus('段落标题行不能按字拆分');
      return false;
    }
    final runeCount = target.text.original.runes.length;
    if (runeCount < 2) {
      setStatus('至少需要 2 个字符才能拆分');
      return false;
    }
    final cleanSplits = splitRuneIndices
        .where((i) => i > 0 && i < runeCount)
        .toSet()
        .toList()
      ..sort();
    if (cleanSplits.isEmpty) return false;

    _pushUndo('拆分歌词');
    final existingIds = {for (final l in _project.lines) l.id};
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final chunks = sliceLyricLineForSplit(
      target,
      cleanSplits,
      boundaryTimesMs: boundaryTimesMs,
      idFactory: (chunkIdx) {
        var candidate = '${target.id}-sp$chunkIdx-$stamp';
        var seq = 0;
        while (existingIds.contains(candidate)) {
          seq++;
          candidate = '${target.id}-sp$chunkIdx-$stamp-$seq';
        }
        existingIds.add(candidate);
        return candidate;
      },
    );
    if (chunks.length < 2) return false;

    final nextLines = <LyricLine>[
      for (final l in _project.lines)
        if (l.id == target.id) ...chunks else l,
    ];

    final targetAlert = getAlertForLine(target.id);
    final nextAlerts = targetAlert == null
        ? _project.alerts
        : [
            for (final a in _project.alerts)
              if (a.id == targetAlert.id)
                a.copyWith(
                  targetLineId: chunks.first.id,
                  triggerTimeMs: chunks.first.startTimeMs,
                )
              else
                a,
          ];

    _activeLineId = chunks.first.id;
    _setProject(_project.copyWith(lines: nextLines, alerts: nextAlerts));
    _refreshCallDensitySeries();
    _syncEngine();
    schedulePersist();
    _setStatusInternal(
      '已将歌词拆分为 ${chunks.length} 句（可点击「撤销」恢复）',
    );
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
    return true;
  }

  void upsertAlignedCall(
    String lineId, {
    String? id,
    required int start,
    required int end,
    required String text,
    String? colorHex,
  }) {
    final lines = [..._project.lines];
    final idx = lines.indexWhere((l) => l.id == lineId);
    if (idx < 0) return;
    final line = lines[idx];
    final originalLength = line.text.original.length;
    if (originalLength <= 0) return;
    final cleanText = text.trim();
    if (cleanText.isEmpty) return;

    final cueId = (id != null && id.trim().isNotEmpty)
        ? id.trim()
        : 'ac-${DateTime.now().millisecondsSinceEpoch}-${math.Random().nextInt(9999)}';
    final nextCue = AlignedCallCue(
      id: cueId,
      start: start,
      end: end,
      text: cleanText,
      colorHex: colorHex,
    );
    final existing = line.alignedCalls.where(
      (c) => c.id != cueId && !(start < c.end && end > c.start),
    );
    final normalized = normalizeAlignedCalls(
      [...existing, nextCue],
      originalLength,
    );
    lines[idx] = line.copyWith(alignedCalls: normalized);
    _setProject(_project.copyWith(lines: lines));
    _refreshCallDensitySeries();
    schedulePersist();
    _notifyProjectChanged();
  }

  void removeAlignedCall(String lineId, String cueId) {
    final lines = [..._project.lines];
    final idx = lines.indexWhere((l) => l.id == lineId);
    if (idx < 0) return;
    final line = lines[idx];
    final next = [
      for (final c in line.alignedCalls)
        if (c.id != cueId) c,
    ];
    if (next.length == line.alignedCalls.length) return;
    lines[idx] = line.copyWith(alignedCalls: next);
    _setProject(_project.copyWith(lines: lines));
    _refreshCallDensitySeries();
    schedulePersist();
    _notifyProjectChanged();
  }

  void snapLineToCurrentTime(String lineId) {
    final orderedBefore = sortedLines;
    final lines = [..._project.lines];
    final idx = lines.indexWhere((l) => l.id == lineId);
    if (idx < 0) return;
    final current = lines[idx];
    if (!_isPlaying &&
        _currentTimeMs <= 0 &&
        current.startTimeMs > 0 &&
        orderedBefore.isNotEmpty &&
        orderedBefore.first.id != lineId) {
      setStatus('当前播放时刻为 00:00.00，请先播放音频或拖动进度条到目标时刻后再「校时」');
      return;
    }

    _pushUndo('校时');
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
    _setStatusInternal('已对齐当前时间 ${formatMsToClock(_currentTimeMs)}（可点击「撤销」恢复）');
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
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
    _notifyProjectChanged();
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
    final isDefaultTemplate = findDefaultSongByProject(_project) != null;
    final totalDur = explicitDurationMs ??
        (_knownAudioDurationMs > 0
            ? _knownAudioDurationMs
            : (_project.meta.platform != 'synthetic' &&
                    !isDefaultTemplate &&
                    _durationMs > 1000
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
    _notifyProjectChanged();
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
      _notifyProjectChanged();
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
    _notifyProjectChanged();
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
    _notifyProjectChanged();
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

  void _emitGtFlash(String lineId, {required bool reverse}) {
    _gtFlashNotifier.value = GtFlashEvent(
      lineId: lineId,
      reverse: reverse,
      seq: ++_gtFlashSeq,
    );
  }

  void toggleLineGtAlert({String? lineId}) {
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
      _emitGtFlash(targetId, reverse: true);
      _playbackNotifier.notifyListeners();
      _notifyProjectChanged();
      return;
    }

    final alert = GtAlert(
      id: 'gt-${DateTime.now().millisecondsSinceEpoch}',
      triggerTimeMs: targetLine.startTimeMs,
      note: '吉他进场，准备衔接 Call',
      targetLineId: targetId,
    );
    _setProject(_project.copyWith(alerts: [..._project.alerts, alert]));
    _syncEngine();
    schedulePersist();
    _setStatusInternal('已为歌词行开启 GT 警报 · ${targetLine.text.original}');
    _emitGtFlash(targetId, reverse: false);
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
  }

  void updateLineGtAlert(
    String lineId, {
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
    _notifyProjectChanged();
  }

  void insertGtAlert({String? lineId}) {
    toggleLineGtAlert(lineId: lineId);
  }

  bool addCustomPreset({
    required String label,
    required String colorHex,
    CallCategory category = CallCategory.compound,
    String shortcut = '',
  }) {
    final clean = label.trim();
    if (clean.isEmpty) return false;
    final shortcutCheck = validatePresetShortcut(
      shortcut,
      existingPresets: _allPresetsCache,
    );
    if (!shortcutCheck.isValid) {
      setStatus(shortcutCheck.errorMessage ?? '快捷键冲突，请更换其他按键');
      return false;
    }
    final normalizedColor =
        RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(colorHex.trim())
            ? colorHex.trim().toUpperCase()
            : '#EC4899';
    final preset = CallPreset(
      id: 'custom-${DateTime.now().millisecondsSinceEpoch}',
      label: clean,
      colorHex: normalizedColor,
      category: category,
      shortcut: shortcutCheck.normalized,
    );
    _customPresets = [..._customPresets, preset];
    _rebuildPresetCaches();
    unawaited(_storage.saveCustomPresets(_customPresets));
    _setStatusInternal('已添加自定义 Call 标签：$clean');
    schedulePersist();
    _notifyProjectChanged();
    return true;
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
    String? validatedShortcut;
    if (shortcut != null) {
      final shortcutCheck = validatePresetShortcut(
        shortcut,
        existingPresets: _allPresetsCache,
        ignorePresetId: presetId,
      );
      if (!shortcutCheck.isValid) {
        setStatus(shortcutCheck.errorMessage ?? '快捷键冲突，请更换其他按键');
        return false;
      }
      validatedShortcut = shortcutCheck.normalized;
    }
    final current = _customPresets[idx];
    final normalizedColor =
        RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(colorHex.trim())
            ? colorHex.trim().toUpperCase()
            : current.colorHex;
    final updated = current.copyWith(
      label: cleanLabel,
      colorHex: normalizedColor,
      category: category,
      shortcut: validatedShortcut,
      builtIn: false,
    );
    final nextPresets = [..._customPresets];
    nextPresets[idx] = updated;
    _customPresets = nextPresets;
    _rebuildPresetCaches();
    unawaited(_storage.saveCustomPresets(_customPresets));
    _setStatusInternal('已更新自定义标签：${updated.label}');
    schedulePersist();
    _notifyProjectChanged();
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
    _rebuildPresetCaches();
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
    _notifyProjectChanged();
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
    if (cleanQuery.isEmpty) return;
    _isSearching = true;
    notifyListeners();
    try {
      final useBackendProxy =
          _backendOnline &&
          (_customProxyEnabled ||
              _gatewayStatus.managedByBackend ||
              (_gatewayStatus.gatewayOnline && _gatewayStatus.nodeAvailable));

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
        // Fall through to empty result status
      }

      _searchResults = const [];
      setStatus('未检索到匹配曲目，可尝试切换音源或使用「默认曲库」/「本地音轨 + LRC」');
    } catch (err) {
      setStatus('搜索失败：$err');
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  Future<void> loadRemoteTrack(TrackSummary summary) async {
    _isFetchingLyrics = true;
    _gatewayNotifier.notifyListeners();
    notifyListeners();
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
      if (rawLines.isEmpty && detail.rawLrc.trim().isNotEmpty) {
        rawLines = parseLrcOffline(
          detail.rawLrc,
          translationLrc: detail.translatedLrc,
        );
      }

      if (_disposed) return;
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
      final nextProject = CallProject(
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
      );
      final switchSeq = ++_sourceSwitchSeq;
      _clearUndoHistory();
      _currentTimeMs = 0;
      _setPlayingState(false);
      _durationMs = _computeProjectDurationMs(
        nextProject,
        knownAudioDurationMs: _knownAudioDurationMs,
      );
      _setProject(nextProject);
      syncPlaybackState(forceNotify: true);
      _activeLineId = sortedLines.isNotEmpty ? sortedLines.first.id : null;
      _activeArchiveId = null;
      _hasFetchedExternalLyrics = true;
      _hasUnsavedChanges = true;
      _refreshCallDensitySeries();
      _syncEngine();
      _persistArchiveSession();
      schedulePersist(markDirty: false);
      _archiveNotifier.notifyListeners();
      _notifyProjectChanged();

      var audioFallbackNote = '';
      try {
        await _audio.setAudioSource(
          url: detail.audioUrl,
          fallbackDurationMs: _durationMs,
        );
      } catch (_) {
        if (_disposed || switchSeq != _sourceSwitchSeq) return;
        try {
          await _audio.setAudioSource(fallbackDurationMs: _durationMs);
        } catch (_) {}
        audioFallbackNote = '（音源加载失败，已切换为节拍器演练）';
      }
      if (_disposed || switchSeq != _sourceSwitchSeq) return;
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
      notify(
        '导入失败：$err',
        level: prism.BannerLevel.error,
        actionLabel: '重试',
        onAction: () => unawaited(loadRemoteTrack(summary)),
      );
    } finally {
      _isFetchingLyrics = false;
      _gatewayNotifier.notifyListeners();
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
    final hasMeasuredExternalAudio =
        _knownAudioDurationMs > 0 &&
        (_project.meta.platform == 'local' ||
            _project.meta.audioUrl.trim().isNotEmpty);
    final durationForOutro =
        hasMeasuredExternalAudio ? _knownAudioDurationMs : null;
    final detected = detectAndMergeSections(
      lines,
      thresholds: _sectionThresholds,
      totalDurationMs: durationForOutro,
    );
    _clearUndoHistory();
    await _audio.pause();
    await _audio.seek(0);
    _setPlayingState(false);
    _currentTimeMs = 0;
    if (!hasMeasuredExternalAudio) {
      _knownAudioDurationMs = 0;
    }
    final nextProject = _project.copyWith(
      lines: detected.lines,
      alerts: const [],
    );
    _durationMs = _computeProjectDurationMs(
      nextProject,
      knownAudioDurationMs: _knownAudioDurationMs,
    );
    _setProject(nextProject);
    syncPlaybackState(forceNotify: true);
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
    _archiveNotifier.notifyListeners();
    _notifyProjectChanged();
  }

  Future<void> loadLocalAudioFile(String filePath, String fileName) async {
    final switchSeq = ++_sourceSwitchSeq;
    _knownAudioDurationMs = 0;
    _currentTimeMs = 0;
    _setPlayingState(false);
    try {
      await _audio.setAudioSource(localPath: filePath);
    } catch (err) {
      if (_disposed || switchSeq != _sourceSwitchSeq) return;
      setStatus('载入本地音频失败：$err');
      _playbackNotifier.notifyListeners();
      return;
    }
    if (_disposed || switchSeq != _sourceSwitchSeq) return;
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
    syncPlaybackState(forceNotify: true);
    schedulePersist();
    _setStatusInternal('已载入本地音频：$fileName');
    _notifyProjectChanged();
  }

  Future<void> loadDefaultSong(
    String songId, {
    bool preferArchive = false,
    bool silent = false,
  }) async {
    final spec = findDefaultSongById(songId) ?? defaultPrimarySong;
    final switchSeq = ++_sourceSwitchSeq;
    _clearUndoHistory();
    await _audio.pause();
    await _audio.seek(0);

    CallbookArchiveEntry? matchingArchive;
    for (final entry in _archives) {
      if (entry.id == spec.archiveId) {
        matchingArchive = entry;
        break;
      }
    }

    final CallProject nextProject;
    final bool useArchive =
        matchingArchive != null &&
        (preferArchive ||
            (matchingArchive.taggedCount == 0 &&
                matchingArchive.alertCount == 0));
    if (useArchive) {
      nextProject = _normalizeProjectAlerts(
        CallProject.fromJson(matchingArchive.project.toJson()),
      );
      _customPresets = [
        for (final p in matchingArchive.customPresets)
          CallPreset.fromJson(p.toJson()),
      ];
      _rebuildPresetCaches();
      _activeArchiveId = matchingArchive.id;
    } else {
      nextProject = spec.buildCleanProject();
      _activeArchiveId = null;
    }

    _knownAudioDurationMs = spec.durationMs;
    _durationMs = _computeProjectDurationMs(
      nextProject,
      knownAudioDurationMs: _knownAudioDurationMs,
    );
    _currentTimeMs = 0;
    _setPlayingState(false);
    _setProject(nextProject);
    syncPlaybackState(forceNotify: true);
    _activeLineId = sortedLines.isNotEmpty ? sortedLines.first.id : null;
    _hasFetchedExternalLyrics = false;
    _hasUnsavedChanges = false;
    _refreshCallDensitySeries();
    _syncEngine();
    _persistArchiveSession();
    schedulePersist(markDirty: false);
    if (!silent) {
      _setStatusInternal('已载入默认曲目：${nextProject.meta.title}');
    }
    _archiveNotifier.notifyListeners();
    _notifyProjectChanged();

    await _restoreAudioSourceForProject(
      nextProject,
      durationMs: _durationMs,
      switchToken: switchSeq,
      refreshExpiredRemoteUrl: true,
    );
    if (_disposed || switchSeq != _sourceSwitchSeq) return;
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
  }

  void reopenOnboarding() {
    if (_showOnboarding) return;
    if (_isPracticeMode) {
      _isPracticeMode = false;
    }
    _showOnboarding = true;
    _onboardingReopened = true;
    _notifyRouteChanged();
  }

  Future<void> skipOnboarding() async {
    _showOnboarding = false;
    _onboardingReopened = false;
    await _storage.saveOnboardingCompleted(true);
    _notifyRouteChanged();
  }

  Future<void> completeOnboarding({
    String? selectedSongId,
    bool userExplicitlyPickedSong = false,
  }) async {
    final wasReopened = _onboardingReopened;
    _showOnboarding = false;
    _onboardingReopened = false;
    await _storage.saveOnboardingCompleted(true);

    final targetId = selectedSongId?.trim();
    if (targetId != null && targetId.isNotEmpty) {
      final currentSpec = findDefaultSongByProject(_project);
      final shouldSwitch = wasReopened
          ? (userExplicitlyPickedSong && currentSpec?.id != targetId)
          : (currentSpec?.id != targetId);
      if (shouldSwitch) {
        _routeNotifier.notifyListeners();
        await loadDefaultSong(targetId, preferArchive: !wasReopened);
        return;
      }
    }
    _notifyRouteChanged();
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
        _rebuildPresetCaches();
        unawaited(_storage.saveCustomPresets(_customPresets));
      }

      final switchSeq = ++_sourceSwitchSeq;
      _clearUndoHistory();
      final normalized = _normalizeProjectAlerts(parsed);
      _setProject(normalized);
      _knownAudioDurationMs = _resolveKnownDurationMs(normalized);
      _durationMs = _computeProjectDurationMs(
        normalized,
        knownAudioDurationMs: _knownAudioDurationMs,
      );
      _currentTimeMs = 0;
      _setPlayingState(false);
      syncPlaybackState(forceNotify: true);

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
      _archiveNotifier.notifyListeners();
      _notifyProjectChanged();

      await _restoreAudioSourceForProject(
        normalized,
        durationMs: _durationMs,
        switchToken: switchSeq,
        refreshExpiredRemoteUrl: true,
      );
      if (!_disposed && switchSeq == _sourceSwitchSeq) {
        _playbackNotifier.notifyListeners();
        _notifyProjectChanged();
      }
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
    _notifyArchiveChanged();
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

    final switchSeq = ++_sourceSwitchSeq;
    _clearUndoHistory();
    final restored = _normalizeProjectAlerts(
      CallProject.fromJson(found.project.toJson()),
    );
    _customPresets = [
      for (final p in found.customPresets) CallPreset.fromJson(p.toJson()),
    ];
    _rebuildPresetCaches();
    _knownAudioDurationMs = _resolveKnownDurationMs(restored);
    _durationMs = _computeProjectDurationMs(
      restored,
      knownAudioDurationMs: _knownAudioDurationMs,
    );
    _currentTimeMs = 0;
    _setPlayingState(false);

    _setProject(restored);
    syncPlaybackState(forceNotify: true);
    _activeLineId = sortedLines.isNotEmpty ? sortedLines.first.id : null;
    _activeArchiveId = found.id;
    _hasUnsavedChanges = false;
    _hasFetchedExternalLyrics = false;
    _refreshCallDensitySeries();
    _syncEngine();
    _persistArchiveSession();
    schedulePersist(markDirty: false);
    _setStatusInternal('已切换至存档「${found.name}」');
    _archiveNotifier.notifyListeners();
    _notifyProjectChanged();

    await _restoreAudioSourceForProject(
      restored,
      durationMs: _durationMs,
      switchToken: switchSeq,
      refreshExpiredRemoteUrl: true,
    );
    if (_disposed || switchSeq != _sourceSwitchSeq) {
      return false;
    }
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
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
    _notifyArchiveChanged();
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
    _notifyArchiveChanged();
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
      if (!_disposed) {
        _archiveNotifier.notifyListeners();
      }
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
      gtBeepEnabled: false,
      playbackRate: _playbackRate,
    );
    _audio.setAlerts(const []);
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
        (line.calls.length +
                (line.customShout.trim().isNotEmpty ? 1 : 0) +
                line.alignedCalls.length)
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
    _routeNotifier.dispose();
    _projectNotifier.dispose();
    _archiveNotifier.dispose();
    _gatewayNotifier.dispose();
    _playbackNotifier.dispose();
    _playbackSyncNotifier.dispose();
    _beatNotifier.dispose();
    _playingLineIdNotifier.dispose();
    _upcomingLineIdNotifier.dispose();
    _isPlayingNotifier.dispose();
    _statusNotifier.dispose();
    _bannerNotifier.dispose();
    _gtFlashNotifier.dispose();
    _jumpToCurrentLineSignal.dispose();
    _scrollToTopSignal.dispose();
    shortcutsVisibleNotifier.dispose();
    super.dispose();
  }
}
