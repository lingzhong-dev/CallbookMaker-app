import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import '../models/callbook_models.dart';
import 'lrc_ruby_parser.dart';

/// Generates a native multi-sheet `.xlsx` CallBook workbook matching the
/// clean, zero-fill OOXML format used across desktop and mobile exports:
/// - Sheet 1 (`Callbook`): Rows 1-5 credits/editor header + Rows 6+ A/B/C rows
///   with `（Call法 / Mix）`, lyric/section text, and `#66CCFF` `（GT警报）` / `（尾句上升气流）`.
/// - Sheet 2 (`详细版`): Same header + Rows 6+ including GT timing/notes in
///   Col C (`#66CCFF`) and enabled ruby/romaji/translation layers in Col D.
Uint8List buildCallBookXlsxBytes(
  CallProject project,
  List<CallPreset> allPresets, {
  DisplayLayers displayLayers = const DisplayLayers(),
}) {
  final pool = _SharedStringPool();
  final meta = project.meta;
  final presetMap = {for (final p in allPresets) p.id: p};

  final sortedLines = [...project.lines]
    ..sort((a, b) => a.startTimeMs.compareTo(b.startTimeMs));

  final alertByLineId = <String, GtAlert>{};
  for (final alert in project.alerts) {
    final targetId = resolveGtAlertTargetLineId(alert, sortedLines);
    if (targetId != null && !alertByLineId.containsKey(targetId)) {
      alertByLineId[targetId] = alert;
    }
  }

  final editorDisplay = meta.editorName.trim();
  final editorNoteDisplay = meta.editorNote.trim();
  final hasTuner = meta.showTuner || meta.tuner.trim().isNotEmpty;
  final composerDisplay = meta.composer.trim();
  final lyricistDisplay = meta.lyricist.trim();
  final tunerDisplay = hasTuner ? meta.tuner.trim() : '';
  final vocalistDisplay = _fallbackTrim(meta.vocalist, meta.artist);

  final sheet1Payloads = <_ExcelRowPayload>[];
  final sheet2Payloads = <_ExcelRowPayload>[];

  for (final line in sortedLines) {
    final callCol = _formatCallFormula(line, presetMap);
    final lyricCol = _formatLyricColumn(line);
    final gtAlert = alertByLineId[line.id];

    final sheet1Flags = <String>[
      if (gtAlert != null) '（GT警报）',
      if (line.tailUpdraft) '（尾句上升气流）',
    ].join('');

    final sheet2FlagsList = <String>[];
    if (gtAlert != null) {
      final cue = (gtAlert.callTimingCue ?? '').trim();
      final note = gtAlert.note.trim();
      final details = <String>[
        if (cue.isNotEmpty) '时机: $cue',
        if (note.isNotEmpty) note,
      ];
      sheet2FlagsList.add(
        details.isEmpty ? '（GT警报）' : '（GT警报） ${details.join(' | ')}',
      );
    }
    if (line.tailUpdraft) {
      sheet2FlagsList.add('（尾句上升气流）');
    }
    final sheet2Flags = sheet2FlagsList.join('');
    final sheet2Aux = _formatAuxiliaryColumn(line, displayLayers);

    sheet1Payloads.add(
      _ExcelRowPayload(
        colA: callCol,
        colB: lyricCol,
        colC: sheet1Flags,
        colD: '',
      ),
    );
    sheet2Payloads.add(
      _ExcelRowPayload(
        colA: callCol,
        colB: lyricCol,
        colC: sheet2Flags,
        colD: sheet2Aux,
      ),
    );
  }

  List<double> computeWidths(List<_ExcelRowPayload> payloads, bool detailed) {
    var maxA = 16.0;
    var maxB = 30.0;
    var maxC = 16.0;
    var maxD = [
      composerDisplay,
      lyricistDisplay,
      tunerDisplay,
      vocalistDisplay,
    ].map(_measureExcelMaxLineWidth).fold<double>(0.0, (a, b) => a > b ? a : b);

    for (final item in payloads) {
      final wAVal = _measureExcelMaxLineWidth(item.colA);
      final wBVal = _measureExcelMaxLineWidth(item.colB);
      final wCVal = _measureExcelMaxLineWidth(item.colC);
      if (wAVal > maxA) maxA = wAVal;
      if (wBVal > maxB) maxB = wBVal;
      if (wCVal > maxC) maxC = wCVal;
      if (detailed) {
        final wDVal = _measureExcelMaxLineWidth(item.colD);
        if (wDVal > maxD) maxD = wDVal;
      }
    }

    final wA = _clampWidth(maxA + 6.0, 22.0, 68.0);
    var wB = _clampWidth(maxB + 6.0, 38.0, 72.0);
    final wC = _clampWidth(maxC + 6.0, detailed ? 26.0 : 22.0, 54.0);
    final wD = _clampWidth(
      maxD + 6.0,
      detailed ? 28.0 : 18.0,
      detailed ? 68.0 : 48.0,
    );

    final editorText = '编者：$editorDisplay';
    final editorNeeded = _measureExcelMaxLineWidth(editorText) + 6.0;
    if (wA + wB < editorNeeded) {
      final candidate = (editorNeeded - wA).ceilToDouble();
      wB = candidate > 80.0 ? 80.0 : candidate;
    }

    final titleText = meta.title.trim().isEmpty ? '未命名 Call 本' : meta.title.trim();
    final titleNeeded = _measureExcelMaxLineWidth(titleText) * 1.15 + 8.0;
    final totalW = wA + wB + wC + wD;
    if (totalW < titleNeeded) {
      final candidate = (wB + (titleNeeded - totalW)).ceilToDouble();
      wB = candidate > 88.0 ? 88.0 : candidate;
    }

    return [wA, wB, wC, wD];
  }

  List<_XlsxRow> buildHeaderRows(List<double> widths) {
    final wA = widths[0];
    final wB = widths[1];
    final wD = widths[3];
    final totalW = widths[0] + widths[1] + widths[2] + widths[3];
    final titleText = meta.title.trim().isEmpty ? '未命名 Call 本' : meta.title.trim();
    final editorText = '编者：$editorDisplay';
    final noteText = '编者语：$editorNoteDisplay';

    final titleLines = _estimateWrappedLines(
      titleText,
      (totalW - 4.0) * 0.85 < 20.0 ? 20.0 : (totalW - 4.0) * 0.85,
    );
    final titleHeight = (titleLines * 22.0 + 10.0) < 30.0
        ? 30.0
        : (titleLines * 22.0 + 10.0);

    final r2Height = _computeRowHeightPt([
      _WidthEntry(editorText, wA + wB),
      _WidthEntry(composerDisplay, wD),
    ]);
    final h3 = _computeRowHeightPt([_WidthEntry(lyricistDisplay, wD)]);
    final h4 = _computeRowHeightPt([_WidthEntry(tunerDisplay, wD)]);
    final h5 = _computeRowHeightPt([_WidthEntry(vocalistDisplay, wD)]);
    final noteLines = _estimateWrappedLines(noteText, wA + wB);
    final noteNeeded =
        (noteLines * 20.0 + 12.0) < 75.0 ? 75.0 : (noteLines * 20.0 + 12.0);
    final sum345 = h3 + h4 + h5;
    final extra = sum345 < noteNeeded ? ((noteNeeded - sum345) / 3.0).ceilToDouble() : 0.0;

    return [
      _XlsxRow(
        rowNumber: 1,
        heightPt: titleHeight,
        cells: [
          _XlsxCell.text('A', 1, titleText),
          const _XlsxCell.empty('B', 1),
          const _XlsxCell.empty('C', 1),
          const _XlsxCell.empty('D', 1),
        ],
      ),
      _XlsxRow(
        rowNumber: 2,
        heightPt: r2Height,
        cells: [
          _XlsxCell.text('A', 2, editorText),
          const _XlsxCell.empty('B', 2),
          const _XlsxCell.text('C', 3, '作曲：'),
          _XlsxCell.text('D', 2, composerDisplay),
        ],
      ),
      _XlsxRow(
        rowNumber: 3,
        heightPt: h3 + extra,
        cells: [
          _XlsxCell.text('A', 2, noteText),
          const _XlsxCell.empty('B', 2),
          const _XlsxCell.text('C', 3, '作词：'),
          _XlsxCell.text('D', 2, lyricistDisplay),
        ],
      ),
      _XlsxRow(
        rowNumber: 4,
        heightPt: h4 + extra,
        cells: [
          const _XlsxCell.empty('A', 2),
          const _XlsxCell.empty('B', 2),
          _XlsxCell.text('C', 3, hasTuner ? '调校：' : ''),
          _XlsxCell.text('D', 2, tunerDisplay),
        ],
      ),
      _XlsxRow(
        rowNumber: 5,
        heightPt: h5 + extra,
        cells: [
          const _XlsxCell.empty('A', 2),
          const _XlsxCell.empty('B', 2),
          const _XlsxCell.text('C', 3, '演唱：'),
          _XlsxCell.text('D', 2, vocalistDisplay),
        ],
      ),
    ];
  }

  List<_XlsxRow> buildBodyRows(
    List<_ExcelRowPayload> payloads,
    List<double> widths,
    bool detailed,
  ) {
    final rows = <_XlsxRow>[];
    var rowNum = 6;
    for (final item in payloads) {
      final heightPt = _computeRowHeightPt([
        _WidthEntry(item.colA, widths[0]),
        _WidthEntry(item.colB, widths[1]),
        _WidthEntry(item.colC, widths[2]),
        if (detailed) _WidthEntry(item.colD, widths[3]),
      ]);
      rows.add(
        _XlsxRow(
          rowNumber: rowNum++,
          heightPt: heightPt,
          cells: [
            _XlsxCell.maybeText('A', 4, item.colA),
            _XlsxCell.maybeText('B', 5, item.colB),
            _XlsxCell.maybeText('C', 6, item.colC),
            if (detailed) _XlsxCell.maybeText('D', 7, item.colD),
          ],
        ),
      );
    }
    return rows;
  }

  final sheet1Widths = computeWidths(sheet1Payloads, false);
  final sheet2Widths = computeWidths(sheet2Payloads, true);

  final sheet1Rows = <_XlsxRow>[
    ...buildHeaderRows(sheet1Widths),
    ...buildBodyRows(sheet1Payloads, sheet1Widths, false),
  ];
  final sheet2Rows = <_XlsxRow>[
    ...buildHeaderRows(sheet2Widths),
    ...buildBodyRows(sheet2Payloads, sheet2Widths, true),
  ];

  final sheet1Xml = _buildWorksheetXml(
    rows: sheet1Rows,
    colWidths: sheet1Widths,
    maxColLetter: 'D',
    selected: true,
    pool: pool,
  );
  final sheet2Xml = _buildWorksheetXml(
    rows: sheet2Rows,
    colWidths: sheet2Widths,
    maxColLetter: 'D',
    selected: false,
    pool: pool,
  );

  final entries = <_ZipSourceEntry>[
    _ZipSourceEntry.utf8('[Content_Types].xml', _contentTypesXml()),
    _ZipSourceEntry.utf8('_rels/.rels', _rootRelsXml()),
    _ZipSourceEntry.utf8('xl/workbook.xml', _workbookXml()),
    _ZipSourceEntry.utf8('xl/_rels/workbook.xml.rels', _workbookRelsXml()),
    _ZipSourceEntry.utf8('xl/styles.xml', _stylesXml()),
    _ZipSourceEntry.utf8('xl/sharedStrings.xml', pool.toXml()),
    _ZipSourceEntry.utf8('xl/worksheets/sheet1.xml', sheet1Xml),
    _ZipSourceEntry.utf8('xl/worksheets/sheet2.xml', sheet2Xml),
  ];

  return _encodeZipArchive(entries);
}

