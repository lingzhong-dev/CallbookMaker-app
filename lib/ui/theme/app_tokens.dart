import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

abstract final class AppTokens {
  // Radii
  static const double radiusCard = 24.0;
  static const double radiusSection = 16.0;
  static const BorderRadius radiusCardBorder = AppRadius.xl;
  static const BorderRadius radiusSectionBorder = AppRadius.md;
  static const RoundedSuperellipseBorder shapeCard = AppShape.xl;
  static const RoundedSuperellipseBorder shapeSection = AppShape.md;
  static const RoundedSuperellipseBorder shapeChip = AppShape.full;
  static const BorderRadius radiusDialog = AppRadius.xl;

  // Spacing
  static const double s4 = 4.0;
  static const double s8 = 8.0;
  static const double s12 = 12.0;
  static const double s16 = 16.0;
  static const double s24 = 24.0;

  // Minimum interactive hit target (Material 3 48x48dp)
  static const double minTapTarget = 48.0;
  static const Size minTapTargetSize = Size(minTapTarget, minTapTarget);
}
