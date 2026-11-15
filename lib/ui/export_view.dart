import 'dart:io' show File, Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../models/callbook_models.dart';
import '../state/callbook_controller.dart';
import '../utils/lrc_ruby_parser.dart';
import '../utils/xlsx_export.dart';
import 'widgets/call_badge_pill.dart';
import 'widgets/callbook_glyphs.dart';
import 'widgets/ruby_lyric_text.dart';

class ExportView extends StatefulWidget {
  const ExportView({super.key, required this.controller});

  final CallbookController controller;

  @override
  State<ExportView> createState() => _ExportViewState();
}

class _ExportViewState extends State<ExportView> {
  final GlobalKey _sheetKey = GlobalKey();
  bool _exportingPng = false;
  bool _exportingXlsx = false;

  Future<bool> _promptEditorInfoBeforeExport() async {
    final c = widget.controller;
    final editorNameCtrl = TextEditingController(
      text: c.project.meta.editorName,
    );
    final editorNoteCtrl = TextEditingController(
      text: c.project.meta.editorNote,
    );
    try {
      final ok = await showFloatingDialog<bool>(
        context: context,
        child: Builder(
          builder: (dialogCtx) => AlertDialog(
            title: '确认编者与编者语',
            hasFields: true,
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(true),
                child: const Text('确认并导出'),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: editorNameCtrl,
                  decoration: const InputDecoration(
                    hintText: '编者（你的圈名/cn）',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: editorNoteCtrl,
                  maxLines: 3,
                  minLines: 2,
                  decoration: const InputDecoration(
                    hintText: '编者语（例如：间奏 GT 警报处请注意跟着喊出声）',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (ok != true || !mounted) return false;
      c.updateMeta(
        editorName: editorNameCtrl.text.trim(),
        editorNote: editorNoteCtrl.text.trim(),
      );
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      return mounted;
    } finally {
      editorNameCtrl.dispose();
      editorNoteCtrl.dispose();
    }
  }

  String _safeFileStem(String rawTitle) {
    final stem = rawTitle
        .replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return stem.isEmpty ? 'callbook' : stem;
  }

  Future<void> _exportQuickRefPng() async {
    if (_exportingPng) return;
    if (!await _promptEditorInfoBeforeExport()) return;
    if (!mounted) return;
    setState(() => _exportingPng = true);
    final c = widget.controller;
    OverlayEntry? offscreenEntry;
    try {
      if (kIsWeb) {
        c.setStatus('Web 端请直接使用浏览器打印 / 导出功能');
        return;
      }

      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) {
        c.setStatus('当前环境不支持离屏视图挂载');
        return;
      }

      final presetMap = {for (final p in c.allPresets) p.id: p};
      final lines = c.sortedLines;
      final fontFamily = c.useGoogleSans ? 'GoogleSans' : null;
      final uniformCallColWidth = _measureUniformCallColumnWidth(
        lines,
        presetMap,
        fontFamily: fontFamily,
        minWidth: 116.0,
        maxWidth: double.infinity,
      );
      final measuredExportWidth = _measureUnconstrainedExportWidth(
        controller: c,
        lines: lines,
        presetMap: presetMap,
        callColWidth: uniformCallColWidth,
        fontFamily: fontFamily,
      );

      final offscreenKey = GlobalKey();
      final baseMq = MediaQuery.of(context);
      offscreenEntry = OverlayEntry(
        builder: (_) => Positioned(
          left: -50000,
          top: 0,
          child: IgnorePointer(
            child: MediaQuery(
              data: baseMq.copyWith(
                size: Size(measuredExportWidth, 4000),
                textScaler: TextScaler.noScaling,
              ),
              child: SizedBox(
                width: measuredExportWidth,
                child: RepaintBoundary(
                  key: offscreenKey,
                  child: _QuickRefSheet(
                    controller: c,
                    presetMap: presetMap,
                    forExport: true,
                    uniformCallColWidth: uniformCallColWidth,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      overlay.insert(offscreenEntry);

      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;

      final ctx = offscreenKey.currentContext;
      final ro = ctx?.findRenderObject();
      if (ro is! RenderRepaintBoundary) {
        c.setStatus('离屏速查卡尚未完成渲染，请稍后再试');
        return;
      }

      final image = await ro.toImage(pixelRatio: 2.5);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        c.setStatus('PNG 编码失败');
        return;
      }

      final bytes = byteData.buffer.asUint8List();
      final dir = await getTemporaryDirectory();
      final outPath =
          '${dir.path}${Platform.pathSeparator}${_safeFileStem(c.project.meta.title)}_callbook.png';
      final file = File(outPath);
      await file.writeAsBytes(bytes, flush: true);

      try {
        await Share.shareXFiles(
          [XFile(file.path)],
          text: '${c.project.meta.title} · Call 速查卡',
        );
      } catch (_) {
        // Desktop platforms without native share sheet still keep the written file.
      }
      c.setStatus('高清速查卡 PNG 已生成：$outPath');
    } catch (err) {
      c.setStatus('导出 PNG 失败：$err');
    } finally {
      offscreenEntry?.remove();
      if (mounted) setState(() => _exportingPng = false);
    }
  }

  Future<void> _exportXlsx() async {
    if (_exportingXlsx) return;
    if (!await _promptEditorInfoBeforeExport()) return;
    if (!mounted) return;
    setState(() => _exportingXlsx = true);
    final c = widget.controller;
    try {
      if (kIsWeb) {
        c.setStatus('Web 端请使用网页端 Excel 导出按钮');
        return;
      }
      final bytes = buildCallBookXlsxBytes(
        c.project,
        c.allPresets,
        displayLayers: c.displayLayers,
      );
      final dir = await getTemporaryDirectory();
      final outPath =
          '${dir.path}${Platform.pathSeparator}${_safeFileStem(c.project.meta.title)}_callbook.xlsx';
      final file = File(outPath);
      await file.writeAsBytes(bytes, flush: true);

      try {
        await Share.shareXFiles(
          [XFile(file.path)],
          text: '${c.project.meta.title} · Call 本 Excel (.xlsx)',
        );
      } catch (_) {
        // Desktop platforms without native share sheet still keep the written file.
      }
      c.setStatus('Excel (.xlsx) 已生成：$outPath');
    } catch (err) {
      c.setStatus('导出 Excel 失败：$err');
    } finally {
      if (mounted) setState(() => _exportingXlsx = false);
    }
  }

  Future<void> _copyJson() async {
    if (!await _promptEditorInfoBeforeExport()) return;
    final c = widget.controller;
    await Clipboard.setData(ClipboardData(text: c.project.toPrettyJson()));
    c.setStatus('已复制完整 CallBook JSON 工程到剪贴板');
  }

  String _buildMarkdown() {
    final c = widget.controller;
    final meta = c.project.meta;
    final presetMap = {for (final p in c.allPresets) p.id: p};
    final creditParts = <String>[
      '艺人：${_formatCreditValue(meta.artist)}',
      '作曲：${_formatCreditValue(meta.composer)}',
      '作词：${_formatCreditValue(meta.lyricist)}',
      '演唱：${_formatCreditValue(meta.vocalist, fallback: meta.artist)}',
      if (meta.showTuner) '调教：${_formatCreditValue(meta.tuner)}',
    ];
    final editorDisplay = meta.editorName.trim().isEmpty
        ? '未署名'
        : meta.editorName.trim();
    final noteDisplay = meta.editorNote.trim();

    final buf = StringBuffer()
      ..writeln('# ${meta.title}')
      ..writeln('> ${creditParts.join(' · ')}')
      ..writeln(
        noteDisplay.isEmpty
            ? '> 编者：$editorDisplay'
            : '> 编者：$editorDisplay ｜ 编者语：$noteDisplay',
      )
      ..writeln()
      ..writeln('## 歌词与 Call 速查时间轴');

    for (final line in c.sortedLines) {
      final tags = [
        for (final t in line.calls)
          if (presetMap[t.presetId] case final p?)
            '`${p.label}${t.suffix != null && t.suffix!.isNotEmpty ? " ${t.suffix}" : ""}`',
      ];
      final callColumn = tags.isEmpty ? '`—`' : tags.join(' ');
      final gtAlert = c.getAlertForLine(line.id);
      final cue = (gtAlert?.callTimingCue ?? '').trim();
      final gtParts = <String>[
        if (cue.isNotEmpty) '时机：$cue',
        if (gtAlert != null && gtAlert.note.trim().isNotEmpty)
          gtAlert.note.trim(),
      ];
      final gtSegment = gtAlert == null
          ? ''
          : ' 【GT 警报${gtParts.isNotEmpty ? " · ${gtParts.join(' · ')}" : ""}】';
      final shoutSegment = line.customShout.trim().isEmpty
          ? ''
          : ' 【${line.customShout.trim()}】';
      final updraftSegment = line.tailUpdraft ? ' 【尾句上升气流】' : '';
      final mainLineText = line.kind.isSection
          ? (line.text.original.trim().isEmpty
                ? '【${line.kind.zhLabel}】'
                : line.text.original.trim())
          : line.text.original;
      buf.writeln('- [$callColumn]$gtSegment$shoutSegment');
      buf.writeln('  $mainLineText$updraftSegment');
      if (!line.kind.isSection &&
          line.text.translation != null &&
          line.text.translation!.trim().isNotEmpty) {
        buf.writeln('  _${line.text.translation}_');
      }
    }
    return buf.toString();
  }

  Future<void> _copyMarkdown() async {
    if (!await _promptEditorInfoBeforeExport()) return;
    final c = widget.controller;
    await Clipboard.setData(ClipboardData(text: _buildMarkdown()));
    c.setStatus('已复制 Markdown Call 本到剪贴板');
  }

  Future<void> _shareMarkdown() async {
    if (!await _promptEditorInfoBeforeExport()) return;
    try {
      await Share.share(
        _buildMarkdown(),
        subject: '${widget.controller.project.meta.title} · Live Call 本',
      );
    } catch (_) {
      await _copyMarkdownAfterPrompt();
    }
  }

  Future<void> _copyMarkdownAfterPrompt() async {
    final c = widget.controller;
    await Clipboard.setData(ClipboardData(text: _buildMarkdown()));
    c.setStatus('已复制 Markdown Call 本到剪贴板');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = context.colorScheme;
    final bottomInset = BottomInsetScope.of(context);
    final presetMap = {for (final p in c.allPresets) p.id: p};
    final fontFamily = c.useGoogleSans ? 'GoogleSans' : null;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 20 + bottomInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            inert: true,
            radius: 22,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '演出现场速查卡 · 多格式导出中心',
                  style: AppTextStyle.headline
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onSurface),
                ),
                const SizedBox(height: 6),
                Text(
                  '${c.statusMessage} · 支持 2.5x 无裁切高清 PNG 长图、双工作表 Excel (.xlsx)、JSON 工程与 Markdown。',
                  style: AppTextStyle.subheadline.of(context).copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _exportingPng ? null : _exportQuickRefPng,
                      icon: const GlyphIcon(CallbookGlyphs.exportCard, size: 17),
                      label: Text(_exportingPng ? '渲染中...' : '导出 / 分享高清 PNG'),
                    ),
                    TonalButton(
                      size: TonalButtonSize.compact,
                      label: _exportingXlsx ? '生成表格中...' : '导出 Excel (.xlsx)',
                      onPressed: _exportingXlsx ? null : _exportXlsx,
                    ),
                    TonalButton(
                      size: TonalButtonSize.compact,
                      glyph: Glyphs.copy,
                      label: '复制 Markdown',
                      onPressed: _copyMarkdown,
                    ),
                    TonalButton(
                      size: TonalButtonSize.compact,
                      label: '分享文本',
                      onPressed: _shareMarkdown,
                    ),
                    TonalButton(
                      size: TonalButtonSize.compact,
                      label: '复制 JSON 工程',
                      onPressed: _copyJson,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          RepaintBoundary(
            key: _sheetKey,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final callColWidth = _measureUniformCallColumnWidth(
                  c.sortedLines,
                  presetMap,
                  fontFamily: fontFamily,
                  minWidth: constraints.maxWidth >= 560 ? 116.0 : 88.0,
                  maxWidth: constraints.maxWidth >= 560 ? 220.0 : 128.0,
                );
                return _QuickRefSheet(
                  controller: c,
                  presetMap: presetMap,
                  forExport: false,
                  uniformCallColWidth: callColWidth,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickRefSheet extends StatelessWidget {
  const _QuickRefSheet({
    required this.controller,
    required this.presetMap,
    required this.forExport,
    required this.uniformCallColWidth,
  });

  final CallbookController controller;
  final Map<String, CallPreset> presetMap;
  final bool forExport;
  final double uniformCallColWidth;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final lines = c.sortedLines;
    final meta = c.project.meta;
    final fontFamily = c.useGoogleSans ? 'GoogleSans' : null;
    final editorDisplay = meta.editorName.trim().isEmpty
        ? '未署名'
        : meta.editorName.trim();
    final editorNoteDisplay = meta.editorNote.trim().isEmpty
        ? '暂无编者语'
        : meta.editorNote.trim();
    final gtCount = lines.where((l) => c.getAlertForLine(l.id) != null).length;
    final updraftCount = lines.where((l) => l.tailUpdraft).length;

    return DefaultTextStyle(
      style: TextStyle(
        fontFamily: fontFamily,
        color: const Color(0xFF0F172A),
      ),
      child: Container(
        padding: const EdgeInsets.all(22),
        decoration: const ShapeDecoration(
          color: Color(0xFFFFFFFF),
          shape: RoundedSuperellipseBorder(
            borderRadius: AppRadius.xl,
            side: BorderSide(color: Color(0xFFE2E8F0)),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wideSheet = forExport || constraints.maxWidth >= 560;

            final titleAndEditor = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'LIVE CALL QUICK-REF SHEET',
                  style: TextStyle(
                    fontFamily: 'GoogleSans',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Color(0xFF0061FF),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  meta.title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  meta.artist,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF475569),
                  ),
                ),
                const SizedBox(height: 6),
                _ExportPill(
                  label: '编者：$editorDisplay',
                  background: const Color(0xFFF1F5F9),
                  foreground: const Color(0xFF334155),
                  fontFamily: fontFamily,
                  fontSize: 12,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3,
                  ),
                ),
              ],
            );

            final editorNoteBox = Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '编者语',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    editorNoteDisplay,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: meta.editorNote.trim().isEmpty
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF1E293B),
                    ),
                  ),
                ],
              ),
            );

            final creditsBox = Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: const ShapeDecoration(
                color: Color(0xFFF1F5F9),
                shape: AppShape.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _SheetCreditLine(
                    label: '作曲',
                    value: _formatCreditValue(meta.composer),
                  ),
                  const SizedBox(height: 2),
                  _SheetCreditLine(
                    label: '作词',
                    value: _formatCreditValue(meta.lyricist),
                  ),
                  const SizedBox(height: 2),
                  _SheetCreditLine(
                    label: '演唱',
                    value: _formatCreditValue(
                      meta.vocalist,
                      fallback: meta.artist,
                    ),
                  ),
                  if (meta.showTuner) ...[
                    const SizedBox(height: 2),
                    _SheetCreditLine(
                      label: '调教',
                      value: _formatCreditValue(meta.tuner),
                    ),
                  ],
                ],
              ),
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wideSheet)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 5, child: titleAndEditor),
                      const SizedBox(width: 12),
                      Expanded(flex: 4, child: editorNoteBox),
                      const SizedBox(width: 12),
                      creditsBox,
                    ],
                  )
                else ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: titleAndEditor),
                      const SizedBox(width: 10),
                      creditsBox,
                    ],
                  ),
                  const SizedBox(height: 10),
                  editorNoteBox,
                ],
                const SizedBox(height: 14),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final p in c.allPresets)
                      CallBadgePill(preset: p, compact: true),
                    _ExportPill(
                      label: 'GT 警报',
                      background: const Color(0xFFF59E0B),
                      foreground: const Color(0xFF000000),
                      fontFamily: fontFamily,
                    ),
                    _ExportPill(
                      label: '尾句上升气流',
                      background: const Color(0xFFE0F2FE),
                      foreground: const Color(0xFF0369A1),
                      borderColor: const Color(0xFF38BDF8),
                      fontFamily: fontFamily,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                for (final line in lines)
                  _QuickRefLineRow(
                    line: line,
                    gtAlert: c.getAlertForLine(line.id),
                    presetMap: presetMap,
                    displayLayers: c.displayLayers,
                    callColWidth: uniformCallColWidth,
                    forExport: forExport,
                    fontFamily: fontFamily,
                  ),
                const SizedBox(height: 10),
                Text(
                  '共 ${lines.length} 句歌词 · $gtCount 句 GT 警报${updraftCount > 0 ? ' · $updraftCount 句尾句上升气流' : ''}',
                  textAlign: TextAlign.right,
                  softWrap: forExport ? false : true,
                  maxLines: forExport ? 1 : null,
                  style: TextStyle(
                    fontFamily: fontFamily ?? 'GoogleSans',
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF64748B),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _QuickRefLineRow extends StatelessWidget {
  const _QuickRefLineRow({
    required this.line,
    required this.gtAlert,
    required this.presetMap,
    required this.displayLayers,
    required this.callColWidth,
    required this.forExport,
    required this.fontFamily,
  });

  final LyricLine line;
  final GtAlert? gtAlert;
  final Map<String, CallPreset> presetMap;
  final DisplayLayers displayLayers;
  final double callColWidth;
  final bool forExport;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    final isSec = line.kind.isSection;
    final cue = (gtAlert?.callTimingCue ?? '').trim();
    final gtNote = (gtAlert?.note ?? '').trim();
    final shout = line.customShout.trim();

    final secColor = switch (line.kind) {
      LyricLineKind.intro => const Color(0xFF0284C7),
      LyricLineKind.interlude => const Color(0xFF4F46E5),
      LyricLineKind.outro => const Color(0xFF7C3AED),
      LyricLineKind.lyric => const Color(0xFF4F46E5),
    };
    final secBg = switch (line.kind) {
      LyricLineKind.intro => const Color(0xFFF0F9FF),
      LyricLineKind.interlude => const Color(0xFFF8FAFF),
      LyricLineKind.outro => const Color(0xFFFAF5FF),
      LyricLineKind.lyric => const Color(0xFFF8FAFF),
    };

    // Compensate border left thickness so inner Call column & lyric start X
    // stay pixel-identical across section, GT, and regular lyric rows.
    final leftBorderThickness = gtAlert != null
        ? 1.4
        : isSec
        ? 3.0
        : 0.0;
    final rowPadding = EdgeInsets.fromLTRB(
      12.0 - leftBorderThickness,
      10,
      12.0,
      10,
    );

    final sectionDisplayTitle = line.text.original.trim().isEmpty
        ? '【${line.kind.zhLabel}】'
        : line.text.original.trim();

    final gtBadgeLabel = cue.isNotEmpty ? 'GT 警报 · 时机：$cue' : 'GT 警报';

    final topAlertStripWidgets = <Widget>[
      if (gtAlert != null)
        _ExportPill(
          label: gtBadgeLabel,
          background: const Color(0xFFF59E0B),
          foreground: const Color(0xFF000000),
          fontFamily: fontFamily,
        ),
      if (gtAlert != null && gtNote.isNotEmpty)
        Text(
          gtNote,
          softWrap: forExport ? false : true,
          maxLines: forExport ? 1 : null,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF92400E),
          ),
        ),
      if (shout.isNotEmpty && !isSec)
        _ExportPill(
          label: shout,
          background: const Color(0xFFE0E7FF),
          foreground: const Color(0xFF3730A3),
          fontFamily: fontFamily,
        ),
    ];

    Widget buildMainTextWithTrailing() {
      if (isSec) {
        final sectionChildren = <Widget>[
          Text(
            sectionDisplayTitle,
            softWrap: forExport ? false : true,
            maxLines: forExport ? 1 : null,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: secColor,
            ),
          ),
          if (shout.isNotEmpty)
            _ExportPill(
              label: shout,
              background: const Color(0xFFE0E7FF),
              foreground: const Color(0xFF3730A3),
              fontFamily: fontFamily,
            ),
          if (line.tailUpdraft) _TailUpdraftExportPill(fontFamily: fontFamily),
        ];

        if (forExport) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < sectionChildren.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                sectionChildren[i],
              ],
            ],
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: sectionChildren,
        );
      }

      final lyricWidget = RubyLyricText(
        original: line.text.original,
        rubyHtml: line.text.ruby,
        showRuby: displayLayers.showRuby,
        softWrap: forExport ? false : null,
        maxLines: forExport ? 1 : null,
        baseStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF0F172A),
        ),
        rtStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 10,
          color: const Color(0xFF64748B),
        ),
      );

      if (!line.tailUpdraft) return lyricWidget;
      final updraftPill = _TailUpdraftExportPill(fontFamily: fontFamily);
      if (forExport) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [lyricWidget, const SizedBox(width: 8), updraftPill],
        );
      }
      return Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [lyricWidget, updraftPill],
      );
    }

    return Container(
      margin: (gtAlert != null || isSec)
          ? const EdgeInsets.symmetric(vertical: 3)
          : EdgeInsets.zero,
      padding: rowPadding,
      decoration: gtAlert != null
          ? BoxDecoration(
              color: const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFF59E0B),
                width: 1.4,
              ),
            )
          : isSec
          ? BoxDecoration(
              color: secBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: secColor.withValues(alpha: 0.45),
                width: 1.2,
              ),
            )
          : const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
            ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: callColWidth,
            child: line.calls.isEmpty
                ? const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Text(
                      '—',
                      style: TextStyle(
                        fontFamily: 'GoogleSans',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  )
                : Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final tag in line.calls)
                        if (presetMap[tag.presetId] case final CallPreset p?)
                          CallBadgePill(
                            preset: p,
                            suffix: tag.suffix,
                            compact: true,
                          ),
                    ],
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (topAlertStripWidgets.isNotEmpty) ...[
                  if (forExport)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        for (var i = 0; i < topAlertStripWidgets.length; i++) ...[
                          if (i > 0) const SizedBox(width: 6),
                          topAlertStripWidgets[i],
                        ],
                      ],
                    )
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: topAlertStripWidgets,
                    ),
                  const SizedBox(height: 6),
                ],
                buildMainTextWithTrailing(),
                if (!isSec &&
                    displayLayers.showRomaji &&
                    line.text.romaji != null &&
                    line.text.romaji!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      line.text.romaji!,
                      softWrap: forExport ? false : true,
                      maxLines: forExport ? 1 : null,
                      style: TextStyle(
                        fontFamily: fontFamily ?? 'GoogleSans',
                        fontSize: 11,
                        color: const Color(0xFF0061FF),
                      ),
                    ),
                  ),
                if (!isSec &&
                    displayLayers.showTranslation &&
                    line.text.translation != null &&
                    line.text.translation!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      line.text.translation!,
                      softWrap: forExport ? false : true,
                      maxLines: forExport ? 1 : null,
                      style: TextStyle(
                        fontFamily: fontFamily,
                        fontSize: 13,
                        color: const Color(0xFF475569),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportPill extends StatelessWidget {
  const _ExportPill({
    required this.label,
    required this.background,
    required this.foreground,
    this.borderColor,
    this.fontFamily,
    this.fontSize = 11,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
  });

  final String label;
  final Color background;
  final Color foreground;
  final Color? borderColor;
  final String? fontFamily;
  final double fontSize;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: ShapeDecoration(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: borderColor != null
              ? BorderSide(color: borderColor!)
              : BorderSide.none,
        ),
      ),
      child: Text(
        label,
        softWrap: false,
        maxLines: 1,
        overflow: TextOverflow.visible,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: foreground,
          height: 1.15,
        ),
      ),
    );
  }
}

