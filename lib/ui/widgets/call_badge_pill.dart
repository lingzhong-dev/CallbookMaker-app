import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../models/callbook_models.dart';

class CallBadgePill extends StatelessWidget {
  const CallBadgePill({
    super.key,
    required this.preset,
    this.suffix,
    this.selected = true,
    this.onTap,
    this.compact = false,
    this.showShortcut = true,
  });

  final CallPreset preset;
  final String? suffix;
  final bool selected;
  final VoidCallback? onTap;
  final bool compact;
  final bool showShortcut;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final baseColor = preset.color;
    final fill = selected ? baseColor : scheme.surfaceContainer;
    final fg = selected ? const Color(0xFFFFFFFF) : scheme.onSurface;
    final hasSuffix = suffix != null && suffix!.trim().isNotEmpty;

    final badgeContent = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 11,
        vertical: compact ? 4 : 5,
      ),
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
      child: Row(
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: ShapeDecoration(
                color: selected
                    ? const Color(0x33000000)
                    : scheme.surfaceContainerHigh,
                shape: AppShape.full,
              ),
              child: Text(
                suffix!,
                softWrap: false,
                maxLines: 1,
                overflow: TextOverflow.visible,
                style: AppTextStyle.caption2
                    .of(context, emphasized: true)
                    .copyWith(
                      fontFamily: 'GoogleSans',
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: fg,
                      height: 1.1,
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
      ),
    );

    if (onTap == null) return badgeContent;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ElasticPress(child: badgeContent),
    );
  }
}
