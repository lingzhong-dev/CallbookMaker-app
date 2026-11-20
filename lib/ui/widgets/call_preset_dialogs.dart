import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../models/callbook_models.dart';
import '../../state/callbook_controller.dart';
import '../theme/app_tokens.dart';
import 'app_dialog.dart';
import 'callbook_glyphs.dart';

const List<String> customPresetColorPalette = [
  '#EF4444',
  '#F59E0B',
  '#8B5CF6',
  '#06B6D4',
  '#10B981',
  '#EC4899',
  '#14B8A6',
  '#2563EB',
];

enum _PresetContextAction { edit, delete }

Future<void> triggerCallPresetWithUi({
  required BuildContext context,
  required CallbookController controller,
  required String presetId,
  String? lineId,
  bool? autoAdvance,
}) async {
  final effectiveAutoAdvance = autoAdvance ?? controller.autoAdvanceOnTag;
  LyricLine? targetLine;
  if (lineId != null) {
    for (final line in controller.project.lines) {
      if (line.id == lineId) {
        targetLine = line;
        break;
      }
    }
  } else {
    targetLine = controller.resolveLineForQuickTag();
  }

  if (targetLine == null) {
    controller.setStatus('暂无可打标的歌词行');
    return;
  }

  final targetId = targetLine.id;
  if (controller.activeLineId != targetId) {
    controller.selectLine(targetId);
  }

  if (presetId == singAlongPresetId) {
    final alreadyTagged = targetLine.calls.any(
      (c) => c.presetId == singAlongPresetId,
    );
    if (alreadyTagged) {
      controller.toggleLineCall(targetId, singAlongPresetId);
      return;
    }

    final entered = await showSingAlongInputDialog(context);
    final clean = entered?.trim() ?? '';
    if (clean.isEmpty) return;

    LyricLine? latestLine;
    for (final l in controller.project.lines) {
      if (l.id == targetId) {
        latestLine = l;
        break;
      }
    }
    if (latestLine == null) return;

    final stillHasTag = latestLine.calls.any(
      (c) => c.presetId == singAlongPresetId,
    );
    if (stillHasTag) {
      controller.setCallTagSuffix(targetId, singAlongPresetId, clean);
    } else {
      final added = controller.toggleLineCall(
        targetId,
        singAlongPresetId,
        suffix: clean,
      );
      if (added && effectiveAutoAdvance) {
        controller.stepActiveLine(1);
      }
    }
    return;
  }

  final added = controller.toggleLineCall(targetId, presetId);
  if (added && effectiveAutoAdvance) {
    controller.stepActiveLine(1);
  }
}

Future<String?> showSingAlongInputDialog(
  BuildContext context, {
  String initialValue = '',
  bool isEditing = false,
}) {
  return showAppDialog<String>(
    context: context,
    builder: (ctx) => _SingAlongDialogModal(
      initialValue: initialValue,
      isEditing: isEditing,
    ),
  );
}

class _SingAlongDialogModal extends StatefulWidget {
  const _SingAlongDialogModal({
    required this.initialValue,
    required this.isEditing,
  });

  final String initialValue;
  final bool isEditing;

  @override
  State<_SingAlongDialogModal> createState() => _SingAlongDialogModalState();
}

class _SingAlongDialogModalState extends State<_SingAlongDialogModal> {
  late final TextEditingController _textCtrl = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final canSubmit = _textCtrl.text.trim().isNotEmpty;
    return AlertDialog(
      title: widget.isEditing ? '编辑跟唱部分' : '输入跟唱部分',
      hasFields: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canSubmit
              ? () => Navigator.of(context).pop(_textCtrl.text.trim())
              : null,
          child: const Text('确认跟唱'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '请输入需要观众/同好一起跟唱的歌词或旋律片段，确认后将显示在「跟唱」徽章与导出 Call 本中。',
            style: AppTextStyle.caption1.of(context).copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _textCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '例如：La la la~ / 副歌跟唱句',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) {
                Navigator.of(context).pop(value.trim());
              }
            },
          ),
        ],
      ),
    );
  }
}

List<PopupMenuItem> buildCustomPresetMenuItems(
  BuildContext context, {
  required CallbookController controller,
  required CallPreset preset,
}) {
  if (preset.builtIn) return const [];
  return [
    PopupMenuItem(
      label: '修改名称 / 颜色',
      onPressed: () => unawaited(
        showEditCustomPresetDialog(
          context,
          controller: controller,
          preset: preset,
        ),
      ),
    ),
    PopupMenuItem(
      label: '删除自定义标签',
      glyph: CallbookGlyphs.trash,
      danger: true,
      onPressed: () => unawaited(
        showDeleteCustomPresetDialog(
          context,
          controller: controller,
          preset: preset,
        ),
      ),
    ),
  ];
}

