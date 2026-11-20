import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../state/callbook_controller.dart';
import '../theme/app_motion.dart';
import '../theme/app_tokens.dart';
import 'callbook_glyphs.dart';

enum _FloatingScrollButtonMode { scrollToTop, backToCurrentLine }

/// Glass circular floating action button that scrolls back to the top of long
/// lists (timeline, practice list, archive list), and cooperates with playback
/// auto-follow by offering a one-tap return to the current line.
class ScrollToTopButton extends StatefulWidget {
  const ScrollToTopButton({
    super.key,
    required this.scrollController,
    this.controller,
    this.isCurrentLineVisible,
    this.bottomOffset = 16.0,
    this.rightOffset = 16.0,
    this.onScrolledToTop,
  });

  final ScrollController scrollController;
  final CallbookController? controller;
  final bool Function()? isCurrentLineVisible;
  final double bottomOffset;
  final double rightOffset;
  final VoidCallback? onScrolledToTop;

  /// Scrolls [scrollController] back to the top using fast-jump + deceleration
  /// when far down (> 3 viewports), and pauses auto-follow if [controller] is
  /// actively playing.
  static Future<void> scrollToTop(
    BuildContext context,
    ScrollController scrollController, {
    CallbookController? controller,
  }) async {
    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    final viewport = position.viewportDimension > 0
        ? position.viewportDimension
        : MediaQuery.sizeOf(context).height;
    final offset = scrollController.offset;

    if (controller != null && controller.isPlaying) {
      controller.pauseFollowFromScrollToTop();
    }

    if (offset <= 0) return;

    if (context.disableAnimations) {
      scrollController.jumpTo(0);
      return;
    }

    final duration = AppMotion.d(context, AppMotion.effectsSlow);
    if (offset > 3.0 * viewport) {
      scrollController.jumpTo(viewport);
    }
    if (!scrollController.hasClients) return;
    await scrollController.animateTo(
      0,
      duration: duration,
      curve: AppMotion.curveEffects,
    );
  }

  @override
  State<ScrollToTopButton> createState() => _ScrollToTopButtonState();
}

