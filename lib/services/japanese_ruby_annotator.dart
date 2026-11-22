import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:kuromoji_dart/kuromoji_dart.dart';

import '../models/callbook_models.dart';
import '../utils/lrc_ruby_parser.dart';

final _kanaPattern = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]');
final _kanjiPattern = RegExp(r'[\u4E00-\u9FFF\u3400-\u4DBF\uF900-\uFAFF々〆ヵヶ]');
final _asciiWordEndPattern = RegExp(r'[A-Za-z0-9]$');
final _asciiWordStartPattern = RegExp(r'^[A-Za-z0-9]');
final _openingPunctPattern = RegExp(r'''^[\(\[\{「『（【《〈"'“‘]''');
final _closingOrAttachPunctPattern = RegExp(
  r'''^[\)\]\},.!?！？、。・…〜~：:；;」』）】》〉"'”’]+$''',
);

/// Pure-Dart offline Japanese morphological annotator backed by embedded
/// IPADIC assets (`packages/kuromoji_dart/assets/dict/`).
///
/// Generates `<ruby>漢字<rt>かんじ</rt></ruby>` furigana markup and Hepburn
/// romaji completely offline on both Android and Windows.
class JapaneseRubyAnnotator {
  JapaneseRubyAnnotator({Tokenizer? tokenizer}) : _tokenizer = tokenizer;

  /// Shared lazily-initialized singleton used by [CallbookController].
  static final JapaneseRubyAnnotator instance = JapaneseRubyAnnotator();

  Tokenizer? _tokenizer;
  Future<Tokenizer?>? _loadingFuture;

  bool get isLoaded => _tokenizer != null;
  Tokenizer? get loadedTokenizer => _tokenizer;

  /// Creates an annotator immediately from an on-disk IPADIC directory (for tests).
  factory JapaneseRubyAnnotator.fromDirectorySync(String dirPath) {
    return JapaneseRubyAnnotator(
      tokenizer: Tokenizer.fromDirectorySync(dirPath),
    );
  }

  /// Lazily loads IPADIC assets from Flutter's [rootBundle] and builds the
  /// [Tokenizer] inside a background isolate so the UI never stutters.
  Future<Tokenizer?> ensureLoaded() async {
    if (_tokenizer != null) return _tokenizer;
    return _loadingFuture ??= _loadFromAssets();
  }

  Future<Tokenizer?> _loadFromAssets() async {
    try {
      final compressed = <String, Uint8List>{};
      await Future.wait([
        for (final name in KuromojiAssetNames.gzippedFiles)
          rootBundle
              .load('${KuromojiAssetNames.packageAssetPrefix}/$name')
              .then((bd) {
            compressed[name] = bd.buffer.asUint8List(
              bd.offsetInBytes,
              bd.lengthInBytes,
            );
          }),
      ]);
      final charDefBd = await rootBundle.load(
        '${KuromojiAssetNames.packageAssetPrefix}/${KuromojiAssetNames.charDefFile}',
      );
      final charDef = charDefBd.buffer.asUint8List(
        charDefBd.offsetInBytes,
        charDefBd.lengthInBytes,
      );
      final built = await Isolate.run(
        () => Tokenizer.fromCompressedAssets(
          compressedFiles: compressed,
          charDef: charDef,
        ),
      );
      _tokenizer = built;
      return built;
    } catch (_) {
      _loadingFuture = null;
      return null;
    }
  }

  /// Returns true when the lyric lines contain Japanese kana (hiragana/katakana),
  /// preventing Chinese-only songs from being mis-annotated with Japanese readings.
  static bool shouldAnnotateLines(
    List<LyricLine> lines, {
    bool forceJapanese = false,
  }) {
    if (forceJapanese) return true;
    for (final line in lines) {
      if (line.kind.isSection) continue;
      if (_kanaPattern.hasMatch(line.text.original)) {
        return true;
      }
    }
    return false;
  }

  /// Annotates a batch of [LyricLine]s with `<ruby>` furigana and Hepburn romaji.
  ///
  /// When [preferExistingRomaji] is `true`, lines that already carry a non-empty
  /// `text.romaji` (such as Netease's official `romalrc`) keep their existing
  /// romaji while still receiving `<ruby>` furigana; missing lines fall back to
  /// offline-generated romaji.
  Future<List<LyricLine>> annotateLines(
    List<LyricLine> lines, {
    bool preferExistingRomaji = true,
    bool forceJapanese = false,
  }) async {
    if (lines.isEmpty) return lines;
    if (!shouldAnnotateLines(lines, forceJapanese: forceJapanese)) {
      return lines;
    }
    final tokenizer = await ensureLoaded();
    if (tokenizer == null) return lines;
    return annotateLinesWithTokenizer(
      tokenizer,
      lines,
      preferExistingRomaji: preferExistingRomaji,
    );
  }

