import '../models/callbook_models.dart';

class RubySegment {
  const RubySegment({required this.base, this.rt});

  final String base;
  final String? rt;
}

final _rubyTagPattern = RegExp(
  r'<ruby>(.*?)<rt>(.*?)</rt></ruby>',
  caseSensitive: false,
  dotAll: true,
);

final _stripTagsPattern = RegExp(r'<[^>]+>');

final _lrcTimestampPattern = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');

/// Parses HTML `<ruby>Kanji<rt>kana</rt></ruby>` segments for native Flutter typography.
List<RubySegment> parseRubySegments(String? rubyHtml, String fallbackOriginal) {
  final source = (rubyHtml != null && rubyHtml.trim().isNotEmpty)
      ? rubyHtml
      : fallbackOriginal;
  if (!source.contains('<ruby')) {
    return [RubySegment(base: source.replaceAll(_stripTagsPattern, ''))];
  }
  final segments = <RubySegment>[];
  var cursor = 0;
  for (final match in _rubyTagPattern.allMatches(source)) {
    if (match.start > cursor) {
      final plain = source
          .substring(cursor, match.start)
          .replaceAll(_stripTagsPattern, '');
      if (plain.isNotEmpty) {
        segments.add(RubySegment(base: plain));
      }
    }
    final base = (match.group(1) ?? '').replaceAll(_stripTagsPattern, '');
    final rt = (match.group(2) ?? '').replaceAll(_stripTagsPattern, '');
    if (base.isNotEmpty) {
      segments.add(RubySegment(base: base, rt: rt.isEmpty ? null : rt));
    }
    cursor = match.end;
  }
  if (cursor < source.length) {
    final tail = source.substring(cursor).replaceAll(_stripTagsPattern, '');
    if (tail.isNotEmpty) {
      segments.add(RubySegment(base: tail));
    }
  }
  if (segments.isEmpty) {
    return [RubySegment(base: fallbackOriginal)];
  }
  return segments;
}

/// Pure-Dart LRC fallback parser when offline (used alongside FastAPI `/api/lyrics/parse`).
List<LyricLine> parseLrcOffline(
  String lrcText, {
  String translationLrc = '',
  int defaultDurationMs = 3000,
}) {
  final transMap = <int, String>{};
  for (final rawLine in translationLrc.split(RegExp(r'\r?\n'))) {
    final matches = _lrcTimestampPattern.allMatches(rawLine).toList();
    if (matches.isEmpty) continue;
    final cleanText = rawLine.replaceAll(_lrcTimestampPattern, '').trim();
    if (cleanText.isEmpty) continue;
    for (final m in matches) {
      final ms = _matchToMs(m);
      transMap[ms] = cleanText;
    }
  }

  final entries = <({int ms, String text})>[];
  final rawLines = lrcText.split(RegExp(r'\r?\n'));
  var fallbackCursor = 0;
  for (final rawLine in rawLines) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty) continue;
    // Skip LRC metadata tags like [ti:...], [ar:...]
    if (RegExp(r'^\[[a-zA-Z]+:.*\]$').hasMatch(trimmed)) continue;

    final matches = _lrcTimestampPattern.allMatches(trimmed).toList();
    final content = trimmed.replaceAll(_lrcTimestampPattern, '').trim();
    if (matches.isEmpty) {
      if (content.isNotEmpty) {
        entries.add((ms: fallbackCursor, text: content));
        fallbackCursor += defaultDurationMs;
      }
      continue;
    }
    if (content.isEmpty) continue;
    for (final m in matches) {
      entries.add((ms: _matchToMs(m), text: content));
    }
  }

  entries.sort((a, b) => a.ms.compareTo(b.ms));
  final result = <LyricLine>[];
  for (var i = 0; i < entries.length; i++) {
    final current = entries[i];
    final nextMs = i + 1 < entries.length
        ? entries[i + 1].ms
        : current.ms + defaultDurationMs;
    final endMs = nextMs > current.ms ? nextMs : current.ms + defaultDurationMs;

    String? matchedTranslation;
    var bestDiff = 600;
    for (final entry in transMap.entries) {
      final diff = (entry.key - current.ms).abs();
      if (diff <= bestDiff) {
        bestDiff = diff;
        matchedTranslation = entry.value;
      }
    }

    result.add(
      LyricLine(
        id: 'lrc-$i-${current.ms}',
        startTimeMs: current.ms,
        endTimeMs: endMs,
        text: LyricText(
          original: current.text,
          translation: matchedTranslation,
        ),
      ),
    );
  }
  return result;
}

int _matchToMs(RegExpMatch match) {
  final min = int.tryParse(match.group(1) ?? '0') ?? 0;
  final sec = int.tryParse(match.group(2) ?? '0') ?? 0;
  final fracRaw = match.group(3) ?? '0';
  final ms = switch (fracRaw.length) {
    0 => 0,
    1 => (int.tryParse(fracRaw) ?? 0) * 100,
    2 => (int.tryParse(fracRaw) ?? 0) * 10,
    _ => int.tryParse(fracRaw.substring(0, 3)) ?? 0,
  };
  return (min * 60 + sec) * 1000 + ms;
}

String formatMsToClock(int ms) {
  final clamped = ms < 0 ? 0 : ms;
  final totalSeconds = clamped ~/ 1000;
  final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  final centis = ((clamped % 1000) ~/ 10).toString().padLeft(2, '0');
  return '$minutes:$seconds.$centis';
}
