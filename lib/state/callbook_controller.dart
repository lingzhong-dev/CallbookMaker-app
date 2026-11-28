import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../data/default_songs.dart';
import '../models/callbook_models.dart';
import '../services/audio_metronome_service.dart';
import '../services/japanese_ruby_annotator.dart';
import '../services/lrclib_direct_client.dart';
import '../services/netease_direct_client.dart';
import '../services/project_storage.dart';
import '../utils/aligned_calls.dart';
import '../utils/lrc_ruby_parser.dart';
import '../utils/netease_cookie_utils.dart';
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
    description: '#66CCFF · 洛天依',
    seedColor: Color(0xFF66CCFF),
    mode: prism.ThemeMode.system,
    style: prism.ColorStyle.vivid,
  ),
  CuratedThemePreset(
    id: 'miku-green',
    name: '初音绿',
    description: '#39C5BB · 初音未来',
    seedColor: Color(0xFF39C5BB),
    mode: prism.ThemeMode.system,
    style: prism.ColorStyle.vivid,
  ),
  CuratedThemePreset(
    id: 'kasumi-red',
    name: '香澄红',
    description: '#FF5522 · 户山香澄',
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
    required this.lines,
    required this.alerts,
    required this.activeLineId,
    required this.label,
  });

  final List<LyricLine> lines;
  final List<GtAlert> alerts;
  final String? activeLineId;
  final String label;
}

