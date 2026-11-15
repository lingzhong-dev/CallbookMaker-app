import 'dart:math' as math;

import '../models/callbook_models.dart';
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
  });

  final int start;
  final int end;
  final ResolvedAlignedCue? call;
  final List<RubySegment> rubyParts;
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
    cleaned.add(
      AlignedCallCue(
        id: item.id.trim().isNotEmpty ? item.id : 'ac-$start-$end',
        start: start,
        end: end,
        text: text,
        colorHex: normalizedColor,
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

  final runs = <AlignedLyricRun>[];
  var cursor = 0;
  for (final cue in resolved) {
    if (cue.start > cursor) {
      runs.add(
        AlignedLyricRun(
          start: cursor,
          end: cue.start,
          rubyParts: _sliceRubySegmentsRange(spans, cursor, cue.start),
        ),
      );
    }
    runs.add(
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
    runs.add(
      AlignedLyricRun(
        start: cursor,
        end: original.length,
        rubyParts: _sliceRubySegmentsRange(spans, cursor, original.length),
      ),
    );
  }
  return runs;
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