  /// Synchronous core used once a [Tokenizer] is ready.
  static List<LyricLine> annotateLinesWithTokenizer(
    Tokenizer tokenizer,
    List<LyricLine> lines, {
    bool preferExistingRomaji = true,
  }) {
    final out = <LyricLine>[];
    for (final line in lines) {
      if (line.kind.isSection) {
        out.add(line);
        continue;
      }
      final original = line.text.original;
      if (original.trim().isEmpty) {
        out.add(line);
        continue;
      }
      final annotated = annotateText(tokenizer, original);
      final existingRomaji = (line.text.romaji ?? '').trim();
      final resolvedRomaji = (preferExistingRomaji && existingRomaji.isNotEmpty)
          ? existingRomaji
          : (annotated.romaji.isNotEmpty
                ? annotated.romaji
                : (existingRomaji.isNotEmpty ? existingRomaji : null));
      final resolvedRuby = annotated.hasRuby ? annotated.rubyHtml : line.text.ruby;
      out.add(
        line.copyWith(
          text: line.text.copyWith(
            ruby: resolvedRuby,
            romaji: resolvedRomaji,
          ),
        ),
      );
    }
    return out;
  }

  /// Annotates a single Japanese line into `<ruby>` HTML and Hepburn romaji.
  static ({String rubyHtml, String romaji, bool hasRuby}) annotateText(
    Tokenizer tokenizer,
    String text,
  ) {
    final tokens = tokenizer.tokenize(text);
    if (tokens.isEmpty) {
      return (rubyHtml: _escapeHtml(text), romaji: '', hasRuby: false);
    }

    final rubyBuf = StringBuffer();
    var hasRuby = false;

    for (final token in tokens) {
      final surface = token.surfaceForm;
      if (surface.isEmpty) continue;
      if (!_kanjiPattern.hasMatch(surface)) {
        rubyBuf.write(_escapeHtml(surface));
        continue;
      }
      final rawReading = token.reading ?? token.pronunciation;
      if (rawReading == null || rawReading.isEmpty) {
        rubyBuf.write(_escapeHtml(surface));
        continue;
      }
      final hiraReading = katakanaToHiragana(rawReading);
      final formatted = buildRubyForToken(surface, hiraReading);
      if (formatted.contains('<ruby>')) {
        hasRuby = true;
      }
      rubyBuf.write(formatted);
    }

    final romaji = tokensToRomaji(tokens);
    return (rubyHtml: rubyBuf.toString(), romaji: romaji, hasRuby: hasRuby);
  }

  /// Aligns kanji runs in [surface] with [hiraReading] so okurigana / kana
  /// prefixes & suffixes stay outside `<ruby>` tags.
  ///
  /// Example: `('食べる', 'たべる')` -> `'<ruby>食<rt>た</rt></ruby>べる'`.
  static String buildRubyForToken(String surface, String hiraReading) {
    if (surface.isEmpty || !_kanjiPattern.hasMatch(surface)) {
      return _escapeHtml(surface);
    }
    final surfaceHira = katakanaToHiragana(surface);
    if (surfaceHira == hiraReading) {
      return _escapeHtml(surface);
    }

    // 1. Strip matching kana prefix.
    var prefixLen = 0;
    while (prefixLen < surface.length &&
        prefixLen < hiraReading.length &&
        !_isKanjiChar(surface[prefixLen]) &&
        surfaceHira[prefixLen] == hiraReading[prefixLen]) {
      prefixLen++;
    }

    // 2. Strip matching kana suffix (okurigana).
    var sEnd = surface.length;
    var rEnd = hiraReading.length;
    while (sEnd > prefixLen &&
        rEnd > prefixLen &&
        !_isKanjiChar(surface[sEnd - 1]) &&
        surfaceHira[sEnd - 1] == hiraReading[rEnd - 1]) {
      sEnd--;
      rEnd--;
    }

    final prefix = surface.substring(0, prefixLen);
    final coreSurface = surface.substring(prefixLen, sEnd);
    final coreReading = hiraReading.substring(prefixLen, rEnd);
    final suffix = surface.substring(sEnd);

    if (coreSurface.isEmpty) {
      return _escapeHtml(surface);
    }
    if (coreReading.isEmpty) {
      return _escapeHtml(surface);
    }

    // 3. If coreSurface has internal kana anchors (e.g. 取り戻 -> 取 + り + 戻),
    // split along kana runs when uniquely alignable.
    final alignedCore = _alignInternalKana(coreSurface, coreReading);
    return '${_escapeHtml(prefix)}$alignedCore${_escapeHtml(suffix)}';
  }