class _ExcelRowPayload {
  const _ExcelRowPayload({
    required this.colA,
    required this.colB,
    required this.colC,
    required this.colD,
  });

  final String colA;
  final String colB;
  final String colC;
  final String colD;
}

class _WidthEntry {
  const _WidthEntry(this.text, this.width);

  final String text;
  final double width;
}

String _fallbackTrim(String raw, String fallback) {
  final clean = raw.trim();
  if (clean.isNotEmpty) return clean;
  return fallback.trim();
}

bool _isWideExcelChar(int cp) =>
    (cp >= 0x1100 && cp <= 0x115F) ||
    cp == 0x2329 ||
    cp == 0x232A ||
    (cp >= 0x2E80 && cp <= 0x303E) ||
    (cp >= 0x3040 && cp <= 0x33FF) ||
    (cp >= 0x3400 && cp <= 0x4DBF) ||
    (cp >= 0x4E00 && cp <= 0xA4CF) ||
    (cp >= 0xAC00 && cp <= 0xD7AF) ||
    (cp >= 0xF900 && cp <= 0xFAFF) ||
    (cp >= 0xFE10 && cp <= 0xFE6F) ||
    (cp >= 0xFF01 && cp <= 0xFF60) ||
    (cp >= 0xFFE0 && cp <= 0xFFE6) ||
    cp >= 0x1F000;

