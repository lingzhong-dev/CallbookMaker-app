import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../models/callbook_models.dart';
import '../../state/callbook_controller.dart';
import '../../utils/aligned_calls.dart';
import '../../utils/lrc_ruby_parser.dart';
import '../../utils/section_detector.dart';
import '../../utils/shortcut_validator.dart';
import '../theme/app_motion.dart';
import '../theme/app_tokens.dart';
import 'call_badge_pill.dart';
import 'call_preset_dialogs.dart';
import 'callbook_glyphs.dart';
import 'ruby_lyric_text.dart';

int? _parseClockText(String raw) {
  final m = RegExp(r'^(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?$').firstMatch(raw.trim());
  if (m == null) return null;
  final min = int.parse(m.group(1)!);
  final sec = int.parse(m.group(2)!);
  final msRaw = m.group(3) ?? '0';
  final ms = switch (msRaw.length) {
    1 => int.parse(msRaw) * 100,
    2 => int.parse(msRaw) * 10,
    _ => int.parse(msRaw.substring(0, 3)),
  };
  return min * 60000 + sec * 1000 + ms;
}

Color _sectionAccentColor(ColorScheme scheme, LyricLineKind kind) => switch (kind) {
  LyricLineKind.intro => const Color(0xFF0EA5E9),
  LyricLineKind.interlude => scheme.primary,
  LyricLineKind.outro => const Color(0xFF8B5CF6),
  LyricLineKind.lyric => scheme.primary,
};

class TimelineEditorWidget extends StatefulWidget {
  const TimelineEditorWidget({
    super.key,
    required this.controller,
    this.compact = false,
  });

  final CallbookController controller;
  final bool compact;

  @override
  State<TimelineEditorWidget> createState() => _TimelineEditorWidgetState();
}

