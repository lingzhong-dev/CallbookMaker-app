import 'package:flutter/widgets.dart';

import '../../utils/lrc_ruby_parser.dart';

/// Native Japanese Furigana (`<ruby>Kanji<rt>kana</rt></ruby>`) renderer for Flutter Desktop & Android.
class RubyLyricText extends StatelessWidget {
  const RubyLyricText({
    super.key,
    required this.original,
    this.rubyHtml,
    required this.showRuby,
    required this.baseStyle,
    this.rtStyle,
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
  final TextAlign textAlign;
  final bool? softWrap;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
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
    final effectiveRtStyle =
        rtStyle ??
        baseStyle.copyWith(
          fontSize: (baseStyle.fontSize ?? 16) * 0.56,
          height: 1.05,
          fontWeight: FontWeight.w500,
          color: baseStyle.color?.withValues(alpha: 0.72),
        );

    return Text.rich(
      TextSpan(
        children: [
          for (final seg in segments)
            if (seg.rt == null)
              TextSpan(text: seg.base, style: baseStyle)
            else
              WidgetSpan(
                alignment: PlaceholderAlignment.bottom,
                child: Column(
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