double _measureExcelLineWidth(String text) {
  var width = 0.0;
  for (final cp in text.runes) {
    if (_isWideExcelChar(cp)) {
      width += 2.25;
    } else if ((cp >= 0x41 && cp <= 0x5A) ||
        cp == 0x40 ||
        cp == 0xD7) {
      width += 1.3;
    } else {
      width += 1.1;
    }
  }
  return width;
}

double _measureExcelMaxLineWidth(String text) {
  if (text.isEmpty) return 0.0;
  var maxW = 0.0;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final w = _measureExcelLineWidth(line);
    if (w > maxW) maxW = w;
  }
  return maxW;
}

int _estimateWrappedLines(String text, double availableColWidth) {
  if (text.isEmpty) return 1;
  final usable = (availableColWidth - 4.0) < 8.0 ? 8.0 : (availableColWidth - 4.0);
  var total = 0;
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final w = _measureExcelLineWidth(rawLine);
    final wrapped = (w / usable).ceil();
    total += wrapped < 1 ? 1 : wrapped;
  }
  return total < 1 ? 1 : total;
}

double _computeRowHeightPt(List<_WidthEntry> entries) {
  var maxLines = 1;
  for (final e in entries) {
    if (e.text.isEmpty) continue;
    final lines = _estimateWrappedLines(e.text, e.width);
    if (lines > maxLines) maxLines = lines;
  }
  final computed = maxLines * 20.0 + 8.0;
  return computed < 25.0 ? 25.0 : computed;
}