class _TimelineEditorWidgetState extends State<TimelineEditorWidget> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _lineKeys = {};
  String? _lastActiveLineId;
  String? _lastLineListSignature;
  String? _pendingScrollLineId;
  bool _showSectionPanel = false;
  bool _showShortcuts = false;

  String _computeLineListSignature(List<TimelineLineItem> items) {
    if (items.isEmpty) return '';
    return '${items.length}:${items.first.line.id}:${items.last.line.id}';
  }

  @override
  void initState() {
    super.initState();
    _lastActiveLineId = widget.controller.activeLineId;
    _lastLineListSignature = _computeLineListSignature(
      widget.controller.timelineItems,
    );
    widget.controller.projectListenable.addListener(_handleProjectChanged);
    widget.controller.playbackSyncListenable.addListener(_handlePlaybackSync);
  }

  @override
  void didUpdateWidget(covariant TimelineEditorWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.projectListenable.removeListener(
        _handleProjectChanged,
      );
      oldWidget.controller.playbackSyncListenable.removeListener(
        _handlePlaybackSync,
      );
      _lastActiveLineId = widget.controller.activeLineId;
      _lastLineListSignature = _computeLineListSignature(
        widget.controller.timelineItems,
      );
      widget.controller.projectListenable.addListener(_handleProjectChanged);
      widget.controller.playbackSyncListenable.addListener(_handlePlaybackSync);
    }
  }

  void _scheduleScrollToLine(String targetId) {
    if (_pendingScrollLineId == targetId) return;
    final wasScheduled = _pendingScrollLineId != null;
    _pendingScrollLineId = targetId;
    if (!wasScheduled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final scheduledId = _pendingScrollLineId;
        _pendingScrollLineId = null;
        if (!mounted || scheduledId == null) return;
        final ctx = _lineKeys[scheduledId]?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: AppMotion.d(context, AppMotion.effectsDefault),
            curve: AppMotion.curveEffects,
            alignment: 0.35,
          );
        }
      });
    }
  }

  void _handleProjectChanged() {
    final c = widget.controller;
    final items = c.timelineItems;
    final nextSig = _computeLineListSignature(items);
    if (nextSig != _lastLineListSignature) {
      _lastLineListSignature = nextSig;
      final validIds = {for (final item in items) item.line.id};
      _lineKeys.removeWhere((id, _) => !validIds.contains(id));
    }

    final nextActive = c.activeLineId;
    final activeChanged = nextActive != null && nextActive != _lastActiveLineId;
    _lastActiveLineId = nextActive;

    if (activeChanged) {
      _scheduleScrollToLine(nextActive);
    }
  }

  void _handlePlaybackSync() {
    final c = widget.controller;
    if (!c.followPlayback || c.isPracticeMode) return;
    final targetId = c.followTargetLineId;
    if (targetId != null) {
      _scheduleScrollToLine(targetId);
    }
  }

  @override
  void dispose() {
    widget.controller.projectListenable.removeListener(_handleProjectChanged);
    widget.controller.playbackSyncListenable.removeListener(
      _handlePlaybackSync,
    );
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _openCreatePresetDialog(BuildContext context) async {
    final result = await showGeneralDialog<
        ({
          String label,
          String colorHex,
          CallCategory category,
          String shortcut,
        })>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: const Color(0x66000000),
      pageBuilder: (ctx, _, _) => Center(
        child: _CreatePresetDialog(
          existingPresets: widget.controller.allPresets,
        ),
      ),
    );

    if (result != null && result.label.trim().isNotEmpty) {
      widget.controller.addCustomPreset(
        label: result.label.trim(),
        colorHex: result.colorHex,
        category: result.category,
        shortcut: result.shortcut.trim(),
      );
    }
  }

  Future<void> _openEditLineDialog(
    BuildContext context,
    LyricLine line, {
    bool autofocusOriginal = false,
  }) async {
    final result = await showGeneralDialog<
        ({
          String action,
          int startTimeMs,
          int endTimeMs,
          LyricLineKind kind,
          String original,
          String translation,
          String customShout,
        })>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: const Color(0x66000000),
      pageBuilder: (ctx, _, _) => Center(
        child: _EditLineDialog(
          line: line,
          autofocusOriginal: autofocusOriginal,
        ),
      ),
    );

    if (result == null ||
        (result.action != 'save' && result.action != 'split')) {
      return;
    }

    widget.controller.updateLineDetails(
      lineId: line.id,
      startTimeMs: result.startTimeMs,
      endTimeMs: result.endTimeMs,
      kind: result.kind,
      original: result.original,
      translation: result.translation,
      customShout: result.customShout,
    );

    if (result.action == 'split' && context.mounted) {
      final updated = widget.controller.project.lines.cast<LyricLine?>().firstWhere(
            (l) => l?.id == line.id,
            orElse: () => null,
          );
      if (updated != null &&
          !updated.kind.isSection &&
          updated.text.original.runes.length >= 2) {
        await _openSplitLineDialog(context, updated);
      }
    }
  }

  Future<void> _openSplitLineDialog(
    BuildContext context,
    LyricLine line,
  ) async {
    if (line.kind.isSection || line.text.original.runes.length < 2) {
      widget.controller.setStatus('至少需要 2 个字符的非段落歌词才能按字拆分');
      return;
    }
    final result = await showGeneralDialog<({List<int> splits, List<int> times})>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: const Color(0x66000000),
      pageBuilder: (ctx, _, _) => Center(
        child: _SplitLyricDialog(
          controller: widget.controller,
          line: line,
        ),
      ),
    );
    if (result == null) return;
    widget.controller.splitLineAtRunes(
      line.id,
      result.splits,
      boundaryTimesMs: result.times,
    );
  }

  Future<void> _openAddSectionDialog(
    BuildContext context, {
    LyricLineKind initialKind = LyricLineKind.interlude,
    String? afterLineId,
  }) async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: const Color(0x66000000),
      pageBuilder: (ctx, _, _) => Center(
        child: AlertDialog(
          title: '添加前奏 / 间奏 / 尾奏',
          hasFields: true,
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
          child: _ManualSectionForm(
            controller: widget.controller,
            initialKind: initialKind,
            afterLineId: afterLineId,
            onAdded: () => Navigator.of(ctx).pop(),
          ),
        ),
      ),
    );
  }

  Future<void> _openSuffixDialog(
    BuildContext context,
    LyricLine line,
    LineCallTag tag,
    CallPreset preset,
  ) async {
    final isSingAlong = preset.id == singAlongPresetId;
    final result = await showGeneralDialog<({bool removed, String suffix})>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: const Color(0x66000000),
      pageBuilder: (ctx, _, _) => Center(
        child: _EditSuffixDialog(
          preset: preset,
          initialSuffix: tag.suffix ?? '',
          isSingAlong: isSingAlong,
        ),
      ),
    );
    if (result == null) return;
    if (result.removed) {
      widget.controller.toggleLineCall(line.id, tag.presetId);
      return;
    }
    if (!isSingAlong || result.suffix.trim().isNotEmpty) {
      widget.controller.setCallTagSuffix(
        line.id,
        tag.presetId,
        result.suffix,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = context.colorScheme;
    final items = c.timelineItems;
    final presetMap = c.presetMap;
    final activeLineHasGt =
        c.activeLineId != null && c.getAlertForLine(c.activeLineId!) != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sticky Call Toolbar Card
        Card(
          inert: true,
          padding: const EdgeInsets.all(14),
          radius: AppTokens.radiusCard,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final titleGroup = Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      Text(
                        c.siteText('编写工作台'),
                        style: AppTextStyle.headline
                            .of(context, emphasized: true)
                            .copyWith(color: scheme.onSurface),
                      ),
                      TonalChip(
                        label:
                            '${c.sortedLines.length} 句 · ${c.sectionStats.total} 段落 · ${c.sortedAlerts.length} GT 警报',
                        color: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurfaceVariant,
                      ),
                      Semantics(
                        label: '键盘快捷键说明',
                        button: true,
                        child: TonalChip(
                          label: '?',
                          color: _showShortcuts
                              ? scheme.primaryContainer
                              : scheme.surfaceContainerHigh,
                          foregroundColor: _showShortcuts
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                          onPressed: () => setState(() {
                            _showShortcuts = !_showShortcuts;
                          }),
                        ),
                      ),
                    ],
                  );
                  final actionsGroup = Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '跟随滚动',
                        style: AppTextStyle.caption1.of(context).copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Switch(
                        value: c.followPlayback,
                        onChanged: c.setFollowPlayback,
                        semanticLabel: '跟随播放滚动',
                      ),
                      Text(
                        '自动跳下句',
                        style: AppTextStyle.caption1.of(context).copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Switch(
                        value: c.autoAdvanceOnTag,
                        onChanged: c.setAutoAdvanceOnTag,
                        semanticLabel: '打标后自动跳转下一句',
                      ),
                      TonalButton(
                        size: TonalButtonSize.compact,
                        label: activeLineHasGt ? '取消 GT 警报' : 'GT 警报',
                        onPressed:
                            items.isEmpty ? null : () => c.insertGtAlert(),
                      ),
                      TonalButton(
                        size: TonalButtonSize.compact,
                        label: _showSectionPanel ? '收起段落' : '前/间/尾奏',
                        onPressed: () => setState(() {
                          _showSectionPanel = !_showSectionPanel;
                        }),
                      ),
                      if (c.canUndo)
                        Semantics(
                          label: '撤销 ${c.lastUndoLabel ?? ''}'.trim(),
                          button: true,
                          child: TonalButton(
                            size: TonalButtonSize.compact,
                            label: '撤销',
                            onPressed: c.undoLastTimelineEdit,
                          ),
                        ),
                      TonalButton(
                        size: TonalButtonSize.compact,
                        label: '加行',
                        onPressed: c.addEmptyLine,
                      ),
                    ],
                  );
                  if (constraints.maxWidth < 680) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        titleGroup,
                        const SizedBox(height: 8),
                        actionsGroup,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: titleGroup),
                      const SizedBox(width: 8),
                      actionsGroup,
                    ],
                  );
                },
              ),
              if (_showSectionPanel) ...[
                const SizedBox(height: 10),
                _InlineSectionPanel(
                  controller: c,
                  onClose: () => setState(() => _showSectionPanel = false),
                ),
              ],
              if (_showShortcuts) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: ShapeDecoration(
                    color: scheme.surfaceContainerLow,
                    shape: AppShape.lg,
                  ),
                  child: Text(
                    'Space 播放/暂停 · 1~0 切换军 Call · G 切换当前行 GT 警报 · ↑/↓ 切行 · ←/→ 跳 2s · F 现场演练',
                    style: AppTextStyle.caption1.of(context).copyWith(
                      fontFamily: 'GoogleSans',
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final preset in c.allPresets)
                    CallBadgePill(
                      preset: preset,
                      selected: c.activeLineId != null &&
                          c.project.lines.any(
                            (l) =>
                                l.id == c.activeLineId &&
                                l.calls.any((tag) => tag.presetId == preset.id),
                          ),
                      compact: true,
                      showShortcut: MediaQuery.sizeOf(context).width >= 600,
                      onTap: () => triggerCallPresetWithUi(
                        context: context,
                        controller: c,
                        presetId: preset.id,
                      ),
                      onContextAction: preset.builtIn
                          ? null
                          : (pos) => showCustomPresetContextMenu(
                              context,
                              controller: c,
                              preset: preset,
                              globalPosition: pos,
                            ),
                    ),
                  ValueListenableBuilder<String?>(
                    valueListenable: c.playingLineIdListenable,
                    builder: (context, _, _) {
                      final quickTargetLine = c.resolveLineForQuickTag();
                      return _TailUpdraftToggleChip(
                        enabled: quickTargetLine?.tailUpdraft == true,
                        compact: true,
                        onTap: quickTargetLine == null
                            ? null
                            : () {
                                final enabled = c.toggleTailUpdraft(
                                  quickTargetLine.id,
                                );
                                if (enabled && c.autoAdvanceOnTag) {
                                  c.stepActiveLine(1);
                                }
                              },
                      );
                    },
                  ),
                  TonalChip(
                    label: '+ 自定义标签',
                    color: scheme.primaryContainer,
                    foregroundColor: scheme.onPrimaryContainer,
                    onPressed: () => _openCreatePresetDialog(context),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        if (items.isEmpty)
          Card(
            inert: true,
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                '时间轴为空，点击「导入音源 / LRC」或右上角「加行」开始制作 Call 本。',
                style: AppTextStyle.subheadline.of(context).copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          ListView.separated(
            controller: _scrollController,
            shrinkWrap: true,
            physics: widget.compact
                ? const NeverScrollableScrollPhysics()
                : const ClampingScrollPhysics(),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, idx) {
              final line = items[idx].line;
              final gtAlert = c.getAlertForLine(line.id);
              final canMergeNext = !line.kind.isSection &&
                  idx + 1 < items.length &&
                  !items[idx + 1].line.kind.isSection;
              final canSplit =
                  !line.kind.isSection && line.text.original.runes.length >= 2;
              return KeyedSubtree(
                key: _lineKeys.putIfAbsent(line.id, GlobalKey.new),
                child: _ReactiveTimelineLineCard(
                  controller: c,
                  line: line,
                  presetMap: presetMap,
                  gtAlert: gtAlert,
                  isSelected: c.activeLineId == line.id,
                  canMergeNext: canMergeNext,
                  canSplit: canSplit,
                  onCreatePreset: () => _openCreatePresetDialog(context),
                  onAddSectionAfter: () => _openAddSectionDialog(
                    context,
                    initialKind: LyricLineKind.interlude,
                    afterLineId: line.id,
                  ),
                  onEditLine: () => _openEditLineDialog(context, line),
                  onDoubleTapEdit: () => _openEditLineDialog(
                    context,
                    line,
                    autofocusOriginal: true,
                  ),
                  onSplitLine: () => _openSplitLineDialog(context, line),
                  onOpenSuffix: (tag, preset) =>
                      _openSuffixDialog(context, line, tag, preset),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _ReactiveTimelineLineCard extends StatefulWidget {
  const _ReactiveTimelineLineCard({
    required this.controller,
    required this.line,
    required this.presetMap,
    required this.gtAlert,
    required this.isSelected,
    required this.canMergeNext,
    required this.canSplit,
    required this.onCreatePreset,
    required this.onAddSectionAfter,
    required this.onEditLine,
    required this.onDoubleTapEdit,
    required this.onSplitLine,
    required this.onOpenSuffix,
  });

  final CallbookController controller;
  final LyricLine line;
  final Map<String, CallPreset> presetMap;
  final GtAlert? gtAlert;
  final bool isSelected;
  final bool canMergeNext;
  final bool canSplit;
  final VoidCallback onCreatePreset;
  final VoidCallback onAddSectionAfter;
  final VoidCallback onEditLine;
  final VoidCallback onDoubleTapEdit;
  final VoidCallback onSplitLine;
  final void Function(LineCallTag tag, CallPreset preset) onOpenSuffix;

  @override
  State<_ReactiveTimelineLineCard> createState() =>
      _ReactiveTimelineLineCardState();
}

class _ReactiveTimelineLineCardState extends State<_ReactiveTimelineLineCard> {
  late bool _isPlaying;
  late bool _isUpcoming;
  DateTime? _lastTapAt;

  @override
  void initState() {
    super.initState();
    _isPlaying = widget.controller.playingLineId == widget.line.id;
    _isUpcoming = widget.controller.upcomingLineId == widget.line.id;
    widget.controller.playingLineIdListenable.addListener(_onPlaybackChanged);
    widget.controller.upcomingLineIdListenable.addListener(_onPlaybackChanged);
  }

  @override
  void didUpdateWidget(covariant _ReactiveTimelineLineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.playingLineIdListenable
          .removeListener(_onPlaybackChanged);
      oldWidget.controller.upcomingLineIdListenable
          .removeListener(_onPlaybackChanged);
      widget.controller.playingLineIdListenable.addListener(_onPlaybackChanged);
      widget.controller.upcomingLineIdListenable.addListener(
        _onPlaybackChanged,
      );
    }
    if (oldWidget.line.id != widget.line.id) {
      _lastTapAt = null;
    }
    _isPlaying = widget.controller.playingLineId == widget.line.id;
    _isUpcoming = widget.controller.upcomingLineId == widget.line.id;
  }

  void _onPlaybackChanged() {
    final nextPlaying = widget.controller.playingLineId == widget.line.id;
    final nextUpcoming = widget.controller.upcomingLineId == widget.line.id;
    if (nextPlaying != _isPlaying || nextUpcoming != _isUpcoming) {
      setState(() {
        _isPlaying = nextPlaying;
        _isUpcoming = nextUpcoming;
      });
    }
  }

  void _handleCardTap() {
    final now = DateTime.now();
    final isDoubleTap =
        _lastTapAt != null &&
        now.difference(_lastTapAt!) <= const Duration(milliseconds: 350);
    _lastTapAt = isDoubleTap ? null : now;
    widget.controller.selectLine(widget.line.id, seekToLine: true);
    if (isDoubleTap) {
      widget.onDoubleTapEdit();
    }
  }

  @override
  void dispose() {
    widget.controller.playingLineIdListenable
        .removeListener(_onPlaybackChanged);
    widget.controller.upcomingLineIdListenable
        .removeListener(_onPlaybackChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final line = widget.line;
    final presetMap = widget.presetMap;
    final gtAlert = widget.gtAlert;
    final isSelected = widget.isSelected;
    final isPlaying = _isPlaying;
    final isUpcoming = _isUpcoming && !isPlaying;

    final scheme = context.colorScheme;
    final highlighted = isPlaying || isSelected || isUpcoming;
    final isSection = line.kind.isSection;
    final sectionAccent = _sectionAccentColor(scheme, line.kind);
    final unalignedShout = isSection
        ? line.customShout.trim()
        : getUnalignedCustomShout(line);

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, headerConstraints) {
            final metaChips = Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TonalChip(
                  label: formatMsToClock(line.startTimeMs),
                  color: gtAlert != null
                      ? scheme.warningContainer
                      : (isSection
                            ? sectionAccent.withValues(alpha: 0.16)
                            : scheme.primaryContainer),
                  foregroundColor: gtAlert != null
                      ? scheme.onWarningContainer
                      : (isSection
                            ? sectionAccent
                            : scheme.onPrimaryContainer),
                  onPressed: () => c.seek(line.startTimeMs),
                ),
                if (isSection)
                  TonalChip(
                    label:
                        '${line.kind.zhLabel} · ${formatGapSec(math.max(0, line.endTimeMs - line.startTimeMs))}',
                    color: sectionAccent.withValues(alpha: 0.14),
                    foregroundColor: sectionAccent,
                  ),
                if (gtAlert != null)
                  TonalChip(
                    label: 'GT 警报',
                    color: scheme.warning,
                    foregroundColor: const Color(0xFF000000),
                  ),
                if (isPlaying)
                  TonalChip(
                    label: 'PLAYING',
                    color: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                  )
                else if (isUpcoming)
                  TonalChip(
                    label: c.siteText('即将演唱'),
                    color: scheme.secondaryContainer,
                    foregroundColor: scheme.onSecondaryContainer,
                  ),
              ],
            );
            final actionChips = Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.end,
              children: [
                _TailUpdraftToggleChip(
                  enabled: line.tailUpdraft,
                  compact: true,
                  onTap: () {
                    final enabled = c.toggleTailUpdraft(line.id);
                    if (enabled && c.autoAdvanceOnTag) {
                      c.stepActiveLine(1);
                    }
                  },
                ),
                TonalChip(
                  label: gtAlert != null ? '取消 GT' : 'GT',
                  color: gtAlert != null
                      ? scheme.warning
                      : scheme.warningContainer,
                  foregroundColor: gtAlert != null
                      ? const Color(0xFF000000)
                      : scheme.onWarningContainer,
                  onPressed: () => c.toggleLineGtAlert(lineId: line.id),
                ),
                TonalChip(
                  label: '校时',
                  color: scheme.surfaceContainerHigh,
                  foregroundColor: scheme.onSurface,
                  onPressed: () => c.snapLineToCurrentTime(line.id),
                ),
                if (widget.canMergeNext)
                  TonalChip(
                    label: '合并下句',
                    color: scheme.surfaceContainerHigh,
                    foregroundColor: scheme.onSurface,
                    onPressed: () => c.mergeWithNextLine(line.id),
                  ),
                if (isSelected && widget.canSplit)
                  TonalChip(
                    label: '拆分',
                    color: scheme.primaryContainer,
                    foregroundColor: scheme.onPrimaryContainer,
                    onPressed: widget.onSplitLine,
                  ),
                if (isSelected && line.kind != LyricLineKind.outro)
                  TonalChip(
                    label: '+间奏',
                    color: scheme.primaryContainer,
                    foregroundColor: scheme.onPrimaryContainer,
                    onPressed: widget.onAddSectionAfter,
                  ),
                TonalChip(
                  label: '编辑',
                  color: scheme.surfaceContainerHigh,
                  foregroundColor: scheme.onSurface,
                  onPressed: widget.onEditLine,
                ),
                GestureDetector(
                  onTap: () => c.deleteLine(line.id),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: GlyphIcon(
                      CallbookGlyphs.trash,
                      size: 17,
                      color: scheme.error,
                    ),
                  ),
                ),
              ],
            );
            if (headerConstraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  metaChips,
                  const SizedBox(height: 6),
                  actionChips,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: metaChips),
                const SizedBox(width: 6),
                Flexible(child: actionChips),
              ],
            );
          },
        ),
        if (line.calls.isNotEmpty || unalignedShout.isNotEmpty || isSelected) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final tag in line.calls)
                if (presetMap[tag.presetId] case final preset?)
                  CallBadgePill(
                    preset: preset,
                    suffix: tag.suffix,
                    compact: true,
                    onTap: () => widget.onOpenSuffix(tag, preset),
                    onContextAction: preset.builtIn
                        ? null
                        : (pos) => showCustomPresetContextMenu(
                            context,
                            controller: c,
                            preset: preset,
                            globalPosition: pos,
                          ),
                  ),
              if (unalignedShout.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: ShapeDecoration(
                    color: scheme.tertiaryContainer,
                    shape: AppShape.full,
                  ),
                  child: Text(
                    unalignedShout,
                    softWrap: false,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    style: AppTextStyle.caption1
                        .of(context, emphasized: true)
                        .copyWith(color: scheme.onTertiaryContainer),
                  ),
                ),
              if (line.calls.isEmpty && isSelected)
                Text(
                  '轻触下方胶囊直接添加 Call 法',
                  style: AppTextStyle.caption2.of(context).copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            RubyLyricText(
              original: line.text.original,
              rubyHtml: line.text.ruby,
              showRuby: c.displayLayers.showRuby,
              alignedCalls: isSection ? const [] : line.alignedCalls,
              customShout: isSection ? '' : line.customShout,
              pillBackground: scheme.tertiaryContainer,
              pillForeground: scheme.onTertiaryContainer,
              pillBorderColor: scheme.outlineVariant,
              underlineColor: const Color(0x886366F1),
              baseStyle: AppTextStyle.body
                  .of(context, emphasized: true)
                  .copyWith(color: scheme.onSurface, fontSize: 17),
            ),
            if (line.tailUpdraft) const _TailUpdraftTagBadge(),
          ],
        ),
        if (c.displayLayers.showRomaji &&
            line.text.romaji != null &&
            line.text.romaji!.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            line.text.romaji!,
            style: AppTextStyle.caption1.of(context).copyWith(
              fontFamily: 'GoogleSans',
              color: scheme.primary,
            ),
          ),
        ],
        if (c.displayLayers.showTranslation &&
            line.text.translation != null &&
            line.text.translation!.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            line.text.translation!,
            style: AppTextStyle.subheadline.of(context).copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        if (isSelected) ...[
          const SizedBox(height: 10),
          Container(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Call 法速选',
                style: AppTextStyle.caption1
                    .of(context, emphasized: true)
                    .copyWith(color: scheme.primary),
              ),
              Text(
                '轻触胶囊添加 / 取消',
                style: AppTextStyle.caption2
                    .of(context)
                    .copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final preset in c.allPresets) ...[
                  CallBadgePill(
                    preset: preset,
                    selected: line.calls.any((t) => t.presetId == preset.id),
                    compact: true,
                    showShortcut: false,
                    onTap: () => triggerCallPresetWithUi(
                      context: context,
                      controller: c,
                      presetId: preset.id,
                      lineId: line.id,
                    ),
                    onContextAction: preset.builtIn
                        ? null
                        : (pos) => showCustomPresetContextMenu(
                            context,
                            controller: c,
                            preset: preset,
                            globalPosition: pos,
                          ),
                  ),
                  const SizedBox(width: 6),
                ],
                _TailUpdraftToggleChip(
                  enabled: line.tailUpdraft,
                  compact: true,
                  onTap: () {
                    final enabled = c.toggleTailUpdraft(line.id);
                    if (enabled && c.autoAdvanceOnTag) {
                      c.stepActiveLine(1);
                    }
                  },
                ),
                const SizedBox(width: 6),
                TonalChip(
                  label: '+ 自定义',
                  color: scheme.surfaceContainerHigh,
                  foregroundColor: scheme.onSurfaceVariant,
                  onPressed: widget.onCreatePreset,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _InlineCustomShoutField(
            key: ValueKey('custom-shout-${line.id}'),
            initialValue: line.customShout,
            onChanged: (v) => c.updateLineDetails(
              lineId: line.id,
              customShout: v,
            ),
          ),
          if (!isSection && line.text.original.isNotEmpty) ...[
            const SizedBox(height: 8),
            _InlineAlignedCallsBar(
              line: line,
              controller: c,
            ),
          ],
        ],
        if (gtAlert != null) ...[
          const SizedBox(height: 10),
          _InlineGtEditor(
            key: ValueKey('gt-editor-${line.id}-${gtAlert.id}'),
            lineId: line.id,
            alert: gtAlert,
            controller: c,
          ),
        ],
      ],
    );

    if (gtAlert != null) {
      return GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: _handleCardTap,
        child: AnimatedContainer(
          duration: AppMotion.d(context, AppMotion.effectsDefault),
          curve: AppMotion.curveEffects,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              scheme.warningContainer.withValues(alpha: highlighted ? 0.46 : 0.34),
              scheme.surfaceContainerLow,
            ),
            borderRadius: BorderRadius.circular(AppTokens.radiusSection),
            border: Border.all(
              color: scheme.warning,
              width: highlighted ? 1.8 : 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.warning.withValues(alpha: highlighted ? 0.24 : 0.16),
                blurRadius: highlighted ? 14 : 10,
              ),
            ],
          ),
          child: body,
        ),
      );
    }

    return Card(
      isSelected: highlighted,
      radius: AppTokens.radiusSection,
      padding: const EdgeInsets.all(14),
      shape: RoundedSuperellipseBorder(
        borderRadius: AppTokens.radiusSectionBorder,
        side: highlighted
            ? BorderSide(
                color: isSection ? sectionAccent : scheme.primary,
                width: isPlaying ? 2.0 : 1.4,
              )
            : (isSection
                  ? BorderSide(
                      color: sectionAccent.withValues(alpha: 0.42),
                      width: 1.2,
                    )
                  : BorderSide.none),
      ),
      onPressed: _handleCardTap,
      child: body,
    );
  }
}

