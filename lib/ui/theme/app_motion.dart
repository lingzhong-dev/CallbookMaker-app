import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

abstract final class AppMotion {
  // Non-overshooting effect durations
  static const Duration effectsFast = Duration(milliseconds: 150);
  static const Duration effectsDefault = Duration(milliseconds: 200);
  static const Duration effectsSlow = Duration(milliseconds: 300);

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

  // Tab transition tokens from prism_ui
  static const Duration tabDuration = fadeTabDuration;
  static const Curve tabCurve = fadeTabCurve;

  /// Resolves [duration] respecting [BuildContextExtension.disableAnimations].
  static Duration d(BuildContext context, Duration duration) =>
      context.motionDuration(duration);
}