Future<void> showCustomPresetContextMenu(
  BuildContext context, {
  required CallbookController controller,
  required CallPreset preset,
  required Offset globalPosition,
}) async {
  if (preset.builtIn) return;

  final action = await showAppDialog<_PresetContextAction>(
    context: context,
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      final scheme = ctx.colorScheme;
      const menuWidth = 204.0;
      const menuHeight = 132.0;
      final left = globalPosition.dx
          .clamp(12.0, math.max(12.0, size.width - menuWidth - 12.0))
          .toDouble();
      final top = globalPosition.dy
          .clamp(12.0, math.max(12.0, size.height - menuHeight - 12.0))
          .toDouble();

      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: menuWidth,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: scheme.surfaceContainerHigh,
                shape: AppShape.lg,
                shadows: [
                  BoxShadow(
                    color: scheme.shadow.withValues(alpha: 0.22),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: preset.color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              preset.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyle.caption1
                                  .of(ctx, emphasized: true)
                                  .copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      height: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.45),
                    ),
                    const SizedBox(height: 4),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () =>
                          Navigator.of(ctx).pop(_PresetContextAction.edit),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        decoration: ShapeDecoration(
                          color: scheme.surfaceContainerLow,
                          shape: AppShape.md,
                        ),
                        child: Row(
                          children: [
                            GlyphIcon(
                              CallbookGlyphs.studio,
                              size: 15,
                              color: scheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '修改名称 / 颜色',
                                style: AppTextStyle.caption1
                                    .of(ctx, emphasized: true)
                                    .copyWith(color: scheme.onSurface),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () =>
                          Navigator.of(ctx).pop(_PresetContextAction.delete),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        decoration: ShapeDecoration(
                          color: scheme.errorContainer,
                          shape: AppShape.md,
                        ),
                        child: Row(
                          children: [
                            GlyphIcon(
                              CallbookGlyphs.trash,
                              size: 15,
                              color: scheme.onErrorContainer,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '删除自定义标签',
                                style: AppTextStyle.caption1
                                    .of(ctx, emphasized: true)
                                    .copyWith(color: scheme.onErrorContainer),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

  if (!context.mounted || action == null) return;
  switch (action) {
    case _PresetContextAction.edit:
      await showEditCustomPresetDialog(
        context,
        controller: controller,
        preset: preset,
      );
    case _PresetContextAction.delete:
      await showDeleteCustomPresetDialog(
        context,
        controller: controller,
        preset: preset,
      );
  }
}

Future<void> showEditCustomPresetDialog(
  BuildContext context, {
  required CallbookController controller,
  required CallPreset preset,
}) async {
  if (preset.builtIn) return;

  final result = await showAppDialog<({String label, String colorHex})>(
    context: context,
    builder: (ctx) => _EditCustomPresetModal(preset: preset),
  );

  if (result != null && result.label.trim().isNotEmpty) {
    controller.updateCustomPreset(
      presetId: preset.id,
      label: result.label.trim(),
      colorHex: result.colorHex,
    );
  }
}

class _EditCustomPresetModal extends StatefulWidget {
  const _EditCustomPresetModal({required this.preset});

  final CallPreset preset;

  @override
  State<_EditCustomPresetModal> createState() => _EditCustomPresetModalState();
}

class _EditCustomPresetModalState extends State<_EditCustomPresetModal> {
  late final TextEditingController _labelCtrl = TextEditingController(
    text: widget.preset.label,
  );
  late final TextEditingController _hexCtrl = TextEditingController(
    text: widget.preset.colorHex.toUpperCase(),
  );
  late String _selectedColorHex = widget.preset.colorHex.toUpperCase();

  @override
  void dispose() {
    _labelCtrl.dispose();
    _hexCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final cleanLabel = _labelCtrl.text.trim();
    if (cleanLabel.isEmpty) return;
    final typedHex = _hexCtrl.text.trim().toUpperCase();
    final resolvedHex = RegExp(r'^#[0-9A-F]{6}$').hasMatch(typedHex)
        ? typedHex
        : _selectedColorHex;
    Navigator.of(context).pop((label: cleanLabel, colorHex: resolvedHex));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final canSave = _labelCtrl.text.trim().isNotEmpty;
    return AlertDialog(
      title: '修改自定义标签',
      hasFields: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canSave ? _submit : null,
          child: const Text('保存修改'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '标签名称',
            style: AppTextStyle.caption1
                .of(context, emphasized: true)
                .copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _labelCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '输入新的标签名称',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          Text(
            '徽章颜色',
            style: AppTextStyle.caption1
                .of(context, emphasized: true)
                .copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final hex in customPresetColorPalette)
                Semantics(
                  button: true,
                  selected: _selectedColorHex.toUpperCase() == hex,
                  label: '颜色 $hex',
                  child: PressSurface(
                    fill: Color(
                      int.parse('FF${hex.substring(1)}', radix: 16),
                    ),
                    shape: AppShape.circle,
                    side: _selectedColorHex.toUpperCase() == hex
                        ? BorderSide(color: scheme.onSurface, width: 2.5)
                        : BorderSide.none,
                    tapTarget: AppTokens.minTapTargetSize,
                    onPressed: () => setState(() {
                      _selectedColorHex = hex;
                      _hexCtrl.text = hex;
                    }),
                    child: const SizedBox(width: 28, height: 28),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _hexCtrl,
            decoration: const InputDecoration(
              hintText: '自定义色值（#RRGGBB）',
            ),
            onChanged: (value) {
              final clean = value.trim().toUpperCase();
              if (RegExp(r'^#[0-9A-F]{6}$').hasMatch(clean)) {
                setState(() => _selectedColorHex = clean);
              }
            },
          ),
        ],
      ),
    );
  }
}

Future<void> showDeleteCustomPresetDialog(
  BuildContext context, {
  required CallbookController controller,
  required CallPreset preset,
}) async {
  if (preset.builtIn) return;

  final usedCount = controller.project.lines
      .where((l) => l.calls.any((c) => c.presetId == preset.id))
      .length;
  final usageNote = usedCount > 0
      ? '（当前已挂载于 $usedCount 句歌词，删除后将同步移除对应徽章）'
      : '';

  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: '删除自定义标签',
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('确认删除'),
        ),
      ],
      child: Text(
        '确定要删除自定义标签「${preset.label}」吗？$usageNote',
        style: AppTextStyle.caption1.of(ctx).copyWith(
          color: ctx.colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );

  if (confirmed == true) {
    controller.deleteCustomPreset(preset.id);
  }
}
