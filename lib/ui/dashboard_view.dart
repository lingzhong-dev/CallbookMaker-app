import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../models/callbook_models.dart';
import '../state/callbook_controller.dart';
import '../utils/color_parser.dart';
import '../utils/lrc_ruby_parser.dart';
import 'theme/app_motion.dart';
import 'theme/app_tokens.dart';
import 'widgets/app_dialog.dart';
import 'widgets/audio_source_panel.dart';
import 'widgets/beat_dots_indicator.dart';
import 'widgets/callbook_glyphs.dart';
import 'widgets/continuous_auto_scroller.dart';
import 'widgets/line_sparkline.dart';
import 'widgets/scalloped_orb_button.dart';
import 'widgets/scroll_to_top_button.dart';
import 'widgets/timeline_editor_widget.dart';

class DashboardView extends StatefulWidget {
  const DashboardView({super.key, required this.controller});

  final CallbookController controller;

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  final ScrollController _scrollController = ScrollController();
  final ScrollController _leftScrollController = ScrollController();
  final ScrollController _timelineScrollController = ScrollController();
  final ValueNotifier<bool> _compactStickyVisible = ValueNotifier<bool>(false);
  final GlobalKey<TimelineEditorWidgetState> _desktopTimelineKey =
      GlobalKey<TimelineEditorWidgetState>();
  final GlobalKey<TimelineEditorWidgetState> _compactTimelineKey =
      GlobalKey<TimelineEditorWidgetState>();
  bool _isTwoColumnLayout = false;

  GlobalKey<TimelineEditorWidgetState> get _activeTimelineKey =>
      _isTwoColumnLayout ? _desktopTimelineKey : _compactTimelineKey;

  late final TextEditingController _titleCtrl;
  late final TextEditingController _artistCtrl;
  late final TextEditingController _bpmCtrl;
  late final TextEditingController _composerCtrl;
  late final TextEditingController _lyricistCtrl;
  late final TextEditingController _arrangerCtrl;
  late final TextEditingController _mixerCtrl;
  late final TextEditingController _vocalistCtrl;
  late final TextEditingController _supportColorCtrl;
  late final TextEditingController _tunerCtrl;
  late final TextEditingController _editorNameCtrl;
  late final TextEditingController _editorNoteCtrl;

  final FocusNode _titleFocus = FocusNode();
  final FocusNode _artistFocus = FocusNode();
  final FocusNode _bpmFocus = FocusNode();
  final FocusNode _composerFocus = FocusNode();
  final FocusNode _lyricistFocus = FocusNode();
  final FocusNode _arrangerFocus = FocusNode();
  final FocusNode _mixerFocus = FocusNode();
  final FocusNode _vocalistFocus = FocusNode();
  final FocusNode _supportColorFocus = FocusNode();
  final FocusNode _tunerFocus = FocusNode();
  final FocusNode _editorNameFocus = FocusNode();
  final FocusNode _editorNoteFocus = FocusNode();

  bool _showOffsetTools = false;

  @override
  void initState() {
    super.initState();
    final meta = widget.controller.project.meta;
    _titleCtrl = TextEditingController(text: meta.title);
    _artistCtrl = TextEditingController(text: meta.artist);
    _bpmCtrl = TextEditingController(text: '${meta.bpm}');
    _composerCtrl = TextEditingController(text: meta.composer);
    _lyricistCtrl = TextEditingController(text: meta.lyricist);
    _arrangerCtrl = TextEditingController(text: meta.arranger);
    _mixerCtrl = TextEditingController(text: meta.mixer);
    _vocalistCtrl = TextEditingController(text: meta.vocalist);
    _supportColorCtrl = TextEditingController(text: meta.supportColor);
    _tunerCtrl = TextEditingController(text: meta.tuner);
    _editorNameCtrl = TextEditingController(text: meta.editorName);
    _editorNoteCtrl = TextEditingController(text: meta.editorNote);
    _titleFocus.addListener(_onTitleFocusChanged);
    _artistFocus.addListener(_onArtistFocusChanged);
    _bpmFocus.addListener(_onBpmFocusChanged);
    _composerFocus.addListener(_onComposerFocusChanged);
    _lyricistFocus.addListener(_onLyricistFocusChanged);
    _arrangerFocus.addListener(_onArrangerFocusChanged);
    _mixerFocus.addListener(_onMixerFocusChanged);
    _vocalistFocus.addListener(_onVocalistFocusChanged);
    _supportColorFocus.addListener(_onSupportColorFocusChanged);
    _tunerFocus.addListener(_onTunerFocusChanged);
    _editorNameFocus.addListener(_onEditorNameFocusChanged);
    _editorNoteFocus.addListener(_onEditorNoteFocusChanged);
    _scrollController.addListener(_onCompactScrollChanged);
    widget.controller.projectListenable.addListener(_syncMetaControllers);
    widget.controller.scrollToTopSignal.addListener(_handleScrollToTopSignal);
  }