double _clampWidth(double val, double min, double max) {
  final ceiled = val.ceilToDouble();
  if (ceiled < min) return min;
  if (ceiled > max) return max;
  return ceiled;
}

String _formatCallFormula(LyricLine line, Map<String, CallPreset> presetMap) {
  final tokens = <String>[];
  for (final tag in line.calls) {
    final preset = presetMap[tag.presetId];
    if (preset == null) continue;
    final suffix = (tag.suffix ?? '').trim();
    tokens.add(suffix.isEmpty ? preset.label : '${preset.label}$suffix');
  }
  final shout = line.customShout.trim();
  if (shout.isNotEmpty) {
    tokens.add(shout);
  }
  for (final aligned in line.alignedCalls) {
    final t = aligned.text.trim();
    if (t.isNotEmpty) {
      tokens.add(t);
    }
  }
  if (tokens.isEmpty) return '';
  return '（${tokens.join(' / ')}）';
}

String _formatLyricColumn(LyricLine line) {
  final clean = line.text.original.trim();
  if (line.kind.isSection) {
    return clean.isEmpty ? '【${line.kind.zhLabel}】' : clean;
  }
  return line.text.original;
}

String _formatAuxiliaryColumn(LyricLine line, DisplayLayers layers) {
  if (line.kind.isSection) return '';
  final parts = <String>[];
  if (layers.showRuby &&
      line.text.ruby != null &&
      line.text.ruby!.contains('<ruby')) {
    final segments = parseRubySegments(line.text.ruby, line.text.original);
    final hasRt = segments.any((s) => s.rt != null && s.rt!.isNotEmpty);
    if (hasRt) {
      final buffer = StringBuffer();
      for (final seg in segments) {
        if (seg.rt == null || seg.rt!.isEmpty) {
          buffer.write(seg.base);
        } else {
          buffer.write('${seg.base}(${seg.rt})');
        }
      }
      final rubyText = buffer.toString().trim();
      if (rubyText.isNotEmpty) parts.add(rubyText);
    }
  }
  if (layers.showRomaji && (line.text.romaji ?? '').trim().isNotEmpty) {
    parts.add(line.text.romaji!.trim());
  }
  if (layers.showTranslation &&
      (line.text.translation ?? '').trim().isNotEmpty) {
    parts.add(line.text.translation!.trim());
  }
  return parts.join('\n');
}