class _InlineCustomShoutField extends StatefulWidget {
  const _InlineCustomShoutField({
    super.key,
    required this.initialValue,
    required this.onChanged,
  });

  final String initialValue;
  final ValueChanged<String> onChanged;

  @override
  State<_InlineCustomShoutField> createState() =>
      _InlineCustomShoutFieldState();
}

class _InlineCustomShoutFieldState extends State<_InlineCustomShoutField> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initialValue,
  );
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant _InlineCustomShoutField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && _ctrl.text != widget.initialValue) {
      _ctrl.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Container(
      padding: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
        ),
      ),
      child: Row(
        children: [
          Text(
            '喊声 / 口上',
            style: AppTextStyle.caption1
                .of(context, emphasized: true)
                .copyWith(color: scheme.tertiary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              style: AppTextStyle.caption1
                  .of(context, emphasized: true)
                  .copyWith(color: scheme.onSurface),
              decoration: const InputDecoration.collapsed(
                hintText: '输入自定义 Mix / 口上...',
              ),
              onChanged: widget.onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineGtEditor extends StatefulWidget {
  const _InlineGtEditor({
    super.key,
    required this.lineId,
    required this.alert,
    required this.controller,
  });

  final String lineId;
  final GtAlert alert;
  final CallbookController controller;

  @override
  State<_InlineGtEditor> createState() => _InlineGtEditorState();
}

class _InlineGtEditorState extends State<_InlineGtEditor> {
  late final TextEditingController _noteCtrl = TextEditingController(
    text: widget.alert.note,
  );
  final FocusNode _noteFocus = FocusNode();

  @override
  void didUpdateWidget(covariant _InlineGtEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_noteFocus.hasFocus && _noteCtrl.text != widget.alert.note) {
      _noteCtrl.text = widget.alert.note;
    }
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: ShapeDecoration(
        color: scheme.surface.withValues(alpha: 0.72),
        shape: AppShape.lg,
      ),
      child: FilledInputTheme(
        borderRadius: AppRadius.md,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 8,
        ),
        fillColor: scheme.surfaceContainerHigh,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'GT 警报备注',
              style: AppTextStyle.caption1
                  .of(context, emphasized: true)
                  .copyWith(color: scheme.onWarningContainer),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _noteCtrl,
              focusNode: _noteFocus,
              decoration: const InputDecoration(
                hintText: '可选备注（如：吉他进场，准备衔接下一段 Call）',
              ),
              onChanged: (v) => widget.controller.updateLineGtAlert(
                widget.lineId,
                note: v,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineSectionPanel extends StatelessWidget {
  const _InlineSectionPanel({
    required this.controller,
    required this.onClose,
  });

  final CallbookController controller;
  final VoidCallback onClose;

  Widget _thresholdStepper(
    BuildContext context, {
    required String label,
    required int valueMs,
    required void Function(int nextMs) onChanged,
  }) {
    final scheme = context.colorScheme;
    final sec = (valueMs / 1000).round();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: AppTextStyle.caption1.of(context, emphasized: true).copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          TonalChip(
            label: '-',
            color: scheme.surfaceContainerHigh,
            foregroundColor: scheme.onSurface,
            onPressed: sec > 2 ? () => onChanged((sec - 1) * 1000) : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '≥ ${sec}s',
              style: AppTextStyle.caption1.of(context, emphasized: true).copyWith(
                color: scheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          TonalChip(
            label: '+',
            color: scheme.surfaceContainerHigh,
            foregroundColor: scheme.onSurface,
            onPressed: sec < 60 ? () => onChanged((sec + 1) * 1000) : null,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final t = controller.sectionThresholds;
    final stats = controller.sectionStats;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '段落识别与手动插入',
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    TonalChip(
                      label:
                          '当前 前奏 ${stats.intro} / 间奏 ${stats.interlude} / 尾奏 ${stats.outro}',
                      color: scheme.primaryContainer,
                      foregroundColor: scheme.onPrimaryContainer,
                    ),
                  ],
                ),
              ),
              TonalChip(
                label: '收起',
                color: scheme.surfaceContainerHigh,
                foregroundColor: scheme.onSurfaceVariant,
                onPressed: onClose,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _thresholdStepper(
                context,
                label: '前奏空档',
                valueMs: t.introThresholdMs,
                onChanged: (ms) => controller.setSectionThresholds(
                  t.copyWith(introThresholdMs: ms),
                ),
              ),
              _thresholdStepper(
                context,
                label: '间奏间隔',
                valueMs: t.interludeThresholdMs,
                onChanged: (ms) => controller.setSectionThresholds(
                  t.copyWith(interludeThresholdMs: ms),
                ),
              ),
              _thresholdStepper(
                context,
                label: '尾奏空档',
                valueMs: t.outroThresholdMs,
                onChanged: (ms) => controller.setSectionThresholds(
                  t.copyWith(outroThresholdMs: ms),
                ),
              ),
              TonalButton(
                size: TonalButtonSize.compact,
                label: '重新识别前间尾奏',
                onPressed: controller.detectSections,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ManualSectionForm(
            controller: controller,
            initialKind: LyricLineKind.interlude,
            onAdded: onClose,
          ),
        ],
      ),
    );
  }
}

class _ManualSectionForm extends StatefulWidget {
  const _ManualSectionForm({
    required this.controller,
    required this.initialKind,
    this.afterLineId,
    required this.onAdded,
  });

  final CallbookController controller;
  final LyricLineKind initialKind;
  final String? afterLineId;
  final VoidCallback onAdded;

  @override
  State<_ManualSectionForm> createState() => _ManualSectionFormState();
}

class _ManualSectionFormState extends State<_ManualSectionForm> {
  late LyricLineKind _kind = widget.initialKind == LyricLineKind.lyric
      ? LyricLineKind.interlude
      : widget.initialKind;
  late final TextEditingController _startCtrl;
  late final TextEditingController _endCtrl;
  late final TextEditingController _titleCtrl;
  final TextEditingController _noteCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final range = _suggestedRange(_kind, afterLineId: widget.afterLineId);
    _startCtrl = TextEditingController(
      text: formatMsToClock(range.startTimeMs),
    );
    _endCtrl = TextEditingController(text: formatMsToClock(range.endTimeMs));
    _titleCtrl = TextEditingController(text: _kind.bracketTitle);
  }

  ({int startTimeMs, int endTimeMs}) _suggestedRange(
    LyricLineKind kind, {
    String? afterLineId,
  }) {
    final c = widget.controller;
    return suggestManualSectionRange(
      kind,
      c.project.lines,
      afterLineId: afterLineId ?? c.activeLineId,
      currentTimeMs: c.currentTimeMs,
      totalDurationMs: c.knownAudioDurationMs,
    );
  }

  void _selectKind(LyricLineKind nextKind) {
    final prevTitle = _kind.bracketTitle;
    final range = _suggestedRange(nextKind, afterLineId: widget.afterLineId);
    setState(() {
      _kind = nextKind;
      _startCtrl.text = formatMsToClock(range.startTimeMs);
      _endCtrl.text = formatMsToClock(range.endTimeMs);
      if (_titleCtrl.text.trim().isEmpty || _titleCtrl.text.trim() == prevTitle) {
        _titleCtrl.text = nextKind.bracketTitle;
      }
    });
  }

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    _titleCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = context.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedControl<LyricLineKind>(
          segments: const [
            (LyricLineKind.intro, '前奏'),
            (LyricLineKind.interlude, '间奏'),
            (LyricLineKind.outro, '尾奏'),
          ],
          value: _kind,
          onChanged: _selectKind,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _startCtrl,
                decoration: const InputDecoration(hintText: '开始 mm:ss.ms'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _endCtrl,
                decoration: const InputDecoration(hintText: '结束 mm:ss.ms'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ListenableBuilder(
              listenable: c.playbackListenable,
              builder: (context, _) => TonalChip(
                label: '填入当前 ${formatMsToClock(c.currentTimeMs)}',
                color: scheme.surfaceContainerHigh,
                foregroundColor: scheme.onSurface,
                onPressed: () {
                  final oldStart = _parseClockText(_startCtrl.text) ?? 0;
                  final oldEnd =
                      _parseClockText(_endCtrl.text) ?? (oldStart + 8000);
                  final dur = math.max(1500, oldEnd - oldStart);
                  setState(() {
                    _startCtrl.text = formatMsToClock(c.currentTimeMs);
                    _endCtrl.text = formatMsToClock(c.currentTimeMs + dur);
                  });
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _titleCtrl,
          decoration: const InputDecoration(hintText: '段落标题（如 【间奏】、Solo）'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _noteCtrl,
          decoration: const InputDecoration(hintText: '可选说明（如 可喊虎火发动 Mix）'),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: () {
            final startMs = _parseClockText(_startCtrl.text) ?? c.currentTimeMs;
            final endMs = math.max(
              startMs + 1000,
              _parseClockText(_endCtrl.text) ?? (startMs + 8000),
            );
            c.addSectionLine(
              kind: _kind,
              startTimeMs: startMs,
              endTimeMs: endMs,
              title: _titleCtrl.text,
              note: _noteCtrl.text,
            );
            widget.onAdded();
          },
          child: Text('添加到时间轴（${_kind.zhLabel}）'),
        ),
      ],
    );
  }
}

class _TailUpdraftToggleChip extends StatelessWidget {
  const _TailUpdraftToggleChip({
    required this.enabled,
    required this.onTap,
    this.compact = false,
  });

  final bool enabled;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final bg = enabled ? const Color(0xFF0284C7) : scheme.surfaceContainerHigh;
    final fg = enabled ? const Color(0xFFFFFFFF) : scheme.onSurface;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1.0,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 9 : 11,
            vertical: compact ? 5 : 7,
          ),
          decoration: ShapeDecoration(
            color: bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
              side: BorderSide(
                color: enabled
                    ? const Color(0xFF0284C7)
                    : scheme.outlineVariant,
              ),
            ),
          ),
          child: Text(
            enabled ? '✓ 尾句上升气流' : '+ 尾句上升气流',
            softWrap: false,
            maxLines: 1,
            overflow: TextOverflow.visible,
            style: AppTextStyle.caption1
                .of(context, emphasized: true)
                .copyWith(color: fg, height: 1.1),
          ),
        ),
      ),
    );
  }
}

class _TailUpdraftTagBadge extends StatelessWidget {
  const _TailUpdraftTagBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: ShapeDecoration(
        color: const Color(0xFFE0F2FE),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: const BorderSide(color: Color(0xFF38BDF8)),
        ),
      ),
      child: Text(
        '尾句上升气流',
        softWrap: false,
        maxLines: 1,
        overflow: TextOverflow.visible,
        style: AppTextStyle.caption2
            .of(context, emphasized: true)
            .copyWith(
              color: const Color(0xFF0369A1),
              height: 1.15,
            ),
      ),
    );
  }
}