  static String _alignInternalKana(String coreSurface, String coreReading) {
    final runs = <({String text, bool isKanji})>[];
    var i = 0;
    while (i < coreSurface.length) {
      final kanji = _isKanjiChar(coreSurface[i]);
      var j = i + 1;
      while (j < coreSurface.length && _isKanjiChar(coreSurface[j]) == kanji) {
        j++;
      }
      runs.add((text: coreSurface.substring(i, j), isKanji: kanji));
      i = j;
    }

    if (runs.length <= 1) {
      return '<ruby>${_escapeHtml(coreSurface)}<rt>${_escapeHtml(coreReading)}</rt></ruby>';
    }

    final buf = StringBuffer();
    var rCursor = 0;
    for (var idx = 0; idx < runs.length; idx++) {
      final run = runs[idx];
      if (!run.isKanji) {
        final anchor = katakanaToHiragana(run.text);
        if (!coreReading.startsWith(anchor, rCursor)) {
          return '<ruby>${_escapeHtml(coreSurface)}<rt>${_escapeHtml(coreReading)}</rt></ruby>';
        }
        buf.write(_escapeHtml(run.text));
        rCursor += anchor.length;
      } else {
        if (idx == runs.length - 1) {
          final rem = coreReading.substring(rCursor);
          if (rem.isEmpty) {
            return '<ruby>${_escapeHtml(coreSurface)}<rt>${_escapeHtml(coreReading)}</rt></ruby>';
          }
          buf.write('<ruby>${_escapeHtml(run.text)}<rt>${_escapeHtml(rem)}</rt></ruby>');
          rCursor = coreReading.length;
        } else {
          final nextAnchor = katakanaToHiragana(runs[idx + 1].text);
          final found = coreReading.indexOf(nextAnchor, rCursor + 1);
          if (found <= rCursor) {
            return '<ruby>${_escapeHtml(coreSurface)}<rt>${_escapeHtml(coreReading)}</rt></ruby>';
          }
          final chunkReading = coreReading.substring(rCursor, found);
          buf.write(
            '<ruby>${_escapeHtml(run.text)}<rt>${_escapeHtml(chunkReading)}</rt></ruby>',
          );
          rCursor = found;
        }
      }
    }
    return buf.toString();
  }

  /// Converts a token stream into spaced Hepburn romaji, respecting Japanese
  /// particle pronunciation (`は -> wa`, `へ -> e`, `を -> wo`).
  static String tokensToRomaji(List<KuromojiToken> tokens) {
    final parts = <({String text, bool attachLeft, bool attachRight})>[];

    for (final token in tokens) {
      final surface = token.surfaceForm;
      if (surface.isEmpty) continue;
      if (surface.trim().isEmpty) continue;

      final isPunct = token.pos == '記号' ||
          _closingOrAttachPunctPattern.hasMatch(surface);
      final isOpenPunct = _openingPunctPattern.hasMatch(surface);

      String roma;
      if (token.pos == '助詞' && surface == 'は') {
        roma = 'wa';
      } else if (token.pos == '助詞' && surface == 'へ') {
        roma = 'e';
      } else if (token.pos == '助詞' && surface == 'を') {
        roma = 'wo';
      } else if (!_kanaPattern.hasMatch(surface) &&
          !_kanjiPattern.hasMatch(surface)) {
        roma = _normalizeFullWidthPunct(surface);
      } else {
        final rawReading = token.reading ?? token.pronunciation ?? surface;
        final hira = katakanaToHiragana(rawReading);
        roma = hiraganaToHepburn(hira);
        if (roma.isEmpty) {
          roma = _normalizeFullWidthPunct(surface);
        }
      }

      if (roma.trim().isEmpty) continue;

      // Attach Japanese prefixes to the following word and suffixes/auxiliaries
      // to the preceding word so romaji reads naturally (`ohimesama`, `tabenai`).
      final isPrefix = token.pos == '接頭詞';
      final isConjSuffix =
          token.pos == '助詞' &&
          token.posDetails.$1 == '接続助詞' &&
          const {'て', 'で', 'ば', 'たり', 'ちゃ', 'じゃ'}.contains(surface);
      final isSuffix =
          token.posDetails.$1 == '接尾' ||
          token.pos == '助動詞' ||
          isConjSuffix ||
          (token.pos == '動詞' && token.posDetails.$1 == '非自立');
      final attachLeft = (isPunct && !isOpenPunct) || isSuffix;
      final attachRight = isOpenPunct || isPrefix;
      parts.add((text: roma, attachLeft: attachLeft, attachRight: attachRight));
    }

    if (parts.isEmpty) return '';

    final buf = StringBuffer();
    for (var i = 0; i < parts.length; i++) {
      final cur = parts[i];
      if (i > 0) {
        final prev = parts[i - 1];
        final needsSpace = !cur.attachLeft &&
            !prev.attachRight &&
            !(_asciiWordEndPattern.hasMatch(prev.text) &&
                _closingOrAttachPunctPattern.hasMatch(cur.text));
        if (needsSpace) {
          buf.write(' ');
        }
      }
      buf.write(cur.text);
    }

    var sentence = buf.toString().replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    if (sentence.isEmpty) return '';
    // Capitalize the first ASCII letter for clean lyric display.
    final firstLetterIdx = sentence.indexOf(RegExp(r'[a-z]'));
    if (firstLetterIdx == 0 ||
        (firstLetterIdx > 0 &&
            _openingPunctPattern.hasMatch(sentence.substring(0, firstLetterIdx)))) {
      sentence = sentence.substring(0, firstLetterIdx) +
          sentence[firstLetterIdx].toUpperCase() +
          sentence.substring(firstLetterIdx + 1);
    }
    return sentence;
  }