class _SharedStringPool {
  final Map<String, int> _indexByValue = <String, int>{};
  final List<String> _values = <String>[];

  int intern(String raw) {
    final sanitized = _stripInvalidXmlChars(raw);
    return _indexByValue.putIfAbsent(sanitized, () {
      final idx = _values.length;
      _values.add(sanitized);
      return idx;
    });
  }

  String toXml() {
    final buf = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
        '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'count="${_values.length}" uniqueCount="${_values.length}">',
      );
    for (final v in _values) {
      buf
        ..write('<si><t xml:space="preserve">')
        ..write(_escapeXml(v))
        ..write('</t></si>');
    }
    buf.write('</sst>');
    return buf.toString();
  }
}

class _XlsxCell {
  const _XlsxCell.text(this.colLetter, this.styleIndex, this.value);

  const _XlsxCell.empty(this.colLetter, this.styleIndex) : value = null;

  factory _XlsxCell.maybeText(
    String colLetter,
    int styleIndex,
    String text,
  ) =>
      text.isEmpty
          ? _XlsxCell.empty(colLetter, styleIndex)
          : _XlsxCell.text(colLetter, styleIndex, text);

  final String colLetter;
  final int styleIndex;
  final String? value;
}

class _XlsxRow {
  const _XlsxRow({
    required this.rowNumber,
    required this.heightPt,
    required this.cells,
  });

  final int rowNumber;
  final double heightPt;
  final List<_XlsxCell> cells;
}

