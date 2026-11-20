import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../models/callbook_models.dart';
import '../state/callbook_controller.dart';
import '../utils/aligned_calls.dart';
import '../utils/lrc_ruby_parser.dart';
import '../utils/section_detector.dart';
import 'theme/app_motion.dart';
import 'theme/app_tokens.dart';
import 'widgets/call_badge_pill.dart';
import 'widgets/ruby_lyric_text.dart';
import 'widgets/scalloped_orb_button.dart';
import 'widgets/scroll_to_top_button.dart';

class PracticeOverlay extends StatefulWidget {
  const PracticeOverlay({super.key, required this.controller});

  final CallbookController controller;

  @override
  State<PracticeOverlay> createState() => _PracticeOverlayState();
}

class _PracticeOverlayState extends State<PracticeOverlay> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _lineKeys = {};
  String? _pendingScrollLineId;

  @override
  void initState() {
    super.initState();
    widget.controller.playbackSyncListenable.addListener(_handlePlaybackSync);
    widget.controller.jumpToCurrentLineSignal.addListener(_handleJumpToCurrent);
    widget.controller.scrollToTopSignal.addListener(_handleScrollToTopSignal);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToLine(
        widget.controller.followTargetLineId ?? widget.controller.activeLineId,
      );
    });
  }

  @override
  void didUpdateWidget(covariant PracticeOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.playbackSyncListenable.removeListener(
        _handlePlaybackSync,
      );
      oldWidget.controller.jumpToCurrentLineSignal.removeListener(
        _handleJumpToCurrent,
      );
      oldWidget.controller.scrollToTopSignal.removeListener(
        _handleScrollToTopSignal,
      );
      widget.controller.playbackSyncListenable.addListener(_handlePlaybackSync);
      widget.controller.jumpToCurrentLineSignal.addListener(
        _handleJumpToCurrent,
      );
      widget.controller.scrollToTopSignal.addListener(_handleScrollToTopSignal);
    }
  }

  void _handleJumpToCurrent() {
    if (!mounted || !widget.controller.isPracticeMode) return;
    _scrollToLine(
      widget.controller.followTargetLineId ?? widget.controller.activeLineId,
    );
  }

  void _handleScrollToTopSignal() {
    if (!mounted || !widget.controller.isPracticeMode) return;
    unawaited(
      ScrollToTopButton.scrollToTop(
        context,
        _scrollController,
        controller: widget.controller,
      ),
    );
  }

  bool _isFollowTargetVisible() {
    final targetId =
        widget.controller.followTargetLineId ?? widget.controller.activeLineId;
    if (targetId == null) return false;
    final ctx = _lineKeys[targetId]?.currentContext;
    if (ctx == null) return false;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return false;
    final scrollable = Scrollable.maybeOf(ctx);
    if (scrollable == null) return true;
    final scrollBox = scrollable.context.findRenderObject();
    if (scrollBox is! RenderBox || !scrollBox.hasSize) return false;
    final topLeft = ro.localToGlobal(Offset.zero, ancestor: scrollBox);
    final rect = topLeft & ro.size;
    return rect.bottom > 0 && rect.top < scrollBox.size.height;
  }

  void _handlePlaybackSync() {
    final c = widget.controller;
    if (!c.isPracticeMode || c.followPausedByScrollTop) return;
    final targetId = c.followTargetLineId ?? c.activeLineId;
    if (targetId == null) return;
    final wasScheduled = _pendingScrollLineId != null;
    _pendingScrollLineId = targetId;
    if (!wasScheduled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final scheduledId = _pendingScrollLineId;
        _pendingScrollLineId = null;
        _scrollToLine(scheduledId);
      });
    }
  }

  void _scrollToLine(String? lineId, {bool allowEstimateFallback = true}) {
    if (!mounted || lineId == null) return;
    final ctx = _lineKeys[lineId]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: AppMotion.d(context, AppMotion.effectsDefault),
        curve: AppMotion.curveEffects,
        alignment: 0.42,
      );
      return;
    }
    if (!allowEstimateFallback || !_scrollController.hasClients) return;
    final lines = widget.controller.sortedLines;
    final idx = lines.indexWhere((l) => l.id == lineId);
    if (idx < 0 || lines.isEmpty) return;
    final maxExtent = _scrollController.position.maxScrollExtent;
    final estimated = lines.length <= 1
        ? 0.0
        : (maxExtent * (idx / (lines.length - 1))).clamp(0.0, maxExtent);
    _scrollController.jumpTo(estimated);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToLine(lineId, allowEstimateFallback: false);
    });
  }

  @override
  void dispose() {
    widget.controller.playbackSyncListenable.removeListener(
      _handlePlaybackSync,
    );
    widget.controller.jumpToCurrentLineSignal.removeListener(
      _handleJumpToCurrent,
    );
    widget.controller.scrollToTopSignal.removeListener(
      _handleScrollToTopSignal,
    );
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = context.colorScheme;
    final lines = c.sortedLines;
    final presetMap = c.presetMap;
    final pad = MediaQuery.paddingOf(context);
    final stageBg = c.pureBlack
        ? const Color(0xFF000000)
        : scheme.surfaceContainerLowest;
    final deckBg = c.pureBlack
        ? const Color(0xFF000000)
        : scheme.surfaceContainer;

    return Positioned.fill(
      child: ColoredBox(
        color: stageBg,
        child: DefaultTextStyle.merge(
          style: TextStyle(
            fontFamily: c.useGoogleSans ? 'GoogleSans' : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: pad.top),

              // Header Bar
              Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                decoration: BoxDecoration(
                  color: deckBg,
                  border: Border(
                    bottom: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final titleColumn = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListenableBuilder(
                          listenable: c.playbackListenable,
                          builder: (context, _) => Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              Text(
                                'LIVE PRACTICE MODE · ${c.project.meta.bpm} BPM · 小节 ${c.currentBar}.${c.currentBeatInBar}',
                                style: AppTextStyle.caption1
                                    .of(context, emphasized: true)
                                    .copyWith(
                                      fontFamily: 'GoogleSans',
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                      color: scheme.primary,
                                    ),
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (
                                    var b = 1;
                                    b <= c.project.meta.beatsPerBar;
                                    b++
                                  ) ...[
                                    AnimatedContainer(
                                      duration: AppMotion.d(
                                        context,
                                        AppMotion.effectsFast,
                                      ),
                                      curve: AppMotion.curveEffects,
                                      width: b == 1 ? 10 : 8,
                                      height: b == 1 ? 10 : 8,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color:
                                            c.isPlaying &&
                                                c.currentBeatInBar == b
                                            ? (b == 1
                                                  ? scheme.primary
                                                  : scheme.tertiary)
                                            : scheme.outlineVariant,
                                      ),
                                    ),
                                    if (b < c.project.meta.beatsPerBar)
                                      const SizedBox(width: 4),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          c.project.meta.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.headline
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onSurface),
                        ),
                      ],
                    );

                    final headerControls = Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _PracticeFilterChip(
                          label: '注音',
                          selected: c.displayLayers.showRuby,
                          onPressed: () => c.updateDisplayLayers(
                            showRuby: !c.displayLayers.showRuby,
                          ),
                        ),
                        _PracticeFilterChip(
                          label: '罗马音',
                          selected: c.displayLayers.showRomaji,
                          onPressed: () => c.updateDisplayLayers(
                            showRomaji: !c.displayLayers.showRomaji,
                          ),
                        ),
                        _PracticeFilterChip(
                          label: '翻译',
                          selected: c.displayLayers.showTranslation,
                          onPressed: () => c.updateDisplayLayers(
                            showTranslation: !c.displayLayers.showTranslation,
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: '退出演练',
                          child: Tooltip(
                            message: '退出演练（Esc / F）',
                            child: TonalButton(
                              size: TonalButtonSize.compact,
                              glyph: Glyphs.close,
                              label: '退出演练',
                              onPressed: () => c.setPracticeMode(false),
                            ),
                          ),
                        ),
                      ],
                    );

                    if (constraints.maxWidth < 720) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          titleColumn,
                          const SizedBox(height: 10),
                          headerControls,
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: titleColumn),
                        const SizedBox(width: 12),
                        headerControls,
                      ],
                    );
                  },
                ),
              ),

              // Scrollable Teleprompter Feed
              Expanded(
                child: lines.isEmpty
                    ? Center(
                        child: Text(
                          '当前曲目暂无歌词行',
                          style: AppTextStyle.headline.of(context).copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : Stack(
                        children: [
                          ListView.separated(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 28,
                            ),
                            itemCount: lines.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 16),
                            itemBuilder: (context, index) {
                              final line = lines[index];
                              final lineAlert = c.getAlertForLine(line.id);
                              return KeyedSubtree(
                                key: _lineKeys.putIfAbsent(
                                  line.id,
                                  GlobalKey.new,
                                ),
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 880,
                                    ),
                                    child: _ReactivePracticeLineCard(
                                      controller: c,
                                      line: line,
                                      lineAlert: lineAlert,
                                      presetMap: presetMap,
                                      displayLayers: c.displayLayers,
                                      textScale: c.textScale,
                                      primaryColor: scheme.primary,
                                      onTap: () => c.seek(line.startTimeMs),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          ScrollToTopButton(
                            scrollController: _scrollController,
                            controller: c,
                            isCurrentLineVisible: _isFollowTargetVisible,
                            bottomOffset: AppTokens.s16,
                          ),
                        ],
                      ),
              ),

              // Bottom Stage Transport Deck
              Container(
                padding: EdgeInsets.fromLTRB(20, 12, 20, pad.bottom + 14),
                decoration: BoxDecoration(
                  color: deckBg,
                  border: Border(
                    top: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 880),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListenableBuilder(
                          listenable: c.playbackListenable,
                          builder: (context, _) {
                            final safeDuration =
                                math.max(1000, c.durationMs).toDouble();
                            final clampedPos = c.currentTimeMs.toDouble().clamp(
                              0.0,
                              safeDuration,
                            );
                            return Slider(
                              value: clampedPos,
                              min: 0,
                              max: safeDuration,
                              onChanged: (v) => c.seek(v.round()),
                            );
                          },
                        ),
                        const SizedBox(height: 6),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final clockText = ListenableBuilder(
                              listenable: c.playbackListenable,
                              builder: (context, _) {
                                final safeDuration = math.max(
                                  1000,
                                  c.durationMs,
                                );
                                return Text(
                                  '${formatMsToClock(c.currentTimeMs)} / ${formatMsToClock(safeDuration)}',
                                  style: AppTextStyle.footnote
                                      .of(context, emphasized: true)
                                      .copyWith(
                                        fontFamily: 'GoogleSans',
                                        fontFeatures: const [
                                          FontFeature.tabularFigures(),
                                        ],
                                        color: scheme.onSurfaceVariant,
                                      ),
                                );
                              },
                            );
                            final transportButtons = Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Semantics(
                                  label: '快退 2 秒',
                                  button: true,
                                  child: Tooltip(
                                    message: '快退 2 秒（←）',
                                    child: TonalChip(
                                      label: '-2s',
                                      color: scheme.surfaceContainerHigh,
                                      foregroundColor: scheme.onSurface,
                                      onPressed: () =>
                                          c.seek(c.currentTimeMs - 2000),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                ListenableBuilder(
                                  listenable: c.playbackListenable,
                                  builder: (context, _) => ScallopedOrbButton(
                                    running: c.isPlaying,
                                    size: 54,
                                    onToggle: c.togglePlay,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Semantics(
                                  label: '快进 2 秒',
                                  button: true,
                                  child: Tooltip(
                                    message: '快进 2 秒（→）',
                                    child: TonalChip(
                                      label: '+2s',
                                      color: scheme.surfaceContainerHigh,
                                      foregroundColor: scheme.onSurface,
                                      onPressed: () =>
                                          c.seek(c.currentTimeMs + 2000),
                                    ),
                                  ),
                                ),
                              ],
                            );
                            final speedChips = ListenableBuilder(
                              listenable: c.playbackListenable,
                              builder: (context, _) => SizedBox(
                                width: 174,
                                child: SegmentedControl<double>(
                                  segments: const [
                                    (0.75, '0.75x'),
                                    (1.0, '1.0x'),
                                    (1.25, '1.25x'),
                                  ],
                                  value: c.playbackRate,
                                  onChanged: c.setPlaybackRate,
                                ),
                              ),
                            );

                            if (constraints.maxWidth < 540) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [clockText, speedChips],
                                  ),
                                  const SizedBox(height: 8),
                                  Center(child: transportButtons),
                                ],
                              );
                            }

                            return Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                clockText,
                                transportButtons,
                                speedChips,
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReactivePracticeLineCard extends StatefulWidget {
  const _ReactivePracticeLineCard({
    required this.controller,
    required this.line,
    required this.lineAlert,
    required this.presetMap,
    required this.displayLayers,
    required this.textScale,
    required this.primaryColor,
    required this.onTap,
  });

  final CallbookController controller;
  final LyricLine line;
  final GtAlert? lineAlert;
  final Map<String, CallPreset> presetMap;
  final DisplayLayers displayLayers;
  final double textScale;
  final Color primaryColor;
  final VoidCallback onTap;

  @override
  State<_ReactivePracticeLineCard> createState() =>
      _ReactivePracticeLineCardState();
}

class _ReactivePracticeLineCardState extends State<_ReactivePracticeLineCard> {
  late bool _isPlaying;
  late bool _isUpcoming;

  @override
  void initState() {
    super.initState();
    _isPlaying = widget.controller.playingLineId == widget.line.id;
    _isUpcoming = widget.controller.upcomingLineId == widget.line.id;
    widget.controller.playingLineIdListenable.addListener(_onPlaybackChanged);
    widget.controller.upcomingLineIdListenable.addListener(_onPlaybackChanged);
  }

  @override
  void didUpdateWidget(covariant _ReactivePracticeLineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.playingLineIdListenable
          .removeListener(_onPlaybackChanged);
      oldWidget.controller.upcomingLineIdListenable
          .removeListener(_onPlaybackChanged);
      widget.controller.playingLineIdListenable.addListener(_onPlaybackChanged);
      widget.controller.upcomingLineIdListenable.addListener(
        _onPlaybackChanged,
      );
    }
    _isPlaying = widget.controller.playingLineId == widget.line.id;
    _isUpcoming = widget.controller.upcomingLineId == widget.line.id;
  }

  void _onPlaybackChanged() {
    final nextPlaying = widget.controller.playingLineId == widget.line.id;
    final nextUpcoming = widget.controller.upcomingLineId == widget.line.id;
    if (nextPlaying != _isPlaying || nextUpcoming != _isUpcoming) {
      setState(() {
        _isPlaying = nextPlaying;
        _isUpcoming = nextUpcoming;
      });
    }
  }

  @override
  void dispose() {
    widget.controller.playingLineIdListenable
        .removeListener(_onPlaybackChanged);
    widget.controller.upcomingLineIdListenable
        .removeListener(_onPlaybackChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _PracticeLineCard(
      line: widget.line,
      lineAlert: widget.lineAlert,
      presetMap: widget.presetMap,
      displayLayers: widget.displayLayers,
      textScale: widget.textScale,
      primaryColor: widget.primaryColor,
      isPlaying: _isPlaying,
      isUpcoming: _isUpcoming && !_isPlaying,
      upcomingLabel: widget.controller.siteText('即将演唱'),
      onTap: widget.onTap,
    );
  }
}

class _PracticeLineCard extends StatelessWidget {
  const _PracticeLineCard({
    required this.line,
    required this.lineAlert,
    required this.presetMap,
    required this.displayLayers,
    required this.textScale,
    required this.primaryColor,
    required this.isPlaying,
    required this.isUpcoming,
    required this.upcomingLabel,
    required this.onTap,
  });

  final LyricLine line;
  final GtAlert? lineAlert;
  final Map<String, CallPreset> presetMap;
  final DisplayLayers displayLayers;
  final double textScale;
  final Color primaryColor;
  final bool isPlaying;
  final bool isUpcoming;
  final String upcomingLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final gtNote = (lineAlert?.note ?? '').trim();
    final isSec = line.kind.isSection;
    final shout = isSec ? line.customShout.trim() : getUnalignedCustomShout(line);

    late final Color borderColor;
    late final Color bgColor;
    late final double opacity;
    List<BoxShadow> shadows = const [];

    if (isPlaying && lineAlert != null) {
      borderColor = scheme.warning;
      bgColor = Color.alphaBlend(
        scheme.warningContainer.withValues(alpha: 0.55),
        scheme.surfaceContainer,
      );
      opacity = 1.0;
      shadows = [
        BoxShadow(
          color: scheme.warning.withValues(alpha: 0.25),
          blurRadius: 24,
        ),
      ];
    } else if (isPlaying) {
      borderColor = scheme.primary;
      bgColor = Color.alphaBlend(
        scheme.primaryContainer.withValues(alpha: 0.38),
        scheme.surfaceContainer,
      );
      opacity = 1.0;
      shadows = [
        BoxShadow(
          color: scheme.primary.withValues(alpha: 0.24),
          blurRadius: 26,
        ),
      ];
    } else if (isUpcoming) {
      borderColor = scheme.tertiary.withValues(alpha: 0.72);
      bgColor = Color.alphaBlend(
        scheme.tertiaryContainer.withValues(alpha: 0.28),
        scheme.surfaceContainer,
      );
      opacity = 0.92;
    } else if (lineAlert != null) {
      borderColor = scheme.warning.withValues(alpha: 0.8);
      bgColor = Color.alphaBlend(
        scheme.warningContainer.withValues(alpha: 0.32),
        scheme.surfaceContainer,
      );
      opacity = 0.88;
    } else {
      borderColor = scheme.outlineVariant;
      bgColor = scheme.surfaceContainer;
      opacity = 0.68;
    }

    return Semantics(
      button: true,
      selected: isPlaying,
      label: line.text.original.isNotEmpty
          ? '跳转到 ${line.text.original}'
          : '跳转到歌词行',
      child: Opacity(
        opacity: opacity,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: AppShape.all(AppTokens.radiusCard),
            shadows: shadows,
          ),
          child: PressSurface(
            fill: bgColor,
            shape: AppShape.all(AppTokens.radiusCard),
            side: BorderSide(
              color: borderColor,
              width: isPlaying ? 1.8 : 1.0,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
            tapTarget: AppTokens.minTapTargetSize,
            selected: isPlaying,
            onPressed: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      formatMsToClock(line.startTimeMs),
                      style: AppTextStyle.caption1.of(context).copyWith(
                        fontFamily: 'GoogleSans',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (isUpcoming)
                      TonalChip(
                        label: upcomingLabel,
                        color: scheme.tertiaryContainer,
                        foregroundColor: scheme.onTertiaryContainer,
                      ),
                    if (line.kind.isSection)
                      TonalChip(
                        label:
                            '${line.kind.zhLabel} · ${formatGapSec(math.max(1000, line.endTimeMs - line.startTimeMs))}',
                        color: scheme.secondaryContainer,
                        foregroundColor: scheme.onSecondaryContainer,
                      ),
                    if (lineAlert != null)
                      TonalChip(
                        label: 'GT 警报',
                        color: scheme.warning,
                        foregroundColor: CallBadgePill.contrastForegroundFor(
                          scheme.warning,
                        ),
                      ),
                    if (lineAlert != null && gtNote.isNotEmpty)
                      Text(
                        gtNote,
                        style: AppTextStyle.footnote
                            .of(context, emphasized: true)
                            .copyWith(color: scheme.warning),
                      ),
                    for (final tag in line.calls)
                      if (presetMap[tag.presetId] case final CallPreset p?)
                        CallBadgePill(
                          preset: p,
                          suffix: tag.suffix,
                        ),
                    if (shout.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: ShapeDecoration(
                          color: scheme.tertiaryContainer,
                          shape: AppShape.full,
                        ),
                        child: Text(
                          shout,
                          softWrap: false,
                          maxLines: 1,
                          overflow: TextOverflow.visible,
                          style: AppTextStyle.caption1
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onTertiaryContainer),
                        ),
                      ),
                    if (line.tailUpdraft)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: ShapeDecoration(
                          color: scheme.tertiary,
                          shape: AppShape.full,
                        ),
                        child: Text(
                          '尾句上升气流',
                          softWrap: false,
                          maxLines: 1,
                          overflow: TextOverflow.visible,
                          style: AppTextStyle.caption1
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onTertiary),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                RubyLyricText(
                  original: line.text.original,
                  rubyHtml: line.text.ruby,
                  showRuby: displayLayers.showRuby,
                  alignedCalls: isSec ? const [] : line.alignedCalls,
                  customShout: isSec ? '' : line.customShout,
                  pillBackground: scheme.tertiaryContainer,
                  pillForeground: scheme.onTertiaryContainer,
                  pillBorderColor: scheme.outlineVariant,
                  underlineColor: scheme.tertiary,
                  baseStyle: TextStyle(
                    fontSize: (isPlaying ? 32 : 22) * textScale,
                    fontWeight: FontWeight.w800,
                    height: 1.32,
                    color: scheme.onSurface,
                  ),
                  rtStyle: TextStyle(
                    fontSize: (isPlaying ? 15 : 11) * textScale,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
                if (displayLayers.showRomaji &&
                    line.text.romaji != null &&
                    line.text.romaji!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    line.text.romaji!,
                    style: TextStyle(
                      fontFamily: 'GoogleSans',
                      fontSize: isPlaying ? 16 : 13,
                      color: scheme.tertiary,
                    ),
                  ),
                ],
                if (displayLayers.showTranslation &&
                    line.text.translation != null &&
                    line.text.translation!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    line.text.translation!,
                    style: TextStyle(
                      fontSize: isPlaying ? 18 : 14,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PracticeFilterChip extends StatelessWidget {
  const _PracticeFilterChip({
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
    final bg = selected ? scheme.primary : scheme.surfaceContainerHigh;
    final fg = selected ? scheme.onPrimary : scheme.onSurfaceVariant;
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
        tapTarget: AppTokens.minTapTargetSize,
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
