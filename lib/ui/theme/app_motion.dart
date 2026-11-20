import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

/// Policy function that determines the effective [LiquidGlassQuality] (or
/// `null` to disable glass) based on user settings and device metrics.
typedef LiquidGlassDegradationPolicy = LiquidGlassQuality? Function({
  required bool userEnabled,
  required bool reduceMotion,
  required TargetPlatform platform,
  required double devicePixelRatio,
  required Size logicalSize,
});

abstract final class AppMotion {
  // Non-overshooting effect durations
  static const Duration effectsFast = Duration(milliseconds: 150);
  static const Duration effectsDefault = Duration(milliseconds: 200);
  static const Duration effectsSlow = Duration(milliseconds: 300);

  // Stage 4 motion choreography tokens
  static const Duration practiceBackdropDuration = Duration(milliseconds: 250);
  static const Duration practiceStaggerStep = Duration(milliseconds: 40);
  static const double practiceExitScale = 0.8;
  static const Duration gtFlashDuration = Duration(milliseconds: 400);
  static const Duration onboardingSlideDuration = Duration(milliseconds: 300);
  static const Duration beatPulseDuration = Duration(milliseconds: 320);
  static const Duration manualScrollResumeDelay = Duration(seconds: 3);

  // Non-overshooting curves
  static const Curve curveEffects = Curves.easeOutCubic;
  static const Curve curveEffectsInOut = Curves.easeInOutCubic;
  static const Curve curveEffectsReverse = Curves.easeInCubic;

  // M3 Expressive spatial spring
  static final SpringDescription spatialDefault =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 450),
        bounce: 0.1,
      );
  static const Duration spatialDefaultDuration = Duration(milliseconds: 450);

  /// Critically damped spring for smooth continuous auto-scrolling that
  /// inherits current velocity when a new target line arrives mid-flight.
  static final SpringDescription autoScrollSpring =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 360),
        bounce: 0.0,
      );

  // Tab transition tokens from prism_ui
  static const Duration tabDuration = fadeTabDuration;
  static const Curve tabCurve = fadeTabCurve;

  /// Default Liquid Glass tier when enabled (medium / standard quality).
  static const LiquidGlassQuality defaultLiquidGlassQuality =
      LiquidGlassQuality.standard;

  /// Optional override hook for tuning low-performance device degradation rules.
  static LiquidGlassDegradationPolicy? liquidGlassDegradationPolicy;

  /// Resolves [duration] respecting [BuildContextExtension.disableAnimations].
  static Duration d(BuildContext context, Duration duration) =>
      context.motionDuration(duration);

  /// Resolves the effective [LiquidGlassQuality], or `null` when disabled by
  /// user preference, reduced motion, or low-performance device heuristics.
  static LiquidGlassQuality? resolveLiquidGlassQuality({
    required bool userEnabled,
    required bool reduceMotion,
    required TargetPlatform platform,
    required double devicePixelRatio,
    required Size logicalSize,
    LiquidGlassDegradationPolicy? policyOverride,
  }) {
    final policy = policyOverride ?? liquidGlassDegradationPolicy;
    if (policy != null) {
      return policy(
        userEnabled: userEnabled,
        reduceMotion: reduceMotion,
        platform: platform,
        devicePixelRatio: devicePixelRatio,
        logicalSize: logicalSize,
      );
    }
    if (!userEnabled || reduceMotion) {
      return null;
    }
    if (platform == TargetPlatform.android) {
      final hasSize = logicalSize.width > 0 && logicalSize.height > 0;
      if (hasSize) {
        final physicalPixels =
            logicalSize.width *
            devicePixelRatio *
            logicalSize.height *
            devicePixelRatio;
        final isLowEndCompact =
            logicalSize.shortestSide < 360 && devicePixelRatio < 1.5;
        final isHeavyBackdropSurface = physicalPixels > 6000000;
        if (isLowEndCompact || isHeavyBackdropSurface) {
          return null;
        }
      }
    }
    return defaultLiquidGlassQuality;
  }
}
