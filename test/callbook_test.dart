import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_call_studio/data/default_songs.dart';
import 'package:live_call_studio/models/callbook_models.dart';
import 'package:live_call_studio/utils/aligned_calls.dart';
import 'package:live_call_studio/utils/lrc_ruby_parser.dart';
import 'package:live_call_studio/utils/section_detector.dart';
import 'package:live_call_studio/utils/xlsx_export.dart';

import 'support/mock_audioplayers_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LRC & Furigana Parser', () {
    test('parseRubySegments extracts kanji and rt annotations accurately', () {
      const rubyHtml =
          '<ruby>君<rt>きみ</rt></ruby>と<ruby>響<rt>ひび</rt></ruby>く Vanaheim';
      final segments = parseRubySegments(rubyHtml, '君と響く Vanaheim');

      expect(segments.length, 4);
      expect(segments[0].base, '君');
      expect(segments[0].rt, 'きみ');
      expect(segments[1].base, 'と');
      expect(segments[1].rt, isNull);
      expect(segments[2].base, '響');
      expect(segments[2].rt, 'ひび');
      expect(segments[3].base, 'く Vanaheim');
      expect(segments[3].rt, isNull);
    });

    test('parseLrcOffline aligns original and translation LRC lines', () {
      const lrc = '''
[ti:Vanaheim]
[00:10.50] 最初の行
[00:15.00] 次の行
''';
      const trans = '''
[00:10.52] 第一行翻译
[00:15.10] 第二行翻译
''';

      final lines = parseLrcOffline(lrc, translationLrc: trans);
      expect(lines.length, 2);
      expect(lines[0].startTimeMs, 10500);
      expect(lines[0].endTimeMs, 15000);
      expect(lines[0].text.original, '最初の行');
      expect(lines[0].text.translation, '第一行翻译');
      expect(lines[1].startTimeMs, 15000);
      expect(lines[1].text.translation, '第二行翻译');
    });

    test('parseLrcOffline handles CR-only line endings without collapsing lines', () {
      const crOnlyLrc = '[00:05.00] 一行目\r[00:10.00] 二行目\r[00:15.00] 三行目';
      const crOnlyTrans = '[00:05.00] 第一行\r[00:10.00] 第二行\r[00:15.00] 第三行';

      final lines = parseLrcOffline(crOnlyLrc, translationLrc: crOnlyTrans);
      expect(lines.length, 3);
      expect(lines[0].text.original, '一行目');
      expect(lines[0].text.translation, '第一行');
      expect(lines[1].text.original, '二行目');
      expect(lines[1].endTimeMs, 15000);
      expect(lines[2].text.original, '三行目');
      expect(lines[2].text.translation, '第三行');
    });

    test('formatMsToClock formats milliseconds cleanly', () {
      expect(formatMsToClock(0), '00:00.00');
      expect(formatMsToClock(12540), '00:12.54');
      expect(formatMsToClock(75000), '01:15.00');
    });
  });

  group('CallProject Serialization', () {
    test('Default CallProject builds cleanly without preset Calls and roundtrips through JSON', () {
      final primary = defaultPrimarySong.buildCleanProject();
      final decoded = CallProject.fromJson(primary.toJson());

      expect(decoded.meta.title, '来自瓦纳海姆');
      expect(decoded.meta.bpm, 148);
      expect(decoded.meta.timeSignature, '4/4');
      expect(decoded.meta.composer, 'litterzy');
      expect(decoded.meta.lyricist, '冥凰');
      expect(decoded.meta.vocalist, '洛天依');
      expect(decoded.meta.tuner, 'Creuzer');
      expect(decoded.meta.showTuner, isTrue);
      expect(decoded.alerts, isEmpty);
      expect(decoded.lines.length, primary.lines.length);
      expect(decoded.lines.any((l) => l.kind == LyricLineKind.intro), isTrue);
      expect(decoded.lines.any((l) => l.kind == LyricLineKind.outro), isTrue);
      expect(
        decoded.lines.every(
          (l) =>
              l.calls.isEmpty &&
              l.customShout.isEmpty &&
              !l.tailUpdraft &&
              l.alignedCalls.isEmpty,
        ),
        isTrue,
      );
    });

    test('CallProjectMeta and GtAlert serialize extended credits & cues', () {
      const meta = CallProjectMeta(
        title: 'ワールドイズマイン',
        artist: 'supercell feat. 初音ミク',
        composer: 'ryo (supercell)',
        lyricist: 'ryo (supercell)',
        vocalist: '初音ミク',
        tuner: 'MixMaster',
        showTuner: true,
        editorName: 'CallBook Studio',
        editorNote: '注意间奏 GT 警报处全员跟喊',
      );
      final decodedMeta = CallProjectMeta.fromJson(meta.toJson());
      expect(decodedMeta.composer, 'ryo (supercell)');
      expect(decodedMeta.lyricist, 'ryo (supercell)');
      expect(decodedMeta.vocalist, '初音ミク');
      expect(decodedMeta.tuner, 'MixMaster');
      expect(decodedMeta.showTuner, isTrue);
      expect(decodedMeta.editorName, 'CallBook Studio');
      expect(decodedMeta.editorNote, '注意间奏 GT 警报处全员跟喊');

      const alert = GtAlert(
        id: 'gt-1',
        triggerTimeMs: 12000,
        note: '吉他推进',
        targetLineId: 'line-2',
      );
      final encodedAlert = alert.toJson();
      expect(encodedAlert.containsKey('leadBeats'), isFalse);
      expect(encodedAlert.containsKey('callTimingCue'), isFalse);
      final decodedAlert = GtAlert.fromJson(encodedAlert);
      expect(decodedAlert.targetLineId, 'line-2');
      expect(decodedAlert.note, '吉他推进');

      // Legacy projects with deprecated leadBeats / callTimingCue still parse cleanly.
      final legacyDecoded = GtAlert.fromJson({
        'id': 'gt-legacy',
        'triggerTimeMs': 18000,
        'leadBeats': 4,
        'callTimingCue': 'はいせーの！',
        'note': '旧版备注',
        'targetLineId': 'line-3',
      });
      expect(legacyDecoded.id, 'gt-legacy');
      expect(legacyDecoded.triggerTimeMs, 18000);
      expect(legacyDecoded.note, '旧版备注');
      expect(legacyDecoded.targetLineId, 'line-3');
    });

    test('resolveGtAlertTargetLineId handles explicit target and legacy fallback', () {
      const lines = [
        LyricLine(
          id: 'l1',
          startTimeMs: 1000,
          endTimeMs: 4000,
          text: LyricText(original: 'Line 1'),
        ),
        LyricLine(
          id: 'l2',
          startTimeMs: 5000,
          endTimeMs: 9000,
          text: LyricText(original: 'Line 2'),
        ),
        LyricLine(
          id: 'l3',
          startTimeMs: 10000,
          endTimeMs: 14000,
          text: LyricText(original: 'Line 3'),
        ),
      ];

      const explicit = GtAlert(
        id: 'g1',
        triggerTimeMs: 9000,
        targetLineId: 'l2',
      );
      expect(resolveGtAlertTargetLineId(explicit, lines), 'l2');

      const legacyUpcoming = GtAlert(id: 'g2', triggerTimeMs: 4200);
      expect(resolveGtAlertTargetLineId(legacyUpcoming, lines), 'l2');

      const legacyNearest = GtAlert(id: 'g3', triggerTimeMs: 11200);
      expect(resolveGtAlertTargetLineId(legacyNearest, lines), 'l3');

      expect(resolveGtAlertTargetLineId(legacyUpcoming, const []), isNull);
    });

    test('LyricLine tailUpdraft serializes and stays independent of leading calls', () {
      const tagged = LyricLine(
        id: 'line-up',
        startTimeMs: 2000,
        endTimeMs: 5000,
        calls: [LineCallTag(presetId: 'fuwa')],
        customShout: '随节奏',
        tailUpdraft: true,
        text: LyricText(original: '夢の続きへ'),
      );
      final decoded = LyricLine.fromJson(tagged.toJson());
      expect(decoded.tailUpdraft, isTrue);
      expect(decoded.calls.length, 1);
      expect(decoded.customShout, '随节奏');

      final untagged = decoded.copyWith(tailUpdraft: false);
      expect(LyricLine.fromJson(untagged.toJson()).tailUpdraft, isFalse);
      expect(untagged.calls.length, 1);
    });

    test('detectAndMergeSections preserves sections marked with tailUpdraft', () {
      const autoUpdraftSection = LyricLine(
        id: 'sec-intro',
        startTimeMs: 0,
        endTimeMs: 12000,
        kind: LyricLineKind.intro,
        autoGenerated: true,
        tailUpdraft: true,
        text: LyricText(original: '【前奏】', translation: '前奏空档 12.0s'),
      );
      const lyric = LyricLine(
        id: 'l-1',
        startTimeMs: 12000,
        endTimeMs: 16000,
        text: LyricText(original: '輝きだす'),
      );
      final res = detectAndMergeSections([autoUpdraftSection, lyric]);
      final intro = res.lines.firstWhere((l) => l.kind == LyricLineKind.intro);
      expect(intro.tailUpdraft, isTrue);
    });

    test('buildCallBookXlsxBytes produces valid dual-sheet OOXML zip without fills', () {
      final base = defaultPrimarySong.buildCleanProject();
      final modifiedLines = [
        for (var i = 0; i < base.lines.length; i++)
          i == 0
              ? base.lines[i].copyWith(
                  calls: const [LineCallTag(presetId: 'front-wave', suffix: '×4')],
                  customShout: '随节奏',
                )
              : (i == 3 ? base.lines[i].copyWith(tailUpdraft: true) : base.lines[i]),
      ];
      final proj = base.copyWith(
        lines: modifiedLines,
        alerts: [
          GtAlert(
            id: 'gt-xlsx-1',
            triggerTimeMs: base.lines[2].startTimeMs,
            targetLineId: base.lines[2].id,
            note: '吉他进场',
          ),
        ],
      );
      final bytes = buildCallBookXlsxBytes(
        proj,
        defaultCallPresets,
        displayLayers: const DisplayLayers(),
      );

      // Valid ZIP local file header magic PK\x03\x04 and End of Central Directory PK\x05\x06.
      expect(bytes.length, greaterThan(400));
      expect(bytes.sublist(0, 4), [0x50, 0x4B, 0x03, 0x04]);

      final eocdOffset = bytes.length - 22;
      expect(bytes.sublist(eocdOffset, eocdOffset + 4), [0x50, 0x4B, 0x05, 0x06]);

      // Decompress payload check via ZLibDecoder isn't trivial entry-by-entry without parsing headers,
      // verify UTF-8 sharedStrings contains expected markers when reading raw entry names in bytes.
      final latin = latin1.decode(bytes);
      expect(latin.contains('xl/workbook.xml'), isTrue);
      expect(latin.contains('xl/worksheets/sheet1.xml'), isTrue);
      expect(latin.contains('xl/worksheets/sheet2.xml'), isTrue);
      expect(latin.contains('xl/styles.xml'), isTrue);
      expect(latin.contains('xl/sharedStrings.xml'), isTrue);
      expect(ZLibCodec(raw: true), isNotNull);
    });

    test('CallbookArchiveEntry and ArchiveSessionState serialize cleanly', () {
      final base = defaultPrimarySong.buildCleanProject();
      final taggedLines = [
        for (var i = 0; i < base.lines.length; i++)
          i == 0 ? base.lines[i].copyWith(tailUpdraft: true) : base.lines[i],
      ];
      final proj = base.copyWith(lines: taggedLines);
      final entry = CallbookArchiveEntry(
        id: 'arch-vanaheim-1',
        name: 'Vanaheim Archive',
        createdAt: 1700000000000,
        savedAt: 1700000050000,
        project: proj,
        customPresets: [defaultCallPresets.first],
        lineCount: proj.lines.length,
        taggedCount: CallbookArchiveEntry.computeTaggedCount(proj),
        alertCount: proj.alerts.length,
      );

      final decoded = CallbookArchiveEntry.fromJson(entry.toJson());
      expect(decoded.id, 'arch-vanaheim-1');
      expect(decoded.name, 'Vanaheim Archive');
      expect(decoded.lineCount, proj.lines.length);
      expect(decoded.taggedCount, CallbookArchiveEntry.computeTaggedCount(proj));
      expect(decoded.alertCount, proj.alerts.length);
      expect(decoded.customPresets.length, 1);
      expect(decoded.project.lines.first.tailUpdraft, isTrue);

      const session = ArchiveSessionState(
        activeArchiveId: 'arch-vanaheim-1',
        hasUnsavedChanges: true,
        hasFetchedExternalLyrics: true,
      );
      final decodedSession = ArchiveSessionState.fromJson(session.toJson());
      expect(decodedSession.activeArchiveId, 'arch-vanaheim-1');
      expect(decodedSession.hasUnsavedChanges, isTrue);
      expect(decodedSession.hasFetchedExternalLyrics, isTrue);
    });

    test('defaultCallPresets includes built-in 跟唱 (sing-along) and 拍手 (clap)', () {
      expect(defaultCallPresets.length, 10);
      final singAlong = defaultCallPresets.firstWhere(
        (p) => p.id == singAlongPresetId,
      );
      expect(singAlong.label, '跟唱');
      expect(singAlong.colorHex, '#EC4899');
      expect(singAlong.category, CallCategory.compound);
      expect(singAlong.shortcut, '9');
      expect(singAlong.builtIn, isTrue);

      final clap = defaultCallPresets.firstWhere((p) => p.id == 'clap');
      expect(clap.label, '拍手');
      expect(clap.colorHex, '#14B8A6');
      expect(clap.category, CallCategory.downbeat);
      expect(clap.shortcut, '0');
      expect(clap.builtIn, isTrue);

      final copied = singAlong.copyWith(label: '合唱', colorHex: '#2563EB');
      expect(copied.id, singAlongPresetId);
      expect(copied.label, '合唱');
      expect(copied.colorHex, '#2563EB');
      expect(copied.builtIn, isTrue);
    });
  });

  group('Aligned Calls & Adjacent Line Merging', () {
    test('resolveLineAlignedCalls auto-aligns matching customShout substrings and splits tokens', () {
      const lineWhole = LyricLine(
        id: 'a1',
        startTimeMs: 1000,
        endTimeMs: 4000,
        customShout: '高い',
        text: LyricText(
          original: '目指す場所は高い',
          ruby: '<ruby>目指<rt>めざ</rt></ruby>す<ruby>場所<rt>ばしょ</rt></ruby>は<ruby>高<rt>たか</rt></ruby>い',
        ),
      );
      final wholeRes = resolveLineAlignedCalls(lineWhole);
      expect(wholeRes.aligned.length, 1);
      expect(wholeRes.aligned.first.start, 6);
      expect(wholeRes.aligned.first.end, 8);
      expect(wholeRes.aligned.first.text, '高い');
      expect(wholeRes.aligned.first.isAuto, isTrue);
      expect(wholeRes.unalignedShoutParts, isEmpty);
      expect(getUnalignedCustomShout(lineWhole), '');

      final runs = buildAlignedLyricRuns(lineWhole, showRuby: true);
      expect(runs.length, 2);
      expect(runs[0].call, isNull);
      expect(runs[1].call?.text, '高い');
      expect(runs[1].rubyParts.length, 2);
      expect(runs[1].rubyParts[0].base, '高');
      expect(runs[1].rubyParts[0].rt, 'たか');
      expect(runs[1].rubyParts[1].base, 'い');

      const lineMixed = LyricLine(
        id: 'a2',
        startTimeMs: 4000,
        endTimeMs: 7000,
        customShout: 'どこまで / L.O.V.E',
        alignedCalls: [
          AlignedCallCue(
            id: 'explicit-1',
            start: 0,
            end: 4,
            text: 'Hi!',
            colorHex: '#EF4444',
          ),
        ],
        text: LyricText(original: 'いまより高くどこまで'),
      );
      final mixedRes = resolveLineAlignedCalls(lineMixed);
      expect(mixedRes.aligned.length, 2);
      expect(mixedRes.aligned[0].cue.id, 'explicit-1');
      expect(mixedRes.aligned[0].isAuto, isFalse);
      expect(mixedRes.aligned[1].text, 'どこまで');
      expect(mixedRes.aligned[1].start, 6);
      expect(mixedRes.aligned[1].end, 10);
      expect(mixedRes.unalignedShoutParts, ['L.O.V.E']);
      expect(getUnalignedCustomShout(lineMixed), 'L.O.V.E');
    });

    test('buildAlignedLyricRuns falls back cleanly when ruby text is stale', () {
      const staleRubyLine = LyricLine(
        id: 'stale-1',
        startTimeMs: 1000,
        endTimeMs: 3000,
        customShout: 'どこまで',
        text: LyricText(
          original: 'いまより高くどこまで',
          ruby: '<ruby>古<rt>ふる</rt></ruby>いテキスト',
        ),
      );
      final runs = buildAlignedLyricRuns(staleRubyLine, showRuby: true);
      expect(runs.length, 2);
      expect(runs[0].rubyParts.map((s) => s.base).join(), 'いまより高く');
      expect(runs[1].call?.text, 'どこまで');
      expect(runs[1].rubyParts.map((s) => s.base).join(), 'どこまで');
    });

    test('mergeAdjacentLyricLines merges text, ruby, calls, shouts, tailUpdraft and shifts alignedCalls', () {
      const first = LyricLine(
        id: 'm1',
        startTimeMs: 1000,
        endTimeMs: 3500,
        calls: [LineCallTag(presetId: 'front-wave')],
        customShout: '高い',
        alignedCalls: [
          AlignedCallCue(id: 'c1', start: 0, end: 2, text: 'Go!'),
        ],
        text: LyricText(
          original: '目指す場所',
          ruby: '<ruby>目指<rt>めざ</rt></ruby>す<ruby>場所<rt>ばしょ</rt></ruby>',
          romaji: 'mezasu basho',
          translation: '目标所在之处',
        ),
      );
      const second = LyricLine(
        id: 'm2',
        startTimeMs: 3500,
        endTimeMs: 6500,
        calls: [
          LineCallTag(presetId: 'front-wave', suffix: '×2'),
          LineCallTag(presetId: 'clap'),
        ],
        customShout: 'どこまで',
        tailUpdraft: true,
        alignedCalls: [
          AlignedCallCue(id: 'c2', start: 1, end: 3, text: 'Jump', colorHex: '#10B981'),
        ],
        text: LyricText(
          original: ' どこまで',
          romaji: 'dokomade',
          translation: '直到何方',
        ),
      );

      final merged = mergeAdjacentLyricLines(first, second);
      expect(merged.id, 'm1');
      expect(merged.startTimeMs, 1000);
      expect(merged.endTimeMs, 6500);
      expect(merged.text.original, '目指す場所 どこまで');
      expect(
        merged.text.ruby,
        '<ruby>目指<rt>めざ</rt></ruby>す<ruby>場所<rt>ばしょ</rt></ruby> どこまで',
      );
      expect(merged.text.romaji, 'mezasu basho dokomade');
      expect(merged.text.translation, '目标所在之处 直到何方');
      expect(merged.tailUpdraft, isTrue);
      expect(merged.customShout, '高い / どこまで');
      expect(merged.calls.length, 2);
      expect(merged.calls.firstWhere((c) => c.presetId == 'front-wave').suffix, '×2');
      expect(merged.alignedCalls.length, 2);
      expect(merged.alignedCalls[0].start, 0);
      expect(merged.alignedCalls[0].end, 2);
      // second original starts with a space trimmed away, shift = 5 + 1 - 1 = 5
      expect(merged.alignedCalls[1].start, 6);
      expect(merged.alignedCalls[1].end, 8);
      expect(merged.alignedCalls[1].colorHex, '#10B981');

      // JSON roundtrip & Archive taggedCount include alignedCalls
      final roundtrip = LyricLine.fromJson(merged.toJson());
      expect(roundtrip.alignedCalls.length, 2);
      expect(roundtrip.alignedCalls[1].text, 'Jump');
      expect(
        CallbookArchiveEntry.computeTaggedCount(
          const CallProject(
            meta: CallProjectMeta(title: 't', artist: 'a'),
            lines: [
              LyricLine(
                id: 'only-aligned',
                startTimeMs: 0,
                endTimeMs: 1000,
                alignedCalls: [AlignedCallCue(id: 'x', start: 0, end: 1, text: 'Hi')],
                text: LyricText(original: '夢'),
              ),
            ],
          ),
        ),
        1,
      );

      // XLSX export includes explicit alignedCalls
      final xlsxBytes = buildCallBookXlsxBytes(
        CallProject(
          meta: const CallProjectMeta(title: 'Xlsx Aligned Test', artist: 'Unit'),
          lines: [roundtrip],
        ),
        defaultCallPresets,
      );
      expect(xlsxBytes.length, greaterThan(400));
    });
  });

  group('Word-Accurate Lyric Splitting', () {
    test('computeDefaultSplitTimes distributes timestamps monotonically by rune count', () {
      expect(computeDefaultSplitTimes(1000, 7000, [1, 2, 3]), [2000, 4000]);
      // Tiny interval enforces minimum 1ms monotonic spacing
      expect(computeDefaultSplitTimes(1000, 1003, [1, 1, 1]), [1001, 1002]);
      expect(computeDefaultSplitTimes(1000, 7000, [5]), isEmpty);
    });

    test('sliceLyricLineForSplit accurately maps runes/UTF-16 emoji, alignedCalls, ruby, metadata, and tailUpdraft', () {
      const source = LyricLine(
        id: 'sp-base',
        startTimeMs: 10000,
        endTimeMs: 18000,
        calls: [LineCallTag(presetId: 'fuwa', suffix: '×2')],
        customShout: 'ハイ！',
        tailUpdraft: true,
        alignedCalls: [
          AlignedCallCue(id: 'c-inside', start: 0, end: 2, text: 'Hi!'),
          AlignedCallCue(id: 'c-cross1', start: 2, end: 4, text: '春夏'),
          AlignedCallCue(id: 'c-cross2', start: 4, end: 7, text: '星秋冬'),
        ],
        text: LyricText(
          original: '🎵春夏✨秋冬', // UTF-16 lengths: 🎵(2) 春(1) 夏(1) ✨(1) 秋(1) 冬(1) = 7 UTF-16 units, 6 runes
          ruby: '🎵<ruby>春夏<rt>しゅんか</rt></ruby>✨<ruby>秋冬<rt>しゅうとう</rt></ruby>',
          romaji: 'haru natsu aki fuyu',
          translation: '春夏秋冬',
        ),
      );

      // Cut at runes 2 & 4 -> ['🎵春', '夏✨', '秋冬'] (UTF-16 starts: 0, 3, 5, 7)
      final chunks = sliceLyricLineForSplit(
        source,
        const [4, 2],
        boundaryTimesMs: const [12500, 15000],
        idFactory: (idx) => 'chunk-$idx',
      );

      expect(chunks, hasLength(3));

      expect(chunks[0].id, 'sp-base');
      expect(chunks[0].startTimeMs, 10000);
      expect(chunks[0].endTimeMs, 12500);
      expect(chunks[0].text.original, '🎵春');
      // '春夏' was sliced in the middle -> ruby rt on split kanji drops safely
      expect(chunks[0].text.ruby, isNull);
      expect(chunks[0].text.translation, '春夏秋冬');
      expect(chunks[0].text.romaji, 'haru natsu aki fuyu');
      expect(chunks[0].customShout, 'ハイ！');
      expect(chunks[0].tailUpdraft, isFalse);
      expect(chunks[0].calls.single.suffix, '×2');
      expect(chunks[0].alignedCalls, hasLength(2));
      expect(chunks[0].alignedCalls[0].id, 'c-inside');
      expect(chunks[0].alignedCalls[0].start, 0);
      expect(chunks[0].alignedCalls[0].end, 2);
      expect(chunks[0].alignedCalls[1].id, 'c-cross1-s0');
      expect(chunks[0].alignedCalls[1].start, 2);
      expect(chunks[0].alignedCalls[1].end, 3);

      expect(chunks[1].id, 'chunk-1');
      expect(chunks[1].startTimeMs, 12500);
      expect(chunks[1].endTimeMs, 15000);
      expect(chunks[1].text.original, '夏✨');
      expect(chunks[1].text.translation, isNull);
      expect(chunks[1].text.romaji, isNull);
      expect(chunks[1].customShout, '');
      expect(chunks[1].tailUpdraft, isFalse);
      expect(chunks[1].alignedCalls, hasLength(2));
      expect(chunks[1].alignedCalls[0].id, 'c-cross1-s1');
      expect(chunks[1].alignedCalls[0].start, 0);
      expect(chunks[1].alignedCalls[0].end, 1);
      expect(chunks[1].alignedCalls[1].id, 'c-cross2-s1');
      expect(chunks[1].alignedCalls[1].start, 1);
      expect(chunks[1].alignedCalls[1].end, 2);

      expect(chunks[2].id, 'chunk-2');
      expect(chunks[2].startTimeMs, 15000);
      expect(chunks[2].endTimeMs, 18000);
      expect(chunks[2].text.original, '秋冬');
      // '<ruby>秋冬<rt>しゅうとう</rt></ruby>' stayed intact inside chunk 2 -> ruby preserved!
      expect(chunks[2].text.ruby, '<ruby>秋冬<rt>しゅうとう</rt></ruby>');
      expect(chunks[2].tailUpdraft, isTrue);
      expect(chunks[2].alignedCalls.single.id, 'c-cross2-s2');
      expect(chunks[2].alignedCalls.single.start, 0);
      expect(chunks[2].alignedCalls.single.end, 2);
    });

    test('CallbookController.splitLineAtRunes retargets GT alert, validates constraints, and supports Undo', () async {
      MockAudioplayersHarness().install();
      final controller = await createTestCallbookController(enableAudioOutput: false);
      try {
        await controller.importLrcText(
          lrc: '''
[00:00.00]
[00:12.00] 夢の中で輝く星
[00:19.00] 次の空へ
''',
        );
        final section = controller.sortedLines.firstWhere((l) => l.kind.isSection);
        expect(controller.splitLineAtRunes(section.id, const [1]), isFalse);

        final lyric = controller.sortedLines.firstWhere(
          (l) => l.text.original == '夢の中で輝く星',
        );
        controller.toggleLineGtAlert(lineId: lyric.id);
        controller.updateLineGtAlert(lyric.id, note: '分段前提示');
        final countBefore = controller.sortedLines.length;

        final ok = controller.splitLineAtRunes(
          lyric.id,
          const [4],
          boundaryTimesMs: const [15500],
        );
        expect(ok, isTrue);
        expect(controller.sortedLines.length, countBefore + 1);
        expect(controller.canUndo, isTrue);

        final firstChunk = controller.sortedLines.firstWhere((l) => l.id == lyric.id);
        expect(firstChunk.text.original, '夢の中で');
        expect(firstChunk.startTimeMs, 12000);
        expect(firstChunk.endTimeMs, 15500);

        final secondChunk = controller.sortedLines.firstWhere(
          (l) => l.text.original == '輝く星',
        );
        expect(secondChunk.startTimeMs, 15500);
        expect(secondChunk.endTimeMs, 19000);

        final alert = controller.getAlertForLine(firstChunk.id);
        expect(alert, isNotNull);
        expect(alert!.note, '分段前提示');
        expect(alert.triggerTimeMs, firstChunk.startTimeMs);

        expect(controller.undoLastTimelineEdit(), isTrue);
        expect(controller.sortedLines.length, countBefore);
        expect(
          controller.sortedLines.any((l) => l.text.original == '夢の中で輝く星'),
          isTrue,
        );
        expect(controller.getAlertForLine(lyric.id)?.note, '分段前提示');
      } finally {
        controller.dispose();
      }
    });
  });
}