  void _onCompactScrollChanged() {
    if (!mounted || _isTwoColumnLayout || !_scrollController.hasClients) {
      if (_compactStickyVisible.value) {
        _compactStickyVisible.value = false;
      }
      return;
    }
    final offset = _scrollController.offset;
    var changed = false;
    if (!_compactStickyVisible.value && offset > 280) {
      _compactStickyVisible.value = true;
      changed = true;
    } else if (_compactStickyVisible.value && offset < 220) {
      _compactStickyVisible.value = false;
      changed = true;
    }
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isTwoColumnLayout) {
          _compactTimelineKey.currentState?.recenterFollowTargetIfActive();
        }
      });
    }
  }

  void _commitTitle() {
    final next = _titleCtrl.text;
    if (next != widget.controller.project.meta.title) {
      widget.controller.updateMeta(title: next);
    }
  }

  void _commitArtist() {
    final next = _artistCtrl.text;
    if (next != widget.controller.project.meta.artist) {
      widget.controller.updateMeta(artist: next);
    }
  }

  void _commitComposer() {
    final next = _composerCtrl.text;
    if (next != widget.controller.project.meta.composer) {
      widget.controller.updateMeta(composer: next);
    }
  }

  void _commitLyricist() {
    final next = _lyricistCtrl.text;
    if (next != widget.controller.project.meta.lyricist) {
      widget.controller.updateMeta(lyricist: next);
    }
  }

  void _commitArranger() {
    final next = _arrangerCtrl.text;
    if (next != widget.controller.project.meta.arranger) {
      widget.controller.updateMeta(arranger: next);
    }
  }

  void _commitMixer() {
    final next = _mixerCtrl.text;
    if (next != widget.controller.project.meta.mixer) {
      widget.controller.updateMeta(mixer: next);
    }
  }

  void _commitVocalist() {
    final next = _vocalistCtrl.text;
    if (next != widget.controller.project.meta.vocalist) {
      widget.controller.updateMeta(vocalist: next);
    }
  }

  void _commitSupportColor() {
    final raw = _supportColorCtrl.text;
    final parsed = parseSupportColor(raw);
    final normalized = parsed != null ? formatHexColor(parsed) : raw;
    if (normalized != _supportColorCtrl.text) {
      _supportColorCtrl.text = normalized;
    }
    if (normalized != widget.controller.project.meta.supportColor) {
      widget.controller.updateMeta(supportColor: normalized);
    }
  }

  void _commitTuner() {
    final next = _tunerCtrl.text;
    if (next != widget.controller.project.meta.tuner) {
      widget.controller.updateMeta(tuner: next);
    }
  }

  void _commitEditorName() {
    final next = _editorNameCtrl.text;
    if (next != widget.controller.project.meta.editorName) {
      widget.controller.updateMeta(editorName: next);
    }
  }

  void _commitEditorNote() {
    final next = _editorNoteCtrl.text;
    if (next != widget.controller.project.meta.editorNote) {
      widget.controller.updateMeta(editorNote: next);
    }
  }

  void _onTitleFocusChanged() {
    if (!_titleFocus.hasFocus && mounted) _commitTitle();
  }

  void _onArtistFocusChanged() {
    if (!_artistFocus.hasFocus && mounted) _commitArtist();
  }

  void _onBpmFocusChanged() {
    if (!_bpmFocus.hasFocus && mounted) {
      _commitBpmInput(widget.controller, _bpmCtrl.text);
    }
  }

  void _onComposerFocusChanged() {
    if (!_composerFocus.hasFocus && mounted) _commitComposer();
  }

  void _onLyricistFocusChanged() {
    if (!_lyricistFocus.hasFocus && mounted) _commitLyricist();
  }

  void _onArrangerFocusChanged() {
    if (!_arrangerFocus.hasFocus && mounted) _commitArranger();
  }

  void _onMixerFocusChanged() {
    if (!_mixerFocus.hasFocus && mounted) _commitMixer();
  }

  void _onVocalistFocusChanged() {
    if (!_vocalistFocus.hasFocus && mounted) _commitVocalist();
  }

  void _onSupportColorFocusChanged() {
    if (!_supportColorFocus.hasFocus && mounted) _commitSupportColor();
  }

  void _onTunerFocusChanged() {
    if (!_tunerFocus.hasFocus && mounted) _commitTuner();
  }

  void _onEditorNameFocusChanged() {
    if (!_editorNameFocus.hasFocus && mounted) _commitEditorName();
  }

  void _onEditorNoteFocusChanged() {
    if (!_editorNoteFocus.hasFocus && mounted) _commitEditorNote();
  }

  @override
  void didUpdateWidget(covariant DashboardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.projectListenable.removeListener(_syncMetaControllers);
      oldWidget.controller.scrollToTopSignal.removeListener(
        _handleScrollToTopSignal,
      );
      widget.controller.projectListenable.addListener(_syncMetaControllers);
      widget.controller.scrollToTopSignal.addListener(_handleScrollToTopSignal);
      _syncMetaControllers();
    }
  }

  void _handleScrollToTopSignal() {
    if (!mounted) return;
    final c = widget.controller;
    if (c.isPracticeMode || c.route != StudioRoute.dashboard) return;
    final activeController = _isTwoColumnLayout
        ? _timelineScrollController
        : _scrollController;
    unawaited(
      ScrollToTopButton.scrollToTop(
        context,
        activeController,
        controller: c,
      ),
    );
  }

  void _syncFieldIfIdle(
    TextEditingController ctrl,
    FocusNode focus,
    String target,
  ) {
    if (!focus.hasFocus && ctrl.text != target) {
      ctrl.text = target;
    }
  }

  void _syncMetaControllers() {
    if (!mounted) return;
    final meta = widget.controller.project.meta;
    _syncFieldIfIdle(_titleCtrl, _titleFocus, meta.title);
    _syncFieldIfIdle(_artistCtrl, _artistFocus, meta.artist);
    _syncFieldIfIdle(_bpmCtrl, _bpmFocus, '${meta.bpm}');
    _syncFieldIfIdle(_composerCtrl, _composerFocus, meta.composer);
    _syncFieldIfIdle(_lyricistCtrl, _lyricistFocus, meta.lyricist);
    _syncFieldIfIdle(_arrangerCtrl, _arrangerFocus, meta.arranger);
    _syncFieldIfIdle(_mixerCtrl, _mixerFocus, meta.mixer);
    _syncFieldIfIdle(_vocalistCtrl, _vocalistFocus, meta.vocalist);
    _syncFieldIfIdle(_supportColorCtrl, _supportColorFocus, meta.supportColor);
    _syncFieldIfIdle(_tunerCtrl, _tunerFocus, meta.tuner);
    _syncFieldIfIdle(_editorNameCtrl, _editorNameFocus, meta.editorName);
    _syncFieldIfIdle(_editorNoteCtrl, _editorNoteFocus, meta.editorNote);
  }

  @override
  void dispose() {
    widget.controller.projectListenable.removeListener(_syncMetaControllers);
    widget.controller.scrollToTopSignal.removeListener(
      _handleScrollToTopSignal,
    );
    _scrollController.removeListener(_onCompactScrollChanged);
    _scrollController.dispose();
    _leftScrollController.dispose();
    _timelineScrollController.dispose();
    _compactStickyVisible.dispose();
    _titleFocus.removeListener(_onTitleFocusChanged);
    _artistFocus.removeListener(_onArtistFocusChanged);
    _bpmFocus.removeListener(_onBpmFocusChanged);
    _composerFocus.removeListener(_onComposerFocusChanged);
    _lyricistFocus.removeListener(_onLyricistFocusChanged);
    _arrangerFocus.removeListener(_onArrangerFocusChanged);
    _mixerFocus.removeListener(_onMixerFocusChanged);
    _vocalistFocus.removeListener(_onVocalistFocusChanged);
    _supportColorFocus.removeListener(_onSupportColorFocusChanged);
    _tunerFocus.removeListener(_onTunerFocusChanged);
    _editorNameFocus.removeListener(_onEditorNameFocusChanged);
    _editorNoteFocus.removeListener(_onEditorNoteFocusChanged);
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _bpmCtrl.dispose();
    _composerCtrl.dispose();
    _lyricistCtrl.dispose();
    _arrangerCtrl.dispose();
    _mixerCtrl.dispose();
    _vocalistCtrl.dispose();
    _supportColorCtrl.dispose();
    _tunerCtrl.dispose();
    _editorNameCtrl.dispose();
    _editorNoteCtrl.dispose();
    _titleFocus.dispose();
    _artistFocus.dispose();
    _bpmFocus.dispose();
    _composerFocus.dispose();
    _lyricistFocus.dispose();
    _arrangerFocus.dispose();
    _mixerFocus.dispose();
    _vocalistFocus.dispose();
    _supportColorFocus.dispose();
    _tunerFocus.dispose();
    _editorNameFocus.dispose();
    _editorNoteFocus.dispose();
    super.dispose();
  }

  void _scrollToTimeline() {
    if (_isTwoColumnLayout) {
      _activeTimelineKey.currentState?.jumpToFollowTargetOrTop();
      return;
    }
    final ctx = _compactTimelineKey.currentContext;
    if (ctx == null || !_scrollController.hasClients) return;
    final target = ContinuousAutoScroller.computeTargetOffset(
      scrollController: _scrollController,
      itemContext: ctx,
      alignment: 0.0,
    );
    if (target == null) return;
    if (context.disableAnimations) {
      _scrollController.jumpTo(target);
    } else {
      unawaited(
        _scrollController.animateTo(
          target,
          duration: AppMotion.d(context, AppMotion.effectsSlow),
          curve: AppMotion.curveEffects,
        ),
      );
    }
  }

  void _commitBpmInput(CallbookController c, String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed != null) {
      c.setBpm(parsed);
    }
    final nextText = '${c.project.meta.bpm}';
    if (_bpmCtrl.text != nextText) {
      _bpmCtrl.text = nextText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = context.colorScheme;
    final bottomInset = BottomInsetScope.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoCols = constraints.maxWidth >= 960;
        _isTwoColumnLayout = twoCols;
        if (twoCols && _compactStickyVisible.value) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _isTwoColumnLayout && _compactStickyVisible.value) {
              _compactStickyVisible.value = false;
            }
          });
        }
        final activeTimelineController = twoCols
            ? _timelineScrollController
            : _scrollController;

        final Widget body;
        if (twoCols) {
          final pinHero = constraints.maxHeight >= 680;
          final leftPane = pinHero
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeroCard(context, c, scheme),
                    const SizedBox(height: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _leftScrollController,
                        padding: EdgeInsets.only(bottom: 20 + bottomInset),
                        child: _buildLeftSecondaryColumn(context, c, scheme),
                      ),
                    ),
                  ],
                )
              : SingleChildScrollView(
                  controller: _leftScrollController,
                  padding: EdgeInsets.only(bottom: 20 + bottomInset),
                  child: _buildLeftControlColumn(context, c, scheme),
                );
          final timeline = TimelineEditorWidget(
            key: _desktopTimelineKey,
            controller: c,
            compact: false,
            externalScrollController: _timelineScrollController,
          );
          body = Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 4, child: leftPane),
                const SizedBox(width: 16),
                Expanded(flex: 8, child: timeline),
              ],
            ),
          );
        } else {
          final leftColumn = _buildLeftControlColumn(context, c, scheme);
          final timeline = TimelineEditorWidget(
            key: _compactTimelineKey,
            controller: c,
            compact: true,
            externalScrollController: _scrollController,
          );
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: _compactStickyVisible,
                builder: (context, visible, _) {
                  if (!visible) return const SizedBox.shrink();
                  return _buildCompactStickyTransportBar(context, c, scheme);
                },
              ),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    _compactTimelineKey.currentState
                        ?.handleOuterScrollNotification(notification);
                    return false;
                  },
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 20 + bottomInset),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        leftColumn,
                        const SizedBox(height: 12),
                        timeline,
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        return Stack(
          children: [
            body,
            ScrollToTopButton(
              scrollController: activeTimelineController,
              controller: c,
              isCurrentLineVisible: () =>
                  _activeTimelineKey.currentState?.isFollowTargetVisible() ??
                  false,
              bottomOffset: bottomInset + AppTokens.s16,
            ),
          ],
        );
      },
    );
  }

  Widget _buildCompactStickyTransportBar(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Card(
        inert: true,
        radius: AppTokens.radiusCard,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: ListenableBuilder(
          listenable: Listenable.merge([c.playbackListenable, c.projectListenable]),
          builder: (context, _) {
            final safeDuration = math.max(1000, c.durationMs).toDouble();
            final clampedPos = c.currentTimeMs.toDouble().clamp(
              0.0,
              safeDuration,
            );
            final playButton = Semantics(
              button: true,
              label: c.isPlaying ? '暂停' : '播放',
              child: IconButton.filled(
                tooltip: c.isPlaying ? '暂停（Space）' : '播放（Space）',
                icon: GlyphIcon(
                  c.isPlaying ? CallbookGlyphs.stop : CallbookGlyphs.play,
                  size: 14,
                  color: scheme.onPrimary,
                  fill: 1,
                ),
                style: ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(scheme.primary),
                  shape: AppShape.circle,
                  minimumSize: const Size(32, 32),
                  fixedSize: const Size(32, 32),
                  tapTargetSize: TapTargetSize.padded,
                ),
                onPressed: c.togglePlay,
              ),
            );
            final slider = Slider(
              value: clampedPos,
              min: 0,
              max: safeDuration,
              onChanged: (v) => c.seek(v.round()),
            );
            final clockText = Text(
              formatMsToClock(c.currentTimeMs),
              style: AppTextStyle.caption2.of(context).copyWith(
                fontFamily: 'GoogleSans',
                fontFeatures: const [FontFeature.tabularFigures()],
                color: scheme.onSurfaceVariant,
              ),
            );
            final locateChip = TonalChip(
              label: '定位',
              color: scheme.surfaceContainerHigh,
              foregroundColor: scheme.onSurface,
              onPressed: () =>
                  _compactTimelineKey.currentState?.jumpToFollowTargetOrTop(),
            );
            final followLabel = Text(
              '跟随',
              style: AppTextStyle.caption2.of(context).copyWith(
                color: scheme.onSurfaceVariant,
              ),
            );
            final followSwitch = Switch(
              value: c.followPlayback,
              onChanged: c.setFollowPlayback,
              semanticLabel: '悬浮条跟随播放滚动',
            );

            return LayoutBuilder(
              builder: (context, barConstraints) {
                if (barConstraints.maxWidth < 440) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          playButton,
                          const SizedBox(width: 8),
                          Expanded(child: slider),
                          const SizedBox(width: 6),
                          clockText,
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          locateChip,
                          const Spacer(),
                          followLabel,
                          const SizedBox(width: 4),
                          followSwitch,
                        ],
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    playButton,
                    const SizedBox(width: 8),
                    Expanded(child: slider),
                    const SizedBox(width: 6),
                    clockText,
                    const SizedBox(width: 8),
                    locateChip,
                    const SizedBox(width: 6),
                    followLabel,
                    const SizedBox(width: 2),
                    followSwitch,
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildLeftControlColumn(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeroCard(context, c, scheme),
        const SizedBox(height: 12),
        _buildLeftSecondaryColumn(context, c, scheme),
      ],
    );
  }

  Widget _buildLeftSecondaryColumn(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildCreditsAndEditorCard(context, c, scheme),
        const SizedBox(height: 12),
        _buildAudioSettingsCard(context, c, scheme),
        const SizedBox(height: 12),
        _buildBpmSparkCard(context, c, scheme),
        const SizedBox(height: 12),
        _buildCoverageSparkCard(context, c, scheme),
        const SizedBox(height: 12),
        _buildExportJumpCard(context, c, scheme),
        const SizedBox(height: 12),
        AudioSourcePanel(controller: c),
      ],
    );
  }

  Widget _buildHeroCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    final sourceModeLabel = c.project.meta.audioUrl.isNotEmpty
        ? (c.project.meta.platform == 'local' ? '本地音频' : '在线音源')
        : '节拍器演练';
    final offsetMs = c.project.meta.offsetMs;

    return Card(
      inert: true,
      radius: AppTokens.radiusCard,
      padding: const EdgeInsets.all(AppTokens.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: ListenableBuilder(
                  listenable: c.playbackListenable,
                  builder: (context, _) {
                    final playingBg = c.isPlaying
                        ? scheme.successContainer
                        : scheme.surfaceContainerHigh;
                    final playingFg = c.isPlaying
                        ? scheme.onSuccessContainer
                        : scheme.onSurfaceVariant;
                    final playingLabel = c.siteText(
                      c.isPlaying ? '播放中' : '已暂停',
                    );
                    final statusDuration = AppMotion.d(
                      context,
                      AppMotion.effectsDefault,
                    );
                    return Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          c.siteText('播放状态'),
                          style: AppTextStyle.caption1
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onSurfaceVariant),
                        ),
                        AnimatedContainer(
                          duration: statusDuration,
                          curve: AppMotion.curveEffects,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: ShapeDecoration(
                            color: playingBg,
                            shape: AppShape.full,
                          ),
                          child: AnimatedSwitcher(
                            duration: statusDuration,
                            switchInCurve: AppMotion.curveEffects,
                            switchOutCurve: AppMotion.curveEffectsReverse,
                            child: Text(
                              playingLabel,
                              key: ValueKey<String>(playingLabel),
                              style: AppTextStyle.caption1
                                  .of(context, emphasized: true)
                                  .copyWith(color: playingFg),
                            ),
                          ),
                        ),
                        TonalChip(
                          label: sourceModeLabel,
                          color: scheme.primaryContainer,
                          foregroundColor: scheme.onPrimaryContainer,
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(width: 6),
              BeatDotsIndicator(
                controller: c,
                downbeatColor: scheme.error,
                beatColor: scheme.primary,
                inactiveColor: scheme.surfaceContainerHighest,
                dotSize: 9,
                spacing: 4,
                showBarBeatLabel: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _titleCtrl,
                      focusNode: _titleFocus,
                      style: AppTextStyle.headline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                      decoration: const InputDecoration.collapsed(
                        hintText: '输入当前歌曲名称',
                      ),
                      onSubmitted: (_) => _commitTitle(),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _artistCtrl,
                            focusNode: _artistFocus,
                            style: AppTextStyle.caption1
                                .of(context)
                                .copyWith(color: scheme.onSurfaceVariant),
                            decoration: const InputDecoration.collapsed(
                              hintText: '歌手 / 企划',
                            ),
                            onSubmitted: (_) => _commitArtist(),
                          ),
                        ),
                        const SizedBox(width: 6),
                        TonalChip(
                          label: '切换曲库 / 导入',
                          color: scheme.surfaceContainerHigh,
                          foregroundColor: scheme.primary,
                          onPressed: () => showAudioSourceModal(context, c),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ListenableBuilder(
                listenable: c.playbackListenable,
                builder: (context, _) => ScallopedOrbButton(
                  running: c.isPlaying,
                  size: 58,
                  onToggle: c.togglePlay,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ListenableBuilder(
            listenable: c.playbackListenable,
            builder: (context, _) {
              final safeDuration = math.max(1000, c.durationMs).toDouble();
              final clampedPos = c.currentTimeMs.toDouble().clamp(
                0.0,
                safeDuration,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Slider(
                    value: clampedPos,
                    min: 0,
                    max: safeDuration,
                    onChanged: (v) => c.seek(v.round()),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatMsToClock(c.currentTimeMs),
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(
                              fontFamily: 'GoogleSans',
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      Text(
                        formatMsToClock(safeDuration.round()),
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(
                              fontFamily: 'GoogleSans',
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '播放倍速与校准偏移',
                  style: AppTextStyle.caption1
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              TonalChip(
                label:
                    '首拍 ${offsetMs > 0 ? "+" : ""}${offsetMs}ms ${_showOffsetTools ? "▴" : "▾"}',
                color: scheme.surfaceContainerHigh,
                foregroundColor: scheme.onSurface,
                onPressed: () =>
                    setState(() => _showOffsetTools = !_showOffsetTools),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: c.playbackListenable,
            builder: (context, _) => SegmentedControl<double>(
              segments: const [
                (0.5, '0.5×'),
                (0.75, '0.75×'),
                (1.0, '1.0×'),
                (1.1, '1.1×'),
                (1.25, '1.25×'),
              ],
              value: c.playbackRate,
              onChanged: c.setPlaybackRate,
            ),
          ),
          if (_showOffsetTools) ...[
            const SizedBox(height: 8),
            ListenableBuilder(
              listenable: c.alignmentListenable,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      for (final delta in const [-100, -20]) ...[
                        Expanded(
                          child: _OffsetChipButton(
                            label: '$delta',
                            color: scheme.surfaceContainerLow,
                            foreground: scheme.onSurface,
                            onTap: () => c.adjustOffset(delta),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: _OffsetChipButton(
                          label: '归零',
                          color: scheme.surfaceContainerLow,
                          foreground: scheme.onSurfaceVariant,
                          onTap: () => c.setOffset(0),
                        ),
                      ),
                      for (final delta in const [20, 100]) ...[
                        const SizedBox(width: 6),
                        Expanded(
                          child: _OffsetChipButton(
                            label: '+$delta',
                            color: scheme.surfaceContainerLow,
                            foreground: scheme.onSurface,
                            onTap: () => c.adjustOffset(delta),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      for (final delta in const [-10, -1, 1, 10]) ...[
                        if (delta != -10) const SizedBox(width: 6),
                        Expanded(
                          child: _OffsetChipButton(
                            label: delta > 0 ? '+$delta' : '$delta',
                            color: scheme.surfaceContainerLow,
                            foreground: scheme.onSurface,
                            onTap: () => c.adjustOffset(delta),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      TonalChip(
                        label: '−半拍',
                        color: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurface,
                        onPressed: () => c.nudgeOffsetHalfBeat(-1),
                      ),
                      TonalChip(
                        label: '+半拍',
                        color: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurface,
                        onPressed: () => c.nudgeOffsetHalfBeat(1),
                      ),
                      TonalChip(
                        label: '设当前为第 1 拍',
                        color: scheme.primaryContainer,
                        foregroundColor: scheme.onPrimaryContainer,
                        onPressed: c.setCurrentTimeAsBeatOne,
                      ),
                      _DisplayFilterChip(
                        label: '锁定 BPM 仅校准首拍',
                        selected: c.lockBpmCalibrateDownbeat,
                        onPressed: () => c.setLockBpmCalibrateDownbeat(
                          !c.lockBpmCalibrateDownbeat,
                        ),
                      ),
                      TonalChip(
                        label: '首拍辅助分析',
                        color: scheme.secondaryContainer,
                        foregroundColor: scheme.onSecondaryContainer,
                        onPressed: () => _showDownbeatAnalyzerModal(context, c),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _DisplayFilterChip(
                label: '日语注音 (Furigana)',
                selected: c.displayLayers.showRuby,
                onPressed: () =>
                    c.updateDisplayLayers(showRuby: !c.displayLayers.showRuby),
              ),
              _DisplayFilterChip(
                label: '罗马音 (Romaji)',
                selected: c.displayLayers.showRomaji,
                onPressed: () => c.updateDisplayLayers(
                  showRomaji: !c.displayLayers.showRomaji,
                ),
              ),
              _DisplayFilterChip(
                label: '中文翻译',
                selected: c.displayLayers.showTranslation,
                onPressed: () => c.updateDisplayLayers(
                  showTranslation: !c.displayLayers.showTranslation,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetaInputField(
    BuildContext context,
    ColorScheme scheme, {
    required String label,
    required String hint,
    required TextEditingController controller,
    required FocusNode focusNode,
    required VoidCallback onSubmitted,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyle.caption2
              .of(context, emphasized: true)
              .copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          focusNode: focusNode,
          maxLines: maxLines,
          minLines: maxLines,
          decoration: InputDecoration(hintText: hint, isDense: true),
          onSubmitted: (_) => onSubmitted(),
        ),
      ],
    );
  }

  Widget _buildCreditsAndEditorCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    final showTuner = c.project.meta.showTuner;
    return Card(
      inert: true,
      radius: AppTokens.radiusCard,
      padding: const EdgeInsets.all(14),
      child: FilledInputTheme(
        borderRadius: AppRadius.md,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        fillColor: scheme.surfaceContainerHigh,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '曲目制作与编者信息',
                    style: AppTextStyle.headline
                        .of(context, emphasized: true)
                        .copyWith(color: scheme.onSurface),
                  ),
                ),
                Semantics(
                  button: true,
                  selected: showTuner,
                  label: '添加调教',
                  child: PressSurface(
                    fill: const Color(0x00000000),
                    shape: AppShape.sm,
                    tapTarget: AppTokens.minTapTargetSize,
                    selected: showTuner,
                    onPressed: () => c.updateMeta(showTuner: !showTuner),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: showTuner,
                          onChanged: (v) =>
                              c.updateMeta(showTuner: v ?? false),
                        ),
                        Text(
                          '添加调教',
                          style: AppTextStyle.footnote
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onSurface),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '作曲',
                    hint: '',
                    controller: _composerCtrl,
                    focusNode: _composerFocus,
                    onSubmitted: _commitComposer,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '作词',
                    hint: '',
                    controller: _lyricistCtrl,
                    focusNode: _lyricistFocus,
                    onSubmitted: _commitLyricist,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '编曲',
                    hint: '',
                    controller: _arrangerCtrl,
                    focusNode: _arrangerFocus,
                    onSubmitted: _commitArranger,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '混音',
                    hint: '',
                    controller: _mixerCtrl,
                    focusNode: _mixerFocus,
                    onSubmitted: _commitMixer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '演唱',
                    hint: c.project.meta.artist.isNotEmpty
                        ? c.project.meta.artist
                        : '',
                    controller: _vocalistCtrl,
                    focusNode: _vocalistFocus,
                    onSubmitted: _commitVocalist,
                  ),
                ),
                if (showTuner) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildMetaInputField(
                      context,
                      scheme,
                      label: '调教',
                      hint: '',
                      controller: _tunerCtrl,
                      focusNode: _tunerFocus,
                      onSubmitted: _commitTuner,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Builder(
              builder: (context) {
                final parsedSupport = extractSupportColor(_supportColorCtrl.text);
                final themeHex = formatHexColor(c.seedColor);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '应援色',
                      style: AppTextStyle.caption2
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: parsedSupport ?? const Color(0x00000000),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: scheme.outlineVariant,
                              width: 1.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _supportColorCtrl,
                            focusNode: _supportColorFocus,
                            decoration: const InputDecoration(
                              hintText: '',
                              isDense: true,
                            ),
                            onChanged: (_) => setState(() {}),
                            onSubmitted: (_) => _commitSupportColor(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final preset in curatedThemePresets)
                          Tooltip(
                            message:
                                '${preset.name} ${formatHexColor(preset.seedColor)}',
                            child: Semantics(
                              button: true,
                              label: '使用 ${preset.name} 应援色',
                              child: PressSurface(
                                fill: scheme.surfaceContainerLow,
                                shape: AppShape.full,
                                side: BorderSide(color: scheme.outlineVariant),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                onPressed: () {
                                  final hex = formatHexColor(preset.seedColor);
                                  _supportColorCtrl.text = hex;
                                  setState(() {});
                                  c.updateMeta(supportColor: hex);
                                },
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        color: preset.seedColor,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      preset.name,
                                      style: AppTextStyle.caption2
                                          .of(context)
                                          .copyWith(color: scheme.onSurface),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        TonalChip(
                          label: '同步主题色',
                          color: scheme.primaryContainer,
                          foregroundColor: scheme.onPrimaryContainer,
                          onPressed: () {
                            _supportColorCtrl.text = themeHex;
                            setState(() {});
                            c.updateMeta(supportColor: themeHex);
                          },
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '编者',
                    hint: '编者署名（导出前也可填）',
                    controller: _editorNameCtrl,
                    focusNode: _editorNameFocus,
                    onSubmitted: _commitEditorName,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '编者语',
                    hint: 'Call 本说明 / 寄语（可选）',
                    controller: _editorNoteCtrl,
                    focusNode: _editorNoteFocus,
                    onSubmitted: _commitEditorNote,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioSettingsCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Card(
      inert: true,
      radius: AppTokens.radiusCard,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: ShapeDecoration(
                  color: scheme.primaryContainer,
                  shape: AppShape.circle,
                ),
                alignment: Alignment.center,
                child: GlyphIcon(
                  CallbookGlyphs.musicNote,
                  size: 16,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '节拍器音频',
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    Text(
                      c.metronomeEnabled
                          ? '音量 ${(c.metronomeVolume * 100).round()}%'
                          : '已静音',
                      style: AppTextStyle.caption2
                          .of(context)
                          .copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Switch(
                value: c.metronomeEnabled,
                onChanged: c.setMetronomeEnabled,
                semanticLabel: '开启节拍器',
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: c.metronomeVolume,
                  min: 0.2,
                  max: 1.5,
                  onChanged: c.metronomeEnabled ? c.setMetronomeVolume : null,
                ),
              ),
              const SizedBox(width: 8),
              TonalChip(
                label: '试听',
                color: scheme.surfaceContainerHigh,
                foregroundColor: scheme.onSurface,
                onPressed: c.testMetronomeClick,
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: ShapeDecoration(
                  color: scheme.surfaceContainerHigh,
                  shape: AppShape.circle,
                ),
                alignment: Alignment.center,
                child: GlyphIcon(
                  CallbookGlyphs.studio,
                  size: 15,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '歌词时间轴跟随',
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    Text(
                      c.followPlayback ? '自动居中当前播放歌词' : '手动自由滚动',
                      style: AppTextStyle.caption2
                          .of(context)
                          .copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Switch(
                value: c.followPlayback,
                onChanged: c.setFollowPlayback,
                semanticLabel: '歌词时间轴跟随',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBpmSparkCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Card(
      inert: true,
      radius: AppTokens.radiusCard,
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: AppRadius.xl,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: ListenableBuilder(
                listenable: c.alignmentListenable,
                builder: (context, _) {
                  final tapCand = c.tapBpmCandidate;
                  final tapCount = c.tapSampleCount;
                  final bpmLocked = c.lockBpmCalibrateDownbeat;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '节拍速率 (BPM)',
                              style: AppTextStyle.caption1
                                  .of(context, emphasized: true)
                                  .copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          if (bpmLocked) ...[
                            TonalChip(
                              label: '已锁定',
                              color: scheme.secondaryContainer,
                              foregroundColor: scheme.onSecondaryContainer,
                            ),
                            const SizedBox(width: 6),
                          ],
                          TonalChip(
                            label: 'Tap',
                            color: scheme.surfaceContainerHigh,
                            foregroundColor: scheme.onSurface,
                            onPressed: c.tapTempo,
                          ),
                          const SizedBox(width: 6),
                          TonalChip(
                            label: c.project.meta.timeSignature,
                            color: scheme.surfaceContainerHigh,
                            foregroundColor: scheme.onSurface,
                            onPressed: () => c.setTimeSignature(
                              c.project.meta.timeSignature == '4/4'
                                  ? '3/4'
                                  : '4/4',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(
                            width: 72,
                            child: TextField(
                              controller: _bpmCtrl,
                              focusNode: _bpmFocus,
                              readOnly: bpmLocked,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: const InputDecoration.collapsed(
                                hintText: '120',
                              ),
                              style: AppTextStyle.title1
                                  .of(context, emphasized: true)
                                  .copyWith(
                                    fontFamily: 'GoogleSans',
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                    color: bpmLocked
                                        ? scheme.onSurfaceVariant
                                        : scheme.onSurface,
                                  ),
                              onChanged: (v) {
                                if (bpmLocked) return;
                                final parsed = int.tryParse(v.trim());
                                if (parsed != null &&
                                    parsed >= 30 &&
                                    parsed <= 300) {
                                  c.setBpm(parsed);
                                }
                              },
                              onSubmitted: (v) {
                                if (!bpmLocked) _commitBpmInput(c, v);
                              },
                              onEditingComplete: () {
                                if (!bpmLocked) {
                                  _commitBpmInput(c, _bpmCtrl.text);
                                }
                              },
                            ),
                          ),
                          Text(
                            'BPM',
                            style: AppTextStyle.caption1
                                .of(context, emphasized: true)
                                .copyWith(color: scheme.onSurfaceVariant),
                          ),
                          const Spacer(),
                          Opacity(
                            opacity: bpmLocked ? 0.45 : 1.0,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TonalChip(
                                  label: '−',
                                  color: scheme.surfaceContainerHigh,
                                  foregroundColor: scheme.onSurface,
                                  onPressed: () =>
                                      c.setBpm(c.project.meta.bpm - 1),
                                ),
                                const SizedBox(width: 6),
                                TonalChip(
                                  label: '+',
                                  color: scheme.surfaceContainerHigh,
                                  foregroundColor: scheme.onSurface,
                                  onPressed: () =>
                                      c.setBpm(c.project.meta.bpm + 1),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (tapCount > 0 || tapCand != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerLow,
                            borderRadius: AppRadius.md,
                          ),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (tapCand == null)
                                Text(
                                  'Tap 采样 $tapCount/4（第 4 下起输出候选）',
                                  style: AppTextStyle.caption2
                                      .of(context)
                                      .copyWith(color: scheme.onSurfaceVariant),
                                )
                              else ...[
                                Text(
                                  '候选 ${tapCand.bpm} BPM · 置信度 ${(tapCand.confidence * 100).round()}%',
                                  style: AppTextStyle.caption1
                                      .of(context, emphasized: true)
                                      .copyWith(color: scheme.onSurface),
                                ),
                                TonalChip(
                                  label: '应用 BPM',
                                  color: scheme.primaryContainer,
                                  foregroundColor: scheme.onPrimaryContainer,
                                  onPressed: c.applyTapBpmCandidate,
                                ),
                              ],
                              TonalChip(
                                label: '清除',
                                color: scheme.surfaceContainerHigh,
                                foregroundColor: scheme.onSurfaceVariant,
                                onPressed: c.clearTapSamples,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
            ListenableBuilder(
              listenable: c.beatListenable,
              builder: (context, _) => SparklineMetricFooter(
                values: c.beatPulseSeries,
                revision: c.beatSeriesRevision,
                color: scheme.primary,
                height: 36,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoverageSparkCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Card(
      inert: true,
      radius: AppTokens.radiusCard,
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: AppRadius.xl,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.siteText('编写覆盖率'),
                          style: AppTextStyle.caption1
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      TonalChip(
                        label: c.siteText('+ GT 警报'),
                        color: scheme.warningContainer,
                        foregroundColor: scheme.onWarningContainer,
                        onPressed: () => c.insertGtAlert(),
                      ),
                      const SizedBox(width: 6),
                      TonalChip(
                        label: '定位时间轴',
                        color: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurface,
                        onPressed: _scrollToTimeline,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '${c.taggedLineCount}',
                        style: AppTextStyle.title1
                            .of(context, emphasized: true)
                            .copyWith(
                              fontFamily: 'GoogleSans',
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: scheme.onSurface,
                            ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '/ ${c.sortedLines.length} 句已标 Call · ${c.sortedAlerts.length} GT 警报',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.caption1
                              .of(context)
                              .copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SparklineMetricFooter(
              values: c.callDensitySeries,
              revision: c.callDensityRevision,
              color: scheme.tertiary,
              height: 36,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExportJumpCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Semantics(
      button: true,
      label: c.siteText('导出Callbook'),
      child: ElasticPress(
        child: Card(
          radius: AppTokens.radiusCard,
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: AppTokens.s12,
          ),
          onPressed: () => c.setRoute(StudioRoute.export),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: ShapeDecoration(
                  color: scheme.successContainer,
                  shape: AppShape.circle,
                ),
                alignment: Alignment.center,
                child: GlyphIcon(
                  CallbookGlyphs.exportCard,
                  size: 16,
                  color: scheme.onSuccessContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.siteText('导出Callbook'),
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    Text(
                      'PNG 长图 · Excel · Markdown · JSON',
                      style: AppTextStyle.caption2
                          .of(context)
                          .copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              GlyphIcon(
                Glyphs.chevronForward,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DisplayFilterChip extends StatelessWidget {
  const _DisplayFilterChip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    final bg = selected
        ? scheme.primaryContainer
        : scheme.surfaceContainerHigh;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: PressSurface(
        fill: bg,
        shape: AppShape.full,
        foreground: fg,
        inkColor: fg,
        selected: selected,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              GlyphIcon(Glyphs.check, size: 13, color: fg),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.caption1
                  .of(context, emphasized: selected)
                  .copyWith(color: fg),
            ),
          ],
        ),
      ),
    );
  }
}

class _OffsetChipButton extends StatelessWidget {
  const _OffsetChipButton({
    required this.label,
    required this.color,
    required this.foreground,
    required this.onTap,
  });

  final String label;
  final Color color;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '偏移 $label 毫秒',
      child: PressSurface(
        fill: color,
        shape: AppShape.md,
        foreground: foreground,
        inkColor: foreground,
        tapTarget: AppTokens.minTapTargetSize,
        padding: const EdgeInsets.symmetric(vertical: 6),
        onPressed: onTap,
        child: Center(
          child: Text(
            label,
            style: AppTextStyle.caption1
                .of(context, emphasized: true)
                .copyWith(
                  fontFamily: 'GoogleSans',
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: foreground,
                ),
          ),
        ),
      ),
    );
  }
}

Future<void> _showDownbeatAnalyzerModal(
  BuildContext context,
  CallbookController controller,
) async {
  if (!controller.downbeatState.isAnalyzing &&
      controller.downbeatState.result == null &&
      controller.downbeatState.errorMessage == null) {
    unawaited(controller.analyzeDownbeatForCurrentTrack());
  }

  try {
    await showAppAdaptiveSheetOrDialog<void>(
      context: context,
      dialogBuilder: (dialogCtx) => AlertDialog(
        title: '首拍辅助分析（已知 BPM 原型）',
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('关闭'),
          ),
        ],
        child: SizedBox(
          width: 440,
          child: _DownbeatAnalyzerBody(
            controller: controller,
            onApplied: () {
              if (dialogCtx.mounted) {
                Navigator.of(dialogCtx).pop();
              }
            },
          ),
        ),
      ),
      sheetBuilder: (sheetCtx, scrollController) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetDragHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '首拍辅助分析（已知 BPM 原型）',
                    style: AppTextStyle.headline
                        .of(sheetCtx, emphasized: true)
                        .copyWith(color: sheetCtx.colorScheme.onSurface),
                  ),
                ),
                Semantics(
                  button: true,
                  label: '关闭首拍辅助分析',
                  child: IconButton(
                    tooltip: '关闭',
                    icon: const GlyphIcon(Glyphs.close, size: 18),
                    style: const ButtonStyle(
                      minimumSize: AppTokens.minTapTargetSize,
                    ),
                    onPressed: () => Navigator.of(sheetCtx).pop(),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.all(AppTokens.s16),
              child: _DownbeatAnalyzerBody(
                controller: controller,
                onApplied: () {
                  if (sheetCtx.mounted) {
                    Navigator.of(sheetCtx).pop();
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  } finally {
    if (controller.downbeatState.isAnalyzing) {
      controller.cancelDownbeatAnalysis();
    }
    controller.clearDownbeatPreviewOffset();
  }
}

class _DownbeatAnalyzerBody extends StatefulWidget {
  const _DownbeatAnalyzerBody({
    required this.controller,
    required this.onApplied,
  });

  final CallbookController controller;
  final VoidCallback onApplied;

  @override
  State<_DownbeatAnalyzerBody> createState() => _DownbeatAnalyzerBodyState();
}

class _DownbeatAnalyzerBodyState extends State<_DownbeatAnalyzerBody> {
  int? _selectedCandidateOffsetMs;
  int? _lastResultReqId;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = context.colorScheme;

    return ListenableBuilder(
      listenable: c.alignmentListenable,
      builder: (context, _) {
        final state = c.downbeatState;
        final res = state.result;
        if (res != null &&
            res.requestId != _lastResultReqId &&
            res.candidates.isNotEmpty) {
          _lastResultReqId = res.requestId;
          _selectedCandidateOffsetMs = res.candidates.first.offsetMs;
        }
        final activeOffset =
            _selectedCandidateOffsetMs ?? c.project.meta.offsetMs;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '基于当前工程已知 BPM（${c.project.meta.bpm} BPM）分析有声起点与节拍相位候选，仅辅助参考，不会自动覆盖现有设置或平移歌词。',
              style: AppTextStyle.caption1.of(context).copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            if (state.isAnalyzing) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: ShapeDecoration(
                  color: scheme.surfaceContainerLow,
                  shape: AppShape.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      state.stageMessage.isNotEmpty
                          ? state.stageMessage
                          : '正在分析音频…',
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    const SizedBox(height: 8),
                    TonalButton(
                      size: TonalButtonSize.compact,
                      label: '取消分析',
                      onPressed: c.cancelDownbeatAnalysis,
                    ),
                  ],
                ),
              ),
            ] else if (state.errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: ShapeDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.45),
                  shape: AppShape.md,
                ),
                child: Text(
                  state.errorMessage!,
                  style: AppTextStyle.caption1.of(context).copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TonalButton(
                size: TonalButtonSize.compact,
                label: '重新分析',
                onPressed: () => c.analyzeDownbeatForCurrentTrack(),
              ),
            ] else if (res != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: ShapeDecoration(
                  color: scheme.surfaceContainerLow,
                  shape: AppShape.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      res.reliable
                          ? '有声起点：${res.audibleStartMs ?? 0}ms（不自动裁剪音频）'
                          : (res.audibleStartMs != null
                                ? '${res.statusMessage}（有声起点：${res.audibleStartMs}ms）'
                                : res.statusMessage),
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(
                            color: res.reliable
                                ? scheme.onSurface
                                : scheme.error,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '已分析 ${(res.telemetry.analyzedDurationMs / 1000).toStringAsFixed(1)}s · '
                      '拉取 ${res.telemetry.fetchMs}ms · 解码 ${res.telemetry.decodeMs}ms · '
                      '重采样 ${res.telemetry.resampleMs}ms · 分析 ${res.telemetry.analyzeMs}ms · '
                      '峰值 ${(res.telemetry.estimatedPeakBytes / (1024 * 1024)).toStringAsFixed(2)}MB',
                      style: AppTextStyle.caption2.of(context).copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              if (res.reliable && res.candidates.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final cand in res.candidates) ...[
                  PressSurface(
                    fill: _selectedCandidateOffsetMs == cand.offsetMs
                        ? scheme.primaryContainer.withValues(alpha: 0.55)
                        : scheme.surfaceContainerLow,
                    shape: AppShape.md,
                    onPressed: () => setState(() {
                      _selectedCandidateOffsetMs = cand.offsetMs;
                    }),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${cand.label} · ${cand.offsetMs}ms',
                            style: AppTextStyle.subheadline
                                .of(context, emphasized: true)
                                .copyWith(color: scheme.onSurface),
                          ),
                        ),
                        TonalChip(
                          label: '置信度 ${(cand.confidence * 100).round()}%',
                          color: scheme.primaryContainer,
                          foregroundColor: scheme.onPrimaryContainer,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                const SizedBox(height: 6),
                Text(
                  '微调与试听偏移：${activeOffset}ms',
                  style: AppTextStyle.caption1
                      .of(context, emphasized: true)
                      .copyWith(
                        color: scheme.onSurface,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final delta in const [-10, -1, 1, 10])
                      TonalChip(
                        label: delta > 0 ? '+$delta' : '$delta',
                        color: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurface,
                        onPressed: () => setState(() {
                          _selectedCandidateOffsetMs = clampSongOffsetMs(
                            activeOffset + delta,
                          );
                        }),
                      ),
                    TonalChip(
                      label: '试听预览',
                      color: scheme.secondaryContainer,
                      foregroundColor: scheme.onSecondaryContainer,
                      onPressed: () => c.previewDownbeatCandidate(activeOffset),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TonalButton(
                        size: TonalButtonSize.compact,
                        label: '重新分析',
                        onPressed: () => c.analyzeDownbeatForCurrentTrack(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          c.applyDownbeatCandidateOffset(activeOffset);
                          widget.onApplied();
                        },
                        child: const Text('应用到首拍'),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                const SizedBox(height: 10),
                TonalButton(
                  size: TonalButtonSize.compact,
                  label: '重新分析',
                  onPressed: () => c.analyzeDownbeatForCurrentTrack(),
                ),
              ],
            ] else ...[
              FilledButton(
                onPressed: () => c.analyzeDownbeatForCurrentTrack(),
                child: const Text('开始分析当前音频'),
              ),
            ],
          ],
        );
      },
    );
  }
}
