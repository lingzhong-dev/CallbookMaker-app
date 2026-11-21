import 'dart:async';
import 'dart:math' as math;

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
  double? _activeTargetOffset;
  bool _isProgrammaticScroll = false;
  bool _manualPauseActive = false;
  bool _disposed = false;

  bool get isManualPauseActive => _manualPauseActive;
  bool get isAnimating => _springCtrl.isAnimating;

  /// Computes the target scroll offset to place [itemContext] at [alignment]
  /// (`0.0` = top of viewport, `0.5` = center) inside [scrollController].
  ///
  /// Resolves the viewport `RenderBox` directly from [scrollController]'s own
  /// `ScrollPosition.context` so nested non-scrolling widgets or `shrinkWrap`
  /// lists never corrupt the coordinate space. Returns `null` if [itemContext]
  /// is currently parked in an off-screen `KeepAlive` bucket.
  static double? computeTargetOffset({
    required ScrollController scrollController,
    required BuildContext itemContext,
    required double alignment,
    double bottomOcclusion = 0.0,
  }) {
    if (!scrollController.hasClients) return null;
    final position = scrollController.position;
    if (!position.hasContentDimensions) return null;
    final itemBox = itemContext.findRenderObject();
    if (itemBox is! RenderBox || !itemBox.attached || !itemBox.hasSize) {
      return null;
    }
    final scrollContext =
        position.context.notificationContext ?? position.context.storageContext;
    final scrollBox = scrollContext.findRenderObject();
    if (scrollBox is! RenderBox || !scrollBox.attached || !scrollBox.hasSize) {
      return null;
    }
    RenderObject? cursor = itemBox;
    var isDescendant = false;
    while (cursor != null) {
      if (identical(cursor, scrollBox)) {
        isDescendant = true;
        break;
      }
      final pd = cursor.parentData;
      if (pd is SliverMultiBoxAdaptorParentData && pd.keptAlive) {
        return null;
      }
      cursor = cursor.parent;
    }
    if (!isDescendant) return null;

    final topLeft = itemBox.localToGlobal(Offset.zero, ancestor: scrollBox);
    final viewportHeight = math.max(
      0.0,
      position.viewportDimension - bottomOcclusion,
    );
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

  /// Jumps [scrollController] immediately to [targetOffset] while marking
  /// the scroll as programmatic so manual-scroll pause detection ignores it.
  void jumpToOffset({
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
    cancelAnimation();
    _activeScrollController = scrollController;
    _jumpProgrammatically(scrollController, clampedTarget);
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
    if (_springCtrl.isAnimating &&
        _activeTargetOffset != null &&
        (clampedTarget - _activeTargetOffset!).abs() < 0.5) {
      return;
    }
    if ((clampedTarget - currentOffset).abs() < 0.5) {
      cancelAnimation();
      return;
    }

    _activeScrollController = scrollController;

    if (context.disableAnimations) {
      cancelAnimation();
      _jumpProgrammatically(scrollController, clampedTarget);
      return;
    }

    _activeTargetOffset = clampedTarget;
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
    double bottomOcclusion = 0.0,
  }) {
    final target = computeTargetOffset(
      scrollController: scrollController,
      itemContext: itemContext,
      alignment: alignment,
      bottomOcclusion: bottomOcclusion,
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
    _activeTargetOffset = null;
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
    if (!_springCtrl.isAnimating) {
      _activeTargetOffset = null;
    }
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
