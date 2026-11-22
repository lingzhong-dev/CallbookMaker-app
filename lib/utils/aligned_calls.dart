import 'dart:math' as math;

import 'package:kuromoji_dart/kuromoji_dart.dart';

import '../models/callbook_models.dart';
import '../services/japanese_ruby_annotator.dart';
import 'lrc_ruby_parser.dart';

class ResolvedAlignedCue {
  const ResolvedAlignedCue({
    required this.cue,
    this.isAuto = false,
  });

  final AlignedCallCue cue;
  final bool isAuto;

  int get start => cue.start;
  int get end => cue.end;
  String get text => cue.text;
  String? get colorHex => cue.colorHex;
}

class AlignedLyricRun {
  const AlignedLyricRun({
    required this.start,
    required this.end,
    this.call,
    required this.rubyParts,
    this.romaji,
  });

  final int start;
  final int end;
  final ResolvedAlignedCue? call;
  final List<RubySegment> rubyParts;
  final String? romaji;
}

final _hexColorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');
final _tokenSplitPattern = RegExp(r'[/／、,|｜]+');

String _escapeHtml(String raw) => raw
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

List<AlignedCallCue> normalizeAlignedCalls(
  List<AlignedCallCue> raw,
  int originalLength,
) {
  if (raw.isEmpty || originalLength <= 0) return const [];
  final cleaned = <AlignedCallCue>[];
  for (final item in raw) {
    final text = item.text.trim();
    if (text.isEmpty) continue;
    final start = item.start.clamp(0, originalLength - 1);
    final end = item.end.clamp(start + 1, originalLength);
    if (end <= start) continue;
    final rawColor = item.colorHex?.trim() ?? '';
    final normalizedColor = _hexColorPattern.hasMatch(rawColor)
        ? rawColor.toUpperCase()
        : null;
    final cleanRomaji = item.romaji?.trim();
    cleaned.add(
      AlignedCallCue(
        id: item.id.trim().isNotEmpty ? item.id : 'ac-$start-$end',
        start: start,
        end: end,
        text: text,
        colorHex: normalizedColor,
        romaji: (cleanRomaji == null || cleanRomaji.isEmpty) ? null : cleanRomaji,
      ),
    );
  }
  cleaned.sort((a, b) {
    final cmp = a.start.compareTo(b.start);
    return cmp != 0 ? cmp : a.end.compareTo(b.end);
  });
  final nonOverlapping = <AlignedCallCue>[];
  var lastEnd = 0;
  for (final cue in cleaned) {
    if (cue.start >= lastEnd) {
      nonOverlapping.add(cue);
      lastEnd = cue.end;
    }
  }
  return nonOverlapping;
}

bool _overlapsExisting(List<ResolvedAlignedCue> cues, int start, int end) {
  for (final c in cues) {
    if (start < c.end && end > c.start) return true;
  }
  return false;
}

int _findNonOverlappingMatch(
  String haystack,
  String needle,
  List<ResolvedAlignedCue> occupied,
) {
  final lowerHaystack = haystack.toLowerCase();
  final lowerNeedle = needle.toLowerCase();
  var fromIndex = 0;
  while (fromIndex <= lowerHaystack.length - lowerNeedle.length) {
    final idx = lowerHaystack.indexOf(lowerNeedle, fromIndex);
    if (idx < 0) return -1;
    if (!_overlapsExisting(occupied, idx, idx + needle.length)) {
      return idx;
    }
    fromIndex = idx + 1;
  }
  return -1;
}

int _compareResolved(ResolvedAlignedCue a, ResolvedAlignedCue b) {
  final cmp = a.start.compareTo(b.start);
  return cmp != 0 ? cmp : a.end.compareTo(b.end);
}

