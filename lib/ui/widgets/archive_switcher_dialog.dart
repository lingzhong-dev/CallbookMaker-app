import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../models/callbook_models.dart';
import '../../state/callbook_controller.dart';
import 'callbook_glyphs.dart';

enum _ArchiveSaveDecision { saveAndContinue, discardAndContinue, cancel }

Future<bool> confirmArchiveSaveIfNeeded(
  BuildContext context,
  CallbookController controller, {
  required String actionLabel,
  String? targetLabel,
}) async {
  if (!controller.needsSavePromptBeforeSwitch) {
    return true;
  }

  final scheme = context.colorScheme;
  final currentName = controller.activeArchiveEntry?.name ??
      (controller.project.meta.title.trim().isNotEmpty
          ? controller.project.meta.title.trim()
          : '当前 Call 本');
  final reasonHint = controller.hasFetchedExternalLyrics
      ? '你已拉取/导入「$currentName」的歌词，尚未保存至 Call 本存档。'
      : '当前 Call 本「$currentName」包含尚未保存至存档的修改。';
  final targetHint =
      targetLabel != null && targetLabel.trim().isNotEmpty
          ? '（目标：$targetLabel）'
          : '';

  final decision = await showFloatingDialog<_ArchiveSaveDecision>(
    context: context,
    child: Builder(
      builder: (dialogCtx) => AlertDialog(
        title: '保存当前 Call 本再$actionLabel？',
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(dialogCtx).pop(_ArchiveSaveDecision.cancel),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(
              _ArchiveSaveDecision.discardAndContinue,
            ),
            child: Text(
              '不保存替换',
              style: TextStyle(color: scheme.error),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(
              _ArchiveSaveDecision.saveAndContinue,
            ),
            child: Text(
              controller.activeArchiveId != null ? '更新并继续' : '保存并继续',
            ),
          ),
        ],
        child: Text(
          '$reasonHint在$actionLabel$targetHint之前，是否先将当前 Call 本存入存档？',
          style: AppTextStyle.subheadline.of(dialogCtx).copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );

  if (decision == _ArchiveSaveDecision.saveAndContinue) {
    controller.saveCurrentToArchive();
    return true;
  }
  return decision == _ArchiveSaveDecision.discardAndContinue;
}

Future<void> showArchiveQuickSwitchDialog(
  BuildContext context,
  CallbookController controller,
) async {
  await showFloatingDialog<void>(
    context: context,
    child: Builder(
      builder: (dialogCtx) => _ArchiveQuickSwitchContent(
        parentContext: context,
        dialogContext: dialogCtx,
        controller: controller,
      ),
    ),
  );
}

class _ArchiveQuickSwitchContent extends StatefulWidget {
  const _ArchiveQuickSwitchContent({
    required this.parentContext,
    required this.dialogContext,
    required this.controller,
  });

  final BuildContext parentContext;
  final BuildContext dialogContext;
  final CallbookController controller;

  @override
  State<_ArchiveQuickSwitchContent> createState() =>
      _ArchiveQuickSwitchContentState();
}

class _ArchiveQuickSwitchContentState
    extends State<_ArchiveQuickSwitchContent> {
  bool _saveAsMode = false;
  String? _editingId;
  final TextEditingController _saveAsCtrl = TextEditingController();
  final TextEditingController _renameCtrl = TextEditingController();

  @override
  void dispose() {
    _saveAsCtrl.dispose();
    _renameCtrl.dispose();
    super.dispose();
  }

  String _formatSavedTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '$mm-$dd $hh:$mi';
  }

  String _currentLabel(CallbookController c) {
    final active = c.activeArchiveEntry;
    if (active != null) return active.name;
    final title = c.project.meta.title.trim();
    return title.isNotEmpty ? title : '未命名 Call 本';
  }

  bool _isSwitching = false;

  Future<void> _handleSwitch(
    CallbookController c,
    CallbookArchiveEntry entry,
  ) async {
    if (_isSwitching) return;
    _isSwitching = true;
    try {
      if (entry.id == c.activeArchiveId && !c.needsSavePromptBeforeSwitch) {
        if (widget.dialogContext.mounted) {
          Navigator.of(widget.dialogContext).pop();
        }
        c.setStatus('当前已处于存档「${entry.name}」');
        return;
      }

      if (c.needsSavePromptBeforeSwitch && widget.dialogContext.mounted) {
        final ok = await confirmArchiveSaveIfNeeded(
          widget.dialogContext,
          c,
          actionLabel: '切换存档',
          targetLabel: entry.name,
        );
        if (!ok) return;
      }

      if (widget.dialogContext.mounted) {
        Navigator.of(widget.dialogContext).pop();
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
    final scheme = widget.dialogContext.colorScheme;
    final ok = await showFloatingDialog<bool>(
      context: widget.dialogContext,
      child: Builder(
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
      animation: c,
      builder: (ctx, _) {
        final scheme = ctx.colorScheme;
        final currentLabel = _currentLabel(c);
        final archives = c.sortedArchives;
        final isSynced = c.activeArchiveId != null && !c.hasUnsavedChanges;
        final statusText = isSynced
            ? '已同步存档'
            : (c.activeArchiveId != null
                ? '有未保存更改'
                : (c.needsSavePromptBeforeSwitch ? '待归档' : '示例工程'));

        return AlertDialog(
          title: 'Call 本存档快捷切换',
          hasFields: _saveAsMode || _editingId != null,
          actions: [
            TextButton(
              onPressed: () => Navigator.of(widget.dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
          child: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: ShapeDecoration(
                    color: scheme.surfaceContainerHighest,
                    shape: AppShape.all(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          GlyphIcon(
                            CallbookGlyphs.archive,
                            size: 16,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              currentLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyle.subheadline
                                  .of(ctx, emphasized: true)
                                  .copyWith(color: scheme.onSurface),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: ShapeDecoration(
                              color: isSynced
                                  ? scheme.successContainer
                                  : (c.needsSavePromptBeforeSwitch
                                      ? scheme.warningContainer
                                      : scheme.surface),
                              shape: AppShape.full,
                            ),
                            child: Text(
                              statusText,
                              style: AppTextStyle.caption2
                                  .of(ctx, emphasized: true)
                                  .copyWith(
                                    color: isSynced
                                        ? scheme.onSuccessContainer
                                        : (c.needsSavePromptBeforeSwitch
                                            ? scheme.onWarningContainer
                                            : scheme.onSurfaceVariant),
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${c.project.lines.length} 行歌词 · ${c.project.alerts.length} 条 GT 警报 · 共 ${archives.length} 个已存工程',
                        style: AppTextStyle.caption1.of(ctx).copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (!_saveAsMode)
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            TonalChip(
                              label: c.activeArchiveId != null
                                  ? '更新当前存档'
                                  : '保存到存档',
                              color: scheme.primary,
                              foregroundColor: scheme.onPrimary,
                              onPressed: () => c.saveCurrentToArchive(),
                            ),
                            TonalChip(
                              label: '另存副本',
                              color: scheme.secondaryContainer,
                              foregroundColor: scheme.onSecondaryContainer,
                              onPressed: () {
                                _saveAsCtrl.text = '$currentLabel (副本)';
                                setState(() => _saveAsMode = true);
                              },
                            ),
                          ],
                        )
                      else
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _saveAsCtrl,
                                decoration: const InputDecoration(
                                  hintText: '输入新存档名称...',
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            TonalChip(
                              label: '确定',
                              color: scheme.primary,
                              foregroundColor: scheme.onPrimary,
                              onPressed: () {
                                final targetName = _saveAsCtrl.text.trim().isEmpty
                                    ? '$currentLabel (副本)'
                                    : _saveAsCtrl.text.trim();
                                c.saveCurrentToArchive(
                                  asNew: true,
                                  customName: targetName,
                                );
                                setState(() => _saveAsMode = false);
                              },
                            ),
                            const SizedBox(width: 4),
                            TonalChip(
                              label: '取消',
                              color: scheme.surface,
                              foregroundColor: scheme.onSurfaceVariant,
                              onPressed: () =>
                                  setState(() => _saveAsMode = false),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: archives.isEmpty
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 22,
                          ),
                          decoration: ShapeDecoration(
                            color: scheme.surfaceContainerLow,
                            shape: AppShape.all(16),
                          ),
                          child: Text(
                            '暂无已保存的 Call 本存档。点击上方「保存到存档」，或在拉取新曲目歌词触发提示时选择保存，即可在这里快捷切换。',
                            textAlign: TextAlign.center,
                            style: AppTextStyle.caption1.of(ctx).copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: archives.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, idx) {
                            final entry = archives[idx];
                            final isCurrent = entry.id == c.activeArchiveId;
                            final isEditing = _editingId == entry.id;
                            return Container(
                              padding: const EdgeInsets.all(10),
                              decoration: ShapeDecoration(
                                color: isCurrent
                                    ? scheme.primaryContainer.withValues(
                                        alpha: 0.45,
                                      )
                                    : scheme.surfaceContainerLow,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  side: BorderSide(
                                    color: isCurrent
                                        ? scheme.primary
                                        : scheme.outlineVariant,
                                  ),
                                ),
                              ),
                              child: isEditing
                                  ? Row(
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller: _renameCtrl,
                                            decoration: const InputDecoration(
                                              hintText: '输入存档新名称...',
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        TonalChip(
                                          label: '保存',
                                          color: scheme.primary,
                                          foregroundColor: scheme.onPrimary,
                                          onPressed: () {
                                            if (c.renameArchive(
                                              entry.id,
                                              _renameCtrl.text,
                                            )) {
                                              setState(() => _editingId = null);
                                            }
                                          },
                                        ),
                                        const SizedBox(width: 4),
                                        TonalChip(
                                          label: '取消',
                                          color: scheme.surface,
                                          foregroundColor:
                                              scheme.onSurfaceVariant,
                                          onPressed: () =>
                                              setState(() => _editingId = null),
                                        ),
                                      ],
                                    )
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: GestureDetector(
                                                behavior: HitTestBehavior.opaque,
                                                onTap: () =>
                                                    _handleSwitch(c, entry),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Flexible(
                                                          child: Text(
                                                            entry.name,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: AppTextStyle
                                                                .subheadline
                                                                .of(
                                                                  ctx,
                                                                  emphasized:
                                                                      true,
                                                                )
                                                                .copyWith(
                                                                  color: scheme
                                                                      .onSurface,
                                                                ),
                                                          ),
                                                        ),
                                                        if (isCurrent) ...[
                                                          const SizedBox(
                                                            width: 6,
                                                          ),
                                                          Container(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                              horizontal: 6,
                                                              vertical: 2,
                                                            ),
                                                            decoration:
                                                                ShapeDecoration(
                                                              color:
                                                                  scheme.primary,
                                                              shape:
                                                                  AppShape.full,
                                                            ),
                                                            child: Text(
                                                              '当前',
                                                              style: AppTextStyle
                                                                  .caption2
                                                                  .of(
                                                                    ctx,
                                                                    emphasized:
                                                                        true,
                                                                  )
                                                                  .copyWith(
                                                                    color: scheme
                                                                        .onPrimary,
                                                                  ),
                                                            ),
                                                          ),
                                                        ],
                                                      ],
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      '${entry.project.meta.artist.isEmpty ? '未知歌手' : entry.project.meta.artist} · ${entry.lineCount} 句 · ${entry.taggedCount} 打标 · ${entry.alertCount} GT · ${_formatSavedTime(entry.savedAt)}',
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: AppTextStyle
                                                          .caption2
                                                          .of(ctx)
                                                          .copyWith(
                                                            color: scheme
                                                                .onSurfaceVariant,
                                                          ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 6,
                                          runSpacing: 6,
                                          children: [
                                            TonalChip(
                                              label: isCurrent
                                                  ? '已加载'
                                                  : '切换到此存档',
                                              color: isCurrent
                                                  ? scheme.surface
                                                  : scheme.primaryContainer,
                                              foregroundColor: isCurrent
                                                  ? scheme.onSurfaceVariant
                                                  : scheme.onPrimaryContainer,
                                              onPressed: () =>
                                                  _handleSwitch(c, entry),
                                            ),
                                            TonalChip(
                                              label: '重命名',
                                              color: scheme.surfaceContainerHigh,
                                              foregroundColor: scheme.onSurface,
                                              onPressed: () {
                                                _renameCtrl.text = entry.name;
                                                setState(
                                                  () => _editingId = entry.id,
                                                );
                                              },
                                            ),
                                            TonalChip(
                                              label: '删除',
                                              color: scheme.errorContainer,
                                              foregroundColor:
                                                  scheme.onErrorContainer,
                                              onPressed: () =>
                                                  _confirmDelete(c, entry),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
