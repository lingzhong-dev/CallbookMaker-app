import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../models/callbook_models.dart';
import '../state/callbook_controller.dart';
import '../utils/lrc_ruby_parser.dart';
import 'dashboard_view.dart';
import 'export_view.dart';
import 'practice_overlay.dart';
import 'theme_view.dart';
import 'widgets/archive_switcher_dialog.dart';
import 'widgets/call_badge_pill.dart';
import 'widgets/callbook_glyphs.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final CallbookController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final FocusNode _shortcutFocus = FocusNode(debugLabel: 'GlobalShortcuts');
  bool _mobileQuickTrayOpen = true;
  bool _autoAdvanceOnTag = false;

  void _stepTargetLine(CallbookController c, int delta) {
    if (c.activeLineId == null) {
      final target = c.resolveLineForQuickTag();
      if (target != null) {
        c.selectLine(target.id);
      }
    }
    c.stepActiveLine(delta);
  }

  String _targetLineLabel(LyricLine? line, int index) {
    if (line == null || index < 0) return '暂无歌词行';
    final raw = line.text.original.trim().isNotEmpty
        ? line.text.original.trim()
        : (line.text.translation?.trim() ?? '空歌词行');
    final clipped = raw.length > 14 ? '${raw.substring(0, 14)}…' : raw;
    return '#${index + 1} · $clipped';
  }

  @override
  void dispose() {
    _shortcutFocus.dispose();
    super.dispose();
  }

  static const _routes = [
    StudioRoute.dashboard,
    StudioRoute.export,
    StudioRoute.theme,
  ];

  String _pageTitle(StudioRoute r) => switch (r) {
    StudioRoute.dashboard => 'Live Call 控制台',
    StudioRoute.export => '速查卡与多格式导出',
    StudioRoute.theme => '外观主题与 Prism 设计系统',
  };

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus != null &&
        primaryFocus.context?.widget is EditableText) {
      return KeyEventResult.ignored;
    }

    final c = widget.controller;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape && c.isPracticeMode) {
      c.setPracticeMode(false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      c.togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      c.setPracticeMode(!c.isPracticeMode);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyG) {
      c.insertGtAlert();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      c.stepActiveLine(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      c.stepActiveLine(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      c.seek(c.currentTimeMs - 2000);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      c.seek(c.currentTimeMs + 2000);
      return KeyEventResult.handled;
    }

    final label = key.keyLabel.toUpperCase();
    if (label.length == 1 && c.activeLineId != null) {
      for (final preset in c.allPresets) {
        if (preset.shortcut.toUpperCase() == label) {
          c.toggleLineCall(c.activeLineId!, preset.id);
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final scheme = context.colorScheme;
        final isDark = scheme.brightness == Brightness.dark;
        final selectedIndex = _routes.indexOf(c.route);

        return Focus(
          focusNode: _shortcutFocus,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isMobile = constraints.maxWidth < 820;

              final pageContent = switch (c.route) {
                StudioRoute.dashboard => DashboardView(controller: c),
                StudioRoute.export => ExportView(controller: c),
                StudioRoute.theme => ThemeView(controller: c),
              };

              final appBar = Container(
                padding: EdgeInsets.fromLTRB(
                  isMobile ? 16 : 24,
                  MediaQuery.paddingOf(context).top + 12,
                  isMobile ? 16 : 24,
                  10,
                ),
                child: Row(
                  children: [
                    if (isMobile) ...[
                      ClipRRect(
                        borderRadius: AppRadius.sm,
                        child: Image.asset(
                          'assets/images/icon.png',
                          width: 30,
                          height: 30,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.siteText(_pageTitle(c.route)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyle.title1
                                .of(context, emphasized: true)
                                .copyWith(color: scheme.onSurface),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${c.project.meta.title} · ${c.project.meta.bpm} BPM (${c.project.meta.timeSignature})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyle.caption1.of(context).copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => showArchiveQuickSwitchDialog(context, c),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: ShapeDecoration(
                          color: scheme.surfaceContainerHigh,
                          shape: AppShape.full,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GlyphIcon(
                              CallbookGlyphs.archive,
                              size: 15,
                              color: scheme.primary,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '存档 ${c.archives.length}',
                              style: AppTextStyle.caption1
                                  .of(context, emphasized: true)
                                  .copyWith(color: scheme.onSurface),
                            ),
                            if (c.needsSavePromptBeforeSwitch) ...[
                              const SizedBox(width: 5),
                              Container(
                                width: 7,
                                height: 7,
                                decoration: ShapeDecoration(
                                  color: scheme.warning,
                                  shape: AppShape.circle,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => c.setPracticeMode(true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: ShapeDecoration(
                          color: scheme.primary,
                          shape: AppShape.full,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GlyphIcon(
                              CallbookGlyphs.fullscreen,
                              size: 15,
                              color: scheme.onPrimary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              c.siteText('演练'),
                              style: AppTextStyle.caption1
                                  .of(context, emphasized: true)
                                  .copyWith(color: scheme.onPrimary),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Semantics(
                      label: c.backendOnline ? '后端在线' : '后端离线',
                      button: true,
                      child: GestureDetector(
                        onTap: () => c.checkBackendHealth(),
                        child: Container(
                          height: 34,
                          padding: EdgeInsets.symmetric(
                            horizontal: isMobile ? 9 : 11,
                          ),
                          decoration: ShapeDecoration(
                            color: c.backendOnline
                                ? scheme.successContainer
                                : scheme.warningContainer,
                            shape: AppShape.full,
                          ),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GlyphIcon(
                                c.backendOnline
                                    ? Glyphs.check
                                    : CallbookGlyphs.musicNote,
                                size: 14,
                                color: c.backendOnline
                                    ? scheme.onSuccessContainer
                                    : scheme.onWarningContainer,
                              ),
                              if (!isMobile) ...[
                                const SizedBox(width: 5),
                                Text(
                                  c.backendOnline ? '后端在线' : '离线模式',
                                  style: AppTextStyle.caption2
                                      .of(context, emphasized: true)
                                      .copyWith(
                                        color: c.backendOnline
                                            ? scheme.onSuccessContainer
                                            : scheme.onWarningContainer,
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Semantics(
                      label: isDark ? '切换浅色主题' : '切换深色主题',
                      button: true,
                      child: GestureDetector(
                        onTap: () => c.setThemeMode(
                          isDark ? ThemeMode.light : ThemeMode.dark,
                        ),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: ShapeDecoration(
                            color: scheme.surfaceContainerHigh,
                            shape: AppShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: GlyphIcon(
                            CallbookGlyphs.theme,
                            size: 16,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );

              final mainColumn = DecoratedBox(
                decoration: BoxDecoration(color: scheme.surface),
                child: Column(
                  children: [
                    appBar,
                    Expanded(child: pageContent),
                  ],
                ),
              );

              return Stack(
                fit: StackFit.expand,
                children: [
                  if (isMobile)
                    BottomInsetScope(
                      inset: (c.floatingNavDock
                              ? NavigationDock.insetOf(context)
                              : 56.0 + MediaQuery.paddingOf(context).bottom) +
                          (c.route == StudioRoute.dashboard &&
                                  _mobileQuickTrayOpen
                              ? 168
                              : 24),
                      child: mainColumn,
                    )
                  else
                    Row(
                      children: [
                        NavigationSidebar(
                          destinations: [
                            SidebarDestination(
                              glyph: CallbookGlyphs.dashboard,
                              label: c.siteText('控制台'),
                            ),
                            SidebarDestination(
                              glyph: CallbookGlyphs.exportCard,
                              label: c.siteText('速查卡导出'),
                            ),
                            SidebarDestination(
                              glyph: CallbookGlyphs.theme,
                              label: c.siteText('外观主题'),
                            ),
                          ],
                          selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
                          expanded: c.sidebarExpanded,
                          onSelected: (idx) => c.setRoute(_routes[idx]),
                          onToggle: c.toggleSidebarExpanded,
                        ),
                        Expanded(child: mainColumn),
                      ],
                    ),

                  // Mobile FlClash NavigationDock + Quick Call Tag Strip
                  if (isMobile && !c.isPracticeMode)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (c.route == StudioRoute.dashboard)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  _FloatingPillButton(
                                    label: _mobileQuickTrayOpen ? '收起速标' : '速标栏',
                                    color: scheme.surfaceContainerHigh,
                                    foreground: scheme.onSurface,
                                    onTap: () => setState(
                                      () => _mobileQuickTrayOpen =
                                          !_mobileQuickTrayOpen,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  _FloatingPillButton(
                                    label: c.activeLineId != null &&
                                            c.getAlertForLine(c.activeLineId!) !=
                                                null
                                        ? '取消 GT'
                                        : '+ GT 警报',
                                    color: c.activeLineId != null &&
                                            c.getAlertForLine(c.activeLineId!) !=
                                                null
                                        ? scheme.warning
                                        : scheme.warningContainer,
                                    foreground: c.activeLineId != null &&
                                            c.getAlertForLine(c.activeLineId!) !=
                                                null
                                        ? const Color(0xFF000000)
                                        : scheme.onWarningContainer,
                                    onTap: () => c.insertGtAlert(),
                                  ),
                                ],
                              ),
                            ),
                          if (_mobileQuickTrayOpen &&
                              c.route == StudioRoute.dashboard)
                            Builder(
                              builder: (context) {
                                final ordered = c.sortedLines;
                                final targetLine = c.resolveLineForQuickTag();
                                final targetIdx = targetLine == null
                                    ? -1
                                    : ordered.indexWhere(
                                        (l) => l.id == targetLine.id,
                                      );
                                return Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                                  child: DecoratedBox(
                                    decoration: ShapeDecoration(
                                      color: scheme.surfaceContainer,
                                      shape: AppShape.xl,
                                      shadows: [
                                        BoxShadow(
                                          color: scheme.shadow
                                              .withValues(alpha: 0.14),
                                          blurRadius: 18,
                                          offset: const Offset(0, 6),
                                        ),
                                      ],
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(10),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  _targetLineLabel(
                                                    targetLine,
                                                    targetIdx,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: AppTextStyle.caption1
                                                      .of(
                                                        context,
                                                        emphasized: true,
                                                      )
                                                      .copyWith(
                                                        color: scheme
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              _QuickTrayChip(
                                                label: '‹ 上一句',
                                                background: scheme.surfaceContainerHigh,
                                                foreground: scheme.onSurface,
                                                onTap: targetIdx > 0
                                                    ? () =>
                                                        _stepTargetLine(c, -1)
                                                    : null,
                                              ),
                                              const SizedBox(width: 4),
                                              _QuickTrayChip(
                                                label: '下一句 ›',
                                                background: scheme.surfaceContainerHigh,
                                                foreground: scheme.onSurface,
                                                onTap: targetIdx >= 0 &&
                                                        targetIdx <
                                                            ordered.length - 1
                                                    ? () =>
                                                        _stepTargetLine(c, 1)
                                                    : null,
                                              ),
                                              const SizedBox(width: 4),
                                              _QuickTrayChip(
                                                label: '打完跳下句',
                                                background: _autoAdvanceOnTag
                                                    ? scheme.primaryContainer
                                                    : scheme.surfaceContainerLow,
                                                foreground: _autoAdvanceOnTag
                                                    ? scheme.onPrimaryContainer
                                                    : scheme.onSurfaceVariant,
                                                borderColor: _autoAdvanceOnTag
                                                    ? scheme.primary
                                                    : scheme.outlineVariant,
                                                onTap: () => setState(
                                                  () => _autoAdvanceOnTag =
                                                      !_autoAdvanceOnTag,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          SizedBox(
                                            height: 34,
                                            child: ListView.separated(
                                              scrollDirection: Axis.horizontal,
                                              itemCount: c.allPresets.length,
                                              separatorBuilder: (_, _) =>
                                                  const SizedBox(width: 6),
                                              itemBuilder: (_, idx) {
                                                final preset = c.allPresets[idx];
                                                final isActive =
                                                    targetLine != null &&
                                                    targetLine.calls.any(
                                                      (t) =>
                                                          t.presetId ==
                                                          preset.id,
                                                    );
                                                return CallBadgePill(
                                                  preset: preset,
                                                  selected: isActive,
                                                  compact: true,
                                                  showShortcut: false,
                                                  onTap: () =>
                                                      c.quickTagActiveLine(
                                                        preset.id,
                                                        autoAdvance:
                                                            _autoAdvanceOnTag,
                                                      ),
                                                );
                                              },
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              _QuickTrayChip(
                                                label: targetLine?.tailUpdraft ==
                                                        true
                                                    ? '✓ 尾句上升气流'
                                                    : '+ 尾句上升气流',
                                                background:
                                                    targetLine?.tailUpdraft ==
                                                            true
                                                        ? const Color(0xFF0284C7)
                                                        : scheme
                                                            .surfaceContainerLow,
                                                foreground:
                                                    targetLine?.tailUpdraft ==
                                                            true
                                                        ? const Color(0xFFFFFFFF)
                                                        : scheme
                                                            .onSurfaceVariant,
                                                borderColor:
                                                    targetLine?.tailUpdraft ==
                                                            true
                                                        ? const Color(0xFF0284C7)
                                                        : scheme.outlineVariant,
                                                onTap: targetLine == null
                                                    ? null
                                                    : () {
                                                        final enabled =
                                                            c.toggleTailUpdraft(
                                                              targetLine.id,
                                                            );
                                                        if (enabled &&
                                                            _autoAdvanceOnTag) {
                                                          c.stepActiveLine(1);
                                                        }
                                                      },
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  '尾句上升气流可与句首 Call 独立共存',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: AppTextStyle.caption2
                                                      .of(context)
                                                      .copyWith(
                                                        color: scheme
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              GestureDetector(
                                                onTap: c.togglePlay,
                                                child: Container(
                                                  width: 34,
                                                  height: 34,
                                                  decoration: ShapeDecoration(
                                                    color: scheme.primary,
                                                    shape: AppShape.circle,
                                                  ),
                                                  alignment: Alignment.center,
                                                  child: GlyphIcon(
                                                    c.isPlaying
                                                        ? CallbookGlyphs.stop
                                                        : CallbookGlyphs.play,
                                                    size: 16,
                                                    color: scheme.onPrimary,
                                                    fill: 1,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Text(
                                                  '${formatMsToClock(c.currentTimeMs)} · ${c.project.meta.bpm} BPM · ${c.currentBar}.${c.currentBeatInBar}',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: AppTextStyle.caption1
                                                      .of(context)
                                                      .copyWith(
                                                        fontFamily: 'GoogleSans',
                                                        fontFeatures: const [
                                                          FontFeature
                                                              .tabularFigures(),
                                                        ],
                                                        color: scheme
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          if (c.floatingNavDock)
                            NavigationDock(
                              destinations: [
                                NavigationDockDestination(
                                  glyph: CallbookGlyphs.dashboard,
                                  label: c.siteText('控制台'),
                                ),
                                NavigationDockDestination(
                                  glyph: CallbookGlyphs.exportCard,
                                  label: c.siteText('导出'),
                                ),
                                NavigationDockDestination(
                                  glyph: CallbookGlyphs.theme,
                                  label: c.siteText('主题'),
                                ),
                              ],
                              selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
                              onSelected: (idx) => c.setRoute(_routes[idx]),
                            )
                          else
                            _AnchoredBottomNavBar(
                              destinations: [
                                (
                                  glyph: CallbookGlyphs.dashboard,
                                  label: c.siteText('控制台'),
                                ),
                                (
                                  glyph: CallbookGlyphs.exportCard,
                                  label: c.siteText('导出'),
                                ),
                                (
                                  glyph: CallbookGlyphs.theme,
                                  label: c.siteText('主题'),
                                ),
                              ],
                              selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
                              onSelected: (idx) => c.setRoute(_routes[idx]),
                            ),
                        ],
                      ),
                    ),

                  if (c.isPracticeMode) PracticeOverlay(controller: c),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _AnchoredBottomNavBar extends StatelessWidget {
  const _AnchoredBottomNavBar({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<({Glyph glyph, String label})> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 6, 8, 6 + bottomPad),
        child: Row(
          children: [
            for (var i = 0; i < destinations.length; i++)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelected(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: ShapeDecoration(
                      color: i == selectedIndex
                          ? scheme.primaryContainer
                          : const Color(0x00000000),
                      shape: AppShape.full,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GlyphIcon(
                          destinations[i].glyph,
                          size: 18,
                          color: i == selectedIndex
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          destinations[i].label,
                          style: AppTextStyle.caption2
                              .of(context, emphasized: i == selectedIndex)
                              .copyWith(
                                color: i == selectedIndex
                                    ? scheme.onPrimaryContainer
                                    : scheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FloatingPillButton extends StatelessWidget {
  const _FloatingPillButton({
    required this.label,
    required this.color,
    required this.foreground,
    required this.onTap,
  });

  final String label;
  final Color color;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ElasticPress(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: ShapeDecoration(
            color: color,
            shape: AppShape.full,
            shadows: const [
              BoxShadow(
                color: Color(0x24000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            label,
            style: AppTextStyle.caption1
                .of(context, emphasized: true)
                .copyWith(color: foreground),
          ),
        ),
      ),
    );
  }
}

class _QuickTrayChip extends StatelessWidget {
  const _QuickTrayChip({
    required this.label,
    required this.background,
    required this.foreground,
    this.borderColor,
    required this.onTap,
  });

  final String label;
  final Color background;
  final Color foreground;
  final Color? borderColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: onTap == null ? 0.42 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
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
            style: AppTextStyle.caption2
                .of(context, emphasized: true)
                .copyWith(color: foreground),
          ),
        ),
      ),
    );
  }
}
