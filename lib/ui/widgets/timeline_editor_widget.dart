import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../models/callbook_models.dart';
import '../../state/callbook_controller.dart';
import '../../utils/lrc_ruby_parser.dart';
import '../../utils/section_detector.dart';
import 'call_badge_pill.dart';
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
  String? _lastPlayingLineId;
  String? _pendingScrollLineId;
  bool _showSectionPanel = false;
  bool _showShortcuts = false;

  @override
  void initState() {
    super.initState();
    _lastActiveLineId = widget.controller.activeLineId;
    _lastPlayingLineId = widget.controller.playingLineId;
    widget.controller.addListener(_handleFollowScroll);
    widget.controller.playingLineIdListenable.addListener(_handleFollowScroll);
  }

  @override
  void didUpdateWidget(covariant TimelineEditorWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleFollowScroll);
      oldWidget.controller.playingLineIdListenable
          .removeListener(_handleFollowScroll);
      _lastActiveLineId = widget.controller.activeLineId;
      _lastPlayingLineId = widget.controller.playingLineId;
      widget.controller.addListener(_handleFollowScroll);
      widget.controller.playingLineIdListenable.addListener(_handleFollowScroll);
    }
  }

  void _handleFollowScroll() {
    final c = widget.controller;
    final nextActive = c.activeLineId;
    final nextPlaying = c.playingLineId;

    String? targetId;
    if (nextActive != null && nextActive != _lastActiveLineId) {
      targetId = nextActive;
    } else if (c.followPlayback &&
        c.isPlaying &&
        !c.isPracticeMode &&
        nextPlaying != null &&
        nextPlaying != _lastPlayingLineId) {
      targetId = nextPlaying;
    }

    _lastActiveLineId = nextActive;
    _lastPlayingLineId = nextPlaying;

    if (targetId != null && _pendingScrollLineId != targetId) {
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
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: 0.35,
            );
          }
        });
      }
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleFollowScroll);
    widget.controller.playingLineIdListenable
        .removeListener(_handleFollowScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _openCreatePresetDialog(BuildContext context) async {
    final labelCtrl = TextEditingController();
    final shortcutCtrl = TextEditingController(text: '9');
    var colorHex = '#EC4899';
    var category = CallCategory.compound;
    final palette = [
      '#EF4444',
      '#F59E0B',
      '#8B5CF6',
      '#06B6D4',
      '#10B981',
      '#EC4899',
      '#2563EB',
    ];

    final confirmed = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: const Color(0x66000000),
      pageBuilder: (ctx, _, _) => Center(
        child: StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: '添加自定义 Call 标签',
          hasFields: true,
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('创建'),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: labelCtrl,
                decoration: const InputDecoration(hintText: '标签名称（如：园长 / 克拉普）'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: shortcutCtrl,
                decoration: const InputDecoration(hintText: '快捷键（单字符，如 9 / Q）'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final hex in palette)
                    GestureDetector(
                      onTap: () => setModalState(() => colorHex = hex),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Color(
                            int.parse('FF${hex.substring(1)}', radix: 16),
                          ),
                          shape: BoxShape.circle,
                          border: colorHex == hex
                              ? Border.all(
                                  color: context.colorScheme.onSurface,
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
                value: category,
                onChanged: (v) => setModalState(() => category = v),
              ),
            ],
          ),
        ),
      ),
    ),
    );

    if (confirmed == true && labelCtrl.text.trim().isNotEmpty) {
      widget.controller.addCustomPreset(
        label: labelCtrl.text.trim(),
        colorHex: colorHex,
        category: category,
        shortcut: shortcutCtrl.text.trim(),
      );
    }
    labelCtrl.dispose();
    shortcutCtrl.dispose();
  }

  Future<void> _openEditLineDialog(
    BuildContext context,
    LyricLine line,
  ) async {
    final originalCtrl = TextEditingController(text: line.text.original);
    final transCtrl = TextEditingController(text: line.text.translation ?? '');
    final shoutCtrl = TextEditingController(text: line.customShout);
    final startCtrl = TextEditingController(
      text: formatMsToClock(line.startTimeMs),
    );
    final endCtrl = TextEditingController(
      text: formatMsToClock(line.endTimeMs),
    );
    var selectedKind = line.kind;

    final ok = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: const Color(0x66000000),
      pageBuilder: (ctx, _, _) => StatefulBuilder(
        builder: (ctx, setModalState) => Center(
          child: AlertDialog(
            title: '编辑歌词与段落',
            hasFields: true,
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
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
                  value: selectedKind,
                  onChanged: (v) {
                    setModalState(() => selectedKind = v);
                    if (v.isSection &&
                        (originalCtrl.text.trim().isEmpty ||
                            originalCtrl.text.trim().startsWith('【'))) {
                      originalCtrl.text = v.bracketTitle;
                    }
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: startCtrl,
                        decoration: const InputDecoration(
                          hintText: '开始 mm:ss.ms',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: endCtrl,
                        decoration: const InputDecoration(
                          hintText: '结束 mm:ss.ms',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: originalCtrl,
                  decoration: const InputDecoration(hintText: '歌词原文 / 段落标题'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: transCtrl,
                  decoration: const InputDecoration(hintText: '中文翻译 / 段落说明'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: shoutCtrl,
                  decoration: const InputDecoration(hintText: '自定义口上 / Mix'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (ok == true) {
      final parsedStart = _parseClockText(startCtrl.text) ?? line.startTimeMs;
      final parsedEnd = _parseClockText(endCtrl.text) ?? line.endTimeMs;
      widget.controller.updateLineDetails(
        lineId: line.id,
        startTimeMs: parsedStart,
        endTimeMs: math.max(parsedStart + 500, parsedEnd),
        kind: selectedKind,
        original: originalCtrl.text,
        translation: transCtrl.text,
        customShout: shoutCtrl.text,
      );
    }
    originalCtrl.dispose();
    transCtrl.dispose();
    shoutCtrl.dispose();
    startCtrl.dispose();
    endCtrl.dispose();
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
    final suffixCtrl = TextEditingController(text: tag.suffix ?? '');
    final scheme = context.colorScheme;
    final ok = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: const Color(0x66000000),
      pageBuilder: (ctx, _, _) => Center(
        child: AlertDialog(
          title: '${preset.label} 备注 / 倍率',
          hasFields: true,
          actions: [
            TextButton(
              onPressed: () {
                widget.controller.toggleLineCall(line.id, tag.presetId);
                Navigator.of(ctx).pop(false);
              },
              child: Text('移除', style: TextStyle(color: scheme.error)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确认'),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: suffixCtrl,
                decoration: const InputDecoration(hintText: '例如：×4、全员、加速'),
              ),
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
                      onPressed: () {
                        suffixCtrl.text = quick;
                        Navigator.of(ctx).pop(true);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok == true) {
      widget.controller.setCallTagSuffix(line.id, tag.presetId, suffixCtrl.text);
    }
    suffixCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = context.colorScheme;
    final items = c.timelineItems;
    final presetMap = {for (final p in c.allPresets) p.id: p};
    final activeLineHasGt =
        c.activeLineId != null && c.getAlertForLine(c.activeLineId!) != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sticky Call Toolbar Card
        Card(
          inert: true,
          padding: const EdgeInsets.all(14),
          radius: 22,
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
                    'Space 播放/暂停 · 1~8 切换军 Call · G 切换当前行 GT 警报 · ↑/↓ 切行 · ←/→ 跳 2s · F 现场演练',
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
                      onTap: () => c.quickTagActiveLine(preset.id),
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
                            : () => c.toggleTailUpdraft(quickTargetLine.id),
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
              ListenableBuilder(
                listenable: c.playbackListenable,
                builder: (context, _) {
                  final activeAlert = c.activeGtAlertStatus;
                  if (activeAlert == null) return const SizedBox.shrink();
                  final activeCue =
                      (activeAlert.alert.callTimingCue ?? '').trim();
                  return Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: ShapeDecoration(
                        color: activeAlert.isTriggered
                            ? scheme.errorContainer
                            : scheme.warningContainer,
                        shape: AppShape.lg,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      activeAlert.isTriggered
                                          ? 'GT 警报触发!'
                                          : '倒数 ${activeAlert.remainingBeats} 拍进场',
                                      style: AppTextStyle.footnote
                                          .of(context, emphasized: true)
                                          .copyWith(
                                            fontFamily: 'GoogleSans',
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                            color: activeAlert.isTriggered
                                                ? scheme.onErrorContainer
                                                : scheme.onWarningContainer,
                                          ),
                                    ),
                                    if (activeCue.isNotEmpty)
                                      TonalChip(
                                        label: activeCue,
                                        color: activeAlert.isTriggered
                                            ? scheme.error
                                            : scheme.warning,
                                        foregroundColor:
                                            const Color(0xFF000000),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  activeAlert.alert.note,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyle.caption1
                                      .of(context, emphasized: true)
                                      .copyWith(
                                        color: activeAlert.isTriggered
                                            ? scheme.onErrorContainer
                                            : scheme.onWarningContainer,
                                      ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(value: activeAlert.progress),
                        ],
                      ),
                    ),
                  );
                },
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
              return KeyedSubtree(
                key: _lineKeys.putIfAbsent(line.id, GlobalKey.new),
                child: _ReactiveTimelineLineCard(
                  controller: c,
                  line: line,
                  presetMap: presetMap,
                  gtAlert: gtAlert,
                  isSelected: c.activeLineId == line.id,
                  onCreatePreset: () => _openCreatePresetDialog(context),
                  onAddSectionAfter: () => _openAddSectionDialog(
                    context,
                    initialKind: LyricLineKind.interlude,
                    afterLineId: line.id,
                  ),
                  onEditLine: () => _openEditLineDialog(context, line),
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
    required this.onCreatePreset,
    required this.onAddSectionAfter,
    required this.onEditLine,
    required this.onOpenSuffix,
  });

  final CallbookController controller;
  final LyricLine line;
  final Map<String, CallPreset> presetMap;
  final GtAlert? gtAlert;
  final bool isSelected;
  final VoidCallback onCreatePreset;
  final VoidCallback onAddSectionAfter;
  final VoidCallback onEditLine;
  final void Function(LineCallTag tag, CallPreset preset) onOpenSuffix;

  @override
  State<_ReactiveTimelineLineCard> createState() =>
      _ReactiveTimelineLineCardState();
}

class _ReactiveTimelineLineCardState extends State<_ReactiveTimelineLineCard> {
  late bool _isPlaying;
  late bool _isGtCountdown;

  @override
  void initState() {
    super.initState();
    _isPlaying = widget.controller.playingLineId == widget.line.id;
    _isGtCountdown =
        widget.controller.activeGtTargetLineIdListenable.value ==
        widget.line.id;
    widget.controller.playingLineIdListenable.addListener(_onPlaybackChanged);
    widget.controller.activeGtTargetLineIdListenable
        .addListener(_onPlaybackChanged);
  }

  @override
  void didUpdateWidget(covariant _ReactiveTimelineLineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.playingLineIdListenable
          .removeListener(_onPlaybackChanged);
      oldWidget.controller.activeGtTargetLineIdListenable
          .removeListener(_onPlaybackChanged);
      widget.controller.playingLineIdListenable.addListener(_onPlaybackChanged);
      widget.controller.activeGtTargetLineIdListenable
          .addListener(_onPlaybackChanged);
    }
    _isPlaying = widget.controller.playingLineId == widget.line.id;
    _isGtCountdown =
        widget.controller.activeGtTargetLineIdListenable.value ==
        widget.line.id;
  }

  void _onPlaybackChanged() {
    final nextPlaying = widget.controller.playingLineId == widget.line.id;
    final nextCountdown =
        widget.controller.activeGtTargetLineIdListenable.value ==
        widget.line.id;
    if (nextPlaying != _isPlaying || nextCountdown != _isGtCountdown) {
      setState(() {
        _isPlaying = nextPlaying;
        _isGtCountdown = nextCountdown;
      });
    }
  }

  @override
  void dispose() {
    widget.controller.playingLineIdListenable
        .removeListener(_onPlaybackChanged);
    widget.controller.activeGtTargetLineIdListenable
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
    final isGtCountdown = _isGtCountdown;

    final scheme = context.colorScheme;
    final highlighted = isPlaying || isSelected;
    final cueText = (gtAlert?.callTimingCue ?? '').trim();
    final isSection = line.kind.isSection;
    final sectionAccent = _sectionAccentColor(scheme, line.kind);

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
                if (gtAlert != null && cueText.isNotEmpty)
                  TonalChip(
                    label: cueText,
                    color: scheme.surface,
                    foregroundColor: scheme.onSurface,
                  ),
                if (isPlaying)
                  TonalChip(
                    label: 'PLAYING',
                    color: scheme.primary,
                    foregroundColor: scheme.onPrimary,
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
                  onTap: () => c.toggleTailUpdraft(line.id),
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
        if (line.calls.isNotEmpty ||
            line.customShout.trim().isNotEmpty ||
            isSelected) ...[
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
                  ),
              if (line.customShout.trim().isNotEmpty)
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
                    line.customShout.trim(),
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
                    onTap: () => c.toggleLineCall(line.id, preset.id),
                  ),
                  const SizedBox(width: 6),
                ],
                _TailUpdraftToggleChip(
                  enabled: line.tailUpdraft,
                  compact: true,
                  onTap: () => c.toggleTailUpdraft(line.id),
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
        onTap: () => c.selectLine(line.id, seekToLine: true),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              scheme.warningContainer.withValues(alpha: isGtCountdown ? 0.56 : 0.34),
              scheme.surfaceContainerLow,
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: scheme.warning,
              width: isGtCountdown ? 2.2 : (highlighted ? 1.8 : 1.4),
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.warning.withValues(alpha: isGtCountdown ? 0.32 : 0.16),
                blurRadius: isGtCountdown ? 18 : 10,
                spreadRadius: isGtCountdown ? 1 : 0,
              ),
            ],
          ),
          child: body,
        ),
      );
    }

    return Card(
      isSelected: highlighted,
      radius: 20,
      padding: const EdgeInsets.all(14),
      shape: RoundedSuperellipseBorder(
        borderRadius: AppRadius.xl,
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
      onPressed: () => c.selectLine(line.id, seekToLine: true),
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
  static const List<String> _quickCues = [
    'se-no',
    'hi hi',
    'hi hi hihihihi',
    'はいせーの！',
  ];

  late final TextEditingController _cueCtrl = TextEditingController(
    text: widget.alert.callTimingCue ?? '',
  );
  late final TextEditingController _noteCtrl = TextEditingController(
    text: widget.alert.note,
  );
  final FocusNode _cueFocus = FocusNode();
  final FocusNode _noteFocus = FocusNode();

  @override
  void didUpdateWidget(covariant _InlineGtEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextCue = widget.alert.callTimingCue ?? '';
    if (!_cueFocus.hasFocus && _cueCtrl.text != nextCue) {
      _cueCtrl.text = nextCue;
    }
    if (!_noteFocus.hasFocus && _noteCtrl.text != widget.alert.note) {
      _noteCtrl.text = widget.alert.note;
    }
  }

  @override
  void dispose() {
    _cueCtrl.dispose();
    _noteCtrl.dispose();
    _cueFocus.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  void _selectCue(String cue) {
    _cueCtrl.value = TextEditingValue(
      text: cue,
      selection: TextSelection.collapsed(offset: cue.length),
    );
    widget.controller.updateLineGtAlert(widget.lineId, callTimingCue: cue);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final currentCue = (widget.alert.callTimingCue ?? '').trim();

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
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '喊声时机',
                  style: AppTextStyle.caption1
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onWarningContainer),
                ),
                for (final cue in _quickCues)
                  TonalChip(
                    label: cue,
                    color: currentCue == cue
                        ? scheme.warning
                        : scheme.surfaceContainerHighest,
                    foregroundColor: currentCue == cue
                        ? const Color(0xFF000000)
                        : scheme.onSurface,
                    onPressed: () => _selectCue(cue),
                  ),
                for (final beats in const [1, 2, 4, 8])
                  TonalChip(
                    label: '前 $beats 拍',
                    color: widget.alert.leadBeats == beats
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHigh,
                    foregroundColor: widget.alert.leadBeats == beats
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                    onPressed: () => widget.controller.updateLineGtAlert(
                      widget.lineId,
                      leadBeats: beats,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final cueField = TextField(
                  controller: _cueCtrl,
                  focusNode: _cueFocus,
                  decoration: const InputDecoration(
                    hintText: '编者手动输入喊声时机，如 se-no / hi hi / hihihihi',
                  ),
                  onChanged: (v) => widget.controller.updateLineGtAlert(
                    widget.lineId,
                    callTimingCue: v,
                  ),
                );
                final noteField = TextField(
                  controller: _noteCtrl,
                  focusNode: _noteFocus,
                  decoration: const InputDecoration(
                    hintText: '可选备注（如：吉他进场，4拍后进PPPH）',
                  ),
                  onChanged: (v) => widget.controller.updateLineGtAlert(
                    widget.lineId,
                    note: v,
                  ),
                );
                if (constraints.maxWidth >= 520) {
                  return Row(
                    children: [
                      Expanded(child: cueField),
                      const SizedBox(width: 8),
                      Expanded(child: noteField),
                    ],
                  );
                }
                return Column(
                  children: [
                    cueField,
                    const SizedBox(height: 8),
                    noteField,
                  ],
                );
              },
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