({List<ResolvedAlignedCue> aligned, List<String> unalignedShoutParts})
resolveLineAlignedCalls(LyricLine line) {
  final original = line.text.original;
  final explicit = normalizeAlignedCalls(line.alignedCalls, original.length);
  final resolved = <ResolvedAlignedCue>[
    for (final c in explicit) ResolvedAlignedCue(cue: c, isAuto: false),
  ];

  final rawShout = line.customShout.trim();
  if (rawShout.isEmpty) {
    return (aligned: resolved, unalignedShoutParts: const []);
  }

  if (original.isNotEmpty && rawShout.length >= 2) {
    final wholeIdx = _findNonOverlappingMatch(original, rawShout, resolved);
    if (wholeIdx >= 0) {
      resolved.add(
        ResolvedAlignedCue(
          cue: AlignedCallCue(
            id: 'auto-shout-$wholeIdx',
            start: wholeIdx,
            end: wholeIdx + rawShout.length,
            text: rawShout,
          ),
          isAuto: true,
        ),
      );
      resolved.sort(_compareResolved);
      return (aligned: resolved, unalignedShoutParts: const []);
    }
  }

  final tokens = rawShout
      .split(_tokenSplitPattern)
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  final unaligned = <String>[];

  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (original.isNotEmpty && token.length >= 2) {
      final idx = _findNonOverlappingMatch(original, token, resolved);
      if (idx >= 0) {
        resolved.add(
          ResolvedAlignedCue(
            cue: AlignedCallCue(
              id: 'auto-shout-$i-$idx',
              start: idx,
              end: idx + token.length,
              text: token,
            ),
            isAuto: true,
          ),
        );
        continue;
      }
    }
    unaligned.add(token);
  }

  resolved.sort(_compareResolved);
  return (aligned: resolved, unalignedShoutParts: unaligned);
}

String getUnalignedCustomShout(LyricLine line) {
  return resolveLineAlignedCalls(line).unalignedShoutParts.join(' / ');
}

class _RubySpan {
  const _RubySpan({
    required this.start,
    required this.end,
    required this.base,
    this.rt,
  });

  final int start;
  final int end;
  final String base;
  final String? rt;
}

List<RubySegment> _sliceRubySegmentsRange(
  List<_RubySpan> spans,
  int rangeStart,
  int rangeEnd,
) {
  final out = <RubySegment>[];
  for (final seg in spans) {
    if (seg.end <= rangeStart || seg.start >= rangeEnd) continue;
    final subStart = math.max(seg.start, rangeStart) - seg.start;
    final subEnd = math.min(seg.end, rangeEnd) - seg.start;
    final textSlice = seg.base.substring(subStart, subEnd);
    if (textSlice.isEmpty) continue;
    final isFullSegment = subStart == 0 && subEnd == seg.base.length;
    out.add(
      RubySegment(
        base: textSlice,
        rt: isFullSegment ? seg.rt : null,
      ),
    );
  }
  return out;
}

List<AlignedLyricRun> buildAlignedLyricRuns(
  LyricLine line, {
  required bool showRuby,
  bool showRomaji = false,
  Tokenizer? tokenizer,
}) {
  final original = line.text.original;
  if (original.isEmpty) return const [];
  final resolved = resolveLineAlignedCalls(line).aligned;

  final rubyHtml = line.text.ruby;
  final parsedRuby = (showRuby && rubyHtml != null && rubyHtml.contains('<ruby'))
      ? parseRubySegments(rubyHtml, original)
      : [RubySegment(base: original)];
  final rubyPlain = parsedRuby.map((s) => s.base).join();
  final segments = rubyPlain == original ? parsedRuby : [RubySegment(base: original)];

  final spans = <_RubySpan>[];
  var pos = 0;
  for (final seg in segments) {
    spans.add(
      _RubySpan(
        start: pos,
        end: pos + seg.base.length,
        base: seg.base,
        rt: seg.rt,
      ),
    );
    pos += seg.base.length;
  }

  final rawRuns = <AlignedLyricRun>[];
  var cursor = 0;
  for (final cue in resolved) {
    if (cue.start > cursor) {
      rawRuns.add(
        AlignedLyricRun(
          start: cursor,
          end: cue.start,
          rubyParts: _sliceRubySegmentsRange(spans, cursor, cue.start),
        ),
      );
    }
    rawRuns.add(
      AlignedLyricRun(
        start: cue.start,
        end: cue.end,
        call: cue,
        rubyParts: _sliceRubySegmentsRange(spans, cue.start, cue.end),
      ),
    );
    cursor = cue.end;
  }
  if (cursor < original.length) {
    rawRuns.add(
      AlignedLyricRun(
        start: cursor,
        end: original.length,
        rubyParts: _sliceRubySegmentsRange(spans, cursor, original.length),
      ),
    );
  }
  if (!showRomaji || rawRuns.isEmpty) return rawRuns;

  final assigned = JapaneseRubyAnnotator.assignRomajiToRuns(
    line,
    [for (final r in rawRuns) (start: r.start, end: r.end)],
    tokenizer: tokenizer ?? JapaneseRubyAnnotator.instance.loadedTokenizer,
  );
  return [
    for (var i = 0; i < rawRuns.length; i++)
      AlignedLyricRun(
        start: rawRuns[i].start,
        end: rawRuns[i].end,
        call: rawRuns[i].call,
        rubyParts: rawRuns[i].rubyParts,
        romaji: assigned[i],
      ),
  ];
}

