import 'package:flutter/widgets.dart';
import 'package:prism_ui/hct/hct.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../state/callbook_controller.dart';
import 'theme/app_motion.dart';
import 'theme/app_tokens.dart';
import 'widgets/callbook_glyphs.dart';

class ThemeView extends StatelessWidget {
  const ThemeView({super.key, required this.controller});

  final CallbookController controller;

  String _hexString(Color color) {
    final rgb = color.toARGB32() & 0x00FFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = context.colorScheme;
    final bottomInset = BottomInsetScope.of(context);

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 20 + bottomInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. 「颜色」卡片
          Card(
            inert: true,
            radius: AppTokens.radiusCard,
            padding: const EdgeInsets.all(AppTokens.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.siteText('颜色'),
                        style: AppTextStyle.headline
                            .of(context, emphasized: true)
                            .copyWith(color: scheme.onSurface),
                      ),
                    ),
                    TonalButton(
                      size: TonalButtonSize.compact,
                      label: c.siteText('恢复默认'),
                      onPressed: c.resetTheme,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 860;
                    final previewSection = _buildThemePreviewSection(
                      context,
                      scheme,
                      c,
                    );
                    final presetSection = _buildPresetsSection(
                      context,
                      scheme,
                      c,
                    );
                    if (wide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: previewSection),
                          const SizedBox(width: 12),
                          Expanded(flex: 7, child: presetSection),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        previewSection,
                        const SizedBox(height: 12),
                        presetSection,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  c.siteText('配色风格'),
                  style: AppTextStyle.caption1.of(context).copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                SegmentedControl<ColorStyle>(
                  segments: const [
                    (ColorStyle.vivid, '鲜艳 Vivid'),
                    (ColorStyle.tinted, '淡雅 Tinted'),
                    (ColorStyle.soft, '柔和 Soft'),
                    (ColorStyle.monochrome, '单色 Mono'),
                  ],
                  value: c.colorStyle,
                  onChanged: c.setColorStyle,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'HCT 色彩调色盘 · 11 × 11 Palette Matrix',
                            style: AppTextStyle.subheadline
                                .of(context, emphasized: true)
                                .copyWith(color: scheme.onSurface),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '直接拖拽或点选任意格子实时生成 Prism ColorScheme 动态配色',
                            style: AppTextStyle.caption1.of(context).copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: ShapeDecoration(
                        color: scheme.primaryContainer,
                        shape: AppShape.full,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: c.seedColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _hexString(c.seedColor),
                            style: AppTextStyle.caption1
                                .of(context, emphasized: true)
                                .copyWith(
                                  fontFamily: 'GoogleSans',
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                  color: scheme.onPrimaryContainer,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final seed in savedSwatchSeeds)
                      _ColorSwatchButton(
                        seed: seed,
                        selected: seed.toARGB32() == c.seedColor.toARGB32(),
                        label: '主题色 ${_hexString(seed)}',
                        onPressed: () => c.setSeedColor(seed),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                _HctPaletteMatrix(
                  selectedColor: c.seedColor,
                  onPick: c.setSeedColor,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 2. 「外观」卡片
          Card(
            inert: true,
            radius: AppTokens.radiusCard,
            padding: const EdgeInsets.all(AppTokens.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  c.siteText('外观'),
                  style: AppTextStyle.headline
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onSurface),
                ),
                const SizedBox(height: 12),
                Text(
                  '主题模式 (ThemeMode)',
                  style: AppTextStyle.caption1.of(context).copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                SegmentedControl<ThemeMode>(
                  segments: const [
                    (ThemeMode.system, '跟随系统'),
                    (ThemeMode.light, '浅色 Light'),
                    (ThemeMode.dark, '深色 Dark'),
                  ],
                  value: c.themeMode,
                  onChanged: c.setThemeMode,
                ),
                const SizedBox(height: 16),
                _SwitchTileRow(
                  title: '纯黑暗色模式 (OLED Pure Black)',
                  subtitle: '深色背景下切换为极净 #000000 舞台黑底，节省便携设备功耗',
                  value: c.pureBlack,
                  onChanged: c.setPureBlack,
                ),
                const SizedBox(height: 10),
                _SwitchTileRow(
                  title: 'Liquid Glass 液态玻璃质感',
                  subtitle: '在悬浮底部导航与模态弹窗启用液态折射效果',
                  value: c.liquidGlass,
                  onChanged: c.setLiquidGlass,
                ),
                const SizedBox(height: 10),
                _SwitchTileRow(
                  title: c.siteText('减少动效'),
                  subtitle: c.siteText(
                    '关闭液态玻璃、节拍脉动、缩放与滑动等装饰动效，仅保留按压反馈与颜色过渡',
                  ),
                  value: c.reduceMotion,
                  onChanged: c.setReduceMotion,
                ),
                const SizedBox(height: 10),
                _SwitchTileRow(
                  title: '悬浮底部导航',
                  subtitle: '移动端与紧凑窗口采用悬浮胶囊底部导航栏',
                  value: c.floatingNavDock,
                  onChanged: c.setFloatingNavDock,
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(AppTokens.s12),
                  decoration: ShapeDecoration(
                    color: scheme.surfaceContainerLow,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: AppTokens.radiusSectionBorder,
                      side: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: ShapeDecoration(
                          color: scheme.primaryContainer,
                          shape: AppShape.md,
                        ),
                        alignment: Alignment.center,
                        child: GlyphIcon(
                          CallbookGlyphs.musicNote,
                          size: 18,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '新手引导与默认曲库向导',
                              style: AppTextStyle.subheadline
                                  .of(context, emphasized: true)
                                  .copyWith(color: scheme.onSurface),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '随时重新浏览 5 步核心功能介绍、快速切换应援主题色或更换初始曲目',
                              style: AppTextStyle.caption1.of(context).copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      TonalButton(
                        size: TonalButtonSize.compact,
                        label: '重新查看功能引导',
                        onPressed: c.reopenOnboarding,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 3. 「文字」卡片
          Card(
            inert: true,
            radius: AppTokens.radiusCard,
            padding: const EdgeInsets.all(AppTokens.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  c.siteText('文字'),
                  style: AppTextStyle.headline
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onSurface),
                ),
                const SizedBox(height: 12),
                _SwitchTileRow(
                  title: '全局启用 Google Sans 字体',
                  subtitle: '统一 UI 排版与 Callbook 导出字体，数字启用等宽对齐',
                  value: c.useGoogleSans,
                  onChanged: c.setUseGoogleSans,
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '全局文字缩放 · ${(c.textScale * 100).round()}%',
                        style: AppTextStyle.subheadline
                            .of(context, emphasized: true)
                            .copyWith(color: scheme.onSurface),
                      ),
                    ),
                    TonalChip(
                      label: '100%',
                      color: scheme.surfaceContainerHigh,
                      foregroundColor: scheme.onSurface,
                      onPressed: () => c.setTextScale(1.0),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Slider(
                  value: c.textScale,
                  min: 0.85,
                  max: 1.25,
                  onChanged: c.setTextScale,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThemePreviewSection(
    BuildContext context,
    ColorScheme scheme,
    CallbookController c,
  ) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.s12),
      decoration: ShapeDecoration(
        color: scheme.surfaceContainerLow,
        shape: RoundedSuperellipseBorder(
          borderRadius: AppTokens.radiusSectionBorder,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const GlyphIcon(CallbookGlyphs.theme, size: 18),
              const SizedBox(width: 8),
              Text(
                '实时主题预览',
                style: AppTextStyle.subheadline
                    .of(context, emphasized: true)
                    .copyWith(color: scheme.onSurface),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: ShapeDecoration(
              color: scheme.surfaceContainerLowest,
              shape: RoundedSuperellipseBorder(
                borderRadius: AppRadius.lg,
                side: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Live Call Stage',
                      style: AppTextStyle.caption1
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    const Spacer(),
                    TonalChip(
                      label: '${c.project.meta.bpm} BPM',
                      color: scheme.primaryContainer,
                      foregroundColor: scheme.onPrimaryContainer,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: ShapeDecoration(
                    color: scheme.surfaceContainer,
                    shape: AppShape.lg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.project.meta.title.trim().isNotEmpty
                            ? c.project.meta.title
                            : '来自瓦纳海姆',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyle.subheadline
                            .of(context, emphasized: true)
                            .copyWith(color: scheme.onSurface),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          TonalChip(
                            label: 'Primary CTA',
                            color: scheme.primary,
                            foregroundColor: scheme.onPrimary,
                          ),
                          TonalChip(
                            label: 'Secondary',
                            color: scheme.secondaryContainer,
                            foregroundColor: scheme.onSecondaryContainer,
                          ),
                          TonalChip(
                            label: 'GT Alert',
                            color: scheme.warningContainer,
                            foregroundColor: scheme.onWarningContainer,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetsSection(
    BuildContext context,
    ColorScheme scheme,
    CallbookController c,
  ) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.s12),
      decoration: ShapeDecoration(
        color: scheme.surfaceContainerLow,
        shape: RoundedSuperellipseBorder(
          borderRadius: AppTokens.radiusSectionBorder,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '精选色彩配方',
            style: AppTextStyle.subheadline
                .of(context, emphasized: true)
                .copyWith(color: scheme.onSurface),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final preset in curatedThemePresets)
                Semantics(
                  button: true,
                  selected:
                      preset.seedColor.toARGB32() == c.seedColor.toARGB32(),
                  label: '${preset.name} 配色方案',
                  child: PressSurface(
                    fill: preset.seedColor.toARGB32() == c.seedColor.toARGB32()
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerLowest,
                    shape: const RoundedSuperellipseBorder(
                      borderRadius: AppRadius.lg,
                    ),
                    side: preset.seedColor.toARGB32() == c.seedColor.toARGB32()
                        ? BorderSide(color: scheme.primary, width: 1.5)
                        : BorderSide.none,
                    padding: const EdgeInsets.all(12),
                    tapTarget: AppTokens.minTapTargetSize,
                    selected:
                        preset.seedColor.toARGB32() == c.seedColor.toARGB32(),
                    onPressed: () => c.applyThemePreset(preset),
                    child: SizedBox(
                      width: 166,
                      child: Row(
                        children: [
                          Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: preset.seedColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  preset.name,
                                  style: AppTextStyle.subheadline
                                      .of(context, emphasized: true)
                                      .copyWith(color: scheme.onSurface),
                                ),
                                Text(
                                  preset.description,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyle.caption2.of(context).copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
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

class _ColorSwatchButton extends StatelessWidget {
  const _ColorSwatchButton({
    required this.seed,
    required this.selected,
    required this.label,
    required this.onPressed,
  });

  final Color seed;
  final bool selected;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final duration = AppMotion.d(context, AppMotion.effectsFast);

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: PressSurface(
        fill: const Color(0x00000000),
        shape: AppShape.circle,
        look: PressLook.none,
        tapTarget: AppTokens.minTapTargetSize,
        selected: selected,
        onPressed: onPressed,
        child: SizedBox.square(
          dimension: 38,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedOpacity(
                opacity: selected ? 1.0 : 0.0,
                duration: duration,
                curve: AppMotion.curveEffects,
                child: AnimatedScale(
                  scale: selected ? 1.0 : 0.72,
                  duration: duration,
                  curve: AppMotion.curveEffects,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.onSurface, width: 2.5),
                    ),
                    child: const SizedBox.square(dimension: 38),
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: seed,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? scheme.surface
                        : scheme.outlineVariant,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: SizedBox.square(
                  dimension: 30,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: selected ? 1.0 : 0.0,
                      duration: duration,
                      curve: AppMotion.curveEffects,
                      child: AnimatedScale(
                        scale: selected ? 1.0 : 0.6,
                        duration: duration,
                        curve: AppMotion.curveEffects,
                        child: const SelectionBadge(size: 18),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchTileRow extends StatelessWidget {
  const _SwitchTileRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppTextStyle.subheadline
                    .of(context, emphasized: true)
                    .copyWith(color: scheme.onSurface),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: AppTextStyle.caption1.of(context).copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Switch(value: value, onChanged: onChanged, semanticLabel: title),
      ],
    );
  }
}

class _HctPaletteMatrix extends StatelessWidget {
  const _HctPaletteMatrix({
    required this.selectedColor,
    required this.onPick,
  });

  final Color selectedColor;
  final ValueChanged<Color> onPick;

  static const int _cols = 11;
  static const int _rows = 11;

  Color _colorAt(int col, int row) {
    final hue = (col / (_cols - 1)) * 330.0 + 10.0;
    final tone = 82.0 - (row / (_rows - 1)) * 56.0;
    final chroma = 44.0 + (1.0 - (row - 5).abs() / 6.0) * 36.0;
    return Color(Hct.from(hue, chroma, tone).toInt());
  }

  void _pickAt(Offset local, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final col = ((local.dx / size.width) * _cols).floor().clamp(0, _cols - 1);
    final row = ((local.dy / size.height) * _rows).floor().clamp(0, _rows - 1);
    onPick(_colorAt(col, row));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 188,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, 188);
          return GestureDetector(
            onTapDown: (d) => _pickAt(d.localPosition, size),
            onPanUpdate: (d) => _pickAt(d.localPosition, size),
            child: ClipRRect(
              borderRadius: AppRadius.lg,
              child: CustomPaint(
                size: size,
                painter: _HctPalettePainter(
                  cols: _cols,
                  rows: _rows,
                  selectedArgb: selectedColor.toARGB32(),
                  colorAt: _colorAt,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HctPalettePainter extends CustomPainter {
  const _HctPalettePainter({
    required this.cols,
    required this.rows,
    required this.selectedArgb,
    required this.colorAt,
  });

  final int cols;
  final int rows;
  final int selectedArgb;
  final Color Function(int col, int row) colorAt;

  @override
  void paint(Canvas canvas, Size size) {
    final cw = size.width / cols;
    final ch = size.height / rows;
    final paint = Paint()..style = PaintingStyle.fill;
    Rect? selectedRect;

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final rect = Rect.fromLTWH(c * cw, r * ch, cw + 0.6, ch + 0.6);
        final color = colorAt(c, r);
        paint.color = color;
        canvas.drawRect(rect, paint);
        if (color.toARGB32() == selectedArgb) {
          selectedRect = rect;
        }
      }
    }

    if (selectedRect != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(selectedRect.deflate(2), const Radius.circular(6)),
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4,
      );
    }
  }

  @override
  bool shouldRepaint(_HctPalettePainter oldDelegate) =>
      oldDelegate.selectedArgb != selectedArgb;
}
