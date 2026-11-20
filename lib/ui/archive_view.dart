import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../models/callbook_models.dart';
import '../state/callbook_controller.dart';
import 'theme/app_motion.dart';
import 'theme/app_tokens.dart';
import 'widgets/app_dialog.dart';
import 'widgets/archive_switcher_dialog.dart';
import 'widgets/callbook_glyphs.dart';
import 'widgets/scroll_to_top_button.dart';

sealed class _ArchiveListItem {
  const _ArchiveListItem(this.key);
  final Object key;
}

final class _ArchiveHeaderItem extends _ArchiveListItem {
  const _ArchiveHeaderItem() : super('__archive_header__');
}

final class _ArchiveEmptyItem extends _ArchiveListItem {
  const _ArchiveEmptyItem() : super('__archive_empty__');
}

final class _ArchiveEntryItem extends _ArchiveListItem {
  _ArchiveEntryItem(this.entry) : super(entry.id);
  final CallbookArchiveEntry entry;
}

class ArchiveView extends StatefulWidget {
  const ArchiveView({super.key, required this.controller});

  final CallbookController controller;

  /// Formats [ms] as `MM-dd HH:mm` when in the same calendar year as [now],
  /// or `yyyy-MM-dd HH:mm` when crossing into another year.
  static String formatSavedTime(int ms, {DateTime? now}) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final refYear = (now ?? DateTime.now()).year;
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    if (dt.year != refYear) {
      final yyyy = dt.year.toString().padLeft(4, '0');
      return '$yyyy-$mm-$dd $hh:$mi';
    }
    return '$mm-$dd $hh:$mi';
  }

  /// Resolves the distinct status badge colors for the 4 project archive states.
  static ({Color background, Color foreground}) statusBadgeColors(
    ColorScheme scheme, {
    required bool isSynced,
    required bool hasActiveArchive,
    required bool needsSavePromptBeforeSwitch,
  }) {
    if (isSynced) {
      return (
        background: scheme.successContainer,
        foreground: scheme.onSuccessContainer,
      );
    }
    if (hasActiveArchive) {
      return (
        background: scheme.warningContainer,
        foreground: scheme.onWarningContainer,
      );
    }
    if (needsSavePromptBeforeSwitch) {
      return (
        background: scheme.tertiaryContainer,
        foreground: scheme.onTertiaryContainer,
      );
    }
    return (
      background: scheme.surfaceContainerHigh,
      foreground: scheme.onSurfaceVariant,
    );
  }

  @override
  State<ArchiveView> createState() => _ArchiveViewState();
}