/// Subdivides non-call stretches into word/token pieces with aligned romaji so
/// [RubyLyricText] can render Call pills, ruby/kanji, and word-aligned romaji
/// vertically while still wrapping gracefully at word boundaries on narrow screens.
List<AlignedLyricRun> buildAlignedWordRunsForRomaji(
  LyricLine line, {
  required bool showRuby,
  Tokenizer? tokenizer,
}) {
  final original = line.text.original;
  if (original.isEmpty) return const [];
  final activeTokenizer =
      tokenizer ?? JapaneseRubyAnnotator.instance.loadedTokenizer;
  final baseRuns = buildAlignedLyricRuns(
    line,
    showRuby: showRuby,
    showRomaji: false,
    tokenizer: activeTokenizer,
  );
  if (baseRuns.isEmpty) return const [];

  final rubyHtml = line.text.ruby;
  final parsedRuby = (showRuby && rubyHtml != null && rubyHtml.contains('<ruby'))
      ? parseRubySegments(rubyHtml, original)
      : [RubySegment(base: original)];
  final rubyPlain = parsedRuby.map((s) => s.base).join();
  final segments = rubyPlain == original ? parsedRuby : [RubySegment(base: original)];
  final spans = <_RubySpan>[];
  var pos = 0;
  for (final seg in segments) {
    spans.add(
      _RubySpan(
        start: pos,
        end: pos + seg.base.length,
        base: seg.base,
        rt: seg.rt,
      ),
    );
    pos += seg.base.length;
  }

  final atoms = JapaneseRubyAnnotator.deriveRomajiAtoms(
    line,
    tokenizer: activeTokenizer,
  );

  final splitRuns = <AlignedLyricRun>[];
  for (final run in baseRuns) {
    if (run.call != null) {
      splitRuns.add(run);
      continue;
    }

    // Collect word/token cut boundaries strictly inside this non-call run.
    final cuts = <int>{run.start, run.end};
    for (final a in atoms) {
      if (a.start > run.start && a.start < run.end) cuts.add(a.start);
      if (a.end > run.start && a.end < run.end) cuts.add(a.end);
    }
    if (cuts.length <= 2) {
      for (final sp in spans) {
        if (sp.start > run.start && sp.start < run.end) cuts.add(sp.start);
        if (sp.end > run.start && sp.end < run.end) cuts.add(sp.end);
      }
    }
    final sorted = cuts.toList()..sort();
    for (var i = 0; i < sorted.length - 1; i++) {
      final s = sorted[i];
      final e = sorted[i + 1];
      if (e <= s) continue;
      splitRuns.add(
        AlignedLyricRun(
          start: s,
          end: e,
          rubyParts: _sliceRubySegmentsRange(spans, s, e),
        ),
      );
    }
  }

  final assigned = JapaneseRubyAnnotator.assignRomajiToRuns(
    line,
    [for (final r in splitRuns) (start: r.start, end: r.end)],
    tokenizer: activeTokenizer,
  );
  return [
    for (var i = 0; i < splitRuns.length; i++)
      AlignedLyricRun(
        start: splitRuns[i].start,
        end: splitRuns[i].end,
        call: splitRuns[i].call,
        rubyParts: splitRuns[i].rubyParts,
        romaji: assigned[i],
      ),
  ];
}