String _buildWorksheetXml({
  required List<_XlsxRow> rows,
  required List<double> colWidths,
  required String maxColLetter,
  required bool selected,
  required _SharedStringPool pool,
}) {
  final lastRow = rows.isEmpty ? 5 : rows.last.rowNumber;
  final buf = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write(
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    )
    ..write('<dimension ref="A1:$maxColLetter$lastRow"/>')
    ..write('<sheetViews>')
    ..write(
      '<sheetView${selected ? ' tabSelected="1"' : ''} workbookViewId="0"/>',
    )
    ..write('</sheetViews>')
    ..write('<sheetFormatPr defaultRowHeight="21"/>')
    ..write('<cols>');

  for (var i = 0; i < colWidths.length; i++) {
    final idx = i + 1;
    buf.write(
      '<col min="$idx" max="$idx" width="${colWidths[i].toStringAsFixed(2)}" customWidth="1"/>',
    );
  }
  buf
    ..write('</cols>')
    ..write('<sheetData>');

  for (final row in rows) {
    final spanEnd = row.cells.length;
    buf.write(
      '<row r="${row.rowNumber}" spans="1:$spanEnd" '
      'ht="${row.heightPt.toStringAsFixed(1)}" customHeight="1">',
    );
    for (final cell in row.cells) {
      final coord = '${cell.colLetter}${row.rowNumber}';
      if (cell.value == null || cell.value!.isEmpty) {
        buf.write('<c r="$coord" s="${cell.styleIndex}"/>');
      } else {
        final ssIdx = pool.intern(cell.value!);
        buf.write('<c r="$coord" s="${cell.styleIndex}" t="s"><v>$ssIdx</v></c>');
      }
    }
    buf.write('</row>');
  }

  buf
    ..write('</sheetData>')
    ..write('<mergeCells count="3">')
    ..write('<mergeCell ref="A1:D1"/>')
    ..write('<mergeCell ref="A2:B2"/>')
    ..write('<mergeCell ref="A3:B5"/>')
    ..write('</mergeCells>')
    ..write('</worksheet>');
  return buf.toString();
}

String _contentTypesXml() =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    '<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
    '</Types>';

String _rootRelsXml() =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    '</Relationships>';

String _workbookXml() =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    '<sheets>'
    '<sheet name="Callbook" sheetId="1" r:id="rId1"/>'
    '<sheet name="详细版" sheetId="2" r:id="rId2"/>'
    '</sheets>'
    '</workbook>';

String _workbookRelsXml() =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>'
    '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    '<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>'
    '</Relationships>';

String _stylesXml() =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<fonts count="4">'
    '<font><sz val="11"/><name val="Microsoft YaHei UI"/><charset val="134"/></font>'
    '<font><b/><sz val="13"/><name val="Microsoft YaHei UI"/><charset val="134"/></font>'
    '<font><b/><sz val="11"/><name val="Microsoft YaHei UI"/><charset val="134"/></font>'
    '<font><sz val="11"/><color rgb="FF66CCFF"/><name val="Microsoft YaHei UI"/><charset val="134"/></font>'
    '</fonts>'
    '<fills count="2">'
    '<fill><patternFill patternType="none"/></fill>'
    '<fill><patternFill patternType="gray125"/></fill>'
    '</fills>'
    '<borders count="1">'
    '<border><left/><right/><top/><bottom/><diagonal/></border>'
    '</borders>'
    '<cellStyleXfs count="1">'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>'
    '</cellStyleXfs>'
    '<cellXfs count="8">'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf>'
    '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf>'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf>'
    '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="right" vertical="center" wrapText="1"/></xf>'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf>'
    '</cellXfs>'
    '<cellStyles count="1">'
    '<cellStyle name="Normal" xfId="0" builtinId="0"/>'
    '</cellStyles>'
    '</styleSheet>';

String _stripInvalidXmlChars(String input) {
  final buf = StringBuffer();
  for (final code in input.runes) {
    if (code == 0x9 ||
        code == 0xA ||
        code == 0xD ||
        (code >= 0x20 && code <= 0xD7FF) ||
        (code >= 0xE000 && code <= 0xFFFD) ||
        (code >= 0x10000 && code <= 0x10FFFF)) {
      buf.writeCharCode(code);
    }
  }
  return buf.toString();
}

String _escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

class _ZipSourceEntry {
  _ZipSourceEntry.utf8(this.name, String content)
      : rawBytes = Uint8List.fromList(utf8.encode(content));

  final String name;
  final Uint8List rawBytes;
}

class _CentralDirRecord {
  const _CentralDirRecord({
    required this.nameBytes,
    required this.crc32,
    required this.compressedLength,
    required this.uncompressedLength,
    required this.localHeaderOffset,
  });

  final Uint8List nameBytes;
  final int crc32;
  final int compressedLength;
  final int uncompressedLength;
  final int localHeaderOffset;
}

