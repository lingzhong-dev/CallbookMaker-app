import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_call_studio/ui/theme/app_motion.dart';
import 'package:live_call_studio/ui/theme/app_tokens.dart';
import 'package:prism_ui/prism_ui.dart';

void main() {
  group('AppTokens design constants', () {
    test('exposes required corner radii, spacing scale, and min tap target', () {
      expect(AppTokens.radiusCard, 24.0);
      expect(AppTokens.radiusSection, 16.0);
      expect(AppTokens.shapeChip, AppShape.full);
      expect(AppTokens.radiusDialog, AppRadius.xl);

      expect(AppTokens.s4, 4.0);
      expect(AppTokens.s8, 8.0);
      expect(AppTokens.s12, 12.0);
      expect(AppTokens.s16, 16.0);
      expect(AppTokens.s24, 24.0);

      expect(AppTokens.minTapTarget, 48.0);
      expect(AppTokens.minTapTargetSize, const Size(48, 48));
    });
  });

  group('AppMotion constants and d() helper', () {
    test('defines effect durations, spatial spring, and tab tokens', () {
      expect(AppMotion.effectsFast, const Duration(milliseconds: 150));
      expect(AppMotion.effectsDefault, const Duration(milliseconds: 200));
      expect(AppMotion.effectsSlow, const Duration(milliseconds: 300));
      expect(AppMotion.tabDuration, fadeTabDuration);
      expect(AppMotion.tabCurve, fadeTabCurve);

      expect(AppMotion.spatialDefault, isA<SpringDescription>());
      expect(AppMotion.spatialDefaultDuration, const Duration(milliseconds: 450));
      final sim = SpringSimulation(AppMotion.spatialDefault, 0, 1, 0);
      expect(sim.x(0.45), greaterThan(0.8));
    });

    testWidgets('AppMotion.d respects MediaQuery.disableAnimations', (tester) async {
      late Duration normalDuration;
      late Duration reducedDuration;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: Builder(
            builder: (context) {
              normalDuration = AppMotion.d(context, AppMotion.effectsDefault);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              reducedDuration = AppMotion.d(context, AppMotion.effectsDefault);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(normalDuration, AppMotion.effectsDefault);
      expect(reducedDuration, Duration.zero);
    });
  });
}
