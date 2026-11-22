import '../models/callbook_models.dart';
import 'section_detector.dart';

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

/// Recognizes explicit standalone section markers in imported LRC lines
/// (such as `【间奏】`, `[前奏]`, `（尾奏）`, `Interlude`).
LyricLineKind? detectExplicitSectionKind(String rawText) {
  var s = rawText.trim();
  if (s.isEmpty) return null;
  if ((s.startsWith('【') && s.endsWith('】')) ||
      (s.startsWith('[') && s.endsWith(']')) ||
      (s.startsWith('(') && s.endsWith(')')) ||
      (s.startsWith('（') && s.endsWith('）'))) {
    s = s.substring(1, s.length - 1).trim();
  }
  final lower = s.toLowerCase();
  if (s == '前奏' || lower == 'intro') return LyricLineKind.intro;
  if (s == '间奏' || lower == 'interlude') return LyricLineKind.interlude;
  if (s == '尾奏' || lower == 'outro') return LyricLineKind.outro;
  return null;
}

/// Pure-Dart LRC parser supporting optional translation (`tlyric`) and
/// romaji (`romalrc`) tracks aligned by nearest timestamp.
List<LyricLine> parseLrcOffline(
  String lrcText, {
  String translationLrc = '',
  String romaLrc = '',
  int defaultDurationMs = 3000,
}) {
  final transMap = _parseAuxiliaryLrcMap(translationLrc);
  final romaMap = _parseAuxiliaryLrcMap(romaLrc);

  final entries = <({int ms, String text})>[];
  final rawLines = lrcText.split(RegExp(r'\r\n|\r|\n'));
  var fallbackCursor = 0;
  for (final rawLine in rawLines) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty) continue;
    // Skip LRC metadata tags like [ti:...], [ar:...] and Netease JSON credit lines
    if (RegExp(r'^\[[a-zA-Z]+:.*\]$').hasMatch(trimmed)) continue;
    if (trimmed.startsWith('{"t":') && trimmed.contains('"c":')) continue;

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

    var originalText = current.text;
    var matchedTranslation = _findNearestTimestampText(transMap, current.ms);
    final matchedRomaji = _findNearestTimestampText(romaMap, current.ms);
    if (matchedTranslation == null) {
      for (final sep in const [' // ', ' || ']) {
        final sepIdx = originalText.indexOf(sep);
        if (sepIdx > 0) {
          final left = originalText.substring(0, sepIdx).trim();
          final right = originalText.substring(sepIdx + sep.length).trim();
          if (left.isNotEmpty && right.isNotEmpty) {
            originalText = left;
            matchedTranslation = right;
            break;
          }
        }
      }
    }

    final sectionKind = detectExplicitSectionKind(originalText);
    if (sectionKind != null) {
      result.add(
        LyricLine(
          id: 'lrc-sec-$i-${current.ms}',
          startTimeMs: current.ms,
          endTimeMs: endMs,
          kind: sectionKind,
          autoGenerated: false,
          text: LyricText(
            original: sectionKind.bracketTitle,
            translation: buildSectionSummary(sectionKind, endMs - current.ms),
          ),
        ),
      );
      continue;
    }

    result.add(
      LyricLine(
        id: 'lrc-$i-${current.ms}',
        startTimeMs: current.ms,
        endTimeMs: endMs,
        text: LyricText(
          original: originalText,
          romaji: matchedRomaji,
          translation: matchedTranslation,
        ),
      ),
    );
  }
  return result;
}

Map<int, String> _parseAuxiliaryLrcMap(String rawLrc) {
  final map = <int, String>{};
  if (rawLrc.trim().isEmpty) return map;
  for (final rawLine in rawLrc.split(RegExp(r'\r\n|\r|\n'))) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty) continue;
    if (RegExp(r'^\[[a-zA-Z]+:.*\]$').hasMatch(trimmed)) continue;
    if (trimmed.startsWith('{"t":') && trimmed.contains('"c":')) continue;
    final matches = _lrcTimestampPattern.allMatches(trimmed).toList();
    if (matches.isEmpty) continue;
    final cleanText = trimmed.replaceAll(_lrcTimestampPattern, '').trim();
    if (cleanText.isEmpty) continue;
    for (final m in matches) {
      map[_matchToMs(m)] = cleanText;
    }
  }
  return map;
}

String? _findNearestTimestampText(Map<int, String> map, int targetMs) {
  if (map.isEmpty) return null;
  String? best;
  var bestDiff = 600;
  for (final entry in map.entries) {
    final diff = (entry.key - targetMs).abs();
    if (diff <= bestDiff) {
      bestDiff = diff;
      best = entry.value;
    }
  }
  return best;
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
