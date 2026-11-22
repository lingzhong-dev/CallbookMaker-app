import 'package:flutter/widgets.dart';

import '../../models/callbook_models.dart';
import '../../services/japanese_ruby_annotator.dart';
import '../../utils/aligned_calls.dart';
import '../../utils/lrc_ruby_parser.dart';

/// Native Japanese Furigana (`<ruby>Kanji<rt>kana</rt></ruby>`) and word-aligned
/// Call cue + romaji renderer for Flutter Desktop & Android.
class RubyLyricText extends StatelessWidget {
  const RubyLyricText({
    super.key,
    required this.original,
    this.rubyHtml,
    required this.showRuby,
    this.lineRomaji,
    this.showRomaji = false,
    required this.baseStyle,
    this.rtStyle,
    this.romajiStyle,
    this.alignedRomajiHighlightColor,
    this.alignedCalls = const [],
    this.customShout = '',
    this.pillBackground,
    this.pillForeground,
    this.pillBorderColor,
    this.underlineColor,
    this.pillFontSize,
    this.pillPadding,
    this.textAlign = TextAlign.start,
    this.softWrap,
    this.maxLines,
    this.overflow,
  });

  final String original;
  final String? rubyHtml;
  final bool showRuby;
  final String? lineRomaji;
  final bool showRomaji;
  final TextStyle baseStyle;
  final TextStyle? rtStyle;
  final TextStyle? romajiStyle;
  final Color? alignedRomajiHighlightColor;
  final List<AlignedCallCue> alignedCalls;
  final String customShout;
  final Color? pillBackground;
  final Color? pillForeground;
  final Color? pillBorderColor;
  final Color? underlineColor;
  final double? pillFontSize;
  final EdgeInsets? pillPadding;
  final TextAlign textAlign;
  final bool? softWrap;
  final int? maxLines;
  final TextOverflow? overflow;

  /// Returns `true` when [RubyLyricText] renders aligned word-by-word romaji
  /// directly below the lyric segments, allowing callers to omit a duplicate
  /// unaligned romaji row underneath.
  static bool willRenderInlineRomaji({
    required String original,
    String? rubyHtml,
    String? lineRomaji,
    required bool showRomaji,
    required List<AlignedCallCue> alignedCalls,
    required String customShout,
  }) {
    if (!showRomaji || original.isEmpty) return false;
    if (alignedCalls.isEmpty && customShout.trim().isEmpty) return false;
    final line = LyricLine(
      id: '',
      startTimeMs: 0,
      endTimeMs: 0,
      customShout: customShout,
      alignedCalls: alignedCalls,
      text: LyricText(original: original, ruby: rubyHtml, romaji: lineRomaji),
    );
    final resolved = resolveLineAlignedCalls(line).aligned;
    if (resolved.isEmpty) return false;
    final atoms = JapaneseRubyAnnotator.deriveRomajiAtoms(
      line,
      tokenizer: JapaneseRubyAnnotator.instance.loadedTokenizer,
    );
    return atoms.any((a) => a.romaji.trim().isNotEmpty);
  }

  static Color _contrastOn(Color bg) =>
      bg.computeLuminance() > 0.56
          ? const Color(0xFF0F172A)
          : const Color(0xFFFFFFFF);

