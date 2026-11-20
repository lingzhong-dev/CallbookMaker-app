import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../models/callbook_models.dart';
import '../state/callbook_controller.dart';
import '../utils/lrc_ruby_parser.dart';
import 'archive_view.dart';
import 'dashboard_view.dart';
import 'export_view.dart';
import 'more_view.dart';
import 'onboarding_overlay.dart';
import 'practice_overlay.dart';
import 'widgets/audio_source_panel.dart';
import 'widgets/call_badge_pill.dart';
import 'widgets/call_preset_dialogs.dart';
import 'widgets/callbook_glyphs.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final CallbookController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  bool _mobileQuickTrayOpen = true;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
  }

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
    final chars = raw.characters;
    final clipped = chars.length > 14 ? '${chars.take(14)}…' : raw;
    return '#${index + 1} · $clipped';
  }

  ThemeMode _nextThemeMode(ThemeMode current) => switch (current) {
    ThemeMode.system => ThemeMode.light,
    ThemeMode.light => ThemeMode.dark,
    ThemeMode.dark => ThemeMode.system,
  };

  String _themeModeCycleLabel(ThemeMode current) => switch (current) {
    ThemeMode.system => '主题：跟随系统（点击切换浅色）',
    ThemeMode.light => '主题：浅色（点击切换深色）',
    ThemeMode.dark => '主题：深色（点击跟随系统）',
  };

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    super.dispose();
  }

  static const _routes = [
    StudioRoute.dashboard,
    StudioRoute.export,
    StudioRoute.archive,
    StudioRoute.more,
  ];

  String _pageTitle(StudioRoute r) => switch (r) {
    StudioRoute.dashboard => 'Callbook Maker',
    StudioRoute.export => '导出',
    StudioRoute.archive => '存档',
    StudioRoute.more => '更多',
  };

  bool _isTextInputFocused() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null ||
        ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  bool _handleHardwareKeyEvent(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (widget.controller.showOnboarding) return false;
    if (_isTextInputFocused()) return false;

    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      if ((keyboard.isControlPressed || keyboard.isMetaPressed) &&
          !keyboard.isAltPressed &&
          !keyboard.isShiftPressed &&
          event.logicalKey == LogicalKeyboardKey.keyZ &&
          widget.controller.canUndo) {
        widget.controller.undoLastTimelineEdit();
        return true;
      }
      return false;
    }

    final c = widget.controller;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape && c.isPracticeMode) {
      c.setPracticeMode(false);
      return true;
    }
    if (key == LogicalKeyboardKey.space) {
      unawaited(c.togglePlay());
      return true;
    }
    if (key == LogicalKeyboardKey.keyF) {
      c.setPracticeMode(!c.isPracticeMode);
      return true;
    }
    if (key == LogicalKeyboardKey.keyG) {
      c.insertGtAlert();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _stepTargetLine(c, -1);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _stepTargetLine(c, 1);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      c.seek(c.currentTimeMs - 2000);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      c.seek(c.currentTimeMs + 2000);
      return true;
    }

    final label = key.keyLabel.toUpperCase();
    if (label.length == 1 && c.activeLineId != null) {
      for (final preset in c.allPresets) {
        if (preset.shortcut.toUpperCase() == label) {
          unawaited(
            triggerCallPresetWithUi(
              context: context,
              controller: c,
              presetId: preset.id,
              lineId: c.activeLineId,
            ),
          );
          return true;
        }
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: Listenable.merge([
        c.routeListenable,
        c.projectListenable,
        c.themeListenable,
      ]),
      builder: (context, _) {
        final scheme = context.colorScheme;
        final isDark = scheme.brightness == Brightness.dark;
        final selectedIndex = _routes.indexOf(c.route);

        return LayoutBuilder(
            builder: (context, constraints) {
              final isMobile = constraints.maxWidth < 820;

              final pageContent = switch (c.route) {
                StudioRoute.dashboard => DashboardView(controller: c),
                StudioRoute.export => ExportView(controller: c),
                StudioRoute.archive => ArchiveView(controller: c),
                StudioRoute.more => MoreView(
                  controller: c,
                  rootResetNonce: c.moreRootResetNonce,
                ),
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
                            c.route == StudioRoute.dashboard
                                ? '为你的偶像写下Callbook吧！'
                                : '${c.project.meta.title} · ${c.project.meta.bpm} BPM (${c.project.meta.timeSignature})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyle.caption1.of(context).copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isMobile) ...[
                      const SizedBox(width: 8),
                      Semantics(
                        label: '导入音源或LRC',
                        button: true,
                        child: GestureDetector(
                          onTap: () => showAudioSourceModal(context, c),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: ShapeDecoration(
                              color: scheme.surfaceContainerHigh,
                              shape: AppShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: GlyphIcon(
                              CallbookGlyphs.musicNote,
                              size: 16,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Semantics(
                        label: _themeModeCycleLabel(c.themeMode),
                        button: true,
                        child: GestureDetector(
                          onTap: () => c.setThemeMode(
                            _nextThemeMode(c.themeMode),
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
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () => c.setPracticeMode(true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
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
                                size: 14,
                                color: scheme.onPrimary,
                              ),
                              const SizedBox(width: 5),
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
                    ],
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
                              label: c.siteText('主页'),
                            ),
                            SidebarDestination(
                              glyph: CallbookGlyphs.exportCard,
                              label: c.siteText('导出'),
                            ),
                            SidebarDestination(
                              glyph: CallbookGlyphs.archive,
                              label: c.siteText('存档'),
                            ),
                            SidebarDestination(
                              glyph: CallbookGlyphs.more,
                              label: c.siteText('更多'),
                            ),
                          ],
                          selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
                          expanded: c.sidebarExpanded,
                          onSelected: (idx) => c.setRoute(_routes[idx]),
                          onToggle: c.toggleSidebarExpanded,
                          headerBuilder: (context, progress, expanded) =>
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Callbook Maker',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyle.subheadline
                                        .of(context, emphasized: true)
                                        .copyWith(color: scheme.onSurface),
                                  ),
                                  Text(
                                    'By 澪终',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyle.caption2
                                        .of(context)
                                        .copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                          footerBuilder: (context, progress, expanded) =>
                              _buildSidebarFooter(context, c, scheme, isDark, progress),
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
                            ListenableBuilder(
                              listenable: c.playingLineIdListenable,
                              builder: (context, _) {
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
                                                background: c.autoAdvanceOnTag
                                                    ? scheme.primaryContainer
                                                    : scheme.surfaceContainerLow,
                                                foreground: c.autoAdvanceOnTag
                                                    ? scheme.onPrimaryContainer
                                                    : scheme.onSurfaceVariant,
                                                borderColor: c.autoAdvanceOnTag
                                                    ? scheme.primary
                                                    : scheme.outlineVariant,
                                                onTap: () => c.setAutoAdvanceOnTag(
                                                  !c.autoAdvanceOnTag,
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
                                                      triggerCallPresetWithUi(
                                                        context: context,
                                                        controller: c,
                                                        presetId: preset.id,
                                                        autoAdvance:
                                                            c.autoAdvanceOnTag,
                                                      ),
                                                  onContextAction:
                                                      preset.builtIn
                                                      ? null
                                                      : (pos) =>
                                                            showCustomPresetContextMenu(
                                                              context,
                                                              controller: c,
                                                              preset: preset,
                                                              globalPosition:
                                                                  pos,
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
                                                            c.autoAdvanceOnTag) {
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
                                              ListenableBuilder(
                                                listenable:
                                                    c.playbackListenable,
                                                builder: (context, _) =>
                                                    GestureDetector(
                                                      onTap: c.togglePlay,
                                                      child: Container(
                                                        width: 34,
                                                        height: 34,
                                                        decoration:
                                                            ShapeDecoration(
                                                              color: scheme
                                                                  .primary,
                                                              shape: AppShape
                                                                  .circle,
                                                            ),
                                                        alignment:
                                                            Alignment.center,
                                                        child: GlyphIcon(
                                                          c.isPlaying
                                                              ? CallbookGlyphs
                                                                    .stop
                                                              : CallbookGlyphs
                                                                    .play,
                                                          size: 16,
                                                          color:
                                                              scheme.onPrimary,
                                                          fill: 1,
                                                        ),
                                                      ),
                                                    ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      c.project.meta.title,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: AppTextStyle
                                                          .caption1
                                                          .of(
                                                            context,
                                                            emphasized: true,
                                                          )
                                                          .copyWith(
                                                            color: scheme
                                                                .onSurface,
                                                          ),
                                                    ),
                                                    ListenableBuilder(
                                                      listenable:
                                                          c.playbackListenable,
                                                      builder: (context, _) =>
                                                          Text(
                                                            '${formatMsToClock(c.currentTimeMs)} · ${c.project.meta.bpm} BPM · ${c.currentBar}.${c.currentBeatInBar}',
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: AppTextStyle
                                                                .caption2
                                                                .of(context)
                                                                .copyWith(
                                                                  fontFamily:
                                                                      'GoogleSans',
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
                                              ),
                                              const SizedBox(width: 8),
                                              GestureDetector(
                                                onTap: () =>
                                                    c.setPracticeMode(true),
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 10,
                                                        vertical: 6,
                                                      ),
                                                  decoration: ShapeDecoration(
                                                    color:
                                                        scheme.primaryContainer,
                                                    shape: AppShape.full,
                                                  ),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      GlyphIcon(
                                                        CallbookGlyphs
                                                            .fullscreen,
                                                        size: 13,
                                                        color: scheme
                                                            .onPrimaryContainer,
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        c.siteText('演练'),
                                                        style: AppTextStyle
                                                            .caption1
                                                            .of(
                                                              context,
                                                              emphasized: true,
                                                            )
                                                            .copyWith(
                                                              color: scheme
                                                                  .onPrimaryContainer,
                                                            ),
                                                      ),
                                                    ],
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
                                  label: c.siteText('主页'),
                                ),
                                NavigationDockDestination(
                                  glyph: CallbookGlyphs.exportCard,
                                  label: c.siteText('导出'),
                                ),
                                NavigationDockDestination(
                                  glyph: CallbookGlyphs.archive,
                                  label: c.siteText('存档'),
                                ),
                                NavigationDockDestination(
                                  glyph: CallbookGlyphs.more,
                                  label: c.siteText('更多'),
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
                                  label: c.siteText('主页'),
                                ),
                                (
                                  glyph: CallbookGlyphs.exportCard,
                                  label: c.siteText('导出'),
                                ),
                                (
                                  glyph: CallbookGlyphs.archive,
                                  label: c.siteText('存档'),
                                ),
                                (
                                  glyph: CallbookGlyphs.more,
                                  label: c.siteText('更多'),
                                ),
                              ],
                              selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
                              onSelected: (idx) => c.setRoute(_routes[idx]),
                            ),
                        ],
                      ),
                    ),

                  if (c.isPracticeMode) PracticeOverlay(controller: c),
                  if (c.showOnboarding) OnboardingOverlay(controller: c),
                ],
              );
            },
          );
      },
    );
  }

  Widget _buildSidebarFooter(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
    bool isDark,
    double progress,
  ) {
    if (progress <= 0.55) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SidebarCompactIconBtn(
            tooltip: '导入音源 / LRC',
            glyph: CallbookGlyphs.musicNote,
            fill: scheme.surfaceContainerHigh,
            iconColor: scheme.primary,
            onTap: () => showAudioSourceModal(context, c),
          ),
          const SizedBox(height: 6),
          _SidebarCompactIconBtn(
            tooltip: '${c.siteText('演练模式')} F',
            glyph: CallbookGlyphs.fullscreen,
            fill: scheme.primary,
            iconColor: scheme.onPrimary,
            onTap: () => c.setPracticeMode(true),
          ),
          const SizedBox(height: 6),
          Semantics(
            label: isDark ? '切换浅色主题' : '切换深色主题',
            button: true,
            child: _SidebarCompactIconBtn(
              tooltip: isDark ? '切换到浅色模式' : '切换到深色模式',
              glyph: CallbookGlyphs.theme,
              fill: scheme.surfaceContainerHigh,
              iconColor: scheme.onSurface,
              onTap: () => c.setThemeMode(
                isDark ? ThemeMode.light : ThemeMode.dark,
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SidebarFooterAction(
          glyph: CallbookGlyphs.musicNote,
          label: '导入音源 / LRC',
          background: scheme.surfaceContainerHigh,
          foreground: scheme.onSurface,
          iconColor: scheme.primary,
          onTap: () => showAudioSourceModal(context, c),
        ),
        const SizedBox(height: 6),
        _SidebarFooterAction(
          glyph: CallbookGlyphs.fullscreen,
          label: '${c.siteText('演练模式')} F',
          background: scheme.primary,
          foreground: scheme.onPrimary,
          iconColor: scheme.onPrimary,
          onTap: () => c.setPracticeMode(true),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ListenableBuilder(
                listenable: c.gatewayListenable,
                builder: (context, _) => GestureDetector(
                  onTap: () => c.refreshGatewayStatus(probeDirect: true),
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: ShapeDecoration(
                          color: c.backendOnline ? scheme.success : scheme.warning,
                          shape: AppShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          c.backendOnline ? '后端在线' : '纯 Dart 直连',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.caption2.of(context).copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Semantics(
              label: isDark ? '切换浅色主题' : '切换深色主题',
              button: true,
              child: GestureDetector(
                onTap: () => c.setThemeMode(
                  isDark ? ThemeMode.light : ThemeMode.dark,
                ),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: ShapeDecoration(
                    color: scheme.surfaceContainerHigh,
                    shape: AppShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: GlyphIcon(
                    CallbookGlyphs.theme,
                    size: 15,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
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

class _SidebarFooterAction extends StatelessWidget {
  const _SidebarFooterAction({
    required this.glyph,
    required this.label,
    required this.background,
    required this.foreground,
    required this.iconColor,
    required this.onTap,
  });

  final Glyph glyph;
  final String label;
  final Color background;
  final Color foreground;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ElasticPress(
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: ShapeDecoration(
            color: background,
            shape: AppShape.all(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GlyphIcon(glyph, size: 15, color: iconColor),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.caption1
                      .of(context, emphasized: true)
                      .copyWith(color: foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarCompactIconBtn extends StatelessWidget {
  const _SidebarCompactIconBtn({
    required this.tooltip,
    required this.glyph,
    required this.fill,
    required this.iconColor,
    required this.onTap,
  });

  final String tooltip;
  final Glyph glyph;
  final Color fill;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: ShapeDecoration(
            color: fill,
            shape: AppShape.all(10),
          ),
          alignment: Alignment.center,
          child: GlyphIcon(glyph, size: 16, color: iconColor),
        ),
      ),
    );
  }
}
