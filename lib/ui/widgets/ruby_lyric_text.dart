import 'package:flutter/widgets.dart';

import '../../models/callbook_models.dart';
import '../../utils/aligned_calls.dart';
import '../../utils/lrc_ruby_parser.dart';

/// Native Japanese Furigana (`<ruby>Kanji<rt>kana</rt></ruby>`) and word-aligned
/// Call cue renderer for Flutter Desktop & Android.
class RubyLyricText extends StatelessWidget {
  const RubyLyricText({
    super.key,
    required this.original,
    this.rubyHtml,
    required this.showRuby,
    required this.baseStyle,
    this.rtStyle,
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
  final TextStyle baseStyle;
  final TextStyle? rtStyle;
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

    final runs = (alignedCalls.isNotEmpty || customShout.trim().isNotEmpty)
        ? buildAlignedLyricRuns(
            LyricLine(
              id: '',
              startTimeMs: 0,
              endTimeMs: 0,
              customShout: customShout,
              alignedCalls: alignedCalls,
              text: LyricText(original: original, ruby: rubyHtml),
            ),
            showRuby: showRuby,
          )
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
                      DecoratedBox(
                        decoration: ShapeDecoration(
                          color: run.call!.cue.color ?? defaultBg,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                            side: BorderSide(
                              color: run.call!.cue.color ?? defaultBorder,
                              width: 0.9,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: resolvedPillPadding,
                          child: Text(
                            run.call!.text,
                            softWrap: false,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style: TextStyle(
                              fontFamily: baseStyle.fontFamily,
                              fontSize: resolvedPillFontSize,
                              fontWeight: FontWeight.w800,
                              height: 1.1,
                              color: run.call!.cue.color != null
                                  ? _contrastOn(run.call!.cue.color!)
                                  : defaultFg,
                            ),
                          ),
                        ),
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