  /// Converts katakana characters (`ァ`..`ヶ`) to hiragana (`ぁ`..`ゖ`).
  static String katakanaToHiragana(String input) {
    final codes = input.codeUnits;
    final out = List<int>.filled(codes.length, 0);
    for (var i = 0; i < codes.length; i++) {
      final c = codes[i];
      if (c >= 0x30A1 && c <= 0x30F6) {
        out[i] = c - 0x60;
      } else {
        out[i] = c;
      }
    }
    return String.fromCharCodes(out);
  }

  /// Converts hiragana (and prolonged sound mark `ー`) into standard Hepburn romaji.
  static String hiraganaToHepburn(String hira) {
    final buf = StringBuffer();
    var i = 0;
    while (i < hira.length) {
      final ch = hira[i];

      // Sokuon (small tsu `っ`): double the following consonant (`t` before `ch`).
      if (ch == 'っ' || ch == 'ッ') {
        if (i + 1 < hira.length) {
          final next = _lookupRomajiAt(hira, i + 1);
          if (next != null && next.romaji.isNotEmpty) {
            if (next.romaji.startsWith('ch')) {
              buf.write('t');
            } else if (_isConsonant(next.romaji[0])) {
              buf.write(next.romaji[0]);
            }
          }
        }
        i++;
        continue;
      }

      // Prolonged sound mark `ー`: repeat previous vowel if present.
      if (ch == 'ー') {
        final s = buf.toString();
        if (s.isNotEmpty) {
          final last = s[s.length - 1];
          if ('aeiou'.contains(last)) {
            buf.write(last);
          }
        }
        i++;
        continue;
      }

      // Try 2-char digraph first, then 1-char kana.
      final match = _lookupRomajiAt(hira, i);
      if (match != null) {
        buf.write(match.romaji);
        i += match.length;
        continue;
      }

      buf.write(_normalizeFullWidthPunct(ch));
      i++;
    }
    return buf.toString();
  }

  static ({String romaji, int length})? _lookupRomajiAt(String s, int i) {
    if (i + 2 <= s.length) {
      final pair = s.substring(i, i + 2);
      final mapped = _digraphRomaji[pair];
      if (mapped != null) {
        return (romaji: mapped, length: 2);
      }
    }
    final single = s[i];
    final mapped = _monographRomaji[single];
    if (mapped != null) {
      return (romaji: mapped, length: 1);
    }
    return null;
  }

  static bool _isConsonant(String ch) {
    return _asciiWordStartPattern.hasMatch(ch) && !'aeiou'.contains(ch);
  }

  static bool _isKanjiChar(String ch) => _kanjiPattern.hasMatch(ch);

  /// Converts a short Japanese Call cue (e.g. `大好き`, `せーの`) into clean
  /// Hepburn romaji when it contains Japanese script; returns `null` otherwise.
  static String? deriveCueRomaji(String cueText, {Tokenizer? tokenizer}) {
    final clean = cueText.trim();
    if (clean.isEmpty) return null;
    final hasJapaneseScript =
        _kanaPattern.hasMatch(clean) || _kanjiPattern.hasMatch(clean);
    if (!hasJapaneseScript) return null;
    if (tokenizer != null) {
      final res = annotateText(tokenizer, clean).romaji.trim();
      return res.isEmpty ? null : res;
    }
    if (!_kanjiPattern.hasMatch(clean)) {
      final hira = katakanaToHiragana(clean);
      final roma = hiraganaToHepburn(hira).trim();
      if (roma.isEmpty) return null;
      return _capitalizeFirstAscii(roma);
    }
    return null;
  }

  /// Derives UTF-16 character-aligned word/segment romaji atoms covering [line.text.original].
  ///
  /// Uses [tokenizer] when available (splitting along `<ruby>`/kana morpheme
  /// boundaries if a range cuts inside a compound), falling back synchronously
  /// to `<ruby>` tags + kana tables, and finally proportional `line.text.romaji`.
  static List<
    ({
      int start,
      int end,
      String romaji,
      bool attachLeft,
      bool attachRight,
    })
  >
  deriveRomajiAtoms(
    LyricLine line, {
    Tokenizer? tokenizer,
  }) {
    final original = line.text.original;
    if (original.isEmpty) return const [];

    final hasRubyTags = (line.text.ruby ?? '').contains('<ruby');
    final isJapanese = _kanaPattern.hasMatch(original) || hasRubyTags;

    if (isJapanese && tokenizer != null) {
      final atoms = _deriveTokenizerAtoms(tokenizer, line);
      if (atoms.isNotEmpty) return atoms;
    }

    if (isJapanese) {
      final atoms = _deriveSyncRubyKanaAtoms(line);
      if (atoms.isNotEmpty) return atoms;
    }

    final existingRomaji = (line.text.romaji ?? '').trim();
    if (existingRomaji.isNotEmpty) {
      return _deriveProportionalRomajiAtoms(original, existingRomaji);
    }

    return const [];
  }

