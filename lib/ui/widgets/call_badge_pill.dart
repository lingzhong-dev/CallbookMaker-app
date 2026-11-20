import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../models/callbook_models.dart';
import '../theme/app_tokens.dart';

class CallBadgePill extends StatelessWidget {
  const CallBadgePill({
    super.key,
    required this.preset,
    this.suffix,
    this.selected = true,
    this.onTap,
    this.onContextAction,
    this.menuItems,
    this.compact = false,
    this.showShortcut = true,
  });

  final CallPreset preset;
  final String? suffix;
  final bool selected;
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onContextAction;
  final List<PopupMenuItem>? menuItems;
  final bool compact;
  final bool showShortcut;

  /// Picks black or white text with at least 4.5:1 WCAG contrast against
  /// [background].
  static Color contrastForegroundFor(Color background) {
    final lum = background.computeLuminance();
    final contrastWhite = 1.05 / (lum + 0.05);
    final contrastBlack = (lum + 0.05) / 0.05;
    return contrastWhite >= contrastBlack
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF000000);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final baseColor = preset.color;
    final fill = selected ? baseColor : scheme.surfaceContainer;
    final fg = selected ? contrastForegroundFor(baseColor) : scheme.onSurface;
    final suffixBg = selected
        ? (fg == const Color(0xFFFFFFFF)
            ? const Color(0x33000000)
            : const Color(0x22000000))
        : scheme.surfaceContainerHigh;
    final hasSuffix = suffix != null && suffix!.trim().isNotEmpty;

    final innerRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!selected) ...[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: baseColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
        ],
        Text(
          preset.label,
          softWrap: false,
          maxLines: 1,
          overflow: TextOverflow.visible,
          style: AppTextStyle.footnote
              .of(context, emphasized: true)
              .copyWith(color: fg, height: 1.15),
        ),
        if (hasSuffix) ...[
          const SizedBox(width: 5),
          Flexible(
            fit: FlexFit.loose,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: ShapeDecoration(
                color: suffixBg,
                shape: AppShape.full,
              ),
              child: Text(
                suffix!,
                softWrap: true,
                style: AppTextStyle.caption2
                    .of(context, emphasized: true)
                    .copyWith(
                      fontFamily: 'GoogleSans',
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: fg,
                      height: 1.15,
                    ),
              ),
            ),
          ),
        ] else if (!selected && showShortcut && preset.shortcut.isNotEmpty) ...[
          const SizedBox(width: 5),
          Text(
            preset.shortcut,
            softWrap: false,
            maxLines: 1,
            overflow: TextOverflow.visible,
            style: AppTextStyle.caption2.of(context).copyWith(
              fontFamily: 'GoogleSans',
              fontFeatures: const [FontFeature.tabularFigures()],
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );

    final padding = EdgeInsets.symmetric(
      horizontal: compact ? 9 : 11,
      vertical: compact ? 4 : 5,
    );

    if (onTap == null &&
        onContextAction == null &&
        (menuItems == null || menuItems!.isEmpty)) {
      return Container(
        padding: padding,
        decoration: ShapeDecoration(
          color: fill,
          shape: AppShape.full,
          shadows: selected
              ? [
                  BoxShadow(
                    color: baseColor.withValues(alpha: 0.28),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: innerRow,
      );
    }

    final semanticLabel = preset.shortcut.isNotEmpty
        ? '${preset.label}（快捷键 ${preset.shortcut}）'
        : preset.label;

    Widget interactive = PressSurface(
      fill: fill,
      shape: AppShape.full,
      foreground: fg,
      inkColor: fg,
      padding: padding,
      tapTarget: AppTokens.minTapTargetSize,
      selected: selected,
      onPressed: onTap,
      inert: onTap == null,
      child: innerRow,
    );

    if (selected) {
      interactive = DecoratedBox(
        decoration: ShapeDecoration(
          shape: AppShape.full,
          shadows: [
            BoxShadow(
              color: baseColor.withValues(alpha: 0.28),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: interactive,
      );
    }

    if (onTap != null) {
      interactive = ElasticPress(child: interactive);
    }

    if (menuItems != null && menuItems!.isNotEmpty) {
      interactive = ContextMenuRegion(
        menuItems: menuItems,
        child: interactive,
      );
    } else if (onContextAction != null) {
      interactive = GestureDetector(
        onSecondaryTapUp: (details) => onContextAction!(details.globalPosition),
        onLongPressStart: (details) => onContextAction!(details.globalPosition),
        behavior: HitTestBehavior.translucent,
        child: interactive,
      );
    }

    return Semantics(
      button: onTap != null,
      selected: selected,
      label: semanticLabel,
      child: onTap != null
          ? Tooltip(
              message: semanticLabel,
              child: interactive,
            )
          : interactive,
    );
  }
}