/// Merges two adjacent lyric lines cleanly, preserving ruby furigana, calls,
/// custom shouts, tailUpdraft, and shifted aligned call offsets.
LyricLine mergeAdjacentLyricLines(LyricLine first, LyricLine second) {
  final rawA = first.text.original;
  final rawB = second.text.original;
  final aTrimRight = rawA.replaceFirst(RegExp(r'\s+$'), '');
  final bTrimLeft = rawB.replaceFirst(RegExp(r'^\s+'), '');
  final bLeadingTrimCount = rawB.length - bTrimLeft.length;
  final bTrim = rawB.trim();

  final hasBothOrig = aTrimRight.isNotEmpty && bTrim.isNotEmpty;
  final mergedOriginal = hasBothOrig
      ? '$aTrimRight $bTrim'
      : (aTrimRight.isNotEmpty ? aTrimRight : bTrim);
  final shiftB = hasBothOrig
      ? aTrimRight.length + 1 - bLeadingTrimCount
      : -bLeadingTrimCount;

  final maxEndA = aTrimRight.isNotEmpty ? aTrimRight.length : mergedOriginal.length;
  final aCalls = normalizeAlignedCalls(first.alignedCalls, rawA.length)
      .where((c) => c.end <= maxEndA)
      .toList();
  final bCalls = [
    for (final c in normalizeAlignedCalls(second.alignedCalls, rawB.length))
      c.copyWith(
        start: math.max(0, c.start + shiftB),
        end: math.min(mergedOriginal.length, c.end + shiftB),
      ),
  ];
  final mergedAligned = normalizeAlignedCalls(
    [...aCalls, ...bCalls],
    mergedOriginal.length,
  );

  final rubyA = (first.text.ruby ?? '').trim();
  final rubyB = (second.text.ruby ?? '').trim();
  String? mergedRuby;
  if (rubyA.isNotEmpty && rubyB.isNotEmpty) {
    mergedRuby = '$rubyA $rubyB';
  } else if (rubyA.isNotEmpty) {
    mergedRuby = bTrim.isNotEmpty ? '$rubyA ${_escapeHtml(bTrim)}' : rubyA;
  } else if (rubyB.isNotEmpty) {
    mergedRuby = aTrimRight.isNotEmpty ? '${_escapeHtml(aTrimRight)} $rubyB' : rubyB;
  }

  final romajiParts = [
    if ((first.text.romaji ?? '').trim().isNotEmpty) first.text.romaji!.trim(),
    if ((second.text.romaji ?? '').trim().isNotEmpty) second.text.romaji!.trim(),
  ];
  final transParts = [
    if ((first.text.translation ?? '').trim().isNotEmpty)
      first.text.translation!.trim(),
    if ((second.text.translation ?? '').trim().isNotEmpty)
      second.text.translation!.trim(),
  ];

  final mergedTags = [for (final t in first.calls) t.copyWith()];
  for (final tag in second.calls) {
    final existingIdx = mergedTags.indexWhere((t) => t.presetId == tag.presetId);
    if (existingIdx < 0) {
      mergedTags.add(tag.copyWith());
    } else if ((mergedTags[existingIdx].suffix ?? '').trim().isEmpty &&
        (tag.suffix ?? '').trim().isNotEmpty) {
      mergedTags[existingIdx] = mergedTags[existingIdx].copyWith(suffix: tag.suffix);
    }
  }

  final shoutA = first.customShout.trim();
  final shoutB = second.customShout.trim();
  final String mergedShout;
  if (shoutA.isNotEmpty && shoutB.isNotEmpty) {
    mergedShout = shoutA == shoutB ? shoutA : '$shoutA / $shoutB';
  } else {
    mergedShout = shoutA.isNotEmpty ? shoutA : shoutB;
  }

  return LyricLine(
    id: first.id,
    startTimeMs: math.min(first.startTimeMs, second.startTimeMs),
    endTimeMs: math.max(first.endTimeMs, second.endTimeMs),
    kind: first.kind,
    autoGenerated: first.autoGenerated && second.autoGenerated,
    calls: mergedTags,
    customShout: mergedShout,
    tailUpdraft: first.tailUpdraft || second.tailUpdraft,
    alignedCalls: mergedAligned,
    text: LyricText(
      original: mergedOriginal,
      ruby: mergedRuby,
      romaji: romajiParts.isEmpty ? null : romajiParts.join(' '),
      translation: transParts.isEmpty ? null : transParts.join(' '),
    ),
  );
}