class _ScrollToTopButtonState extends State<ScrollToTopButton>
    with SingleTickerProviderStateMixin {
  bool _pastThreshold = false;
  late final AnimationController _visibilityCtrl = AnimationController(
    vsync: this,
    duration: AppMotion.effectsDefault,
  );
  late final CurvedAnimation _visibilityCurve = CurvedAnimation(
    parent: _visibilityCtrl,
    curve: AppMotion.curveEffects,
    reverseCurve: AppMotion.curveEffectsReverse,
  );
  late final Animation<double> _scaleAnim = Tween<double>(
    begin: 0.8,
    end: 1.0,
  ).animate(_visibilityCurve);

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_syncVisibility);
    widget.controller?.playbackSyncListenable.addListener(_syncVisibility);
    widget.controller?.projectListenable.addListener(_syncVisibility);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncVisibility();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visibilityCtrl.duration = AppMotion.d(context, AppMotion.effectsDefault);
  }

  @override
  void didUpdateWidget(ScrollToTopButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_syncVisibility);
      widget.scrollController.addListener(_syncVisibility);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.playbackSyncListenable.removeListener(_syncVisibility);
      oldWidget.controller?.projectListenable.removeListener(_syncVisibility);
      widget.controller?.playbackSyncListenable.addListener(_syncVisibility);
      widget.controller?.projectListenable.addListener(_syncVisibility);
    }
    _syncVisibility();
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_syncVisibility);
    widget.controller?.playbackSyncListenable.removeListener(_syncVisibility);
    widget.controller?.projectListenable.removeListener(_syncVisibility);
    _visibilityCurve.dispose();
    _visibilityCtrl.dispose();
    super.dispose();
  }

  bool get _showBackToCurrentLine {
    final c = widget.controller;
    if (c == null || !c.isPlaying || !c.followPausedByScrollTop) {
      return false;
    }
    if (c.followPlayback && (widget.isCurrentLineVisible?.call() ?? false)) {
      return false;
    }
    return true;
  }

  void _syncVisibility() {
    if (!mounted) return;
    final sc = widget.scrollController;
    var nextPast = _pastThreshold;
    if (!sc.hasClients) {
      nextPast = false;
    } else {
      final position = sc.position;
      final viewport = position.viewportDimension > 0
          ? position.viewportDimension
          : MediaQuery.sizeOf(context).height;
      final offset = sc.offset;
      if (!_pastThreshold && offset > 1.5 * viewport) {
        nextPast = true;
      } else if (_pastThreshold && offset <= 0.5 * viewport) {
        nextPast = false;
      }
    }

    if (nextPast != _pastThreshold) {
      setState(() => _pastThreshold = nextPast);
    }

    final shouldShow = _showBackToCurrentLine || _pastThreshold;
    if (shouldShow) {
      if (context.disableAnimations) {
        _visibilityCtrl.value = 1.0;
      } else {
        unawaited(_visibilityCtrl.forward());
      }
    } else {
      if (context.disableAnimations) {
        _visibilityCtrl.value = 0.0;
      } else {
        unawaited(_visibilityCtrl.reverse());
      }
    }
  }

  Future<void> _handlePressed(_FloatingScrollButtonMode mode) async {
    if (mode == _FloatingScrollButtonMode.backToCurrentLine) {
      widget.controller?.resumeFollowFromScrollToTop();
      return;
    }
    await ScrollToTopButton.scrollToTop(
      context,
      widget.scrollController,
      controller: widget.controller,
    );
    widget.onScrolledToTop?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final listenables = <Listenable>[
      if (c != null) c.playbackSyncListenable,
      if (c != null) c.projectListenable,
    ];
    final listenable = listenables.isEmpty
        ? _visibilityCtrl
        : Listenable.merge([_visibilityCtrl, ...listenables]);

    return Positioned(
      right: widget.rightOffset,
      bottom: widget.bottomOffset,
      child: AnimatedBuilder(
        animation: listenable,
        builder: (context, _) {
          final showBackToCurrent = _showBackToCurrentLine;
          final shouldShow = showBackToCurrent || _pastThreshold;
          if (!shouldShow && _visibilityCtrl.isDismissed) {
            return const SizedBox.shrink();
          }

          final scheme = context.colorScheme;
          final glassEnabled = LiquidGlassScope.of(context);
          final mode = showBackToCurrent
              ? _FloatingScrollButtonMode.backToCurrentLine
              : _FloatingScrollButtonMode.scrollToTop;
          final label = mode == _FloatingScrollButtonMode.backToCurrentLine
              ? (c?.siteText('回到当前行') ?? '回到当前行')
              : '${c?.siteText('回到顶部') ?? '回到顶部'}（Ctrl+Home）';
          final glyph = mode == _FloatingScrollButtonMode.backToCurrentLine
              ? CallbookGlyphs.currentLine
              : CallbookGlyphs.arrowUp;
          final iconColor = mode == _FloatingScrollButtonMode.backToCurrentLine
              ? scheme.primary
              : scheme.onSurface;

          final switcherDuration = AppMotion.d(context, AppMotion.effectsFast);

          return IgnorePointer(
            ignoring: !shouldShow,
            child: FadeTransition(
              opacity: _visibilityCurve,
              child: ScaleTransition(
                scale: _scaleAnim,
                child: Semantics(
                  container: true,
                  button: true,
                  label: label,
                  excludeSemantics: true,
                  child: IconButton(
                    onPressed: () => _handlePressed(mode),
                    tooltip: label,
                    iconSize: 20,
                    style: ButtonStyle(
                      foregroundColor: WidgetStatePropertyAll(iconColor),
                      backgroundColor: WidgetStatePropertyAll(
                        glassEnabled
                            ? const Color(0x00000000)
                            : scheme.surfaceContainerHigh,
                      ),
                      side: WidgetStatePropertyAll(
                        BorderSide(
                          color: scheme.outlineVariant.withValues(alpha: 0.75),
                        ),
                      ),
                      shape: AppShape.circle,
                      minimumSize: AppTokens.minTapTargetSize,
                      fixedSize: AppTokens.minTapTargetSize,
                      tapTargetSize: TapTargetSize.padded,
                      backgroundBuilder: glassEnabled
                          ? LiquidGlass.buttonBackground(
                              (_) => LiquidGlassStyle.pill(scheme),
                            )
                          : null,
                    ),
                    icon: AnimatedSwitcher(
                      duration: switcherDuration,
                      switchInCurve: AppMotion.curveEffects,
                      switchOutCurve: AppMotion.curveEffectsReverse,
                      child: KeyedSubtree(
                        key: ValueKey<_FloatingScrollButtonMode>(mode),
                        child: GlyphIcon(
                          glyph,
                          size: 20,
                          color: iconColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