Uint8List _encodeZipArchive(List<_ZipSourceEntry> entries) {
  final out = BytesBuilder(copy: false);
  final records = <_CentralDirRecord>[];
  final codec = ZLibCodec(raw: true);

  for (final entry in entries) {
    final nameBytes = Uint8List.fromList(utf8.encode(entry.name));
    final raw = entry.rawBytes;
    final compressed = Uint8List.fromList(codec.encode(raw));
    final crc = _computeCrc32(raw);
    final localOffset = out.length;

    final localHeader = ByteData(30);
    localHeader.setUint32(0, 0x04034B50, Endian.little);
    localHeader.setUint16(4, 20, Endian.little);
    localHeader.setUint16(6, 0x0800, Endian.little);
    localHeader.setUint16(8, 8, Endian.little);
    localHeader.setUint16(10, 0, Endian.little);
    localHeader.setUint16(12, 0x5421, Endian.little);
    localHeader.setUint32(14, crc, Endian.little);
    localHeader.setUint32(18, compressed.length, Endian.little);
    localHeader.setUint32(22, raw.length, Endian.little);
    localHeader.setUint16(26, nameBytes.length, Endian.little);
    localHeader.setUint16(28, 0, Endian.little);

    out.add(localHeader.buffer.asUint8List());
    out.add(nameBytes);
    out.add(compressed);

    records.add(
      _CentralDirRecord(
        nameBytes: nameBytes,
        crc32: crc,
        compressedLength: compressed.length,
        uncompressedLength: raw.length,
        localHeaderOffset: localOffset,
      ),
    );
  }

  final cdStartOffset = out.length;
  for (final rec in records) {
    final cd = ByteData(46);
    cd.setUint32(0, 0x02014B50, Endian.little);
    cd.setUint16(4, 20, Endian.little);
    cd.setUint16(6, 20, Endian.little);
    cd.setUint16(8, 0x0800, Endian.little);
    cd.setUint16(10, 8, Endian.little);
    cd.setUint16(12, 0, Endian.little);
    cd.setUint16(14, 0x5421, Endian.little);
    cd.setUint32(16, rec.crc32, Endian.little);
    cd.setUint32(20, rec.compressedLength, Endian.little);
    cd.setUint32(24, rec.uncompressedLength, Endian.little);
    cd.setUint16(28, rec.nameBytes.length, Endian.little);
    cd.setUint16(30, 0, Endian.little);
    cd.setUint16(32, 0, Endian.little);
    cd.setUint16(34, 0, Endian.little);
    cd.setUint16(36, 0, Endian.little);
    cd.setUint32(38, 0, Endian.little);
    cd.setUint32(42, rec.localHeaderOffset, Endian.little);

    out.add(cd.buffer.asUint8List());
    out.add(rec.nameBytes);
  }
  final cdSize = out.length - cdStartOffset;

  final eocd = ByteData(22);
  eocd.setUint32(0, 0x06054B50, Endian.little);
  eocd.setUint16(4, 0, Endian.little);
  eocd.setUint16(6, 0, Endian.little);
  eocd.setUint16(8, records.length, Endian.little);
  eocd.setUint16(10, records.length, Endian.little);
  eocd.setUint32(12, cdSize, Endian.little);
  eocd.setUint32(16, cdStartOffset, Endian.little);
  eocd.setUint16(20, 0, Endian.little);
  out.add(eocd.buffer.asUint8List());

  return out.toBytes();
}

final Uint32List _crc32Table = _buildCrc32Table();

Uint32List _buildCrc32Table() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var j = 0; j < 8; j++) {
      if ((c & 1) != 0) {
        c = 0xEDB88320 ^ (c >>> 1);
      } else {
        c = c >>> 1;
      }
    }
    table[i] = c;
  }
  return table;
}

int _computeCrc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (var i = 0; i < bytes.length; i++) {
    crc = _crc32Table[(crc ^ bytes[i]) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
