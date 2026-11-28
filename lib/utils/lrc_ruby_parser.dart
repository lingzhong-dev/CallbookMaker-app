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

class LrcExtractedMeta {
  const LrcExtractedMeta({
    this.lyricist = '',
    this.composer = '',
    this.arranger = '',
    this.mixer = '',
    this.vocalist = '',
  });

  final String lyricist;
  final String composer;
  final String arranger;
  final String mixer;
  final String vocalist;

  bool get isEmpty =>
      lyricist.isEmpty &&
      composer.isEmpty &&
      arranger.isEmpty &&
      mixer.isEmpty &&
      vocalist.isEmpty;
}

class LrcParseResult {
  const LrcParseResult({
    required this.lines,
    required this.originalLines,
    required this.filteredCreditLines,
    required this.extractedMeta,
  });

  /// Active timeline lines after optional header credit filtering.
  final List<LyricLine> lines;

  /// Complete parsed lines preserving source order before filtering.
  final List<LyricLine> originalLines;

  /// Header credit lines filtered from the active timeline (recoverable).
  final List<LyricLine> filteredCreditLines;

  /// Extracted credit metadata from matched header credit lines.
  final LrcExtractedMeta extractedMeta;
}

enum _CreditField {
  lyricist,
  composer,
  lyricistAndComposer,
  arranger,
  mixer,
  vocalist,
  other,
}

final List<({_CreditField field, RegExp pattern})> _creditLabelRules = [
  (
    field: _CreditField.lyricistAndComposer,
    pattern: RegExp(
      r'^\s*(?:词曲|詞曲|作词\s*[/／&]\s*作曲|作詞\s*[/／&]\s*作曲|词\s*[/／&]\s*曲|詞\s*[/／&]\s*曲)\s*[:：]\s*(.+?)\s*$',
      caseSensitive: false,
    ),
  ),
  (
    field: _CreditField.lyricist,
    pattern: RegExp(
      r'^\s*(?:作词|作詞|lyricist|lyrics(?:\s+by)?|words(?:\s+by)?)\s*[:：]\s*(.+?)\s*$',
      caseSensitive: false,
    ),
  ),
  (
    field: _CreditField.composer,
    pattern: RegExp(
      r'^\s*(?:作曲|composer|music(?:\s+by)?)\s*[:：]\s*(.+?)\s*$',
      caseSensitive: false,
    ),
  ),
  (
    field: _CreditField.arranger,
    pattern: RegExp(
      r'^\s*(?:编曲|編曲|arranger|arrangement|arranged(?:\s+by)?)\s*[:：]\s*(.+?)\s*$',
      caseSensitive: false,
    ),
  ),
  (
    field: _CreditField.mixer,
    pattern: RegExp(
      r'^\s*(?:混音师|混音師|混音|母带处理|母带后期|母带|母帶|mixing|mix|mastering|mixed(?:\s+by)?|mastered(?:\s+by)?)\s*[:：]\s*(.+?)\s*$',
      caseSensitive: false,
    ),
  ),
  (
    field: _CreditField.vocalist,
    pattern: RegExp(
      r'^\s*(?:演唱|原唱|vocals|vocal)\s*[:：]\s*(.+?)\s*$',
      caseSensitive: false,
    ),
  ),
  (
    field: _CreditField.other,
    pattern: RegExp(
      r'^\s*(?:制作人|製作人|producer|produced(?:\s+by)?|和声|和聲|backing\s+vocals|录音|錄音|recording|监制|監製|统筹|統籌)\s*[:：]\s*(.+?)\s*$',
      caseSensitive: false,
    ),
  ),
];

({_CreditField field, String value})? _matchHeaderCredit(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  for (final rule in _creditLabelRules) {
    final m = rule.pattern.firstMatch(trimmed);
    if (m != null) {
      final value = (m.group(1) ?? '').trim();
      if (value.isNotEmpty && RegExp(r'[^\s:：]').hasMatch(value)) {
        return (field: rule.field, value: value);
      }
      return null;
    }
  }
  return null;
}

