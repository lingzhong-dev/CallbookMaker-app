import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../models/callbook_models.dart';
import '../state/callbook_controller.dart';
import '../utils/lrc_ruby_parser.dart';
import '../utils/section_detector.dart';
import 'widgets/call_badge_pill.dart';
import 'widgets/callbook_glyphs.dart';
import 'widgets/ruby_lyric_text.dart';
import 'widgets/scalloped_orb_button.dart';

class PracticeOverlay extends StatelessWidget {
  const PracticeOverlay({super.key, required this.controller});

  final CallbookController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final lines = c.sortedLines;
    final presetMap = {for (final p in c.allPresets) p.id: p};

    // Pure OLED black stage without any screen-edge flashing borders.
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: DefaultTextStyle.merge(
          style: TextStyle(
            fontFamily: c.useGoogleSans ? 'GoogleSans' : null,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              MediaQuery.paddingOf(context).top + 16,
              20,
              MediaQuery.paddingOf(context).bottom + 18,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top Stage Bar
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.project.meta.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyle.headline
                                .of(context, emphasized: true)
                                .copyWith(color: const Color(0xFFFFFFFF)),
                          ),
                          const SizedBox(height: 2),
                          ListenableBuilder(
                            listenable: c.playbackListenable,
                            builder: (context, _) => Text(
                              '${c.project.meta.bpm} BPM (${c.project.meta.timeSignature}) · BAR ${c.currentBar}.${c.currentBeatInBar}',
                              style: AppTextStyle.caption1.of(context).copyWith(
                                fontFamily: 'GoogleSans',
                                fontFeatures: const [FontFeature.tabularFigures()],
                                color: const Color(0xFF94A3B8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ListenableBuilder(
                      listenable: c.playbackListenable,
                      builder: (context, _) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var b = 1; b <= c.project.meta.beatsPerBar; b++) ...[
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 90),
                              width: b == 1 ? 12 : 9,
                              height: b == 1 ? 12 : 9,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: c.isPlaying && c.currentBeatInBar == b
                                    ? (b == 1
                                          ? const Color(0xFF38BDF8)
                                          : const Color(0xFF22D3EE))
                                    : const Color(0xFF1E293B),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () => c.setPracticeMode(false),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: const ShapeDecoration(
                          color: Color(0xFF1E293B),
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
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFFFFFFF),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                ListenableBuilder(
                  listenable: c.playbackListenable,
                  builder: (context, _) {
                    final activeAlert = c.activeGtAlertStatus;
                    if (activeAlert == null) return const SizedBox.shrink();
                    final activeAlertCue = (activeAlert.alert.callTimingCue ?? '').trim();
                    return Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: ShapeDecoration(
                          color: activeAlert.isTriggered
                              ? const Color(0xFF991B1B)
                              : const Color(0xFF78350F),
                          shape: AppShape.xl,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 10,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                TonalChip(
                                  label: activeAlert.isTriggered
                                      ? 'GT TRIGGER!'
                                      : '倒数 ${activeAlert.remainingBeats} 拍',
                                  color: activeAlert.isTriggered
                                      ? const Color(0xFFEF4444)
                                      : const Color(0xFFF59E0B),
                                  foregroundColor: const Color(0xFF000000),
                                ),
                                if (activeAlertCue.isNotEmpty)
                                  TonalChip(
                                    label: activeAlertCue,
                                    color: const Color(0xFFFEF3C7),
                                    foregroundColor: const Color(0xFF78350F),
                                  ),
                                Text(
                                  activeAlert.alert.note,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFFFFFFFF),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(value: activeAlert.progress),
                          ],
                        ),
                      ),
                    );
                  },
                ),

                // Center Teleprompter Focus Area: only rebuilds on line/alert transition
                Expanded(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([
                      c.playingLineIdListenable,
                      c.activeGtTargetLineIdListenable,
                    ]),
                    builder: (context, _) {
                      final activeId = c.playingLineId ?? c.activeLineId;
                      var activeIdx = lines.indexWhere((l) => l.id == activeId);
                      if (activeIdx < 0 && lines.isNotEmpty) activeIdx = 0;

                      final currentLine = activeIdx >= 0 ? lines[activeIdx] : null;
                      final prevLine = activeIdx > 0 ? lines[activeIdx - 1] : null;
                      final nextLine = activeIdx >= 0 && activeIdx + 1 < lines.length
                          ? lines[activeIdx + 1]
                          : null;

                      final activeGtTargetId = c.activeGtTargetLineIdListenable.value;
                      final currentGtAlert = currentLine != null
                          ? c.getAlertForLine(currentLine.id)
                          : null;
                      final nextGtAlert = nextLine != null
                          ? c.getAlertForLine(nextLine.id)
                          : null;
                      final currentGtCue =
                          (currentGtAlert?.callTimingCue ?? '').trim();
                      final nextGtCue = (nextGtAlert?.callTimingCue ?? '').trim();
                      final isCurrentGtCountdown = currentLine != null &&
                          activeGtTargetId == currentLine.id;
                      final isNextGtCountdown = nextLine != null &&
                          activeGtTargetId == nextLine.id;

                      return Center(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (prevLine != null) ...[
                                Text(
                                  prevLine.text.original,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    color: Color(0xFF475569),
                                  ),
                                ),
                                const SizedBox(height: 22),
                              ],

                              if (currentLine != null)
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  padding: currentGtAlert != null
                                      ? const EdgeInsets.symmetric(
                                          horizontal: 20,
                                          vertical: 16,
                                        )
                                      : EdgeInsets.zero,
                                  decoration: currentGtAlert != null
                                      ? BoxDecoration(
                                          color: isCurrentGtCountdown
                                              ? const Color(0xFF78350F)
                                                  .withValues(alpha: 0.65)
                                              : const Color(0xFF451A03)
                                                  .withValues(alpha: 0.55),
                                          borderRadius: BorderRadius.circular(22),
                                          border: Border.all(
                                            color: const Color(0xFFF59E0B),
                                            width: isCurrentGtCountdown ? 2.2 : 1.5,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: const Color(0xFFF59E0B)
                                                  .withValues(
                                                alpha: isCurrentGtCountdown
                                                    ? 0.35
                                                    : 0.18,
                                              ),
                                              blurRadius:
                                                  isCurrentGtCountdown ? 24 : 14,
                                            ),
                                          ],
                                        )
                                      : null,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (currentLine.kind.isSection ||
                                          currentGtAlert != null ||
                                          currentLine.calls.isNotEmpty ||
                                          currentLine.customShout
                                              .trim()
                                              .isNotEmpty ||
                                          currentLine.tailUpdraft) ...[
                                        Wrap(
                                          alignment: WrapAlignment.center,
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            if (currentLine.kind.isSection)
                                              TonalChip(
                                                label:
                                                    '${currentLine.kind.zhLabel} · ${formatGapSec(math.max(0, currentLine.endTimeMs - currentLine.startTimeMs))}',
                                                color: const Color(0xFF0EA5E9),
                                                foregroundColor:
                                                    const Color(0xFFFFFFFF),
                                              ),
                                            if (currentGtAlert != null)
                                              const TonalChip(
                                                label: 'GT 警报',
                                                color: Color(0xFFF59E0B),
                                                foregroundColor: Color(0xFF000000),
                                              ),
                                            if (currentGtAlert != null &&
                                                currentGtCue.isNotEmpty)
                                              TonalChip(
                                                label: currentGtCue,
                                                color: const Color(0xFFFEF3C7),
                                                foregroundColor:
                                                    const Color(0xFF78350F),
                                              ),
                                            for (final tag in currentLine.calls)
                                              if (presetMap[tag.presetId]
                                                  case final CallPreset p?)
                                                CallBadgePill(
                                                  preset: p,
                                                  suffix: tag.suffix,
                                                ),
                                            if (currentLine.customShout
                                                .trim()
                                                .isNotEmpty)
                                              Container(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 5,
                                                ),
                                                decoration: const ShapeDecoration(
                                                  color: Color(0xFF4F46E5),
                                                  shape: AppShape.full,
                                                ),
                                                child: Text(
                                                  currentLine.customShout.trim(),
                                                  softWrap: false,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.visible,
                                                  style: AppTextStyle.caption1
                                                      .of(context, emphasized: true)
                                                      .copyWith(
                                                        color:
                                                            const Color(0xFFFFFFFF),
                                                      ),
                                                ),
                                              ),
                                            if (currentLine.tailUpdraft)
                                              Container(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 5,
                                                ),
                                                decoration: const ShapeDecoration(
                                                  color: Color(0xFF0284C7),
                                                  shape: AppShape.full,
                                                ),
                                                child: Text(
                                                  '尾句上升气流',
                                                  softWrap: false,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.visible,
                                                  style: AppTextStyle.caption1
                                                      .of(context, emphasized: true)
                                                      .copyWith(
                                                        color:
                                                            const Color(0xFFFFFFFF),
                                                      ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 16),
                                      ],
                                      RubyLyricText(
                                        original: currentLine.text.original,
                                        rubyHtml: currentLine.text.ruby,
                                        showRuby: c.displayLayers.showRuby,
                                        textAlign: TextAlign.center,
                                        baseStyle: TextStyle(
                                          fontSize: 32 * c.textScale,
                                          fontWeight: FontWeight.w800,
                                          height: 1.32,
                                          color: const Color(0xFFFFFFFF),
                                        ),
                                        rtStyle: TextStyle(
                                          fontSize: 15 * c.textScale,
                                          fontWeight: FontWeight.w600,
                                          color: const Color(0xFF38BDF8),
                                        ),
                                      ),
                                      if (c.displayLayers.showRomaji &&
                                          currentLine.text.romaji != null &&
                                          currentLine.text.romaji!.isNotEmpty) ...[
                                        const SizedBox(height: 10),
                                        Text(
                                          currentLine.text.romaji!,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            fontFamily: 'GoogleSans',
                                            fontSize: 16,
                                            color: Color(0xFF7DD3FC),
                                          ),
                                        ),
                                      ],
                                      if (c.displayLayers.showTranslation &&
                                          currentLine.text.translation != null &&
                                          currentLine.text.translation!
                                              .isNotEmpty) ...[
                                        const SizedBox(height: 10),
                                        Text(
                                          currentLine.text.translation!,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            fontSize: 19,
                                            fontWeight: FontWeight.w500,
                                            color: Color(0xFFCBD5E1),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                )
                              else
                                const Text(
                                  '当前曲目暂无歌词行',
                                  style: TextStyle(
                                    fontSize: 20,
                                    color: Color(0xFF64748B),
                                  ),
                                ),

                              if (nextLine != null) ...[
                                const SizedBox(height: 30),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: nextGtAlert != null
                                        ? (isNextGtCountdown
                                              ? const Color(0xFF451A03)
                                              : const Color(0xFF291709))
                                        : const Color(0xFF0F172A),
                                    borderRadius: BorderRadius.circular(14),
                                    border: nextGtAlert != null
                                        ? Border.all(
                                            color: const Color(0xFFF59E0B),
                                            width: 1.4,
                                          )
                                        : null,
                                  ),
                                  child: Column(
                                    children: [
                                      Wrap(
                                        alignment: WrapAlignment.center,
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: [
                                          const Text(
                                            'NEXT',
                                            style: TextStyle(
                                              fontFamily: 'GoogleSans',
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF64748B),
                                            ),
                                          ),
                                          if (nextGtAlert != null)
                                            const TonalChip(
                                              label: 'GT',
                                              color: Color(0xFFF59E0B),
                                              foregroundColor: Color(0xFF000000),
                                            ),
                                          if (nextGtAlert != null &&
                                              nextGtCue.isNotEmpty)
                                            TonalChip(
                                              label: nextGtCue,
                                              color: const Color(0xFFFEF3C7),
                                              foregroundColor:
                                                  const Color(0xFF78350F),
                                            ),
                                          for (final tag in nextLine.calls)
                                            if (presetMap[tag.presetId]
                                                case final p?)
                                              CallBadgePill(
                                                preset: p,
                                                suffix: tag.suffix,
                                                compact: true,
                                              ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        nextLine.text.original,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 18,
                                          color: Color(0xFF94A3B8),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),

                // Bottom Stage Transport Deck
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: const ShapeDecoration(
                    color: Color(0xFF0F172A),
                    shape: AppShape.xl,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          ScallopedOrbButton(
                            running: c.isPlaying,
                            size: 56,
                            onToggle: c.togglePlay,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ListenableBuilder(
                              listenable: c.playbackListenable,
                              builder: (context, _) {
                                final safeDuration =
                                    math.max(1000, c.durationMs).toDouble();
                                final clampedPos = c.currentTimeMs
                                    .toDouble()
                                    .clamp(0.0, safeDuration);
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          '${formatMsToClock(c.currentTimeMs)} / ${formatMsToClock(safeDuration.round())}',
                                          style: const TextStyle(
                                            fontFamily: 'GoogleSans',
                                            fontFeatures: [
                                              FontFeature.tabularFigures(),
                                            ],
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFFFFFFFF),
                                          ),
                                        ),
                                        const Spacer(),
                                        GestureDetector(
                                          onTap: () => c.setPracticeMode(false),
                                          child: const GlyphIcon(
                                            CallbookGlyphs.musicNote,
                                            size: 16,
                                            color: Color(0xFF94A3B8),
                                          ),
                                        ),
                                      ],
                                    ),
                                    Slider(
                                      value: clampedPos,
                                      min: 0,
                                      max: safeDuration,
                                      onChanged: (v) => c.seek(v.round()),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final rate in const [0.75, 1.0, 1.25])
                          TonalChip(
                            label: '${rate}x',
                            color: c.playbackRate == rate
                                ? const Color(0xFF0284C7)
                                : const Color(0xFF1E293B),
                            foregroundColor: const Color(0xFFFFFFFF),
                            onPressed: () => c.setPlaybackRate(rate),
                          ),
                        TonalChip(
                          label: 'Ruby',
                          color: c.displayLayers.showRuby
                              ? const Color(0xFF0284C7)
                              : const Color(0xFF1E293B),
                          foregroundColor: const Color(0xFFFFFFFF),
                          onPressed: () => c.updateDisplayLayers(
                            showRuby: !c.displayLayers.showRuby,
                          ),
                        ),
                        TonalChip(
                          label: 'Romaji',
                          color: c.displayLayers.showRomaji
                              ? const Color(0xFF0284C7)
                              : const Color(0xFF1E293B),
                          foregroundColor: const Color(0xFFFFFFFF),
                          onPressed: () => c.updateDisplayLayers(
                            showRomaji: !c.displayLayers.showRomaji,
                          ),
                        ),
                        TonalChip(
                          label: '译文',
                          color: c.displayLayers.showTranslation
                              ? const Color(0xFF0284C7)
                              : const Color(0xFF1E293B),
                          foregroundColor: const Color(0xFFFFFFFF),
                          onPressed: () => c.updateDisplayLayers(
                            showTranslation: !c.displayLayers.showTranslation,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
