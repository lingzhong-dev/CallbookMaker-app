import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../models/callbook_models.dart';
import '../state/callbook_controller.dart';
import '../utils/aligned_calls.dart';
import '../utils/lrc_ruby_parser.dart';
import '../utils/section_detector.dart';
import 'widgets/call_badge_pill.dart';
import 'widgets/ruby_lyric_text.dart';
import 'widgets/scalloped_orb_button.dart';

class PracticeOverlay extends StatefulWidget {
  const PracticeOverlay({super.key, required this.controller});

  final CallbookController controller;

  @override
  State<PracticeOverlay> createState() => _PracticeOverlayState();
}

class _PracticeOverlayState extends State<PracticeOverlay> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _lineKeys = {};
  String? _lastPlayingLineId;

  @override
  void initState() {
    super.initState();
    _lastPlayingLineId = widget.controller.playingLineId;
    widget.controller.playingLineIdListenable.addListener(
      _handlePlayingLineChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToLine(_lastPlayingLineId ?? widget.controller.activeLineId);
    });
  }

  @override
  void didUpdateWidget(covariant PracticeOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.playingLineIdListenable.removeListener(
        _handlePlayingLineChanged,
      );
      _lastPlayingLineId = widget.controller.playingLineId;
      widget.controller.playingLineIdListenable.addListener(
        _handlePlayingLineChanged,
      );
    }
  }

  void _handlePlayingLineChanged() {
    final c = widget.controller;
    final nextPlaying = c.playingLineId;
    if (nextPlaying != null && nextPlaying != _lastPlayingLineId) {
      _lastPlayingLineId = nextPlaying;
      if (c.isPracticeMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToLine(nextPlaying);
        });
      }
    } else {
      _lastPlayingLineId = nextPlaying;
    }
  }

  void _scrollToLine(String? lineId) {
    if (!mounted || lineId == null) return;
    final ctx = _lineKeys[lineId]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: 0.42,
      );
    }
  }

  @override
  void dispose() {
    widget.controller.playingLineIdListenable.removeListener(
      _handlePlayingLineChanged,
    );
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = context.colorScheme;
    final lines = c.sortedLines;
    final presetMap = {for (final p in c.allPresets) p.id: p};
    final pad = MediaQuery.paddingOf(context);

    // Pure OLED black stage without any screen-edge flashing borders.
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xFF000000),
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
                decoration: const BoxDecoration(
                  color: Color(0xFF09090B),
                  border: Border(
                    bottom: BorderSide(color: Color(0xFF27272A)),
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
                                      duration: const Duration(
                                        milliseconds: 90,
                                      ),
                                      width: b == 1 ? 10 : 8,
                                      height: b == 1 ? 10 : 8,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color:
                                            c.isPlaying &&
                                                c.currentBeatInBar == b
                                            ? (b == 1
                                                  ? const Color(0xFF38BDF8)
                                                  : const Color(0xFF22D3EE))
                                            : const Color(0xFF27272A),
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
                              .copyWith(color: const Color(0xFFFFFFFF)),
                        ),
                      ],
                    );

                    final headerControls = Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TonalChip(
                          label: '注音',
                          color: c.displayLayers.showRuby
                              ? scheme.primary
                              : const Color(0xFF18181B),
                          foregroundColor: c.displayLayers.showRuby
                              ? scheme.onPrimary
                              : const Color(0xFFA1A1AA),
                          onPressed: () => c.updateDisplayLayers(
                            showRuby: !c.displayLayers.showRuby,
                          ),
                        ),
                        TonalChip(
                          label: '罗马音',
                          color: c.displayLayers.showRomaji
                              ? scheme.primary
                              : const Color(0xFF18181B),
                          foregroundColor: c.displayLayers.showRomaji
                              ? scheme.onPrimary
                              : const Color(0xFFA1A1AA),
                          onPressed: () => c.updateDisplayLayers(
                            showRomaji: !c.displayLayers.showRomaji,
                          ),
                        ),
                        TonalChip(
                          label: '翻译',
                          color: c.displayLayers.showTranslation
                              ? scheme.primary
                              : const Color(0xFF18181B),
                          foregroundColor: c.displayLayers.showTranslation
                              ? scheme.onPrimary
                              : const Color(0xFFA1A1AA),
                          onPressed: () => c.updateDisplayLayers(
                            showTranslation: !c.displayLayers.showTranslation,
                          ),
                        ),
                        GestureDetector(
                          onTap: () => c.setPracticeMode(false),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: const ShapeDecoration(
                              color: Color(0xFF27272A),
                              shape: AppShape.full,
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GlyphIcon(
                                  Glyphs.close,
                                  size: 16,
                                  color: Color(0xFFFFFFFF),
                                ),
                                SizedBox(width: 6),
                                Text(
                                  '退出演练',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFFFFFFFF),
                                  ),
                                ),
                              ],
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
                    ? const Center(
                        child: Text(
                          '当前曲目暂无歌词行',
                          style: TextStyle(
                            fontSize: 18,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      )
                    : ListView.separated(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 28,
                        ),
                        itemCount: lines.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 16),
                        itemBuilder: (context, index) {
                          final line = lines[index];
                          final lineAlert = c.getAlertForLine(line.id);
                          return KeyedSubtree(
                            key: _lineKeys.putIfAbsent(line.id, GlobalKey.new),
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
              ),

              // Bottom Stage Transport Deck
              Container(
                padding: EdgeInsets.fromLTRB(20, 12, 20, pad.bottom + 14),
                decoration: const BoxDecoration(
                  color: Color(0xFF09090B),
                  border: Border(
                    top: BorderSide(color: Color(0xFF27272A)),
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
                                  style: const TextStyle(
                                    fontFamily: 'GoogleSans',
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFFD4D4D8),
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
                                  child: TonalChip(
                                    label: '-2s',
                                    color: const Color(0xFF27272A),
                                    foregroundColor: const Color(0xFFFFFFFF),
                                    onPressed: () =>
                                        c.seek(c.currentTimeMs - 2000),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                ScallopedOrbButton(
                                  running: c.isPlaying,
                                  size: 54,
                                  onToggle: c.togglePlay,
                                ),
                                const SizedBox(width: 12),
                                Semantics(
                                  label: '快进 2 秒',
                                  button: true,
                                  child: TonalChip(
                                    label: '+2s',
                                    color: const Color(0xFF27272A),
                                    foregroundColor: const Color(0xFFFFFFFF),
                                    onPressed: () =>
                                        c.seek(c.currentTimeMs + 2000),
                                  ),
                                ),
                              ],
                            );
                            final speedChips = Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final rate in const [0.75, 1.0, 1.25])
                                  TonalChip(
                                    label: '${rate}x',
                                    color: (c.playbackRate - rate).abs() < 0.01
                                        ? scheme.primary
                                        : const Color(0xFF18181B),
                                    foregroundColor:
                                        (c.playbackRate - rate).abs() < 0.01
                                        ? scheme.onPrimary
                                        : const Color(0xFFD4D4D8),
                                    onPressed: () => c.setPlaybackRate(rate),
                                  ),
                              ],
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

  @override
  void initState() {
    super.initState();
    _isPlaying = widget.controller.playingLineId == widget.line.id;
    widget.controller.playingLineIdListenable.addListener(_onPlaybackChanged);
  }

  @override
  void didUpdateWidget(covariant _ReactivePracticeLineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.playingLineIdListenable
          .removeListener(_onPlaybackChanged);
      widget.controller.playingLineIdListenable.addListener(_onPlaybackChanged);
    }
    _isPlaying = widget.controller.playingLineId == widget.line.id;
  }

  void _onPlaybackChanged() {
    final nextPlaying = widget.controller.playingLineId == widget.line.id;
    if (nextPlaying != _isPlaying) {
      setState(() {
        _isPlaying = nextPlaying;
      });
    }
  }

  @override
  void dispose() {
    widget.controller.playingLineIdListenable
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
    required this.onTap,
  });

  final LyricLine line;
  final GtAlert? lineAlert;
  final Map<String, CallPreset> presetMap;
  final DisplayLayers displayLayers;
  final double textScale;
  final Color primaryColor;
  final bool isPlaying;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final gtNote = (lineAlert?.note ?? '').trim();
    final isSec = line.kind.isSection;
    final shout = isSec ? line.customShout.trim() : getUnalignedCustomShout(line);

    late final Color borderColor;
    late final Color bgColor;
    late final double opacity;
    List<BoxShadow> shadows = const [];

    if (isPlaying && lineAlert != null) {
      borderColor = const Color(0xFFF59E0B);
      bgColor = const Color(0xFF1F1608);
      opacity = 1.0;
      shadows = const [
        BoxShadow(
          color: Color(0x40F59E0B),
          blurRadius: 24,
        ),
      ];
    } else if (isPlaying) {
      borderColor = primaryColor;
      bgColor = const Color(0xFF12151C);
      opacity = 1.0;
      shadows = [
        BoxShadow(
          color: primaryColor.withValues(alpha: 0.24),
          blurRadius: 26,
        ),
      ];
    } else if (lineAlert != null) {
      borderColor = const Color(0xFFB45309);
      bgColor = const Color(0xFF1A1307);
      opacity = 0.88;
    } else {
      borderColor = const Color(0xFF27272A);
      bgColor = const Color(0xFF09090B);
      opacity = 0.62;
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: opacity,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: borderColor,
              width: isPlaying ? 1.8 : 1.0,
            ),
            boxShadow: shadows,
          ),
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
                    style: const TextStyle(
                      fontFamily: 'GoogleSans',
                      fontFeatures: [FontFeature.tabularFigures()],
                      fontSize: 12,
                      color: Color(0xFFA1A1AA),
                    ),
                  ),
                  if (line.kind.isSection)
                    TonalChip(
                      label:
                          '${line.kind.zhLabel} · ${formatGapSec(math.max(1000, line.endTimeMs - line.startTimeMs))}',
                      color: const Color(0xFF6366F1),
                      foregroundColor: const Color(0xFFFFFFFF),
                    ),
                  if (lineAlert != null)
                    const TonalChip(
                      label: 'GT 警报',
                      color: Color(0xFFF59E0B),
                      foregroundColor: Color(0xFF000000),
                    ),
                  if (lineAlert != null && gtNote.isNotEmpty)
                    Text(
                      gtNote,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFFCD34D),
                      ),
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
                      decoration: const ShapeDecoration(
                        color: Color(0xFFE11D48),
                        shape: AppShape.full,
                      ),
                      child: Text(
                        shout,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFFFFFFFF),
                        ),
                      ),
                    ),
                  if (line.tailUpdraft)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: const ShapeDecoration(
                        color: Color(0xFF0284C7),
                        shape: AppShape.full,
                      ),
                      child: const Text(
                        '尾句上升气流',
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFFFFFFFF),
                        ),
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
                pillBackground: const Color(0xFFE11D48),
                pillForeground: const Color(0xFFFFFFFF),
                pillBorderColor: const Color(0xFFFB7185),
                underlineColor: const Color(0xFFF43F5E),
                baseStyle: TextStyle(
                  fontSize: (isPlaying ? 32 : 22) * textScale,
                  fontWeight: FontWeight.w800,
                  height: 1.32,
                  color: const Color(0xFFFFFFFF),
                ),
                rtStyle: TextStyle(
                  fontSize: (isPlaying ? 15 : 11) * textScale,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF38BDF8),
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
                    color: const Color(0xFF7DD3FC),
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
                    color: const Color(0xFFD4D4D8),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