/// Computes internal split boundary timestamps by proportional rune count
/// across `[startMs, endMs]`. Returned list has `chunkRuneCounts.length - 1`
/// monotonically non-decreasing values inside `[startMs, endMs]`.
List<int> computeDefaultSplitTimes(
  int startMs,
  int endMs,
  List<int> chunkRuneCounts,
) {
  if (chunkRuneCounts.length <= 1) return const [];
  final safeStart = math.max(0, startMs);
  final safeEnd = math.max(safeStart, endMs);
  final span = safeEnd - safeStart;
  final totalRunes = chunkRuneCounts.fold<int>(
    0,
    (sum, count) => sum + math.max(1, count),
  );
  final chunkCount = chunkRuneCounts.length;
  final enforceMinGap = span >= chunkCount;

  final boundaries = <int>[];
  var cumulative = 0;
  var prev = safeStart;
  for (var i = 0; i < chunkCount - 1; i++) {
    cumulative += math.max(1, chunkRuneCounts[i]);
    var target = safeStart + (span * cumulative / totalRunes).round();
    final minAllowed = enforceMinGap ? prev + 1 : prev;
    final remainingChunks = chunkCount - 1 - i;
    final maxAllowed = enforceMinGap ? safeEnd - remainingChunks : safeEnd;
    if (target < minAllowed) target = minAllowed;
    if (target > maxAllowed) target = maxAllowed;
    boundaries.add(target);
    prev = target;
  }
  return boundaries;
}

String? _serializeRubySegments(List<RubySegment> segments) {
  if (segments.isEmpty) return null;
  final hasAnyRt = segments.any((s) => (s.rt ?? '').trim().isNotEmpty);
  if (!hasAnyRt) return null;
  final buf = StringBuffer();
  for (final seg in segments) {
    final rt = seg.rt?.trim();
    if (rt != null && rt.isNotEmpty) {
      buf.write('<ruby>${_escapeHtml(seg.base)}<rt>${_escapeHtml(rt)}</rt></ruby>');
    } else {
      buf.write(_escapeHtml(seg.base));
    }
  }
  return buf.toString();
}