  /// Assigns aligned Hepburn/derived romaji strings for a sequential list of
  /// `[start, end)` UTF-16 ranges partitioning [line.text.original].
  static List<String> assignRomajiToRuns(
    LyricLine line,
    List<({int start, int end})> runs, {
    Tokenizer? tokenizer,
  }) {
    if (runs.isEmpty) return const [];
    final atoms = deriveRomajiAtoms(line, tokenizer: tokenizer);
    if (atoms.isEmpty) {
      return List<String>.filled(runs.length, '');
    }

    // Refine atoms only at run cut boundaries that split inside an atom.
    final cuts = <int>{
      for (final r in runs) ...[r.start, r.end],
    }.toList()..sort();

    final splitAtoms =
        <({int start, int end, String romaji, bool attachLeft, bool attachRight})>[];
    for (final atom in atoms) {
      final innerCuts = cuts
          .where((c) => c > atom.start && c < atom.end)
          .toList();
      if (innerCuts.isEmpty) {
        splitAtoms.add(atom);
        continue;
      }
      final points = [atom.start, ...innerCuts, atom.end];
      final pieces = _splitSingleAtomRomaji(
        line: line,
        start: atom.start,
        end: atom.end,
        atomRomaji: atom.romaji,
        cutPoints: points,
        attachLeft: atom.attachLeft,
        attachRight: atom.attachRight,
      );
      splitAtoms.addAll(pieces);
    }

    final out = <String>[];
    for (final run in runs) {
      final matching = [
        for (final a in splitAtoms)
          if (a.start >= run.start && a.end <= run.end) a,
      ];
      out.add(_joinAtomsToRomaji(matching));
    }
    return out;
  }

  /// Returns derived/aligned romaji for an arbitrary selection `[start, end)`
  /// inside [line.text.original].
  static String sliceRomajiForRange(
    LyricLine line,
    int start,
    int end, {
    Tokenizer? tokenizer,
  }) {
    final len = line.text.original.length;
    if (len <= 0) return '';
    final s = start.clamp(0, len);
    final e = end.clamp(s, len);
    if (e <= s) return '';
    final ranges = <({int start, int end})>[
      if (s > 0) (start: 0, end: s),
      (start: s, end: e),
      if (e < len) (start: e, end: len),
    ];
    final targetIdx = s > 0 ? 1 : 0;
    final assigned = assignRomajiToRuns(line, ranges, tokenizer: tokenizer);
    return assigned[targetIdx].trim();
  }

  static List<
    ({
      int start,
      int end,
      String romaji,
      bool attachLeft,
      bool attachRight,
    })
  >
  _deriveTokenizerAtoms(Tokenizer tokenizer, LyricLine line) {
    final original = line.text.original;
    final tokens = tokenizer.tokenize(original);
    if (tokens.isEmpty) return const [];

    final out =
        <({int start, int end, String romaji, bool attachLeft, bool attachRight})>[];
    var cursor = 0;

    for (final token in tokens) {
      final surface = token.surfaceForm;
      if (surface.isEmpty) continue;
      final hintStart = (token.wordPosition - 1).clamp(0, original.length);
      int start;
      if (hintStart >= cursor && original.startsWith(surface, hintStart)) {
        start = hintStart;
      } else {
        final found = original.indexOf(surface, cursor);
        if (found < 0) continue;
        start = found;
      }
      final end = start + surface.length;
      cursor = end;

      final mapped = _tokenToRomajiMeta(token);
      if (mapped == null) continue;
      out.add((
        start: start,
        end: end,
        romaji: mapped.text,
        attachLeft: mapped.attachLeft,
        attachRight: mapped.attachRight,
      ));
    }
    return out;
  }