class _ArchiveViewState extends State<ArchiveView> {
  final ScrollController _scrollController = ScrollController();
  bool _saveAsMode = false;
  String? _editingId;
  bool _isSwitching = false;
  final TextEditingController _saveAsCtrl = TextEditingController();
  final TextEditingController _renameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.scrollToTopSignal.addListener(_handleScrollToTopSignal);
  }

  @override
  void didUpdateWidget(covariant ArchiveView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.scrollToTopSignal.removeListener(
        _handleScrollToTopSignal,
      );
      widget.controller.scrollToTopSignal.addListener(
        _handleScrollToTopSignal,
      );
    }
  }

  void _handleScrollToTopSignal() {
    if (!mounted) return;
    final c = widget.controller;
    if (c.isPracticeMode || c.route != StudioRoute.archive) return;
    unawaited(ScrollToTopButton.scrollToTop(context, _scrollController));
  }

  @override
  void dispose() {
    widget.controller.scrollToTopSignal.removeListener(
      _handleScrollToTopSignal,
    );
    _scrollController.dispose();
    _saveAsCtrl.dispose();
    _renameCtrl.dispose();
    super.dispose();
  }

  String _formatSavedTime(int ms) => ArchiveView.formatSavedTime(ms);

  String _currentLabel(CallbookController c) {
    final active = c.activeArchiveEntry;
    if (active != null) return active.name;
    final title = c.project.meta.title.trim();
    return title.isNotEmpty ? title : '未命名 Call 本';
  }

  Future<void> _handleSwitch(
    CallbookController c,
    CallbookArchiveEntry entry,
  ) async {
    if (_isSwitching) return;
    _isSwitching = true;
    try {
      if (entry.id == c.activeArchiveId && !c.needsSavePromptBeforeSwitch) {
        c.setStatus('当前已处于存档「${entry.name}」');
        return;
      }

      if (c.needsSavePromptBeforeSwitch && mounted) {
        final ok = await confirmArchiveSaveIfNeeded(
          context,
          c,
          actionLabel: '切换存档',
          targetLabel: entry.name,
        );
        if (!ok) return;
      }

      await c.switchToArchive(entry.id);
    } finally {
      _isSwitching = false;
    }
  }

  Future<void> _confirmDelete(
    CallbookController c,
    CallbookArchiveEntry entry,
  ) async {
    final scheme = context.colorScheme;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (confirmCtx) => AlertDialog(
        title: '删除 Call 本存档？',
        actions: [
          TextButton(
            onPressed: () => Navigator.of(confirmCtx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(confirmCtx).pop(true),
            child: Text(
              '删除存档',
              style: TextStyle(color: scheme.error),
            ),
          ),
        ],
        child: Text(
          '确定要删除存档「${entry.name}」吗？该操作不可撤销。',
          style: AppTextStyle.subheadline.of(confirmCtx).copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
    if (ok == true) {
      c.deleteArchive(entry.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return AnimatedBuilder(
      animation: Listenable.merge([c.archiveListenable, c.projectListenable]),
      builder: (ctx, _) {
        final scheme = ctx.colorScheme;
        final bottomInset = BottomInsetScope.of(ctx);
        final currentLabel = _currentLabel(c);
        final archives = c.sortedArchives;
        final isSynced = c.activeArchiveId != null && !c.hasUnsavedChanges;
        final statusText = c.siteText(
          isSynced
              ? '已同步存档'
              : (c.activeArchiveId != null
                    ? '有未保存更改'
                    : (c.needsSavePromptBeforeSwitch ? '待归档' : '示例工程')),
        );

        final listItems = <_ArchiveListItem>[
          const _ArchiveHeaderItem(),
          if (archives.isEmpty)
            const _ArchiveEmptyItem()
          else
            for (final entry in archives) _ArchiveEntryItem(entry),
        ];

        return Stack(
          children: [
            KeyedAnimatedList<_ArchiveListItem>(
              controller: _scrollController,
              items: listItems,
              keyOf: (item) => item.key,
              duration: AppMotion.d(ctx, AppMotion.effectsSlow),
              padding: EdgeInsets.fromLTRB(16, 4, 16, 20 + bottomInset),
              itemBuilder: (itemCtx, item) => switch (item) {
                _ArchiveHeaderItem() => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _buildHeaderCard(
                    itemCtx,
                    scheme,
                    c,
                    currentLabel: currentLabel,
                    archivesCount: archives.length,
                    isSynced: isSynced,
                    statusText: statusText,
                  ),
                ),
                _ArchiveEmptyItem() => _buildEmptyCard(itemCtx, scheme),
                _ArchiveEntryItem(:final entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _buildArchiveCard(itemCtx, scheme, c, entry),
                ),
              },
            ),
            ScrollToTopButton(
              scrollController: _scrollController,
              controller: c,
              bottomOffset: 16 + bottomInset,
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeaderCard(
    BuildContext ctx,
    ColorScheme scheme,
    CallbookController c, {
    required String currentLabel,
    required int archivesCount,
    required bool isSynced,
    required String statusText,
  }) {
    final statusDuration = AppMotion.d(ctx, AppMotion.effectsDefault);
    final statusColors = ArchiveView.statusBadgeColors(
      scheme,
      isSynced: isSynced,
      hasActiveArchive: c.activeArchiveId != null,
      needsSavePromptBeforeSwitch: c.needsSavePromptBeforeSwitch,
    );
    final statusBg = statusColors.background;
    final statusFg = statusColors.foreground;

    return Card(
      inert: true,
      radius: AppTokens.radiusCard,
      padding: const EdgeInsets.all(AppTokens.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: ShapeDecoration(
                  color: scheme.primaryContainer,
                  shape: AppShape.all(10),
                ),
                alignment: Alignment.center,
                child: GlyphIcon(
                  CallbookGlyphs.archive,
                  size: 18,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.headline
                          .of(ctx, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${c.project.lines.length} 行歌词 · ${c.project.alerts.length} 条 GT 警报 · 共 $archivesCount 个已存工程',
                      style: AppTextStyle.caption1.of(ctx).copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AnimatedContainer(
                duration: statusDuration,
                curve: AppMotion.curveEffects,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: ShapeDecoration(
                  color: statusBg,
                  shape: AppShape.full,
                ),
                child: AnimatedSwitcher(
                  duration: statusDuration,
                  switchInCurve: AppMotion.curveEffects,
                  switchOutCurve: AppMotion.curveEffectsReverse,
                  child: Text(
                    statusText,
                    key: ValueKey<String>(statusText),
                    style: AppTextStyle.caption2
                        .of(ctx, emphasized: true)
                        .copyWith(color: statusFg),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AnimatedSize(
            duration: statusDuration,
            curve: AppMotion.curveEffects,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: statusDuration,
              switchInCurve: AppMotion.curveEffects,
              switchOutCurve: AppMotion.curveEffectsReverse,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: child,
              ),
              child: !_saveAsMode
                  ? Align(
                      key: const ValueKey<bool>(false),
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton(
                            onPressed: () => c.saveCurrentToArchive(),
                            child: Text(
                              c.activeArchiveId != null ? '更新当前存档' : '保存到存档',
                            ),
                          ),
                          TonalButton(
                            label: '另存副本',
                            onPressed: () {
                              _saveAsCtrl.text = '$currentLabel (副本)';
                              setState(() => _saveAsMode = true);
                            },
                          ),
                        ],
                      ),
                    )
                  : Column(
                      key: const ValueKey<bool>(true),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _saveAsCtrl,
                          decoration: const InputDecoration(
                            hintText: '输入新存档名称...',
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton(
                              onPressed: () {
                                final targetName =
                                    _saveAsCtrl.text.trim().isEmpty
                                    ? '$currentLabel (副本)'
                                    : _saveAsCtrl.text.trim();
                                FocusManager.instance.primaryFocus?.unfocus();
                                c.saveCurrentToArchive(
                                  asNew: true,
                                  customName: targetName,
                                );
                                setState(() => _saveAsMode = false);
                              },
                              child: const Text('确定保存'),
                            ),
                            TonalButton(
                              label: '取消',
                              onPressed: () {
                                FocusManager.instance.primaryFocus?.unfocus();
                                setState(() => _saveAsMode = false);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyCard(BuildContext ctx, ColorScheme scheme) {
    return Card(
      inert: true,
      radius: AppTokens.radiusCard,
      padding: const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: 28,
      ),
      child: Column(
        children: [
          GlyphIcon(
            CallbookGlyphs.archive,
            size: 32,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(
            '暂无已保存的 Call 本存档',
            style: AppTextStyle.subheadline
                .of(ctx, emphasized: true)
                .copyWith(color: scheme.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            '点击上方「保存到存档」，或在拉取新曲目歌词触发提示时选择保存，即可在这里管理与切换。',
            textAlign: TextAlign.center,
            style: AppTextStyle.caption1.of(ctx).copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArchiveCard(
    BuildContext context,
    ColorScheme scheme,
    CallbookController c,
    CallbookArchiveEntry entry,
  ) {
    final isCurrent = entry.id == c.activeArchiveId;
    final isEditing = _editingId == entry.id;

    final menuItems = <PopupMenuItem>[
      PopupMenuItem(
        label: c.siteText('重命名'),
        onPressed: () {
          _renameCtrl.text = entry.name;
          setState(() => _editingId = entry.id);
        },
      ),
      PopupMenuItem(
        label: c.siteText('删除'),
        glyph: CallbookGlyphs.trash,
        danger: true,
        onPressed: () => unawaited(_confirmDelete(c, entry)),
      ),
    ];

    final cardContent = Container(
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: isCurrent
            ? scheme.primaryContainer.withValues(alpha: 0.35)
            : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusSection),
          side: BorderSide(
            color: isCurrent ? scheme.primary : scheme.outlineVariant,
          ),
        ),
      ),
      child: isEditing
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _renameCtrl,
                  decoration: const InputDecoration(hintText: '输入存档新名称...'),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TonalChip(
                      label: '保存',
                      color: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      onPressed: () {
                        if (c.renameArchive(entry.id, _renameCtrl.text)) {
                          FocusManager.instance.primaryFocus?.unfocus();
                          setState(() => _editingId = null);
                        }
                      },
                    ),
                    TonalChip(
                      label: '取消',
                      color: scheme.surface,
                      foregroundColor: scheme.onSurfaceVariant,
                      onPressed: () {
                        FocusManager.instance.primaryFocus?.unfocus();
                        setState(() => _editingId = null);
                      },
                    ),
                  ],
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  button: true,
                  selected: isCurrent,
                  label: '存档 ${entry.name}',
                  child: PressSurface(
                    fill: const Color(0x00000000),
                    shape: AppShape.all(AppTokens.radiusSection),
                    tapTarget: AppTokens.minTapTargetSize,
                    selected: isCurrent,
                    onPressed: () => _handleSwitch(c, entry),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTextStyle.subheadline
                                    .of(context, emphasized: true)
                                    .copyWith(color: scheme.onSurface),
                              ),
                            ),
                            if (isCurrent) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: ShapeDecoration(
                                  color: scheme.primary,
                                  shape: AppShape.full,
                                ),
                                child: Text(
                                  '当前',
                                  style: AppTextStyle.caption2
                                      .of(context, emphasized: true)
                                      .copyWith(color: scheme.onPrimary),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${entry.project.meta.artist.isEmpty ? '未知歌手' : entry.project.meta.artist} · ${entry.lineCount} 句 · ${entry.taggedCount} 打标 · ${entry.alertCount} GT · ${_formatSavedTime(entry.savedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.caption1.of(context).copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    TonalChip(
                      label: isCurrent ? '已加载' : '切换到此存档',
                      color: isCurrent
                          ? scheme.surface
                          : scheme.primaryContainer,
                      foregroundColor: isCurrent
                          ? scheme.onSurfaceVariant
                          : scheme.onPrimaryContainer,
                      onPressed: () => _handleSwitch(c, entry),
                    ),
                    const Spacer(),
                    Text(
                      c.siteText('长按或右键可重命名 / 删除'),
                      style: AppTextStyle.caption2.of(context).copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );

    return ContextMenuRegion(
      menuItems: isEditing ? null : menuItems,
      child: cardContent,
    );
  }
}