class CallbookController extends ChangeNotifier {
  CallbookController({
    ProjectStorage? storage,
    NeteaseDirectClient? neteaseDirectClient,
    LrclibDirectClient? lrclibDirectClient,
    JapaneseRubyAnnotator? rubyAnnotator,
    bool enableAudioOutput = true,
    MonotonicClock? audioClock,
  }) : _storage = storage ?? ProjectStorage(),
       _neteaseDirect = neteaseDirectClient ?? NeteaseDirectClient(),
       _lrclibDirect = lrclibDirectClient ?? LrclibDirectClient(),
       _rubyAnnotator = rubyAnnotator ?? JapaneseRubyAnnotator.instance,
       _snapClock = audioClock {
    _snapClock?.start();
    if (_snapClock == null) {
      _snapFallbackWatch.start();
    }
    _audio = AudioMetronomeService(
      enablePlatformAudio: enableAudioOutput,
      clock: audioClock,
      onTimeUpdate: _handleTimeUpdate,
      onBeatTrigger: _handleBeatTrigger,
      onGtAlertBeep: (_) {},
      onDurationChanged: (durMs) {
        if (_disposed) return;
        if (durMs > 1000 &&
            _audio.hasExternalAudio &&
            _audio.hasMeasuredExternalDuration) {
          final changed = durMs != _knownAudioDurationMs;
          _knownAudioDurationMs = durMs;
          _durationMs = _computeProjectDurationMs(
            _project,
            knownAudioDurationMs: _knownAudioDurationMs,
          );
          if (changed) {
            detectSections(onlyOutro: true, silent: true);
          }
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

  late final ProjectStorage _storage;
  late final NeteaseDirectClient _neteaseDirect;
  late final LrclibDirectClient _lrclibDirect;
  late final JapaneseRubyAnnotator _rubyAnnotator;
  late final AudioMetronomeService _audio;

  // Scoped sub-notifiers to keep high-frequency playback/status updates from
  // rebuilding PrismApp, ThemeCrossFade, HomeShell, or the timeline card list.
  final ChangeNotifier _themeNotifier = ChangeNotifier();
  final ChangeNotifier _routeNotifier = ChangeNotifier();
  final ChangeNotifier _projectNotifier = ChangeNotifier();
  final ChangeNotifier _archiveNotifier = ChangeNotifier();
  final ChangeNotifier _gatewayNotifier = ChangeNotifier();
  final ChangeNotifier _playbackNotifier = ChangeNotifier();
  final ChangeNotifier _alignmentNotifier = ChangeNotifier();
  final ChangeNotifier _playbackSyncNotifier = ChangeNotifier();
  final ChangeNotifier _beatNotifier = ChangeNotifier();
  final ChangeNotifier _initNotifier = ChangeNotifier();
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
  bool _localInitDone = false;

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
  int _cueOutputCompensationMs = 0;
  BpmEstimateResult? _tapBpmCandidate;
  bool _lockBpmCalibrateDownbeat = false;
  int _currentTimeMs = 0;
  int _durationMs = defaultPrimarySong.durationMs;
  int _knownAudioDurationMs = defaultPrimarySong.durationMs;
  SectionDetectThresholds _sectionThresholds = const SectionDetectThresholds();
  int _currentBar = 1;
  int _currentBeatInBar = 1;
  bool _isSearching = false;
  bool _isFetchingLyrics = false;
  bool _isConfiguringGateway = false;
  bool _offlineRubyEnabled = true;
  bool _preferNeteaseRomaLrc = true;
  bool _filterLrcHeaderCredits = true;
  bool _isAnnotatingRuby = false;
  List<LyricLine> _restorableCreditLines = const [];
  GatewayStatusInfo _gatewayStatus = const GatewayStatusInfo();
  String _savedNeteaseCookie = '';
  String _statusMessage = '已就绪 · CallbookMaker';
  List<TrackSummary> _searchResults = const [];
  List<CallbookArchiveEntry> _archives = const [];
  String? _activeArchiveId;
  bool _hasUnsavedChanges = false;
  bool _hasFetchedExternalLyrics = false;
  final List<_TimelineUndoEntry> _undoHistory = <_TimelineUndoEntry>[];
  String? _lastUndoCoalesceKey;
  final Stopwatch _undoCoalesceWatch = Stopwatch();
  final MonotonicClock? _snapClock;
  final Stopwatch _snapFallbackWatch = Stopwatch();
  String? _lastSnapLineId;
  int _lastSnapAtMs = -1;

  int _snapNowMs() => _snapClock != null
      ? (_snapClock.elapsedMicroseconds ~/ 1000)
      : _snapFallbackWatch.elapsedMilliseconds;

  // Sparkline Histories (`LineChart` data)
  final List<double> _beatPulseSeries = List<double>.filled(24, 0.24, growable: true);
  int _beatSeriesRevision = 0;
  final List<double> _callDensitySeries = List<double>.filled(16, 0.2, growable: true);
  int _callDensityRevision = 0;

  Timer? _persistTimer;
  AppLifecycleListener? _lifecycleListener;

  // Scoped listenables
  Listenable get themeListenable => _themeNotifier;
  Listenable get routeListenable => _routeNotifier;
  Listenable get projectListenable => _projectNotifier;
  Listenable get archiveListenable => _archiveNotifier;
  Listenable get gatewayListenable => _gatewayNotifier;
  Listenable get playbackListenable => _playbackNotifier;
  Listenable get alignmentListenable => _alignmentNotifier;
  Listenable get playbackSyncListenable => _playbackSyncNotifier;
  Listenable get beatListenable => _beatNotifier;
  Listenable get initListenable => _initNotifier;
  ValueListenable<String?> get playingLineIdListenable => _playingLineIdNotifier;
  ValueListenable<String?> get upcomingLineIdListenable => _upcomingLineIdNotifier;
  ValueListenable<bool> get isPlayingListenable => _isPlayingNotifier;
  ValueListenable<String> get statusListenable => _statusNotifier;
  ValueListenable<AppBannerEvent?> get bannerListenable => _bannerNotifier;
  ValueListenable<GtFlashEvent?> get gtFlashListenable => _gtFlashNotifier;
  ValueListenable<int> get jumpToCurrentLineSignal => _jumpToCurrentLineSignal;
  ValueListenable<int> get scrollToTopSignal => _scrollToTopSignal;

  // Getters
  bool get isLocalInitDone => _localInitDone;
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
  int get cueOutputCompensationMs => _cueOutputCompensationMs;
  BpmEstimateResult? get tapBpmCandidate => _tapBpmCandidate;
  int get tapSampleCount => _audio.tapSampleCount;
  bool get lockBpmCalibrateDownbeat => _lockBpmCalibrateDownbeat;
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
  bool get isSearching => _isSearching;
  bool get isConfiguringGateway => _isConfiguringGateway;
  bool get offlineRubyEnabled => _offlineRubyEnabled;
  bool get preferNeteaseRomaLrc => _preferNeteaseRomaLrc;
  bool get filterLrcHeaderCredits => _filterLrcHeaderCredits;
  List<LyricLine> get restorableCreditLines =>
      List.unmodifiable(_restorableCreditLines);
  bool get hasRestorableCreditLines => _restorableCreditLines.isNotEmpty;
  bool get isAnnotatingRuby => _isAnnotatingRuby;
  GatewayStatusInfo get gatewayStatus => _gatewayStatus;
  String get savedNeteaseCookie => _savedNeteaseCookie;
  String get statusMessage => _statusMessage;
  List<TrackSummary> get searchResults => _searchResults;
  String siteText(String defaultText) => defaultText;
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
    LyricLine? bestMatch;
    for (final line in _sortedLinesCache) {
      if (t >= line.startTimeMs && t < line.endTimeMs) {
        if (bestMatch == null || line.startTimeMs > bestMatch.startTimeMs) {
          bestMatch = line;
        } else if (line.startTimeMs == bestMatch.startTimeMs) {
          final currentIsActive = line.id == _activeLineId;
          final bestIsActive = bestMatch.id == _activeLineId;
          if (currentIsActive && !bestIsActive) {
            bestMatch = line;
          } else if (currentIsActive == bestIsActive) {
            final currSpan = line.endTimeMs - line.startTimeMs;
            final bestSpan = bestMatch.endTimeMs - bestMatch.startTimeMs;
            if (currSpan <= bestSpan) {
              bestMatch = line;
            }
          }
        }
      }
    }
    final nextPlayingId = bestMatch?.id;
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
    final clampedOffset = clampSongOffsetMs(proj.meta.offsetMs);
    var nextProj = clampedOffset == proj.meta.offsetMs
        ? proj
        : proj.copyWith(meta: proj.meta.copyWith(offsetMs: clampedOffset));
    if (nextProj.alerts.isEmpty || nextProj.lines.isEmpty) return nextProj;
    final ordered = [...nextProj.lines]
      ..sort((a, b) => a.startTimeMs.compareTo(b.startTimeMs));
    final seenTargets = <String>{};
    final normalized = <GtAlert>[];
    for (final alert in nextProj.alerts) {
      final targetId = resolveGtAlertTargetLineId(alert, ordered);
      if (targetId == null || seenTargets.contains(targetId)) continue;
      seenTargets.add(targetId);
      normalized.add(
        alert.targetLineId == targetId
            ? alert
            : alert.copyWith(targetLineId: targetId),
      );
    }
    return nextProj.copyWith(alerts: normalized);
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
          refreshed = await _neteaseDirect
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

  CallProject _upgradeUntouchedDefaultProject(CallProject proj) {
    final spec = findDefaultSongByProject(proj);
    if (spec == null) return proj;
    final cleanSpec = spec.buildCleanProject();

    var upgradedMeta = proj.meta;
    var metaChanged = false;
    if (upgradedMeta.arranger.trim().isEmpty &&
        cleanSpec.meta.arranger.isNotEmpty) {
      upgradedMeta = upgradedMeta.copyWith(arranger: cleanSpec.meta.arranger);
      metaChanged = true;
    }
    if (upgradedMeta.supportColor.trim().isEmpty &&
        cleanSpec.meta.supportColor.isNotEmpty) {
      upgradedMeta = upgradedMeta.copyWith(
        supportColor: cleanSpec.meta.supportColor,
      );
      metaChanged = true;
    }

    final untouched =
        proj.alerts.isEmpty &&
        proj.lines.every(
          (l) =>
              l.calls.isEmpty &&
              l.customShout.trim().isEmpty &&
              !l.tailUpdraft &&
              l.alignedCalls.isEmpty,
        );
    if (!untouched) {
      return metaChanged ? proj.copyWith(meta: upgradedMeta) : proj;
    }

    var linesDiffer = proj.lines.length != cleanSpec.lines.length;
    if (!linesDiffer) {
      for (var i = 0; i < proj.lines.length; i++) {
        if (proj.lines[i].startTimeMs != cleanSpec.lines[i].startTimeMs ||
            proj.lines[i].endTimeMs != cleanSpec.lines[i].endTimeMs ||
            proj.lines[i].kind != cleanSpec.lines[i].kind ||
            proj.lines[i].text.original != cleanSpec.lines[i].text.original) {
          linesDiffer = true;
          break;
        }
      }
    }
    if (!linesDiffer) {
      return metaChanged ? proj.copyWith(meta: upgradedMeta) : proj;
    }

    return proj.copyWith(meta: upgradedMeta, lines: cleanSpec.lines);
  }

  Future<void> init({bool awaitBackgroundSync = true}) async {
    await _audio.init();
    try {
      _lifecycleListener ??= AppLifecycleListener(
        onResume: () => unawaited(onAppResumed()),
      );
    } catch (_) {
      // Ignore lifecycle binding errors in non-widget environments.
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
    _cueOutputCompensationMs = await _storage.loadCueOutputCompensationMs();

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

      var archivesUpgraded = false;
      if (_archives.isNotEmpty) {
        final nextArchives = <CallbookArchiveEntry>[];
        for (final entry in _archives) {
          if (entry.taggedCount == 0 && entry.alertCount == 0) {
            final upgradedEntryProj = _upgradeUntouchedDefaultProject(
              entry.project,
            );
            if (!identical(upgradedEntryProj, entry.project)) {
              archivesUpgraded = true;
              nextArchives.add(
                entry.copyWith(
                  project: upgradedEntryProj,
                  lineCount: upgradedEntryProj.lines.length,
                ),
              );
              continue;
            }
          }
          nextArchives.add(entry);
        }
        _archives = nextArchives;
      }

      if (savedProj != null && savedProj.lines.isNotEmpty) {
        final normalizedSaved = _normalizeProjectAlerts(savedProj);
        final upgradedSaved = _upgradeUntouchedDefaultProject(normalizedSaved);
        _setProject(upgradedSaved);
        if (!identical(upgradedSaved, normalizedSaved)) {
          await _storage.saveProject(upgradedSaved);
        }
      } else {
        _setProject(
          _normalizeProjectAlerts(defaultPrimarySong.buildCleanProject()),
        );
      }
      if (archivesUpgraded) {
        await _storage.saveArchives(_archives);
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
    _localInitDone = true;
    _initNotifier.notifyListeners();
    _themeNotifier.notifyListeners();
    _routeNotifier.notifyListeners();
    _projectNotifier.notifyListeners();
    _archiveNotifier.notifyListeners();
    _gatewayNotifier.notifyListeners();
    notifyListeners();

    final initSeq = ++_sourceSwitchSeq;
    if (awaitBackgroundSync) {
      await _runPostInitNetworkSync(initSeq);
    } else {
      unawaited(_runPostInitNetworkSync(initSeq));
    }
  }

  Future<void> _runPostInitNetworkSync(int initSeq) async {
    _refreshLocalDirectStatus();
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
    _offlineRubyEnabled = map['offlineRubyEnabled'] != false;
    _preferNeteaseRomaLrc = map['preferNeteaseRomaLrc'] != false;
    _filterLrcHeaderCredits = map['filterLrcHeaderCredits'] != false;
    _textScale = ((map['textScale'] as num?)?.toDouble() ?? 1.0).clamp(0.85, 1.25);
  }

  void _refreshLocalDirectStatus() {
    final hasCookie = _savedNeteaseCookie.trim().isNotEmpty;
    final masked = hasCookie ? maskNeteaseCookie(_savedNeteaseCookie) : '';
    final prevAccount = (hasCookie && _gatewayStatus.cookieConfigured)
        ? _gatewayStatus.neteaseAccount
        : null;
    _gatewayStatus = GatewayStatusInfo(
      reachable: _gatewayStatus.reachable,
      cookieConfigured: hasCookie,
      cookieMasked: masked,
      neteaseAccount: prevAccount,
      message: hasCookie
          ? '纯 Dart 直连就绪（免后端 · 已加载本地 Cookie${prevAccount != null && prevAccount.isNotEmpty ? " · $prevAccount" : ""}）'
          : '纯 Dart 直连就绪（免后端 · 支持网易云游客直连 / LRCLIB / 默认曲库）',
    );
    _setStatusInternal('纯 Dart 直连模式 · 免后端直接搜歌演练');
    _notifyGatewayChanged();
  }

  Future<bool> _verifyDirectNetease({required String cookie}) async {
    final probe = await _neteaseDirect.probeAccount(cookie: cookie);
    _gatewayStatus = GatewayStatusInfo(
      reachable: probe.reachable,
      cookieConfigured: probe.cookieConfigured,
      cookieMasked: probe.cookieMasked,
      neteaseAccount: probe.nickname,
      message: probe.message,
    );
    _setStatusInternal(probe.message);
    _notifyGatewayChanged();
    return probe.reachable;
  }

  Future<void> refreshGatewayStatus({bool probeDirect = false}) async {
    _refreshLocalDirectStatus();
    if (probeDirect) {
      await _verifyDirectNetease(cookie: _savedNeteaseCookie);
    }
  }

  Future<bool> oneClickConfigureAndStartGateway({
    required String cookie,
  }) async {
    if (_isConfiguringGateway) return false;
    _isConfiguringGateway = true;
    final normCookie = normalizeNeteaseCookie(cookie);
    if (normCookie.isNotEmpty) {
      _savedNeteaseCookie = normCookie;
      await _storage.saveNeteaseCookie(normCookie);
    } else if (cookie.trim().isEmpty) {
      _savedNeteaseCookie = '';
      await _storage.saveNeteaseCookie('');
    }
    _setStatusInternal('正在保存 Cookie 并验证网易云纯 Dart 直连...');
    _notifyGatewayChanged();

    try {
      return await _verifyDirectNetease(cookie: normCookie);
    } catch (err) {
      _setStatusInternal('配置网易云直连失败：$err');
      return false;
    } finally {
      _isConfiguringGateway = false;
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

  void setOfflineRubyEnabled(bool v) {
    if (_offlineRubyEnabled == v) return;
    _offlineRubyEnabled = v;
    _saveThemePrefs();
    _gatewayNotifier.notifyListeners();
    notifyListeners();
  }

  void setPreferNeteaseRomaLrc(bool v) {
    if (_preferNeteaseRomaLrc == v) return;
    _preferNeteaseRomaLrc = v;
    _saveThemePrefs();
    _gatewayNotifier.notifyListeners();
    notifyListeners();
  }

  void setFilterLrcHeaderCredits(bool v) {
    if (_filterLrcHeaderCredits == v) return;
    _filterLrcHeaderCredits = v;
    _saveThemePrefs();
    _gatewayNotifier.notifyListeners();
    notifyListeners();
  }

  /// Runs the built-in offline Japanese morphological annotator on the current
  /// project's lyric lines, preserving existing romaji when [preferNeteaseRomaLrc]
  /// is enabled unless [overwriteExistingRomaji] is explicitly true.
  Future<int> annotateCurrentProjectLyrics({
    bool forceJapanese = false,
    bool overwriteExistingRomaji = false,
  }) async {
    if (_isAnnotatingRuby) return 0;
    _isAnnotatingRuby = true;
    _gatewayNotifier.notifyListeners();
    try {
      final before = _project.lines;
      if (!JapaneseRubyAnnotator.shouldAnnotateLines(
        before,
        forceJapanese: forceJapanese,
      )) {
        setStatus('当前歌曲未检测到日语假名，已跳过日语注音');
        return 0;
      }
      final annotated = await _rubyAnnotator.annotateLines(
        before,
        preferExistingRomaji: !overwriteExistingRomaji && _preferNeteaseRomaLrc,
        forceJapanese: forceJapanese,
      );
      if (_disposed) return 0;
      var updatedCount = 0;
      for (var i = 0; i < annotated.length && i < before.length; i++) {
        if (annotated[i].text.ruby != before[i].text.ruby ||
            annotated[i].text.romaji != before[i].text.romaji) {
          updatedCount++;
        }
      }
      if (updatedCount > 0) {
        _setProject(_project.copyWith(lines: annotated));
        schedulePersist();
        _notifyProjectChanged();
        setStatus('已离线为 $updatedCount 行日语歌词生成假名注音与罗马音');
      } else {
        setStatus('当前歌曲的日语注音已是最新');
      }
      return updatedCount;
    } finally {
      _isAnnotatingRuby = false;
      if (!_disposed) {
        _gatewayNotifier.notifyListeners();
      }
    }
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
        'offlineRubyEnabled': _offlineRubyEnabled,
        'preferNeteaseRomaLrc': _preferNeteaseRomaLrc,
        'filterLrcHeaderCredits': _filterLrcHeaderCredits,
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

  Future<void> onAppResumed() => _audio.onAppResumed();

  Future<void> seek(int ms) async {
    _clearTapSession(notify: true);
    await _audio.seek(ms);
    if (!_disposed) {
      syncPlaybackState(forceNotify: true);
      if (_followPlayback) {
        _jumpToCurrentLineSignal.value++;
      }
    }
  }

  void _clearTapSession({bool notify = true}) {
    final hadTap = _tapBpmCandidate != null || _audio.tapSampleCount > 0;
    _tapBpmCandidate = null;
    _audio.clearTapSamples();
    if (notify && hadTap && !_disposed) {
      _alignmentNotifier.notifyListeners();
      _playbackNotifier.notifyListeners();
      notifyListeners();
    }
  }

  void clearTapSamples() {
    _clearTapSession(notify: true);
  }

  void setLockBpmCalibrateDownbeat(bool locked) {
    if (_lockBpmCalibrateDownbeat == locked) return;
    _lockBpmCalibrateDownbeat = locked;
    _setStatusInternal(
      locked ? '已锁定 BPM，仅校准首拍位置' : '已解除 BPM 锁定',
    );
    _alignmentNotifier.notifyListeners();
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  void setBpm(int bpm) {
    if (_lockBpmCalibrateDownbeat) {
      setStatus('已锁定 BPM，仅校准首拍位置');
      return;
    }
    final clamped = bpm.clamp(30, 300);
    _setProject(_project.copyWith(meta: _project.meta.copyWith(bpm: clamped)));
    _syncEngine();
    schedulePersist();
    _alignmentNotifier.notifyListeners();
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
    _alignmentNotifier.notifyListeners();
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
  }

  void adjustOffset(int deltaMs) {
    final nextOffset = clampSongOffsetMs(_project.meta.offsetMs + deltaMs);
    _setProject(
      _project.copyWith(
        meta: _project.meta.copyWith(offsetMs: nextOffset),
      ),
    );
    _syncEngine();
    schedulePersist();
    _alignmentNotifier.notifyListeners();
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
  }

  void setOffset(int ms) {
    final clamped = clampSongOffsetMs(ms);
    _setProject(
      _project.copyWith(meta: _project.meta.copyWith(offsetMs: clamped)),
    );
    _syncEngine();
    schedulePersist();
    _alignmentNotifier.notifyListeners();
    _playbackNotifier.notifyListeners();
    _notifyProjectChanged();
  }

  void nudgeOffsetHalfBeat(int direction) {
    final sign = direction < 0 ? -1 : 1;
    final halfBeatMs = (30000.0 / math.max(30, _project.meta.bpm)).round();
    adjustOffset(sign * halfBeatMs);
  }

  void setCurrentTimeAsBeatOne() {
    final beatDurationMs = 60000.0 / math.max(30, _project.meta.bpm);
    final barDurationMs = beatDurationMs * _project.meta.beatsPerBar;
    final targetOffset = _currentTimeMs <= kMaxSongOffsetMs
        ? _currentTimeMs
        : (_currentTimeMs % barDurationMs).round();
    setOffset(targetOffset);
    setStatus('已设当前位置 (${_currentTimeMs}ms) 为第 1 拍');
  }

  void setCueOutputCompensationMs(int ms) {
    final clamped = clampCueOutputCompensationMs(ms);
    if (clamped == _cueOutputCompensationMs) return;
    _cueOutputCompensationMs = clamped;
    _syncEngine();
    unawaited(_storage.saveCueOutputCompensationMs(clamped));
    _alignmentNotifier.notifyListeners();
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  void setPlaybackRate(double rate) {
    _playbackRate = rate.clamp(0.5, 2.0);
    _tapBpmCandidate = null;
    _audio.clearTapSamples();
    _syncEngine();
    _alignmentNotifier.notifyListeners();
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
    if (_lockBpmCalibrateDownbeat) {
      if (!_isPlaying) {
        setStatus('已暂停：不能用静止进度推算首拍，请播放后校准');
        return;
      }
      setCurrentTimeAsBeatOne();
      return;
    }
    final candidate = _audio.recordTapSample();
    if (candidate != null) {
      _tapBpmCandidate = candidate;
      _setStatusInternal(
        'Tap 候选：${candidate.bpm} BPM（置信度 ${(candidate.confidence * 100).round()}%），点击应用生效',
      );
    } else {
      _tapBpmCandidate = null;
      _setStatusInternal(
        'Tap 已采样 ${_audio.tapSampleCount}/4 次，继续连按以生成候选 BPM',
      );
    }
    _alignmentNotifier.notifyListeners();
    _playbackNotifier.notifyListeners();
    notifyListeners();
  }

  void applyTapBpmCandidate() {
    if (_lockBpmCalibrateDownbeat) {
      setStatus('已锁定 BPM，仅校准首拍位置');
      return;
    }
    final candidate = _tapBpmCandidate;
    if (candidate == null) return;
    _tapBpmCandidate = null;
    _audio.clearTapSamples();
    setBpm(candidate.bpm);
    setStatus(
      '已应用 Tap 候选：${candidate.bpm} BPM（置信度 ${(candidate.confidence * 100).round()}%）',
    );
  }

  void updateMeta({
    String? title,
    String? artist,
    String? composer,
    String? lyricist,
    String? arranger,
    String? mixer,
    String? vocalist,
    String? supportColor,
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
          arranger: arranger,
          mixer: mixer,
          vocalist: vocalist,
          supportColor: supportColor,
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
    if (showRomaji == true && !_rubyAnnotator.isLoaded) {
      unawaited(
        _rubyAnnotator.ensureLoaded().then((t) {
          if (t != null && !_disposed && _displayLayers.showRomaji) {
            _notifyProjectChanged();
          }
        }),
      );
    }
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
    _pushUndo(exists ? '取消 Call 标签' : '添加 Call 标签');
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
    _pushUndo(enabled ? '标记尾句上升气流' : '取消尾句上升气流');
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
    final nextSuffix = suffix.trim().isEmpty ? null : suffix.trim();
    var changed = false;
    final nextCalls = [
      for (final c in line.calls)
        if (c.presetId == presetId)
          (() {
            if (c.suffix != nextSuffix) {
              changed = true;
            }
            return LineCallTag(
              presetId: c.presetId,
              suffix: nextSuffix,
            );
          })()
        else
          c,
    ];
    if (!changed) return;
    _pushUndo('修改 Call 后缀');
    lines[idx] = line.copyWith(calls: nextCalls);
    _setProject(_project.copyWith(lines: lines));
    schedulePersist();
    _notifyProjectChanged();
  }

  bool _areAlignedCallsEqual(List<AlignedCallCue> a, List<AlignedCallCue> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final ca = a[i];
      final cb = b[i];
      if (ca.id != cb.id ||
          ca.start != cb.start ||
          ca.end != cb.end ||
          ca.text != cb.text ||
          ca.colorHex != cb.colorHex ||
          ca.romaji != cb.romaji) {
        return false;
      }
    }
    return true;
  }

  bool _areCallTagsEqual(List<LineCallTag> a, List<LineCallTag> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].presetId != b[i].presetId || a[i].suffix != b[i].suffix) {
        return false;
      }
    }
    return true;
  }

  bool _areLinesEqual(List<LyricLine> a, List<LyricLine> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final la = a[i];
      final lb = b[i];
      if (la.id != lb.id ||
          la.startTimeMs != lb.startTimeMs ||
          la.endTimeMs != lb.endTimeMs ||
          la.kind != lb.kind ||
          la.autoGenerated != lb.autoGenerated ||
          la.customShout != lb.customShout ||
          la.tailUpdraft != lb.tailUpdraft ||
          la.text.original != lb.text.original ||
          la.text.ruby != lb.text.ruby ||
          la.text.romaji != lb.text.romaji ||
          la.text.translation != lb.text.translation ||
          !_areCallTagsEqual(la.calls, lb.calls) ||
          !_areAlignedCallsEqual(la.alignedCalls, lb.alignedCalls)) {
        return false;
      }
    }
    return true;
  }

  bool _areAlertsEqual(List<GtAlert> a, List<GtAlert> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].triggerTimeMs != b[i].triggerTimeMs ||
          a[i].note != b[i].note ||
          a[i].targetLineId != b[i].targetLineId) {
        return false;
      }
    }
    return true;
  }

  List<LyricLine> _normalizeLinesForInsertOrEdit(
    List<LyricLine> rawLines,
    LyricLine target,
  ) {
    int? nextStrictStart;
    for (final line in rawLines) {
      if (line.id != target.id && line.startTimeMs > target.startTimeMs) {
        if (nextStrictStart == null || line.startTimeMs < nextStrictStart) {
          nextStrictStart = line.startTimeMs;
        }
      }
    }
    var effectiveTarget = target;
    if (effectiveTarget.endTimeMs <= effectiveTarget.startTimeMs) {
      final fallbackEnd = effectiveTarget.startTimeMs + 400;
      effectiveTarget = effectiveTarget.copyWith(
        endTimeMs: fallbackEnd,
        text: effectiveTarget.kind.isSection
            ? effectiveTarget.text.copyWith(
                translation: buildSectionSummary(
                  effectiveTarget.kind,
                  fallbackEnd - effectiveTarget.startTimeMs,
                ),
              )
            : null,
      );
    }
    if (nextStrictStart != null && effectiveTarget.endTimeMs > nextStrictStart) {
      effectiveTarget = effectiveTarget.copyWith(
        endTimeMs: nextStrictStart,
        text: effectiveTarget.kind.isSection
            ? effectiveTarget.text.copyWith(
                translation: buildSectionSummary(
                  effectiveTarget.kind,
                  nextStrictStart - effectiveTarget.startTimeMs,
                ),
              )
            : null,
      );
    }

    final next = <LyricLine>[];
    for (final line in rawLines) {
      if (line.id == effectiveTarget.id) {
        next.add(effectiveTarget);
      } else if (line.startTimeMs < effectiveTarget.startTimeMs &&
          line.endTimeMs > effectiveTarget.startTimeMs) {
        final trimmedEnd = effectiveTarget.startTimeMs;
        if (line.kind.isSection) {
          next.add(
            line.copyWith(
              endTimeMs: trimmedEnd,
              text: line.text.copyWith(
                translation: buildSectionSummary(
                  line.kind,
                  trimmedEnd - line.startTimeMs,
                ),
              ),
            ),
          );
        } else {
          next.add(line.copyWith(endTimeMs: trimmedEnd));
        }
      } else {
        next.add(line);
      }
    }
    next.sort((a, b) {
      final cmp = a.startTimeMs.compareTo(b.startTimeMs);
      if (cmp != 0) return cmp;
      if (a.id == effectiveTarget.id && b.id != effectiveTarget.id) return 1;
      if (b.id == effectiveTarget.id && a.id != effectiveTarget.id) return -1;
      return a.endTimeMs.compareTo(b.endTimeMs);
    });
    return next;
  }

  void _refreshTimelineAfterMutation({bool forcePlaybackSync = true}) {
    final computedDuration = _computeProjectDurationMs(
      _project,
      knownAudioDurationMs: _knownAudioDurationMs,
    );
    _durationMs = computedDuration;
    _audio.setFallbackDurationMs(_durationMs);
    if (!_audio.hasExternalAudio && _currentTimeMs > _durationMs) {
      _currentTimeMs = _durationMs;
    }
    _recomputePlaybackDerivedStates(forceNotify: forcePlaybackSync);
    _refreshCallDensitySeries();
    _syncEngine();
    if (!_disposed) {
      _playbackNotifier.notifyListeners();
    }
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
    final effectiveStart = math.max(0, startTimeMs ?? current.startTimeMs);
    final preservedSpan = current.endTimeMs > current.startTimeMs
        ? current.endTimeMs - current.startTimeMs
        : 400;
    final candidateEnd = endTimeMs ??
        (startTimeMs != null
            ? effectiveStart + preservedSpan
            : current.endTimeMs);
    final effectiveEnd = candidateEnd > effectiveStart
        ? candidateEnd
        : effectiveStart + 400;
    final nextOriginal = original ?? current.text.original;
    final nextAligned = original != null
        ? (nextOriginal.trim().isEmpty
            ? const <AlignedCallCue>[]
            : normalizeAlignedCalls(current.alignedCalls, nextOriginal.length))
        : current.alignedCalls;
    final nextKind = kind ?? current.kind;
    final kindChanged = nextKind != current.kind;
    final nextText = current.text.copyWith(
      original: original,
      translation: translation,
    );
    final sectionManuallyEdited = current.kind.isSection &&
        current.autoGenerated &&
        (kindChanged ||
            (startTimeMs != null && effectiveStart != current.startTimeMs) ||
            ((endTimeMs != null || startTimeMs != null) &&
                effectiveEnd != current.endTimeMs) ||
            nextText.original != current.text.original ||
            nextText.translation != current.text.translation);
    final updatedLine = current.copyWith(
      startTimeMs: startTimeMs != null ? effectiveStart : null,
      endTimeMs: endTimeMs != null || startTimeMs != null ? effectiveEnd : null,
      kind: kind,
      autoGenerated:
          (kindChanged || sectionManuallyEdited) ? false : current.autoGenerated,
      customShout: customShout,
      alignedCalls: nextAligned,
      text: nextText,
    );
    lines[idx] = updatedLine;
    final normalizedLines = (startTimeMs != null || endTimeMs != null)
        ? _normalizeLinesForInsertOrEdit(lines, updatedLine)
        : lines;
    final nextAlerts = startTimeMs != null
        ? [
            for (final a in _project.alerts)
              if (resolveGtAlertTargetLineId(a, orderedBefore) == lineId)
                a.copyWith(targetLineId: lineId, triggerTimeMs: effectiveStart)
              else
                a,
          ]
        : _project.alerts;
    if (_areLinesEqual(normalizedLines, _project.lines) &&
        _areAlertsEqual(nextAlerts, _project.alerts)) {
      return;
    }
    final isShoutOnlyEdit = startTimeMs == null &&
        endTimeMs == null &&
        kind == null &&
        original == null &&
        translation == null &&
        customShout != null;
    _pushUndo(
      '编辑行内容',
      coalesceKey: isShoutOnlyEdit ? 'shout:$lineId' : null,
    );
    _setProject(_project.copyWith(lines: normalizedLines, alerts: nextAlerts));
    _refreshTimelineAfterMutation(
      forcePlaybackSync: startTimeMs != null || endTimeMs != null,
    );
    schedulePersist();
    _notifyProjectChanged();
  }

  void _clearUndoHistory() {
    _undoHistory.clear();
    _lastUndoCoalesceKey = null;
    _undoCoalesceWatch.stop();
    _undoCoalesceWatch.reset();
  }

  void _pushUndo(
    String label, {
    String? coalesceKey,
    String? activeLineIdOverride,
  }) {
    if (coalesceKey != null &&
        coalesceKey == _lastUndoCoalesceKey &&
        _undoHistory.isNotEmpty &&
        _undoCoalesceWatch.isRunning &&
        _undoCoalesceWatch.elapsedMilliseconds <= 800) {
      _undoCoalesceWatch
        ..reset()
        ..start();
      return;
    }
    if (coalesceKey != null) {
      _lastUndoCoalesceKey = coalesceKey;
      _undoCoalesceWatch
        ..reset()
        ..start();
    } else {
      _lastUndoCoalesceKey = null;
      _undoCoalesceWatch.stop();
      _undoCoalesceWatch.reset();
    }
    final normalized = _normalizeProjectAlerts(
      CallProject(
        meta: _project.meta,
        alerts: [
          for (final a in _project.alerts) GtAlert.fromJson(a.toJson()),
        ],
        lines: [
          for (final l in _project.lines) LyricLine.fromJson(l.toJson()),
        ],
      ),
    );
    _undoHistory.add(
      _TimelineUndoEntry(
        lines: List<LyricLine>.unmodifiable(normalized.lines),
        alerts: List<GtAlert>.unmodifiable(normalized.alerts),
        activeLineId: activeLineIdOverride ?? _activeLineId,
        label: label,
      ),
    );
    if (_undoHistory.length > 25) {
      _undoHistory.removeAt(0);
    }
  }

  bool undoLastTimelineEdit() {
    if (_undoHistory.isEmpty) return false;
    _lastUndoCoalesceKey = null;
    _undoCoalesceWatch.stop();
    _undoCoalesceWatch.reset();
    final prevAlertLineIds = _alertByLineIdCache.keys.toSet();
    final entry = _undoHistory.removeLast();
    _setProject(
      _normalizeProjectAlerts(
        _project.copyWith(
          lines: [for (final l in entry.lines) LyricLine.fromJson(l.toJson())],
          alerts: [for (final a in entry.alerts) GtAlert.fromJson(a.toJson())],
        ),
      ),
    );
    final fallbackId = sortedLines.isNotEmpty ? sortedLines.first.id : null;
    if (entry.activeLineId != null &&
        _project.lines.any((l) => l.id == entry.activeLineId)) {
      _activeLineId = entry.activeLineId;
    } else {
      _activeLineId = fallbackId;
    }
    _refreshTimelineAfterMutation(forcePlaybackSync: true);
    final nextAlertLineIds = _alertByLineIdCache.keys.toSet();
    final removedGtLines = prevAlertLineIds.difference(nextAlertLineIds);
    final addedGtLines = nextAlertLineIds.difference(prevAlertLineIds);
    if (removedGtLines.isNotEmpty) {
      _emitGtFlash(removedGtLines.first, reverse: true);
    } else if (addedGtLines.isNotEmpty) {
      _emitGtFlash(addedGtLines.first, reverse: false);
    }
    schedulePersist();
    _setStatusInternal('已撤销「${entry.label}」');
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
    _refreshTimelineAfterMutation();
    schedulePersist();
    _setStatusInternal('已合并相邻两句歌词（可点击「撤销」恢复）');
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

    _pushUndo('拆分歌词');
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
    _refreshTimelineAfterMutation();
    schedulePersist();
    _setStatusInternal(
      '已将歌词拆分为 ${chunks.length} 句（可点击「撤销」恢复）',
    );
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
    String? romaji,
  }) {
    final lines = [..._project.lines];
    final idx = lines.indexWhere((l) => l.id == lineId);
    if (idx < 0) return;
    final line = lines[idx];
    final originalLength = line.text.original.length;
    if (originalLength <= 0) return;
    final cleanText = text.trim();
    if (cleanText.isEmpty) return;
    final cleanRomaji = romaji?.trim();

    final cueId = (id != null && id.trim().isNotEmpty)
        ? id.trim()
        : 'ac-${DateTime.now().millisecondsSinceEpoch}-${math.Random().nextInt(9999)}';
    final nextCue = AlignedCallCue(
      id: cueId,
      start: start,
      end: end,
      text: cleanText,
      colorHex: colorHex,
      romaji: (cleanRomaji == null || cleanRomaji.isEmpty) ? null : cleanRomaji,
    );
    final existing = line.alignedCalls.where(
      (c) => c.id != cueId && !(start < c.end && end > c.start),
    );
    final normalized = normalizeAlignedCalls(
      [...existing, nextCue],
      originalLength,
    );
    if (_areAlignedCallsEqual(normalized, line.alignedCalls)) return;
    _pushUndo('编辑词对位 Call');
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
    _pushUndo('移除词对位 Call');
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

    final dur = current.endTimeMs > current.startTimeMs
        ? current.endTimeMs - current.startTimeMs
        : 400;
    final snappedTimeChanged = _currentTimeMs != current.startTimeMs;
    final snappedLine = current.copyWith(
      startTimeMs: _currentTimeMs,
      endTimeMs: _currentTimeMs + dur,
      autoGenerated: (current.kind.isSection && snappedTimeChanged)
          ? false
          : current.autoGenerated,
      text: current.kind.isSection
          ? current.text.copyWith(
              translation: buildSectionSummary(current.kind, dur),
            )
          : null,
    );
    lines[idx] = snappedLine;
    final normalizedLines = _normalizeLinesForInsertOrEdit(lines, snappedLine);
    final nextAlerts = [
      for (final a in _project.alerts)
        if (resolveGtAlertTargetLineId(a, orderedBefore) == lineId)
          a.copyWith(targetLineId: lineId, triggerTimeMs: _currentTimeMs)
        else
          a,
    ];
    if (_areLinesEqual(normalizedLines, _project.lines) &&
        _areAlertsEqual(nextAlerts, _project.alerts)) {
      return;
    }
    final nowMs = _snapNowMs();
    if (_lastSnapLineId == lineId &&
        _lastSnapAtMs >= 0 &&
        (nowMs - _lastSnapAtMs) >= 0 &&
        (nowMs - _lastSnapAtMs) < 160) {
      return;
    }
    _lastSnapLineId = lineId;
    _lastSnapAtMs = nowMs;
    _pushUndo('校时');
    _setProject(_project.copyWith(lines: normalizedLines, alerts: nextAlerts));
    _refreshTimelineAfterMutation();
    schedulePersist();
    _setStatusInternal('已对齐当前时间 ${formatMsToClock(_currentTimeMs)}（可点击「撤销」恢复）');
    _notifyProjectChanged();
  }

  void addEmptyLine() {
    final start = math.max(0, _currentTimeMs);
    var nextLineStart = start + 3000;
    for (final line in sortedLines) {
      if (line.startTimeMs > start + 400) {
        nextLineStart = math.min(nextLineStart, line.startTimeMs);
        break;
      }
    }
    final end = math.max(start + 1000, nextLineStart);
    final newLine = LyricLine(
      id: 'line-${DateTime.now().millisecondsSinceEpoch}-${_project.lines.length}',
      startTimeMs: start,
      endTimeMs: end,
      text: const LyricText(original: '新歌词行（点击编辑）', translation: ''),
    );
    final normalizedLines = _normalizeLinesForInsertOrEdit(
      [..._project.lines, newLine],
      newLine,
    );
    _pushUndo('添加歌词行');
    _activeLineId = newLine.id;
    _setProject(_project.copyWith(lines: normalizedLines));
    _refreshTimelineAfterMutation();
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
    final totalDur =
        explicitDurationMs ??
        (_knownAudioDurationMs > 0 ? _knownAudioDurationMs : null);
    final prevLines = _project.lines;
    final result = detectAndMergeSections(
      prevLines,
      thresholds: _sectionThresholds,
      totalDurationMs: totalDur,
      protectedLineIds: _getProtectedSectionLineIds(),
      onlyOutro: onlyOutro,
    );
    final linesChanged = !_areLinesEqual(result.lines, prevLines);
    if (linesChanged) {
      _setProject(_project.copyWith(lines: result.lines));
      if (_activeLineId != null &&
          !_project.lines.any((l) => l.id == _activeLineId)) {
        _activeLineId =
            result.lines.isNotEmpty ? result.lines.first.id : null;
      }
      _refreshTimelineAfterMutation();
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
      id: 'sec-manual-${safeKind.name}-${DateTime.now().millisecondsSinceEpoch}-${_project.lines.length}',
      startTimeMs: safeStart,
      endTimeMs: safeEnd,
      kind: safeKind,
      autoGenerated: false,
      text: LyricText(
        original: effectiveTitle,
        translation: effectiveNote,
      ),
    );

    final nextLines = _normalizeLinesForInsertOrEdit(
      [..._project.lines, newSection],
      newSection,
    );

    _pushUndo('添加段落');
    _activeLineId = newSection.id;
    _setProject(_project.copyWith(lines: nextLines));
    _refreshTimelineAfterMutation();
    schedulePersist();
    _setStatusInternal('已添加${safeKind.zhLabel}段落（${formatGapSec(gap)}）');
    _notifyProjectChanged();
  }

  bool splitSectionAtTime(
    String lineId,
    int splitTimeMs, {
    String? firstTitle,
    String? secondTitle,
  }) {
    final idx = _project.lines.indexWhere((l) => l.id == lineId);
    if (idx < 0) return false;
    final target = _project.lines[idx];
    if (!target.kind.isSection) {
      setStatus('仅支持拆分前奏 / 间奏 / 尾奏段落');
      return false;
    }
    const minSegmentMs = 500;
    final span = target.endTimeMs - target.startTimeMs;
    if (span < minSegmentMs * 2) {
      setStatus('该段落时长不足，无法拆分为两段');
      return false;
    }
    if (splitTimeMs < target.startTimeMs + minSegmentMs ||
        splitTimeMs > target.endTimeMs - minSegmentMs) {
      setStatus('切分时间点需严格位于段落起止区间内');
      return false;
    }

    final resolvedFirstTitle =
        (firstTitle != null && firstTitle.trim().isNotEmpty)
            ? firstTitle.trim()
            : target.text.original;
    final resolvedSecondTitle =
        (secondTitle != null && secondTitle.trim().isNotEmpty)
            ? secondTitle.trim()
            : target.kind.bracketTitle;

    final seg1 = target.copyWith(
      endTimeMs: splitTimeMs,
      autoGenerated: false,
      tailUpdraft: false,
      text: target.text.copyWith(
        original: resolvedFirstTitle,
        translation: buildSectionSummary(
          target.kind,
          splitTimeMs - target.startTimeMs,
        ),
      ),
    );

    final existingIds = {for (final l in _project.lines) l.id};
    final stamp = DateTime.now().millisecondsSinceEpoch;
    var seg2Id = 'sec-split-${target.kind.name}-$stamp';
    var seq = 0;
    while (existingIds.contains(seg2Id)) {
      seq++;
      seg2Id = 'sec-split-${target.kind.name}-$stamp-$seq';
    }
    final seg2 = LyricLine(
      id: seg2Id,
      startTimeMs: splitTimeMs,
      endTimeMs: target.endTimeMs,
      kind: target.kind,
      autoGenerated: false,
      calls: const [],
      customShout: '',
      tailUpdraft: target.tailUpdraft,
      text: LyricText(
        original: resolvedSecondTitle,
        translation: buildSectionSummary(
          target.kind,
          target.endTimeMs - splitTimeMs,
        ),
      ),
    );

    _pushUndo('拆分段落');
    final nextLines = <LyricLine>[
      for (final l in _project.lines)
        if (l.id == target.id) ...[seg1, seg2] else l,
    ]..sort((a, b) => a.startTimeMs.compareTo(b.startTimeMs));

    _activeLineId = seg1.id;
    _setProject(_project.copyWith(lines: nextLines));
    _refreshTimelineAfterMutation();
    schedulePersist();
    _setStatusInternal(
      '已将${target.kind.zhLabel}拆分为两段（可点击「撤销」恢复）',
    );
    _notifyProjectChanged();
    return true;
  }

  void deleteLine(String lineId) {
    final idx = _project.lines.indexWhere((l) => l.id == lineId);
    if (idx < 0) return;
    final deletedLine = _project.lines[idx];
    final orderedBefore = sortedLines;

    int? earliestLyricStart(List<LyricLine> list) {
      int? earliest;
      for (final l in list) {
        if (!l.kind.isSection) {
          if (earliest == null || l.startTimeMs < earliest) {
            earliest = l.startTimeMs;
          }
        }
      }
      return earliest;
    }

    final earliestBefore = earliestLyricStart(_project.lines);
    var nextLines = _project.lines.where((l) => l.id != lineId).toList();
    final nextAlerts = _project.alerts
        .where((a) => resolveGtAlertTargetLineId(a, orderedBefore) != lineId)
        .toList();
    final earliestAfter = earliestLyricStart(nextLines);

    if (!deletedLine.kind.isSection &&
        earliestBefore != null &&
        earliestAfter != null &&
        earliestAfter > earliestBefore) {
      final sortedRemaining = [...nextLines]
        ..sort((a, b) => a.startTimeMs.compareTo(b.startTimeMs));
      final protectedIds = <String>{
        for (final a in nextAlerts)
          if (resolveGtAlertTargetLineId(a, sortedRemaining) != null)
            resolveGtAlertTargetLineId(a, sortedRemaining)!,
      };
      LyricLine? candidateIntro;
      for (final l in sortedRemaining) {
        if (l.kind == LyricLineKind.intro && l.startTimeMs < earliestAfter) {
          candidateIntro = l;
        }
      }
      if (candidateIntro != null &&
          isAutoMaintainableSection(candidateIntro, protectedIds)) {
        final intro = candidateIntro;
        final blockedByLaterSection = sortedRemaining.any(
          (s) =>
              s.id != intro.id &&
              s.kind.isSection &&
              s.startTimeMs >= intro.endTimeMs &&
              s.startTimeMs < earliestAfter,
        );
        if (!blockedByLaterSection && intro.endTimeMs != earliestAfter) {
          nextLines = [
            for (final l in nextLines)
              if (l.id == intro.id)
                l.copyWith(
                  endTimeMs: earliestAfter,
                  text: l.text.copyWith(
                    translation: buildSectionSummary(
                      LyricLineKind.intro,
                      earliestAfter - l.startTimeMs,
                    ),
                  ),
                )
              else
                l,
          ];
        }
      }
    }

    _pushUndo('删除行');
    _setProject(
      _project.copyWith(
        lines: nextLines,
        alerts: nextAlerts,
      ),
    );
    if (_activeLineId == lineId) {
      _activeLineId = sortedLines.isNotEmpty ? sortedLines.first.id : null;
    }
    _refreshTimelineAfterMutation();
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
      _pushUndo('取消 GT 警报');
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

    _pushUndo('开启 GT 警报');
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
    final nextAlerts = [
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
    ];
    if (_areAlertsEqual(nextAlerts, _project.alerts)) return;
    _pushUndo(
      '编辑 GT 警报',
      coalesceKey: (triggerTimeMs == null && note != null)
          ? 'gt-note:$lineId'
          : null,
    );
    _setProject(_project.copyWith(alerts: nextAlerts));
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

  // Direct search, LRC import & local audio
  Future<void> searchTracks(String query, {String source = 'auto'}) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return;
    _isSearching = true;
    notifyListeners();
    try {
      if (source == 'lrclib') {
        final results = await _lrclibDirect.searchTracks(cleanQuery);
        _searchResults = results;
        setStatus('搜索完成 (LRCLIB 直连) · ${results.length} 首');
        return;
      }

      if (source == 'custom_proxy') {
        final directResults = await _neteaseDirect.searchTracks(
          cleanQuery,
          cookie: _savedNeteaseCookie,
        );
        _searchResults = directResults;
        setStatus('搜索完成 (网易云纯 Dart 直连) · ${directResults.length} 首');
        return;
      }

      // source == 'auto'
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
        final lrclibResults = await _lrclibDirect.searchTracks(cleanQuery);
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

      if (providerName == 'netease_direct' || summary.platform == 'netease') {
        detail = await _neteaseDirect.fetchTrackDetail(
          summary.id,
          cookie: _savedNeteaseCookie,
          fallbackSummary: summary,
        );
      } else if (providerName == 'lrclib' || summary.platform == 'lrclib') {
        detail = await _lrclibDirect.fetchTrackDetail(summary.id);
      } else {
        throw Exception('暂不支持直连该来源 ($providerName)');
      }

      var rawLines = detail.lines;
      var filteredCredits = const <LyricLine>[];
      var extractedMeta = const LrcExtractedMeta();
      if (detail.rawLrc.trim().isNotEmpty &&
          (rawLines.isEmpty || rawLines.every((l) => l.text.ruby == null))) {
        final parsed = parseLrcOfflineDetailed(
          detail.rawLrc,
          translationLrc: detail.translatedLrc,
          romaLrc: _preferNeteaseRomaLrc ? detail.romaLrc : '',
          filterHeaderCredits: _filterLrcHeaderCredits,
        );
        rawLines = parsed.lines;
        filteredCredits = parsed.filteredCreditLines;
        extractedMeta = parsed.extractedMeta;
      } else if (!_preferNeteaseRomaLrc && detail.romaLrc.trim().isNotEmpty) {
        // User opted out of Netease romalrc; re-parse without romalrc so built-in
        // offline engine (or blank) controls romaji cleanly.
        final parsed = parseLrcOfflineDetailed(
          detail.rawLrc,
          translationLrc: detail.translatedLrc,
          filterHeaderCredits: _filterLrcHeaderCredits,
        );
        rawLines = parsed.lines;
        filteredCredits = parsed.filteredCreditLines;
        extractedMeta = parsed.extractedMeta;
      }

      if (_offlineRubyEnabled &&
          rawLines.isNotEmpty &&
          rawLines.every((l) => l.text.ruby == null)) {
        try {
          rawLines = await _rubyAnnotator.annotateLines(
            rawLines,
            preferExistingRomaji: _preferNeteaseRomaLrc,
          );
        } catch (_) {
          // Keep parsed LRC lines if offline annotator is unavailable
        }
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
      final baseMeta = CallProjectMeta(
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
      );
      final nextProject = CallProject(
        meta: _filterLrcHeaderCredits
            ? _mergeExtractedCreditsMeta(baseMeta, extractedMeta)
            : baseMeta,
        alerts: const [],
        lines: detected.lines,
      );
      final switchSeq = ++_sourceSwitchSeq;
      _clearTapSession(notify: false);
      _clearUndoHistory();
      _restorableCreditLines = List<LyricLine>.unmodifiable(filteredCredits);
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
      final filterHint = filteredCredits.isNotEmpty
          ? '（已过滤 ${filteredCredits.length} 行片头制作信息）'
          : '';
      _setStatusInternal(
        totalDetected > 0
            ? '已导入曲目：${detail.track.title}（自动识别前/间/尾奏：前${detected.stats.intro}·间${detected.stats.interlude}·尾${detected.stats.outro}）$filterHint$audioHint'
            : '已导入曲目：${detail.track.title}$filterHint$audioHint',
      );
      if (filteredCredits.isNotEmpty) {
        notify(
          '已过滤 ${filteredCredits.length} 行片头制作信息（点此可恢复）',
          level: prism.BannerLevel.info,
          actionLabel: '恢复被过滤的制作信息行',
          onAction: () => restoreFilteredCreditLines(),
        );
      }
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

  CallProjectMeta _mergeExtractedCreditsMeta(
    CallProjectMeta base,
    LrcExtractedMeta extracted,
  ) {
    if (extracted.isEmpty) return base;
    return base.copyWith(
      lyricist: base.lyricist.trim().isEmpty && extracted.lyricist.isNotEmpty
          ? extracted.lyricist
          : null,
      composer: base.composer.trim().isEmpty && extracted.composer.isNotEmpty
          ? extracted.composer
          : null,
      arranger: base.arranger.trim().isEmpty && extracted.arranger.isNotEmpty
          ? extracted.arranger
          : null,
      mixer: base.mixer.trim().isEmpty && extracted.mixer.isNotEmpty
          ? extracted.mixer
          : null,
      vocalist: base.vocalist.trim().isEmpty && extracted.vocalist.isNotEmpty
          ? extracted.vocalist
          : null,
    );
  }

  Future<void> importLrcText({
    required String lrc,
    String translationLrc = '',
    String romaLrc = '',
    bool enableRuby = true,
    bool? filterHeaderCredits,
  }) async {
    final useCreditFilter = filterHeaderCredits ?? _filterLrcHeaderCredits;
    final parsed = parseLrcOfflineDetailed(
      lrc,
      translationLrc: translationLrc,
      romaLrc: _preferNeteaseRomaLrc ? romaLrc : '',
      filterHeaderCredits: useCreditFilter,
    );
    var lines = parsed.lines;
    if (enableRuby && _offlineRubyEnabled && lines.isNotEmpty) {
      try {
        lines = await _rubyAnnotator.annotateLines(
          lines,
          preferExistingRomaji: _preferNeteaseRomaLrc,
        );
      } catch (_) {
        // Keep offline parsed lines
      }
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
    _clearTapSession(notify: false);
    _clearUndoHistory();
    _restorableCreditLines =
        List<LyricLine>.unmodifiable(parsed.filteredCreditLines);
    await _audio.pause();
    await _audio.seek(0);
    _setPlayingState(false);
    _currentTimeMs = 0;
    if (!hasMeasuredExternalAudio) {
      _knownAudioDurationMs = 0;
    }
    final nextMeta = useCreditFilter
        ? _mergeExtractedCreditsMeta(_project.meta, parsed.extractedMeta)
        : _project.meta;
    final nextProject = _project.copyWith(
      meta: nextMeta,
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
    final filterNote = parsed.filteredCreditLines.isNotEmpty
        ? '（已过滤 ${parsed.filteredCreditLines.length} 行制作信息）'
        : '';
    _setStatusInternal(
      totalDetected > 0
          ? '已解析 ${lines.length} 行 LRC · 自动识别前奏 ${detected.stats.intro} / 间奏 ${detected.stats.interlude}${detected.stats.outro > 0 ? ' / 尾奏 ${detected.stats.outro}' : ''}$filterNote'
          : '已解析 ${lines.length} 行 LRC 歌词$filterNote',
    );
    if (parsed.filteredCreditLines.isNotEmpty) {
      notify(
        '已过滤 ${parsed.filteredCreditLines.length} 行片头制作信息（点此可恢复）',
        level: prism.BannerLevel.info,
        actionLabel: '恢复被过滤的制作信息行',
        onAction: () => restoreFilteredCreditLines(),
      );
    }
    _gatewayNotifier.notifyListeners();
    _archiveNotifier.notifyListeners();
    _notifyProjectChanged();
  }

  /// Restores header credit lines filtered during the most recent LRC import
  /// without changing `offsetMs` or shifting any existing lyric timestamps.
  int restoreFilteredCreditLines() {
    if (_restorableCreditLines.isEmpty) return 0;
    final existingIds = {for (final l in _project.lines) l.id};
    final toRestore = [
      for (final l in _restorableCreditLines)
        if (!existingIds.contains(l.id)) l,
    ];
    _restorableCreditLines = const [];
    if (toRestore.isEmpty) {
      _gatewayNotifier.notifyListeners();
      return 0;
    }

    final earliestRestoredStart = toRestore
        .map((l) => l.startTimeMs)
        .reduce((a, b) => a < b ? a : b);
    final orderedBefore = sortedLines;
    final protectedIds = <String>{
      for (final a in _project.alerts)
        if (resolveGtAlertTargetLineId(a, orderedBefore) != null)
          resolveGtAlertTargetLineId(a, orderedBefore)!,
    };

    final nextLines = <LyricLine>[];
    for (final line in _project.lines) {
      if (line.kind == LyricLineKind.intro &&
          line.startTimeMs == 0 &&
          line.endTimeMs > earliestRestoredStart &&
          isAutoMaintainableSection(line, protectedIds)) {
        if (earliestRestoredStart >= _sectionThresholds.introThresholdMs) {
          final shrunkDur = earliestRestoredStart - line.startTimeMs;
          nextLines.add(
            line.copyWith(
              endTimeMs: earliestRestoredStart,
              text: line.text.copyWith(
                translation: buildSectionSummary(LyricLineKind.intro, shrunkDur),
              ),
            ),
          );
        }
        // If shorter than intro threshold, drop the auto-only intro cleanly.
        continue;
      }
      nextLines.add(line);
    }

    nextLines.addAll(toRestore);
    nextLines.sort((a, b) => a.startTimeMs.compareTo(b.startTimeMs));

    _setProject(_project.copyWith(lines: nextLines));
    _refreshTimelineAfterMutation();
    schedulePersist();
    _setStatusInternal('已恢复 ${toRestore.length} 行片头制作信息');
    _gatewayNotifier.notifyListeners();
    _notifyProjectChanged();
    return toRestore.length;
  }

  Future<void> loadLocalAudioFile(String filePath, String fileName) async {
    final switchSeq = ++_sourceSwitchSeq;
    _clearTapSession(notify: false);
    _knownAudioDurationMs = 0;
    _durationMs = _computeProjectDurationMs(
      _project,
      knownAudioDurationMs: 0,
    );
    _currentTimeMs = 0;
    _setPlayingState(false);
    try {
      await _audio.setAudioSource(
        localPath: filePath,
        fallbackDurationMs: _durationMs,
      );
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
    _clearTapSession(notify: false);
    _clearUndoHistory();
    _restorableCreditLines = const [];
    _gatewayNotifier.notifyListeners();
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
      _clearTapSession(notify: false);
      _clearUndoHistory();
      _restorableCreditLines = const [];
      _gatewayNotifier.notifyListeners();
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
    _clearTapSession(notify: false);
    _clearUndoHistory();
    _restorableCreditLines = const [];
    _gatewayNotifier.notifyListeners();
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
      cueOutputCompensationMs: _cueOutputCompensationMs,
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
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    unawaited(_audio.dispose());
    _neteaseDirect.dispose();
    _lrclibDirect.dispose();
    _themeNotifier.dispose();
    _routeNotifier.dispose();
    _projectNotifier.dispose();
    _archiveNotifier.dispose();
    _gatewayNotifier.dispose();
    _playbackNotifier.dispose();
    _alignmentNotifier.dispose();
    _playbackSyncNotifier.dispose();
    _beatNotifier.dispose();
    _initNotifier.dispose();
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