  static ({String text, bool attachLeft, bool attachRight})?
  _tokenToRomajiMeta(KuromojiToken token) {
    final surface = token.surfaceForm;
    if (surface.trim().isEmpty) return null;

    final isPunct =
        token.pos == '記号' || _closingOrAttachPunctPattern.hasMatch(surface);
    final isOpenPunct = _openingPunctPattern.hasMatch(surface);

    String roma;
    if (token.pos == '助詞' && surface == 'は') {
      roma = 'wa';
    } else if (token.pos == '助詞' && surface == 'へ') {
      roma = 'e';
    } else if (token.pos == '助詞' && surface == 'を') {
      roma = 'wo';
    } else if (!_kanaPattern.hasMatch(surface) &&
        !_kanjiPattern.hasMatch(surface)) {
      roma = _normalizeFullWidthPunct(surface);
    } else {
      final rawReading = token.reading ?? token.pronunciation ?? surface;
      final hira = katakanaToHiragana(rawReading);
      roma = hiraganaToHepburn(hira);
      if (roma.isEmpty) {
        roma = _normalizeFullWidthPunct(surface);
      }
    }
    if (roma.trim().isEmpty) return null;

    final isPrefix = token.pos == '接頭詞';
    final isConjSuffix =
        token.pos == '助詞' &&
        token.posDetails.$1 == '接続助詞' &&
        const {'て', 'で', 'ば', 'たり', 'ちゃ', 'じゃ'}.contains(surface);
    final isSuffix =
        token.posDetails.$1 == '接尾' ||
        token.pos == '助動詞' ||
        isConjSuffix ||
        (token.pos == '動詞' && token.posDetails.$1 == '非自立');
    final attachLeft = (isPunct && !isOpenPunct) || isSuffix;
    final attachRight = isOpenPunct || isPrefix;
    return (text: roma, attachLeft: attachLeft, attachRight: attachRight);
  }

  static List<
    ({
      int start,
      int end,
      String romaji,
      bool attachLeft,
      bool attachRight,
    })
  >
  _deriveSyncRubyKanaAtoms(LyricLine line) {
    final original = line.text.original;
    final parsed =
        ((line.text.ruby ?? '').contains('<ruby')
            ? parseRubySegments(line.text.ruby, original)
            : [RubySegment(base: original)]);
    final segs = parsed.map((s) => s.base).join() == original
        ? parsed
        : [RubySegment(base: original)];

    final out =
        <({int start, int end, String romaji, bool attachLeft, bool attachRight})>[];
    var pos = 0;
    var prevWasRubyKanji = false;

    for (var sIdx = 0; sIdx < segs.length; sIdx++) {
      final seg = segs[sIdx];
      final segStart = pos;
      final segEnd = segStart + seg.base.length;
      pos = segEnd;

      if (seg.rt != null && seg.rt!.trim().isNotEmpty) {
        final roma = hiraganaToHepburn(katakanaToHiragana(seg.rt!.trim()));
        if (roma.isNotEmpty) {
          out.add((
            start: segStart,
            end: segEnd,
            romaji: roma,
            attachLeft: false,
            attachRight: false,
          ));
        }
        prevWasRubyKanji = true;
        continue;
      }

      // Split plain segment into whitespace-delimited / particle-aware runs.
      var i = 0;
      while (i < seg.base.length) {
        final ch = seg.base[i];
        if (ch.trim().isEmpty) {
          i++;
          prevWasRubyKanji = false;
          continue;
        }

        // Punctuation run
        if (_closingOrAttachPunctPattern.hasMatch(ch) ||
            _openingPunctPattern.hasMatch(ch)) {
          final isOpen = _openingPunctPattern.hasMatch(ch);
          out.add((
            start: segStart + i,
            end: segStart + i + 1,
            romaji: _normalizeFullWidthPunct(ch).trim(),
            attachLeft: !isOpen,
            attachRight: isOpen,
          ));
          i++;
          prevWasRubyKanji = false;
          continue;
        }

        // Single standalone kana particle `を` or `は`/`へ` right after ruby kanji
        if (ch == 'を' ||
            (prevWasRubyKanji &&
                (ch == 'は' || ch == 'へ') &&
                (i + 1 >= seg.base.length ||
                    _closingOrAttachPunctPattern.hasMatch(seg.base[i + 1]) ||
                    seg.base[i + 1].trim().isEmpty ||
                    _kanaPattern.hasMatch(seg.base[i + 1])))) {
          // Wait: avoid mis-reading `行く`? No, okurigana after `<ruby>高い</ruby>` is `い`, not `は`.
          // `<ruby>場所</ruby>は<ruby>高</ruby>い` -> `場所` + `は` (`wa`)!
          final particleRoma = switch (ch) {
            'は' => 'wa',
            'へ' => 'e',
            _ => 'wo',
          };
          out.add((
            start: segStart + i,
            end: segStart + i + 1,
            romaji: particleRoma,
            attachLeft: false,
            attachRight: false,
          ));
          i++;
          prevWasRubyKanji = false;
          continue;
        }

        // Contiguous ASCII / kana run
        final isKana = _kanaPattern.hasMatch(ch);
        var j = i + 1;
        while (j < seg.base.length) {
          final nextCh = seg.base[j];
          if (nextCh.trim().isEmpty ||
              _closingOrAttachPunctPattern.hasMatch(nextCh) ||
              _openingPunctPattern.hasMatch(nextCh)) {
            break;
          }
          if (_kanaPattern.hasMatch(nextCh) != isKana) break;
          j++;
        }
        final chunk = seg.base.substring(i, j);
        final roma = isKana
            ? hiraganaToHepburn(katakanaToHiragana(chunk))
            : chunk;
        if (roma.trim().isNotEmpty) {
          out.add((
            start: segStart + i,
            end: segStart + j,
            romaji: roma,
            attachLeft: false,
            attachRight: false,
          ));
        }
        i = j;
        prevWasRubyKanji = false;
      }
    }
    return out;
  }