class _TailUpdraftExportPill extends StatelessWidget {
  const _TailUpdraftExportPill({this.fontFamily});

  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    return _ExportPill(
      label: '尾句上升气流',
      background: const Color(0xFFE0F2FE),
      foreground: const Color(0xFF0369A1),
      borderColor: const Color(0xFF38BDF8),
      fontFamily: fontFamily,
      fontSize: 11,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
    );
  }
}

class _SheetCreditLine extends StatelessWidget {
  const _SheetCreditLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label：$value',
      textAlign: TextAlign.right,
      softWrap: false,
      maxLines: 1,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Color(0xFF334155),
      ),
    );
  }
}

String _formatCreditValue(String raw, {String fallback = ''}) {
  final clean = raw.trim();
  if (clean.isNotEmpty) return clean;
  final alt = fallback.trim();
  return alt.isEmpty ? '—' : alt;
}

double _measureTextWidth(String text, TextStyle style) {
  if (text.isEmpty) return 0;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: ui.TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return painter.width;
}

double _measureRubyLineWidth({
  required String original,
  required String? rubyHtml,
  required bool showRuby,
  required TextStyle baseStyle,
  required TextStyle rtStyle,
}) {
  if (!showRuby || rubyHtml == null || !rubyHtml.contains('<ruby')) {
    return _measureTextWidth(original, baseStyle);
  }
  final segments = parseRubySegments(rubyHtml, original);
  var total = 0.0;
  for (final seg in segments) {
    final baseW = _measureTextWidth(seg.base, baseStyle);
    final rtW = seg.rt == null ? 0.0 : _measureTextWidth(seg.rt!, rtStyle);
    total += math.max(baseW, rtW);
  }
  return total;
}

