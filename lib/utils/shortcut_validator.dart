import '../models/callbook_models.dart';

class ShortcutValidationResult {
  const ShortcutValidationResult.valid(this.normalized)
    : isValid = true,
      errorMessage = null;

  const ShortcutValidationResult.invalid(this.errorMessage)
    : isValid = false,
      normalized = '';

  final bool isValid;
  final String normalized;
  final String? errorMessage;
}

const Map<String, String> _reservedShortcutReasons = {
  'F': 'F 已用于切换现场演练模式',
  'G': 'G 已用于切换 GT 警报',
  'Z': 'Z 已保留给撤销快捷键',
  'SPACE': '空格键已用于播放/暂停',
  'ARROWUP': '方向键已用于切行和快进退',
  'ARROWDOWN': '方向键已用于切行和快进退',
  'ARROWLEFT': '方向键已用于切行和快进退',
  'ARROWRIGHT': '方向键已用于切行和快进退',
  'UP': '方向键已用于切行和快进退',
  'DOWN': '方向键已用于切行和快进退',
  'LEFT': '方向键已用于切行和快进退',
  'RIGHT': '方向键已用于切行和快进退',
  '↑': '方向键已用于切行和快进退',
  '↓': '方向键已用于切行和快进退',
  '←': '方向键已用于切行和快进退',
  '→': '方向键已用于切行和快进退',
  'HOME': 'Home / Ctrl+Home 已保留给回到顶部',
  'CTRL+HOME': 'Ctrl+Home 已保留给回到顶部',
};

/// Validates a custom call preset shortcut against reserved global shortcuts
/// (F, G, Space, Arrow keys, Z, Ctrl+Home).
ShortcutValidationResult validatePresetShortcut(
  String raw, {
  Iterable<CallPreset> existingPresets = const [],
  String? ignorePresetId,
  bool checkDuplicates = false,
}) {
  if (raw.isEmpty) {
    return const ShortcutValidationResult.valid('');
  }
  if (raw.contains(' ') && raw.trim().isEmpty) {
    return const ShortcutValidationResult.invalid('快捷键冲突：空格键已用于播放/暂停');
  }
  final normalized = raw.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
  if (normalized.isEmpty) {
    return const ShortcutValidationResult.valid('');
  }

  final reservedReason = _reservedShortcutReasons[normalized];
  if (reservedReason != null) {
    return ShortcutValidationResult.invalid('快捷键冲突：$reservedReason');
  }

  if (normalized.length != 1) {
    return const ShortcutValidationResult.invalid('快捷键请填写单个字符（如 Q / W / E）');
  }

  if (checkDuplicates) {
    for (final preset in existingPresets) {
      if (ignorePresetId != null && preset.id == ignorePresetId) continue;
      if (preset.shortcut.trim().toUpperCase() == normalized) {
        return ShortcutValidationResult.invalid(
          '快捷键「$normalized」已被「${preset.label}」占用',
        );
      }
    }
  }

  return ShortcutValidationResult.valid(normalized);
}