/// Splits a single [LyricLine] at one or more rune boundaries (strictly inside
/// `1 .. original.runes.length - 1`), accurately translating rune offsets to
/// UTF-16 code units, clipping/shifting `alignedCalls` and `<ruby>` spans, and
/// allocating timestamps across the resulting chunks.
List<LyricLine> sliceLyricLineForSplit(
  LyricLine line,
  List<int> splitRuneIndices, {
  List<int>? boundaryTimesMs,
  required String Function(int chunkIndex) idFactory,
}) {
  final original = line.text.original;
  final runes = original.runes.toList(growable: false);
  final runeCount = runes.length;
  if (runeCount < 2) return [line];

  final cleanSplits = splitRuneIndices
      .where((i) => i > 0 && i < runeCount)
      .toSet()
      .toList()
    ..sort();
  if (cleanSplits.isEmpty) return [line];

  final runeToUtf16 = List<int>.filled(runeCount + 1, 0);
  var utf16Cursor = 0;
  for (var i = 0; i < runeCount; i++) {
    runeToUtf16[i] = utf16Cursor;
    utf16Cursor += String.fromCharCode(runes[i]).length;
  }
  runeToUtf16[runeCount] = utf16Cursor;

  final runeCutPoints = <int>[0, ...cleanSplits, runeCount];
  final chunkCount = runeCutPoints.length - 1;
  final chunkRuneCounts = <int>[
    for (var i = 0; i < chunkCount; i++) runeCutPoints[i + 1] - runeCutPoints[i],
  ];

  final safeStart = math.max(0, line.startTimeMs);
  final safeEnd = math.max(safeStart, line.endTimeMs);
  final List<int> boundaries;
  if (boundaryTimesMs != null && boundaryTimesMs.length == chunkCount - 1) {
    final normalized = <int>[];
    var prev = safeStart;
    final span = safeEnd - safeStart;
    final enforceMinGap = span >= chunkCount;
    for (var i = 0; i < chunkCount - 1; i++) {
      var val = boundaryTimesMs[i].clamp(safeStart, safeEnd);
      final minAllowed = enforceMinGap ? prev + 1 : prev;
      final remainingChunks = chunkCount - 1 - i;
      final maxAllowed = enforceMinGap ? safeEnd - remainingChunks : safeEnd;
      if (val < minAllowed) val = minAllowed;
      if (val > maxAllowed) val = maxAllowed;
      normalized.add(val);
      prev = val;
    }
    boundaries = normalized;
  } else {
    boundaries = computeDefaultSplitTimes(safeStart, safeEnd, chunkRuneCounts);
  }

  final rawRuby = line.text.ruby;
  List<_RubySpan>? rubySpans;
  if (rawRuby != null && rawRuby.contains('<ruby')) {
    final parsed = parseRubySegments(rawRuby, original);
    if (parsed.map((s) => s.base).join() == original) {
      final built = <_RubySpan>[];
      var pos = 0;
      for (final seg in parsed) {
        built.add(
          _RubySpan(
            start: pos,
            end: pos + seg.base.length,
            base: seg.base,
            rt: seg.rt,
          ),
        );
        pos += seg.base.length;
      }
      rubySpans = built;
    }
  }

  final normalizedAligned = normalizeAlignedCalls(line.alignedCalls, original.length);
  final timePoints = <int>[safeStart, ...boundaries, safeEnd];
  final out = <LyricLine>[];

  for (var k = 0; k < chunkCount; k++) {
    final uStart = runeToUtf16[runeCutPoints[k]];
    final uEnd = runeToUtf16[runeCutPoints[k + 1]];
    final chunkOriginal = original.substring(uStart, uEnd);

    final chunkAlignedRaw = <AlignedCallCue>[];
    for (final cue in normalizedAligned) {
      if (cue.end <= uStart || cue.start >= uEnd) continue;
      final subStart = math.max(cue.start, uStart) - uStart;
      final subEnd = math.min(cue.end, uEnd) - uStart;
      if (subEnd <= subStart) continue;
      final fullyInside = cue.start >= uStart && cue.end <= uEnd;
      chunkAlignedRaw.add(
        cue.copyWith(
          id: fullyInside ? cue.id : '${cue.id}-s$k',
          start: subStart,
          end: subEnd,
        ),
      );
    }
    final chunkAligned = normalizeAlignedCalls(chunkAlignedRaw, chunkOriginal.length);

    String? chunkRuby;
    if (rubySpans != null) {
      final slicedSegments = _sliceRubySegmentsRange(rubySpans, uStart, uEnd);
      chunkRuby = _serializeRubySegments(slicedSegments);
    }

    out.add(
      LyricLine(
        id: k == 0 ? line.id : idFactory(k),
        startTimeMs: timePoints[k],
        endTimeMs: timePoints[k + 1],
        kind: line.kind,
        autoGenerated: line.autoGenerated,
        calls: [for (final tag in line.calls) tag.copyWith()],
        customShout: k == 0 ? line.customShout : '',
        tailUpdraft: k == chunkCount - 1 ? line.tailUpdraft : false,
        alignedCalls: chunkAligned,
        text: LyricText(
          original: chunkOriginal,
          ruby: chunkRuby,
          romaji: k == 0 ? line.text.romaji : null,
          translation: k == 0 ? line.text.translation : null,
        ),
      ),
    );
  }
  return out;
}