double _measureUniformCallColumnWidth(
  List<LyricLine> lines,
  Map<String, CallPreset> presetMap, {
  String? fontFamily,
  double minWidth = 116.0,
  double maxWidth = 240.0,
}) {
  final labelStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w700,
  );
  final suffixStyle = TextStyle(
    fontFamily: fontFamily ?? 'GoogleSans',
    fontSize: 11,
    fontWeight: FontWeight.w700,
  );
  var widest = minWidth;
  for (final line in lines) {
    if (line.calls.isEmpty) continue;
    var rowW = 0.0;
    var count = 0;
    for (final tag in line.calls) {
      final preset = presetMap[tag.presetId];
      if (preset == null) continue;
      if (count > 0) rowW += 4.0;
      rowW += 18.0 + _measureTextWidth(preset.label, labelStyle) + 2.0;
      final sfx = (tag.suffix ?? '').trim();
      if (sfx.isNotEmpty) {
        rowW += 5.0 + 10.0 + _measureTextWidth(sfx, suffixStyle) + 2.0;
      }
      count++;
    }
    if (rowW > widest) widest = rowW;
  }
  return widest.clamp(minWidth, maxWidth).ceilToDouble();
}

double _measureUnconstrainedExportWidth({
  required CallbookController controller,
  required List<LyricLine> lines,
  required Map<String, CallPreset> presetMap,
  required double callColWidth,
  String? fontFamily,
}) {
  final lyricBaseStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    fontWeight: FontWeight.w700,
  );
  final secStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w800,
  );
  final rtStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 10,
    fontWeight: FontWeight.w500,
  );
  final pillStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w700,
  );
  final noteStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w600,
  );
  final romajiStyle = TextStyle(
    fontFamily: fontFamily ?? 'GoogleSans',
    fontSize: 11,
  );
  final transStyle = TextStyle(fontFamily: fontFamily, fontSize: 13);

  final updraftPillWidth =
      18.0 + _measureTextWidth('尾句上升气流', pillStyle) + 2.0;

  var maxRightContentWidth = 0.0;
  for (final line in lines) {
    final isSec = line.kind.isSection;
    final gtAlert = controller.getAlertForLine(line.id);
    final cue = (gtAlert?.callTimingCue ?? '').trim();
    final gtNote = (gtAlert?.note ?? '').trim();
    final shout = line.customShout.trim();

    var topStripWidth = 0.0;
    var stripCount = 0;
    if (gtAlert != null) {
      final gtLabel = cue.isNotEmpty ? 'GT 警报 · 时机：$cue' : 'GT 警报';
      topStripWidth += 16.0 + _measureTextWidth(gtLabel, pillStyle) + 2.0;
      stripCount++;
      if (gtNote.isNotEmpty) {
        topStripWidth += 6.0 + _measureTextWidth(gtNote, noteStyle);
        stripCount++;
      }
    }
    if (shout.isNotEmpty && !isSec) {
      if (stripCount > 0) topStripWidth += 6.0;
      topStripWidth += 16.0 + _measureTextWidth(shout, pillStyle) + 2.0;
    }

    var mainRowWidth = 0.0;
    if (isSec) {
      final secTitle = line.text.original.trim().isEmpty
          ? '【${line.kind.zhLabel}】'
          : line.text.original.trim();
      mainRowWidth = _measureTextWidth(secTitle, secStyle);
      if (shout.isNotEmpty) {
        mainRowWidth += 8.0 + 16.0 + _measureTextWidth(shout, pillStyle) + 2.0;
      }
      if (line.tailUpdraft) {
        mainRowWidth += 8.0 + updraftPillWidth;
      }
    } else {
      mainRowWidth = _measureRubyLineWidth(
        original: line.text.original,
        rubyHtml: line.text.ruby,
        showRuby: controller.displayLayers.showRuby,
        baseStyle: lyricBaseStyle,
        rtStyle: rtStyle,
      );
      if (line.tailUpdraft) {
        mainRowWidth += 8.0 + updraftPillWidth;
      }
    }

    final romajiWidth =
        (!isSec &&
            controller.displayLayers.showRomaji &&
            (line.text.romaji ?? '').isNotEmpty)
        ? _measureTextWidth(line.text.romaji!, romajiStyle)
        : 0.0;
    final transWidth =
        (!isSec &&
            controller.displayLayers.showTranslation &&
            (line.text.translation ?? '').isNotEmpty)
        ? _measureTextWidth(line.text.translation!, transStyle)
        : 0.0;

    final rowMax = math.max(
      math.max(topStripWidth, mainRowWidth),
      math.max(romajiWidth, transWidth),
    );
    if (rowMax > maxRightContentWidth) {
      maxRightContentWidth = rowMax;
    }
  }

  // Outer card horizontal padding (22 * 2) + row inner horizontal padding (12 * 2)
  // + Call column + gap (12) + right content + safety margin (40).
  return math
      .max(760.0, 44.0 + 24.0 + callColWidth + 12.0 + maxRightContentWidth + 40.0)
      .ceilToDouble();
}