  static List<
    ({
      int start,
      int end,
      String romaji,
      bool attachLeft,
      bool attachRight,
    })
  >
  _deriveProportionalRomajiAtoms(String original, String romajiText) {
    final words = romajiText
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty || original.isEmpty) return const [];
    final out =
        <({int start, int end, String romaji, bool attachLeft, bool attachRight})>[];
    final total = original.length;
    for (var i = 0; i < words.length; i++) {
      final s = (((i * total) / words.length).floor()).clamp(0, math.max(0, total - 1)).toInt();
      var e = ((((i + 1) * total) / words.length).ceil()).clamp(s + 1, total).toInt();
      if (i == words.length - 1) e = total;
      if (e <= s) continue;
      out.add((
        start: s,
        end: e,
        romaji: words[i],
        attachLeft: false,
        attachRight: false,
      ));
    }
    return out;
  }

  static List<
    ({
      int start,
      int end,
      String romaji,
      bool attachLeft,
      bool attachRight,
    })
  >
  _splitSingleAtomRomaji({
    required LyricLine line,
    required int start,
    required int end,
    required String atomRomaji,
    required List<int> cutPoints,
    required bool attachLeft,
    required bool attachRight,
  }) {
    final original = line.text.original;
    final sub = original.substring(start, end);

    // If pure kana, map each chunk cleanly via hiraganaToHepburn.
    if (!_kanjiPattern.hasMatch(sub) && _kanaPattern.hasMatch(sub)) {
      return [
        for (var i = 0; i < cutPoints.length - 1; i++)
          (
            start: cutPoints[i],
            end: cutPoints[i + 1],
            romaji: hiraganaToHepburn(
              katakanaToHiragana(
                original.substring(cutPoints[i], cutPoints[i + 1]),
              ),
            ),
            attachLeft: i == 0 && attachLeft,
            attachRight: i == cutPoints.length - 2 && attachRight,
          ),
      ];
    }

    // Proportional slice of atomRomaji for kanji compounds cut mid-token.
    final totalChars = math.max(1, end - start);
    final romaLen = atomRomaji.length;
    final out =
        <({int start, int end, String romaji, bool attachLeft, bool attachRight})>[];
    var rCursor = 0;
    for (var i = 0; i < cutPoints.length - 1; i++) {
      final subStart = cutPoints[i];
      final subEnd = cutPoints[i + 1];
      final relEnd = subEnd - start;
      final nextRCursor = (i == cutPoints.length - 2)
          ? romaLen
          : ((relEnd * romaLen) / totalChars).round().clamp(rCursor, romaLen);
      final pieceRoma = atomRomaji.substring(rCursor, nextRCursor);
      rCursor = nextRCursor;
      out.add((
        start: subStart,
        end: subEnd,
        romaji: pieceRoma,
        attachLeft: i == 0 && attachLeft,
        attachRight: i == cutPoints.length - 2 && attachRight,
      ));
    }
    return out;
  }

  static String _joinAtomsToRomaji(
    List<
      ({
        int start,
        int end,
        String romaji,
        bool attachLeft,
        bool attachRight,
      })
    >
    atoms,
  ) {
    if (atoms.isEmpty) return '';
    final buf = StringBuffer();
    for (var i = 0; i < atoms.length; i++) {
      final cur = atoms[i];
      final txt = cur.romaji.trim();
      if (txt.isEmpty) continue;
      if (buf.isNotEmpty && i > 0) {
        final prev = atoms[i - 1];
        final needsSpace =
            !cur.attachLeft &&
            !prev.attachRight &&
            !(_asciiWordEndPattern.hasMatch(prev.romaji) &&
                _closingOrAttachPunctPattern.hasMatch(txt));
        if (needsSpace) buf.write(' ');
      }
      buf.write(txt);
    }
    return buf.toString().replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }

  static String _capitalizeFirstAscii(String s) {
    final idx = s.indexOf(RegExp(r'[a-z]'));
    if (idx < 0) return s;
    return s.substring(0, idx) +
        s[idx].toUpperCase() +
        s.substring(idx + 1);
  }

  static String _escapeHtml(String raw) {
    return raw
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  static String _normalizeFullWidthPunct(String s) {
    return s
        .replaceAll('　', ' ')
        .replaceAll('、', ', ')
        .replaceAll('。', '.')
        .replaceAll('！', '!')
        .replaceAll('？', '?')
        .replaceAll('（', '(')
        .replaceAll('）', ')')
        .replaceAll('「', '"')
        .replaceAll('」', '"')
        .replaceAll('『', '"')
        .replaceAll('』', '"')
        .replaceAll('…', '...');
  }
}

