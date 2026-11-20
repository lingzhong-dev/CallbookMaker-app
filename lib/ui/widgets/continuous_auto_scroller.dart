import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../state/callbook_controller.dart';
import '../theme/app_motion.dart';

/// Smooth continuous auto-scroller that replaces `Scrollable.ensureVisible`.
///
/// Computes exact target offsets from `GlobalKey` render boxes, drives the
/// attached [ScrollController] with a velocity-preserving [SpringSimulation],
/// pauses on manual user scrolling, and resumes after 3 seconds unless paused
/// explicitly by the "Back to Top" button.
class ContinuousAutoScroller {
  ContinuousAutoScroller({
    required TickerProvider vsync,
    required this.onResumeAutoFollow,
  }) : _springCtrl = AnimationController.unbounded(vsync: vsync) {
    _springCtrl.addListener(_onSpringTick);
  }

  final VoidCallback onResumeAutoFollow;
  final AnimationController _springCtrl;

  ScrollController? _activeScrollController;
  Timer? _manualResumeTimer;
  bool _isProgrammaticScroll = false;
  bool _manualPauseActive = false;
  bool _disposed = false;

  bool get isManualPauseActive => _manualPauseActive;
  bool get isAnimating => _springCtrl.isAnimating;

  /// Computes the target scroll offset to place [itemContext] at [alignment]
  /// (`0.0` = top of viewport, `0.5` = center) inside [scrollController].
  static double? computeTargetOffset({
    required ScrollController scrollController,
    required BuildContext itemContext,
    required double alignment,
  }) {
    if (!scrollController.hasClients) return null;
    final position = scrollController.position;
    if (!position.hasContentDimensions) return null;
    final itemBox = itemContext.findRenderObject();
    if (itemBox is! RenderBox || !itemBox.attached || !itemBox.hasSize) {
      return null;
    }
    final scrollable = Scrollable.maybeOf(itemContext);
    if (scrollable == null) return null;
    final scrollBox = scrollable.context.findRenderObject();
    if (scrollBox is! RenderBox || !scrollBox.attached || !scrollBox.hasSize) {
      return null;
    }
    final topLeft = itemBox.localToGlobal(Offset.zero, ancestor: scrollBox);
    final viewportHeight = position.viewportDimension;
    final itemHeight = itemBox.size.height;
    final desiredTop = itemHeight >= viewportHeight
        ? 0.0
        : (viewportHeight - itemHeight) * alignment;
    final delta = topLeft.dy - desiredTop;
    return (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
  }

  /// Scrolls [scrollController] to [targetOffset], seamlessly inheriting
  /// current position and velocity if an auto-scroll is already in flight.
  void scrollToOffset({
    required BuildContext context,
    required ScrollController scrollController,
    required double targetOffset,
  }) {
    if (_disposed || !scrollController.hasClients) return;
    final position = scrollController.position;
    if (!position.hasContentDimensions) return;
    final clampedTarget = targetOffset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final currentOffset = position.pixels;
    if ((clampedTarget - currentOffset).abs() < 0.5) return;

    _activeScrollController = scrollController;

    if (context.disableAnimations) {
      cancelAnimation();
      _jumpProgrammatically(scrollController, clampedTarget);
      return;
    }

    final velocity = _springCtrl.isAnimating ? _springCtrl.velocity : 0.0;
    final sim = SpringSimulation(
      AppMotion.autoScrollSpring,
      currentOffset,
      clampedTarget,
      velocity,
    );
    _springCtrl.animateWith(sim);
  }

  /// Scrolls [scrollController] to align [itemContext] at [alignment].
  bool scrollToContext({
    required BuildContext context,
    required ScrollController scrollController,
    required BuildContext itemContext,
    required double alignment,
  }) {
    final target = computeTargetOffset(
      scrollController: scrollController,
      itemContext: itemContext,
      alignment: alignment,
    );
    if (target == null) return false;
    scrollToOffset(
      context: context,
      scrollController: scrollController,
      targetOffset: target,
    );
    return true;
  }

  /// Observes scroll notifications to detect manual drags / mouse wheel
  /// scrolling and pause automatic following for 3 seconds after scrolling ends.
  void handleScrollNotification(
    ScrollNotification notification,
    CallbookController controller,
  ) {
    if (_disposed || _isProgrammaticScroll) return;

    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null) {
        _pauseForManualInteraction();
      }
      return;
    }

    if (notification is UserScrollNotification) {
      if (notification.direction != ScrollDirection.idle) {
        _pauseForManualInteraction();
      } else if (_manualPauseActive) {
        _scheduleManualResume(controller);
      }
      return;
    }

    if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails != null ||
          (notification.scrollDelta != null &&
              notification.scrollDelta!.abs() > 0.0)) {
        _pauseForManualInteraction();
        if (notification.dragDetails == null) {
          _scheduleManualResume(controller);
        }
      }
      return;
    }

    if (notification is ScrollEndNotification && _manualPauseActive) {
      _scheduleManualResume(controller);
    }
  }

  void _pauseForManualInteraction() {
    cancelAnimation();
    _manualPauseActive = true;
    _manualResumeTimer?.cancel();
    _manualResumeTimer = null;
  }

  void _scheduleManualResume(CallbookController controller) {
    _manualResumeTimer?.cancel();
    _manualResumeTimer = Timer(AppMotion.manualScrollResumeDelay, () {
      if (_disposed) return;
      _manualPauseActive = false;
      if (!controller.followPausedByScrollTop) {
        onResumeAutoFollow();
      }
    });
  }

  /// Clears any manual scroll pause (e.g. when user explicitly taps
  /// "Back to current line" or selects a line).
  void clearManualPause() {
    _manualResumeTimer?.cancel();
    _manualResumeTimer = null;
    _manualPauseActive = false;
  }

  void cancelAnimation() {
    if (_springCtrl.isAnimating) {
      _springCtrl.stop();
    }
  }

  void _onSpringTick() {
    final sc = _activeScrollController;
    if (_disposed || sc == null || !sc.hasClients) {
      cancelAnimation();
      return;
    }
    final position = sc.position;
    if (!position.hasContentDimensions) return;
    final next = _springCtrl.value.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _jumpProgrammatically(sc, next);
  }

  void _jumpProgrammatically(ScrollController sc, double offset) {
    _isProgrammaticScroll = true;
    try {
      if (sc.hasClients) {
        sc.jumpTo(offset);
      }
    } finally {
      _isProgrammaticScroll = false;
    }
  }

  void dispose() {
    _disposed = true;
    _manualResumeTimer?.cancel();
    _springCtrl.removeListener(_onSpringTick);
    _springCtrl.dispose();
  }
}