  Widget _buildRubySegmentWidget(
    RubySegment seg,
    TextStyle effectiveRtStyle,
  ) {
    if (seg.rt == null) {
      return Text(
        seg.base,
        style: baseStyle,
        softWrap: false,
        maxLines: 1,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          seg.rt!,
          style: effectiveRtStyle,
          softWrap: false,
          maxLines: 1,
        ),
        Text(
          seg.base,
          style: baseStyle,
          softWrap: false,
          maxLines: 1,
        ),
      ],
    );
  }

  Widget _buildCallPill({
    required ResolvedAlignedCue cue,
    required Color defaultBg,
    required Color defaultFg,
    required Color defaultBorder,
    required double resolvedPillFontSize,
    required EdgeInsets resolvedPillPadding,
  }) {
    final pillBg = cue.cue.color ?? defaultBg;
    final pillFg = cue.cue.color != null ? _contrastOn(cue.cue.color!) : defaultFg;
    final cueRomaji = showRomaji ? (cue.cue.romaji ?? '').trim() : '';

    return DecoratedBox(
      decoration: ShapeDecoration(
        color: pillBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: BorderSide(
            color: cue.cue.color ?? defaultBorder,
            width: 0.9,
          ),
        ),
      ),
      child: Padding(
        padding: resolvedPillPadding,
        child: cueRomaji.isEmpty
            ? Text(
                cue.text,
                softWrap: false,
                maxLines: 1,
                overflow: TextOverflow.visible,
                style: TextStyle(
                  fontFamily: baseStyle.fontFamily,
                  fontSize: resolvedPillFontSize,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                  color: pillFg,
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    cue.text,
                    softWrap: false,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    style: TextStyle(
                      fontFamily: baseStyle.fontFamily,
                      fontSize: resolvedPillFontSize,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                      color: pillFg,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    cueRomaji,
                    softWrap: false,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    style: TextStyle(
                      fontFamily: romajiStyle?.fontFamily ?? 'GoogleSans',
                      fontSize: (resolvedPillFontSize - 1.5).clamp(8.5, 11.5),
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                      color: pillFg.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final effectiveRtStyle =
        rtStyle ??
        baseStyle.copyWith(
          fontSize: (baseStyle.fontSize ?? 16) * 0.56,
          height: 1.05,
          fontWeight: FontWeight.w500,
          color: baseStyle.color?.withValues(alpha: 0.72),
        );

    final effectiveRomajiStyle =
        romajiStyle ??
        TextStyle(
          fontFamily: 'GoogleSans',
          fontSize: ((baseStyle.fontSize ?? 16) * 0.68).clamp(10.5, 14.0),
          height: 1.25,
          color: baseStyle.color?.withValues(alpha: 0.72) ?? const Color(0xFF0061FF),
        );

    final modelLine = (alignedCalls.isNotEmpty || customShout.trim().isNotEmpty)
        ? LyricLine(
            id: '',
            startTimeMs: 0,
            endTimeMs: 0,
            customShout: customShout,
            alignedCalls: alignedCalls,
            text: LyricText(
              original: original,
              ruby: rubyHtml,
              romaji: lineRomaji,
            ),
          )
        : null;

    final inlineRomajiActive =
        showRomaji &&
        modelLine != null &&
        willRenderInlineRomaji(
          original: original,
          rubyHtml: rubyHtml,
          lineRomaji: lineRomaji,
          showRomaji: showRomaji,
          alignedCalls: alignedCalls,
          customShout: customShout,
        );

    final runs = modelLine != null
        ? (inlineRomajiActive
              ? buildAlignedWordRunsForRomaji(
                  modelLine,
                  showRuby: showRuby,
                )
              : buildAlignedLyricRuns(
                  modelLine,
                  showRuby: showRuby,
                ))
        : const <AlignedLyricRun>[];

    final hasAlignedCalls = runs.any((r) => r.call != null);

    if (!hasAlignedCalls) {
      if (!showRuby || rubyHtml == null || !rubyHtml!.contains('<ruby')) {
        return Text(
          original,
          style: baseStyle,
          textAlign: textAlign,
          softWrap: softWrap,
          maxLines: maxLines,
          overflow: overflow,
        );
      }

      final segments = parseRubySegments(rubyHtml, original);
      return Text.rich(
        TextSpan(
          children: [
            for (final seg in segments)
              if (seg.rt == null)
                TextSpan(text: seg.base, style: baseStyle)
              else
                WidgetSpan(
                  alignment: PlaceholderAlignment.bottom,
                  child: _buildRubySegmentWidget(seg, effectiveRtStyle),
                ),
          ],
        ),
        textAlign: textAlign,
        softWrap: softWrap,
        maxLines: maxLines,
        overflow: overflow,
      );
    }

    final resolvedPillFontSize =
        pillFontSize ?? ((baseStyle.fontSize ?? 16) * 0.64).clamp(10.0, 14.0);
    final resolvedPillPadding =
        pillPadding ?? const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5);
    final defaultBg = pillBackground ?? const Color(0xFFE0E7FF);
    final defaultFg = pillForeground ?? const Color(0xFF3730A3);
    final defaultBorder = pillBorderColor ?? const Color(0xFFC7D2FE);
    final defaultUnderline = underlineColor ?? const Color(0x886366F1);

    if (inlineRomajiActive) {
      final fixedRomajiStyle = effectiveRomajiStyle.copyWith(height: 1.22);
      final highlightAccent =
          alignedRomajiHighlightColor ?? defaultUnderline.withValues(alpha: 1.0);
      return Text.rich(
        TextSpan(
          children: [
            for (final run in runs)
              WidgetSpan(
                alignment: PlaceholderAlignment.bottom,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: run.call != null ? 1.5 : 0.0,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (run.call != null) ...[
                        _buildCallPill(
                          cue: run.call!,
                          defaultBg: defaultBg,
                          defaultFg: defaultFg,
                          defaultBorder: defaultBorder,
                          resolvedPillFontSize: resolvedPillFontSize,
                          resolvedPillPadding: resolvedPillPadding,
                        ),
                        const SizedBox(height: 2),
                      ],
                      if (run.call != null)
                        DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color:
                                    run.call!.cue.color?.withValues(alpha: 0.72) ??
                                    defaultUnderline,
                                width: 1.8,
                              ),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 1.2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                for (final seg in run.rubyParts)
                                  _buildRubySegmentWidget(seg, effectiveRtStyle),
                              ],
                            ),
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3.0),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (final seg in run.rubyParts)
                                _buildRubySegmentWidget(seg, effectiveRtStyle),
                            ],
                          ),
                        ),
                      const SizedBox(height: 2),
                      if (run.call != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: (run.call!.cue.color ?? highlightAccent)
                                .withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            (run.romaji ?? '').trim().isEmpty
                                ? ' '
                                : run.romaji!.trim(),
                            softWrap: false,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style: fixedRomajiStyle.copyWith(
                              fontWeight: FontWeight.w700,
                              color: run.call!.cue.color != null
                                  ? (run.call!.cue.color!.computeLuminance() > 0.72
                                        ? fixedRomajiStyle.color
                                        : run.call!.cue.color!)
                                  : defaultFg,
                            ),
                          ),
                        )
                      else
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal:
                                (run.romaji ?? '').trim().isEmpty ? 0.5 : 2.5,
                            vertical: 1,
                          ),
                          child: Text(
                            (run.romaji ?? '').trim().isEmpty
                                ? ' '
                                : run.romaji!.trim(),
                            softWrap: false,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style: fixedRomajiStyle,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        textAlign: textAlign,
        softWrap: softWrap,
        maxLines: maxLines,
        overflow: overflow,
      );
    }

    return Text.rich(
      TextSpan(
        children: [
          for (final run in runs)
            if (run.call == null)
              for (final seg in run.rubyParts)
                if (seg.rt == null)
                  TextSpan(text: seg.base, style: baseStyle)
                else
                  WidgetSpan(
                    alignment: PlaceholderAlignment.bottom,
                    child: _buildRubySegmentWidget(seg, effectiveRtStyle),
                  )
            else
              WidgetSpan(
                alignment: PlaceholderAlignment.bottom,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _buildCallPill(
                        cue: run.call!,
                        defaultBg: defaultBg,
                        defaultFg: defaultFg,
                        defaultBorder: defaultBorder,
                        resolvedPillFontSize: resolvedPillFontSize,
                        resolvedPillPadding: resolvedPillPadding,
                      ),
                      const SizedBox(height: 2),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color:
                                  run.call!.cue.color?.withValues(alpha: 0.72) ??
                                  defaultUnderline,
                              width: 1.8,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 1),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (final seg in run.rubyParts)
                                _buildRubySegmentWidget(seg, effectiveRtStyle),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
      textAlign: textAlign,
      softWrap: softWrap,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