const Map<String, String> _digraphRomaji = {
  'きゃ': 'kya', 'きゅ': 'kyu', 'きょ': 'kyo', 'きぇ': 'kye',
  'ぎゃ': 'gya', 'ぎゅ': 'gyu', 'ぎょ': 'gyo', 'ぎぇ': 'gye',
  'しゃ': 'sha', 'しゅ': 'shu', 'しょ': 'sho', 'しぇ': 'she',
  'じゃ': 'ja', 'じゅ': 'ju', 'じょ': 'jo', 'じぇ': 'je',
  'ちゃ': 'cha', 'ちゅ': 'chu', 'ちょ': 'cho', 'ちぇ': 'che',
  'ぢゃ': 'ja', 'ぢゅ': 'ju', 'ぢょ': 'jo',
  'にゃ': 'nya', 'にゅ': 'nyu', 'にょ': 'nyo', 'にぇ': 'nye',
  'ひゃ': 'hya', 'ひゅ': 'hyu', 'ひょ': 'hyo', 'ひぇ': 'hye',
  'びゃ': 'bya', 'びゅ': 'byu', 'びょ': 'byo', 'びぇ': 'bye',
  'ぴゃ': 'pya', 'ぴゅ': 'pyu', 'ぴょ': 'pyo', 'ぴぇ': 'pye',
  'みゃ': 'mya', 'みゅ': 'myu', 'みょ': 'myo', 'みぇ': 'mye',
  'りゃ': 'rya', 'りゅ': 'ryu', 'りょ': 'ryo', 'りぇ': 'rye',
  'てぃ': 'ti', 'てゅ': 'tyu', 'でぃ': 'di', 'でゅ': 'dyu',
  'とぅ': 'tu', 'どぅ': 'du',
  'ふぁ': 'fa', 'ふぃ': 'fi', 'ふぇ': 'fe', 'ふぉ': 'fo', 'ふゅ': 'fyu',
  'うぃ': 'wi', 'うぇ': 'we', 'うぉ': 'wo',
  'ゔぁ': 'va', 'ゔぃ': 'vi', 'ゔぇ': 've', 'ゔぉ': 'vo', 'ゔゅ': 'vyu',
  'つぁ': 'tsa', 'つぃ': 'tsi', 'つぇ': 'tse', 'つぉ': 'tso',
  'いぇ': 'ye',
};

const Map<String, String> _monographRomaji = {
  'あ': 'a', 'い': 'i', 'う': 'u', 'え': 'e', 'お': 'o',
  'か': 'ka', 'き': 'ki', 'く': 'ku', 'け': 'ke', 'こ': 'ko',
  'が': 'ga', 'ぎ': 'gi', 'ぐ': 'gu', 'げ': 'ge', 'ご': 'go',
  'さ': 'sa', 'し': 'shi', 'す': 'su', 'せ': 'se', 'そ': 'so',
  'ざ': 'za', 'じ': 'ji', 'ず': 'zu', 'ぜ': 'ze', 'ぞ': 'zo',
  'た': 'ta', 'ち': 'chi', 'つ': 'tsu', 'て': 'te', 'と': 'to',
  'だ': 'da', 'ぢ': 'ji', 'づ': 'zu', 'で': 'de', 'ど': 'do',
  'な': 'na', 'に': 'ni', 'ぬ': 'nu', 'ね': 'ne', 'の': 'no',
  'は': 'ha', 'ひ': 'hi', 'ふ': 'fu', 'へ': 'he', 'ほ': 'ho',
  'ば': 'ba', 'び': 'bi', 'ぶ': 'bu', 'べ': 'be', 'ぼ': 'bo',
  'ぱ': 'pa', 'ぴ': 'pi', 'ぷ': 'pu', 'ぺ': 'pe', 'ぽ': 'po',
  'ま': 'ma', 'み': 'mi', 'む': 'mu', 'め': 'me', 'も': 'mo',
  'や': 'ya', 'ゆ': 'yu', 'よ': 'yo',
  'ら': 'ra', 'り': 'ri', 'る': 'ru', 'れ': 're', 'ろ': 'ro',
  'わ': 'wa', 'ゐ': 'wi', 'ゑ': 'we', 'を': 'wo', 'ん': 'n',
  'ゔ': 'vu',
  'ぁ': 'a', 'ぃ': 'i', 'ぅ': 'u', 'ぇ': 'e', 'ぉ': 'o',
  'ゃ': 'ya', 'ゅ': 'yu', 'ょ': 'yo', 'ゎ': 'wa',
};