class _InlineAlignedCallsBar extends StatelessWidget {
  const _InlineAlignedCallsBar({
    required this.line,
    required this.controller,
  });

  final LyricLine line;
  final CallbookController controller;

  Future<void> _openPicker(BuildContext context, [AlignedCallCue? editing]) async {
    final res = await showGeneralDialog<_AlignedCallFormResult>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: const Color(0x66000000),
      pageBuilder: (ctx, _, _) => Center(
        child: _AlignedCallPickerDialog(
          original: line.text.original,
          initialCue: editing,
        ),
      ),
    );
    if (res == null) return;
    controller.upsertAlignedCall(
      line.id,
      id: editing?.id,
      start: res.start,
      end: res.end,
      text: res.text,
      colorHex: res.colorHex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final original = line.text.original;
    final resolved = resolveLineAlignedCalls(line).aligned;
    final autoCues = [for (final c in resolved) if (c.isAuto) c];

    return Container(
      padding: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'CALL 词对位',
                style: AppTextStyle.caption1
                    .of(context, emphasized: true)
                    .copyWith(color: scheme.primary),
              ),
              TonalChip(
                label: '+ 对位 Call',
                color: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
                onPressed: () => _openPicker(context),
              ),
              for (final cue in line.alignedCalls)
                _AlignedCueChip(
                  cue: cue,
                  targetSnippet: original.substring(
                    cue.start.clamp(0, original.length),
                    cue.end.clamp(0, original.length),
                  ),
                  onEdit: () => _openPicker(context, cue),
                  onRemove: () => controller.removeAlignedCall(line.id, cue.id),
                ),
              for (final auto in autoCues)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: ShapeDecoration(
                    color: scheme.tertiaryContainer.withValues(alpha: 0.55),
                    shape: AppShape.full,
                  ),
                  child: Text(
                    '自动对位: ${auto.text}',
                    style: AppTextStyle.caption2.of(context).copyWith(
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AlignedCueChip extends StatelessWidget {
  const _AlignedCueChip({
    required this.cue,
    required this.targetSnippet,
    required this.onEdit,
    required this.onRemove,
  });

  final AlignedCallCue cue;
  final String targetSnippet;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final customColor = cue.color;
    final bg = customColor ?? scheme.secondaryContainer;
    final fg = customColor != null
        ? (customColor.computeLuminance() > 0.56
              ? const Color(0xFF0F172A)
              : const Color(0xFFFFFFFF))
        : scheme.onSecondaryContainer;
    return Container(
      decoration: ShapeDecoration(
        color: bg,
        shape: AppShape.full,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onEdit,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(9, 4, 4, 4),
              child: Text(
                '${cue.text} → $targetSnippet',
                style: AppTextStyle.caption1
                    .of(context, emphasized: true)
                    .copyWith(color: fg),
              ),
            ),
          ),
          GestureDetector(
            onTap: onRemove,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 4, 8, 4),
              child: GlyphIcon(
                Glyphs.close,
                size: 13,
                color: fg.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlignedCallFormResult {
  const _AlignedCallFormResult({
    required this.start,
    required this.end,
    required this.text,
    this.colorHex,
  });

  final int start;
  final int end;
  final String text;
  final String? colorHex;
}

class _AlignedCallPickerDialog extends StatefulWidget {
  const _AlignedCallPickerDialog({
    required this.original,
    this.initialCue,
  });

  final String original;
  final AlignedCallCue? initialCue;

  @override
  State<_AlignedCallPickerDialog> createState() =>
      _AlignedCallPickerDialogState();
}

class _AlignedCallPickerDialogState extends State<_AlignedCallPickerDialog> {
  late final List<({String text, int start, int end})> _chars;
  late int _start;
  late int _end;
  late final TextEditingController _textCtrl;
  String? _colorHex;
  bool _textAutoFilled = false;

  @override
  void initState() {
    super.initState();
    final spans = <({String text, int start, int end})>[];
    var offset = 0;
    for (final rune in widget.original.runes) {
      final ch = String.fromCharCode(rune);
      spans.add((text: ch, start: offset, end: offset + ch.length));
      offset += ch.length;
    }
    _chars = spans;

    if (widget.initialCue != null) {
      _start = widget.initialCue!.start.clamp(0, widget.original.length - 1);
      _end = widget.initialCue!.end.clamp(_start + 1, widget.original.length);
      _textCtrl = TextEditingController(text: widget.initialCue!.text);
      _colorHex = widget.initialCue!.colorHex;
      _textAutoFilled = false;
    } else if (_chars.isNotEmpty) {
      _start = _chars.first.start;
      _end = _chars.first.end;
      _textCtrl = TextEditingController(
        text: widget.original.substring(_start, _end),
      );
      _textAutoFilled = true;
    } else {
      _start = 0;
      _end = 0;
      _textCtrl = TextEditingController();
    }
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  void _onTapChar(({String text, int start, int end}) span) {
    final prevSlice = widget.original.substring(_start, _end);
    int nextStart;
    int nextEnd;
    if (_end - _start > 1 || (span.start == _start && span.end == _end)) {
      nextStart = span.start;
      nextEnd = span.end;
    } else {
      nextStart = math.min(_start, span.start);
      nextEnd = math.max(_end, span.end);
    }
    final nextSlice = widget.original.substring(nextStart, nextEnd);
    setState(() {
      _start = nextStart;
      _end = nextEnd;
      if (_textCtrl.text.trim().isEmpty ||
          _textAutoFilled ||
          _textCtrl.text.trim() == prevSlice.trim()) {
        _textCtrl.text = nextSlice;
        _textAutoFilled = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final selectedSlice = widget.original.isEmpty
        ? ''
        : widget.original.substring(_start, _end);
    final canSave = _end > _start && _textCtrl.text.trim().isNotEmpty;

    return AlertDialog(
      title: widget.initialCue != null ? '编辑词对位 Call' : '添加词对位 Call',
      hasFields: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canSave
              ? () => Navigator.of(context).pop(
                  _AlignedCallFormResult(
                    start: _start,
                    end: _end,
                    text: _textCtrl.text.trim(),
                    colorHex: _colorHex,
                  ),
                )
              : null,
          child: const Text('确认对位'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '点击选字确定对位范围（点首尾两字可连选）：当前已选「$selectedSlice」',
            style: AppTextStyle.caption1.of(context).copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final span in _chars)
                GestureDetector(
                  onTap: () => _onTapChar(span),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 5,
                    ),
                    decoration: ShapeDecoration(
                      color: (span.start >= _start && span.end <= _end)
                          ? scheme.primary
                          : scheme.surfaceContainerHigh,
                      shape: AppShape.sm,
                    ),
                    child: Text(
                      span.text == ' ' ? '␣' : span.text,
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(
                            color: (span.start >= _start && span.end <= _end)
                                ? scheme.onPrimary
                                : scheme.onSurface,
                          ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _textCtrl,
            decoration: const InputDecoration(
              hintText: '输入对位喊声（如 高い / Hi! / L.O.V.E）',
            ),
            onChanged: (_) => setState(() {
              _textAutoFilled = false;
            }),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              GestureDetector(
                onTap: () => setState(() => _colorHex = null),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: ShapeDecoration(
                    color: const Color(0xFFE0E7FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                      side: _colorHex == null
                          ? BorderSide(color: scheme.onSurface, width: 2)
                          : const BorderSide(color: Color(0xFFC7D2FE)),
                    ),
                  ),
                  child: const Text(
                    '默认靛蓝',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF3730A3),
                    ),
                  ),
                ),
              ),
              for (final hex in customPresetColorPalette)
                GestureDetector(
                  onTap: () => setState(() => _colorHex = hex),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Color(
                        int.parse('FF${hex.substring(1)}', radix: 16),
                      ),
                      shape: BoxShape.circle,
                      border: _colorHex == hex
                          ? Border.all(
                              color: scheme.onSurface,
                              width: 2.5,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SplitLyricDialog extends StatefulWidget {
  const _SplitLyricDialog({
    required this.controller,
    required this.line,
  });

  final CallbookController controller;
  final LyricLine line;

  @override
  State<_SplitLyricDialog> createState() => _SplitLyricDialogState();
}

class _SplitLyricDialogState extends State<_SplitLyricDialog> {
  late final List<String> _runeChars = [
    for (final rune in widget.line.text.original.runes)
      String.fromCharCode(rune),
  ];
  late final Set<int> _splitIndices = <int>{};
  final Map<int, TextEditingController> _ctrlsBySplitIdx =
      <int, TextEditingController>{};
  final List<TextEditingController> _retiredCtrls = <TextEditingController>[];
  final Map<int, int> _customTimeBySplitIdx = <int, int>{};

  @override
  void initState() {
    super.initState();
    if (_runeChars.length >= 2) {
      _splitIndices.add(_runeChars.length ~/ 2);
    }
    _syncBoundaryControllers();
  }

  @override
  void dispose() {
    for (final ctrl in _ctrlsBySplitIdx.values) {
      ctrl.dispose();
    }
    for (final ctrl in _retiredCtrls) {
      ctrl.dispose();
    }
    super.dispose();
  }

  List<int> _sortedSplits() => _splitIndices.toList()..sort();

  List<int> _defaultTimesFor(List<int> sortedSplits) {
    if (sortedSplits.isEmpty) return const [];
    final runeCount = _runeChars.length;
    final cutPoints = <int>[0, ...sortedSplits, runeCount];
    final chunkRuneCounts = <int>[
      for (var i = 0; i < cutPoints.length - 1; i++)
        cutPoints[i + 1] - cutPoints[i],
    ];
    return computeDefaultSplitTimes(
      widget.line.startTimeMs,
      widget.line.endTimeMs,
      chunkRuneCounts,
    );
  }

  void _syncBoundaryControllers() {
    final activeSet = _splitIndices;
    final removedKeys = [
      for (final k in _ctrlsBySplitIdx.keys)
        if (!activeSet.contains(k)) k,
    ];
    for (final k in removedKeys) {
      final removed = _ctrlsBySplitIdx.remove(k);
      if (removed != null) {
        // Retire rather than disposing synchronously during setState(), so any
        // unmounting TextField can cleanly detach listeners on the next frame.
        _retiredCtrls.add(removed);
      }
      _customTimeBySplitIdx.remove(k);
    }

    final sorted = _sortedSplits();
    final defaults = _defaultTimesFor(sorted);
    for (var i = 0; i < sorted.length; i++) {
      final splitIdx = sorted[i];
      final targetMs = _customTimeBySplitIdx[splitIdx] ?? defaults[i];
      final targetText = formatMsToClock(targetMs);
      final existing = _ctrlsBySplitIdx[splitIdx];
      if (existing == null) {
        _ctrlsBySplitIdx[splitIdx] = TextEditingController(text: targetText);
      } else if (!_customTimeBySplitIdx.containsKey(splitIdx) &&
          existing.text != targetText) {
        existing.value = TextEditingValue(
          text: targetText,
          selection: TextSelection.collapsed(offset: targetText.length),
        );
      }
    }
  }

  void _toggleSplitAt(int splitIdx) {
    if (splitIdx <= 0 || splitIdx >= _runeChars.length) return;
    setState(() {
      if (_splitIndices.contains(splitIdx)) {
        _splitIndices.remove(splitIdx);
      } else {
        _splitIndices.add(splitIdx);
      }
      _syncBoundaryControllers();
    });
  }

  void _resetTwoWayMidpoint() {
    setState(() {
      _splitIndices
        ..clear()
        ..add(_runeChars.length ~/ 2);
      _customTimeBySplitIdx.clear();
      _syncBoundaryControllers();
    });
  }

  void _clearAllSplits() {
    setState(() {
      _splitIndices.clear();
      _customTimeBySplitIdx.clear();
      _syncBoundaryControllers();
    });
  }

  void _resetProportionalTimes() {
    setState(() {
      _customTimeBySplitIdx.clear();
      _syncBoundaryControllers();
    });
  }

  void _setBoundaryTimeMs(int splitIdx, int ms) {
    final clamped = ms.clamp(
      widget.line.startTimeMs,
      widget.line.endTimeMs,
    );
    final formatted = formatMsToClock(clamped);
    setState(() {
      _customTimeBySplitIdx[splitIdx] = clamped;
      final ctrl = _ctrlsBySplitIdx[splitIdx];
      if (ctrl != null) {
        ctrl.value = TextEditingValue(
          text: formatted,
          selection: TextSelection.collapsed(offset: formatted.length),
        );
      }
    });
  }

  List<int> _resolvedBoundaryTimesMs(List<int> sortedSplits) {
    if (sortedSplits.isEmpty) return const [];
    final defaults = _defaultTimesFor(sortedSplits);
    return [
      for (var i = 0; i < sortedSplits.length; i++)
        _parseClockText(_ctrlsBySplitIdx[sortedSplits[i]]?.text ?? '') ??
            _customTimeBySplitIdx[sortedSplits[i]] ??
            defaults[i],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final sortedSplits = _sortedSplits();
    final resolvedTimes = _resolvedBoundaryTimesMs(sortedSplits);
    final previewChunks = sortedSplits.isEmpty
        ? const <LyricLine>[]
        : sliceLyricLineForSplit(
            widget.line,
            sortedSplits,
            boundaryTimesMs: resolvedTimes,
            idFactory: (idx) => 'split-preview-$idx',
          );

    return AlertDialog(
      title: '按字拆分歌词',
      hasFields: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: sortedSplits.isNotEmpty
              ? () => Navigator.of(context).pop((
                  splits: sortedSplits,
                  times: _resolvedBoundaryTimesMs(sortedSplits),
                ))
              : null,
          child: const Text('确认拆分'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '原句时段 ${formatMsToClock(widget.line.startTimeMs)} → ${formatMsToClock(widget.line.endTimeMs)} · 共 ${_runeChars.length} 字',
            style: AppTextStyle.caption1.of(context).copyWith(
              color: scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TonalChip(
                label: '均分 2 段',
                color: scheme.secondaryContainer,
                foregroundColor: scheme.onSecondaryContainer,
                onPressed: _resetTwoWayMidpoint,
              ),
              TonalChip(
                label: '清空切分',
                color: scheme.surfaceContainerHigh,
                foregroundColor: scheme.onSurface,
                onPressed: sortedSplits.isEmpty ? null : _clearAllSplits,
              ),
              if (_customTimeBySplitIdx.isNotEmpty)
                TonalChip(
                  label: '按字数均分时间',
                  color: scheme.surfaceContainerHigh,
                  foregroundColor: scheme.onSurface,
                  onPressed: _resetProportionalTimes,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '点击字间分隔符 ⋮ / ✂ 选择拆分位置：',
            style: AppTextStyle.caption2.of(context).copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: ShapeDecoration(
              color: scheme.surfaceContainerLow,
              shape: AppShape.lg,
            ),
            child: Wrap(
              spacing: 2,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (var i = 0; i < _runeChars.length; i++) ...[
                  Builder(
                    builder: (context) {
                      final chunkIdx = _splitIndices.where((s) => s <= i).length;
                      final evenChunk = chunkIdx.isEven;
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: ShapeDecoration(
                          color: evenChunk
                              ? scheme.primaryContainer.withValues(alpha: 0.72)
                              : scheme.secondaryContainer.withValues(alpha: 0.72),
                          shape: AppShape.sm,
                        ),
                        child: Text(
                          _runeChars[i] == ' ' ? '␣' : _runeChars[i],
                          style: AppTextStyle.subheadline
                              .of(context, emphasized: true)
                              .copyWith(
                                color: evenChunk
                                    ? scheme.onPrimaryContainer
                                    : scheme.onSecondaryContainer,
                              ),
                        ),
                      );
                    },
                  ),
                  if (i < _runeChars.length - 1)
                    Semantics(
                      label: '在第 ${i + 1} 字后拆分',
                      button: true,
                      toggled: _splitIndices.contains(i + 1),
                      excludeSemantics: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _toggleSplitAt(i + 1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 4,
                          ),
                          decoration: ShapeDecoration(
                            color: _splitIndices.contains(i + 1)
                                ? scheme.primary
                                : scheme.surfaceContainerHigh,
                            shape: AppShape.sm,
                          ),
                          child: Text(
                            _splitIndices.contains(i + 1) ? '✂' : '⋮',
                            style: AppTextStyle.caption1
                                .of(context, emphasized: true)
                                .copyWith(
                                  color: _splitIndices.contains(i + 1)
                                      ? scheme.onPrimary
                                      : scheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
          if (sortedSplits.isNotEmpty) ...[
            const SizedBox(height: 10),
            ListenableBuilder(
              listenable: widget.controller.playbackListenable,
              builder: (context, _) {
                final nowMs = widget.controller.currentTimeMs;
                final canUseCurrentTime = nowMs > widget.line.startTimeMs &&
                    nowMs < widget.line.endTimeMs;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < sortedSplits.length; i++) ...[
                      Padding(
                        padding: EdgeInsets.only(bottom: i < sortedSplits.length - 1 ? 8 : 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '切分点 ${i + 1}（第 ${sortedSplits[i]} 字后）时间戳',
                              style: AppTextStyle.caption1
                                  .of(context, emphasized: true)
                                  .copyWith(color: scheme.onSurface),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                  width: 118,
                                  child: TextField(
                                    controller: _ctrlsBySplitIdx[sortedSplits[i]],
                                    decoration: const InputDecoration(
                                      hintText: 'mm:ss.ms',
                                    ),
                                    onChanged: (raw) {
                                      final parsed = _parseClockText(raw);
                                      if (parsed != null) {
                                        setState(() {
                                          _customTimeBySplitIdx[sortedSplits[i]] =
                                              parsed;
                                        });
                                      }
                                    },
                                  ),
                                ),
                                if (canUseCurrentTime)
                                  TonalChip(
                                    label: '采用当前时刻 ${formatMsToClock(nowMs)}',
                                    color: scheme.tertiaryContainer,
                                    foregroundColor: scheme.onTertiaryContainer,
                                    onPressed: () => _setBoundaryTimeMs(
                                      sortedSplits[i],
                                      nowMs,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 10),
            Text(
              '拆分预览（${previewChunks.length} 句）',
              style: AppTextStyle.caption1
                  .of(context, emphasized: true)
                  .copyWith(color: scheme.primary),
            ),
            const SizedBox(height: 6),
            for (var i = 0; i < previewChunks.length; i++)
              Container(
                margin: EdgeInsets.only(
                  bottom: i < previewChunks.length - 1 ? 6 : 0,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: ShapeDecoration(
                  color: scheme.surfaceContainerLow,
                  shape: AppShape.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '#${i + 1} · ${formatMsToClock(previewChunks[i].startTimeMs)} → ${formatMsToClock(previewChunks[i].endTimeMs)}',
                      style: AppTextStyle.caption2.of(context).copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      previewChunks[i].text.original,
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    if (previewChunks[i].alignedCalls.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '保留 ${previewChunks[i].alignedCalls.length} 个词对位 Call',
                          style: AppTextStyle.caption2.of(context).copyWith(
                            color: scheme.tertiary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _CreatePresetDialog extends StatefulWidget {
  const _CreatePresetDialog({required this.existingPresets});

  final List<CallPreset> existingPresets;

  @override
  State<_CreatePresetDialog> createState() => _CreatePresetDialogState();
}

class _CreatePresetDialogState extends State<_CreatePresetDialog> {
  final TextEditingController _labelCtrl = TextEditingController();
  final TextEditingController _shortcutCtrl = TextEditingController(text: 'Q');
  String _colorHex = '#EC4899';
  CallCategory _category = CallCategory.compound;
  static const _palette = [
    '#EF4444',
    '#F59E0B',
    '#8B5CF6',
    '#06B6D4',
    '#10B981',
    '#EC4899',
    '#14B8A6',
    '#2563EB',
  ];

  @override
  void dispose() {
    _labelCtrl.dispose();
    _shortcutCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final shortcutCheck = validatePresetShortcut(
      _shortcutCtrl.text,
      existingPresets: widget.existingPresets,
    );
    final canCreate =
        _labelCtrl.text.trim().isNotEmpty && shortcutCheck.isValid;
    return AlertDialog(
      title: '添加自定义 Call 标签',
      hasFields: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canCreate
              ? () => Navigator.of(context).pop((
                  label: _labelCtrl.text,
                  colorHex: _colorHex,
                  category: _category,
                  shortcut: shortcutCheck.normalized,
                ))
              : null,
          child: const Text('创建'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _labelCtrl,
            decoration: const InputDecoration(hintText: '标签名称（如：园长 / 克拉普）'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _shortcutCtrl,
            decoration: const InputDecoration(hintText: '快捷键（单字符，如 Q / W）'),
            onChanged: (_) => setState(() {}),
          ),
          if (!shortcutCheck.isValid && shortcutCheck.errorMessage != null) ...[
            const SizedBox(height: 6),
            Text(
              shortcutCheck.errorMessage!,
              style: AppTextStyle.caption2.of(context).copyWith(
                color: scheme.error,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final hex in _palette)
                GestureDetector(
                  onTap: () => setState(() => _colorHex = hex),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Color(
                        int.parse('FF${hex.substring(1)}', radix: 16),
                      ),
                      shape: BoxShape.circle,
                      border: _colorHex == hex
                          ? Border.all(
                              color: scheme.onSurface,
                              width: 2.5,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedControl<CallCategory>(
            segments: const [
              (CallCategory.downbeat, '正拍'),
              (CallCategory.upbeat, '里拍'),
              (CallCategory.build, '推升'),
              (CallCategory.compound, '复合'),
            ],
            value: _category,
            onChanged: (v) => setState(() => _category = v),
          ),
        ],
      ),
    );
  }
}

class _EditLineDialog extends StatefulWidget {
  const _EditLineDialog({
    required this.line,
    this.autofocusOriginal = false,
  });

  final LyricLine line;
  final bool autofocusOriginal;

  @override
  State<_EditLineDialog> createState() => _EditLineDialogState();
}

class _EditLineDialogState extends State<_EditLineDialog> {
  late final TextEditingController _originalCtrl = TextEditingController(
    text: widget.line.text.original,
  );
  late final TextEditingController _transCtrl = TextEditingController(
    text: widget.line.text.translation ?? '',
  );
  late final TextEditingController _shoutCtrl = TextEditingController(
    text: widget.line.customShout,
  );
  late final TextEditingController _startCtrl = TextEditingController(
    text: formatMsToClock(widget.line.startTimeMs),
  );
  late final TextEditingController _endCtrl = TextEditingController(
    text: formatMsToClock(widget.line.endTimeMs),
  );
  late LyricLineKind _selectedKind = widget.line.kind;

  @override
  void dispose() {
    _originalCtrl.dispose();
    _transCtrl.dispose();
    _shoutCtrl.dispose();
    _startCtrl.dispose();
    _endCtrl.dispose();
    super.dispose();
  }

  void _closeWithAction(String action) {
    final parsedStart =
        _parseClockText(_startCtrl.text) ?? widget.line.startTimeMs;
    final parsedEnd = _parseClockText(_endCtrl.text) ?? widget.line.endTimeMs;
    Navigator.of(context).pop((
      action: action,
      startTimeMs: parsedStart,
      endTimeMs: math.max(parsedStart + 500, parsedEnd),
      kind: _selectedKind,
      original: _originalCtrl.text,
      translation: _transCtrl.text,
      customShout: _shoutCtrl.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final canSplitEdited =
        !_selectedKind.isSection && _originalCtrl.text.runes.length >= 2;
    return AlertDialog(
      title: '编辑歌词与段落',
      hasFields: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => _closeWithAction('save'),
          child: const Text('保存'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedControl<LyricLineKind>(
            segments: const [
              (LyricLineKind.lyric, '歌词'),
              (LyricLineKind.intro, '前奏'),
              (LyricLineKind.interlude, '间奏'),
              (LyricLineKind.outro, '尾奏'),
            ],
            value: _selectedKind,
            onChanged: (v) {
              setState(() {
                _selectedKind = v;
                if (v.isSection &&
                    (_originalCtrl.text.trim().isEmpty ||
                        _originalCtrl.text.trim().startsWith('【'))) {
                  _originalCtrl.text = v.bracketTitle;
                }
              });
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _startCtrl,
                  decoration: const InputDecoration(
                    hintText: '开始 mm:ss.ms',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _endCtrl,
                  decoration: const InputDecoration(
                    hintText: '结束 mm:ss.ms',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _originalCtrl,
            autofocus: widget.autofocusOriginal,
            decoration: const InputDecoration(
              hintText: '歌词原文 / 段落标题',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _transCtrl,
            decoration: const InputDecoration(hintText: '中文翻译 / 段落说明'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _shoutCtrl,
            decoration: const InputDecoration(hintText: '自定义口上 / Mix'),
          ),
          if (canSplitEdited) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TonalChip(
                label: '按字拆分此句',
                color: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
                onPressed: () => _closeWithAction('split'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EditSuffixDialog extends StatefulWidget {
  const _EditSuffixDialog({
    required this.preset,
    required this.initialSuffix,
    required this.isSingAlong,
  });

  final CallPreset preset;
  final String initialSuffix;
  final bool isSingAlong;

  @override
  State<_EditSuffixDialog> createState() => _EditSuffixDialogState();
}

class _EditSuffixDialogState extends State<_EditSuffixDialog> {
  late final TextEditingController _suffixCtrl = TextEditingController(
    text: widget.initialSuffix,
  );

  @override
  void dispose() {
    _suffixCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return AlertDialog(
      title: widget.isSingAlong
          ? '编辑跟唱部分'
          : '${widget.preset.label} 备注 / 倍率',
      hasFields: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop((
            removed: true,
            suffix: '',
          )),
          child: Text('移除', style: TextStyle(color: scheme.error)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            removed: false,
            suffix: _suffixCtrl.text,
          )),
          child: const Text('确认'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _suffixCtrl,
            autofocus: true,
            decoration: InputDecoration(
              hintText: widget.isSingAlong
                  ? '例如：La la la~ / 副歌跟唱句'
                  : '例如：×4、全员、加速',
            ),
            onSubmitted: (_) => Navigator.of(context).pop((
              removed: false,
              suffix: _suffixCtrl.text,
            )),
          ),
          if (!widget.isSingAlong) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final quick in const ['×2', '×4', '全员', '加速'])
                  TonalChip(
                    label: quick,
                    color: scheme.secondaryContainer,
                    foregroundColor: scheme.onSecondaryContainer,
                    onPressed: () => Navigator.of(context).pop((
                      removed: false,
                      suffix: quick,
                    )),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