/// Pure-Dart LRC parser returning structured lines, filtered header credit
/// candidates, and extracted metadata while preserving untimestamped plain text.
LrcParseResult parseLrcOfflineDetailed(
  String lrcText, {
  String translationLrc = '',
  String romaLrc = '',
  int defaultDurationMs = 3000,
  bool filterHeaderCredits = true,
}) {
  final transMap = _parseAuxiliaryLrcMap(translationLrc);
  final romaMap = _parseAuxiliaryLrcMap(romaLrc);

  final entries = <({int ms, int seq, String text, bool hasTimestamp})>[];
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
        entries.add((
          ms: fallbackCursor,
          seq: entries.length,
          text: content,
          hasTimestamp: false,
        ));
        fallbackCursor += defaultDurationMs;
      }
      continue;
    }
    if (content.isEmpty) continue;
    for (final m in matches) {
      entries.add((
        ms: _matchToMs(m),
        seq: entries.length,
        text: content,
        hasTimestamp: true,
      ));
    }
  }

  entries.sort((a, b) {
    final cmp = a.ms.compareTo(b.ms);
    return cmp != 0 ? cmp : a.seq.compareTo(b.seq);
  });
  final built = <({LyricLine line, bool hasTimestamp})>[];
  var i = 0;
  while (i < entries.length) {
    final groupMs = entries[i].ms;
    var groupEnd = i + 1;
    while (groupEnd < entries.length && entries[groupEnd].ms == groupMs) {
      groupEnd++;
    }
    final nextDistinctMs = groupEnd < entries.length
        ? entries[groupEnd].ms
        : groupMs + defaultDurationMs;
    final endMs = nextDistinctMs > groupMs
        ? nextDistinctMs
        : groupMs + defaultDurationMs;

    for (var k = i; k < groupEnd; k++) {
      final current = entries[k];
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
        built.add((
          line: LyricLine(
            id: 'lrc-sec-$k-${current.ms}',
            startTimeMs: current.ms,
            endTimeMs: endMs,
            kind: sectionKind,
            autoGenerated: false,
            text: LyricText(
              original: sectionKind.bracketTitle,
              translation: buildSectionSummary(sectionKind, endMs - current.ms),
            ),
          ),
          hasTimestamp: current.hasTimestamp,
        ));
        continue;
      }

      built.add((
        line: LyricLine(
          id: 'lrc-$k-${current.ms}',
          startTimeMs: current.ms,
          endTimeMs: endMs,
          text: LyricText(
            original: originalText,
            romaji: matchedRomaji,
            translation: matchedTranslation,
          ),
        ),
        hasTimestamp: current.hasTimestamp,
      ));
    }
    i = groupEnd;
  }

  var lyricist = '';
  var composer = '';
  var arranger = '';
  var mixer = '';
  var vocalist = '';
  final filteredIndices = <int>{};
  final inspectLimit = built.length < 10 ? built.length : 10;
  for (var idx = 0; idx < inspectLimit; idx++) {
    final item = built[idx];
    if (!item.hasTimestamp ||
        item.line.startTimeMs > 20000 ||
        item.line.kind.isSection) {
      continue;
    }
    final credit = _matchHeaderCredit(item.line.text.original);
    if (credit == null) continue;
    switch (credit.field) {
      case _CreditField.lyricist:
        if (lyricist.isEmpty) lyricist = credit.value;
      case _CreditField.composer:
        if (composer.isEmpty) composer = credit.value;
      case _CreditField.lyricistAndComposer:
        if (lyricist.isEmpty) lyricist = credit.value;
        if (composer.isEmpty) composer = credit.value;
      case _CreditField.arranger:
        if (arranger.isEmpty) arranger = credit.value;
      case _CreditField.mixer:
        if (mixer.isEmpty) mixer = credit.value;
      case _CreditField.vocalist:
        if (vocalist.isEmpty) vocalist = credit.value;
      case _CreditField.other:
        break;
    }
    if (filterHeaderCredits) {
      filteredIndices.add(idx);
    }
  }

  final originalLines = [for (final item in built) item.line];
  final filteredCreditLines = [
    for (var idx = 0; idx < built.length; idx++)
      if (filteredIndices.contains(idx)) built[idx].line,
  ];
  final activeLines = filterHeaderCredits
      ? [
          for (var idx = 0; idx < built.length; idx++)
            if (!filteredIndices.contains(idx)) built[idx].line,
        ]
      : originalLines;

  return LrcParseResult(
    lines: activeLines,
    originalLines: originalLines,
    filteredCreditLines: filteredCreditLines,
    extractedMeta: LrcExtractedMeta(
      lyricist: lyricist,
      composer: composer,
      arranger: arranger,
      mixer: mixer,
      vocalist: vocalist,
    ),
  );
}

/// Pure-Dart LRC parser supporting optional translation (`tlyric`) and
/// romaji (`romalrc`) tracks aligned by nearest timestamp.
List<LyricLine> parseLrcOffline(
  String lrcText, {
  String translationLrc = '',
  String romaLrc = '',
  int defaultDurationMs = 3000,
  bool filterHeaderCredits = false,
}) {
  return parseLrcOfflineDetailed(
    lrcText,
    translationLrc: translationLrc,
    romaLrc: romaLrc,
    defaultDurationMs: defaultDurationMs,
    filterHeaderCredits: filterHeaderCredits,
  ).lines;
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
