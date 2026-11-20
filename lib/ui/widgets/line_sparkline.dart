import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../theme/app_motion.dart';

/// Wraps `prism_ui`'s native [LineChart] inside a soft bottom-bleed Gaussian
/// curve container and smoothly interpolates from previous values to new values
/// on data updates using [TweenAnimationBuilder].
class SparklineMetricFooter extends StatefulWidget {
  const SparklineMetricFooter({
    super.key,
    required this.values,
    required this.revision,
    this.color,
    this.height = 54,
  });

  final List<double> values;
  final int revision;
  final Color? color;
  final double height;

  @override
  State<SparklineMetricFooter> createState() => _SparklineMetricFooterState();
}

class _SparklineMetricFooterState extends State<SparklineMetricFooter> {
  late List<double> _fromValues = List<double>.from(widget.values);
  late List<double> _toValues = List<double>.from(widget.values);
  late List<double> _lastRendered = List<double>.from(widget.values);
  int _transitionGeneration = 0;
  int _chartRevision = 0;

  @override
  void didUpdateWidget(covariant SparklineMetricFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision ||
        !_listEquals(oldWidget.values, widget.values)) {
      _fromValues = List<double>.from(_lastRendered);
      _toValues = List<double>.from(widget.values);
      _transitionGeneration++;
    }
  }

  bool _listEquals(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 1e-6) return false;
    }
    return true;
  }

  List<double> _interpolate(List<double> from, List<double> to, double t) {
    if (t >= 1.0 || from.isEmpty) {
      return to;
    }
    final targetLen = to.length;
    if (targetLen == 0) return const [];
    final out = List<double>.filled(targetLen, 0.0);
    for (var i = 0; i < targetLen; i++) {
      final fromIdx = from.length == targetLen
          ? i
          : ((i / math.max(1, targetLen - 1)) * (from.length - 1)).round();
      final a = from[fromIdx.clamp(0, from.length - 1)];
      final b = to[i];
      out[i] = a + (b - a) * t;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final seriesColor = widget.color ?? scheme.primary;
    final capacity = math.max(12, _toValues.length);
    final duration = AppMotion.d(context, AppMotion.effectsDefault);

    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: TweenAnimationBuilder<double>(
        key: ValueKey<int>(_transitionGeneration),
        tween: Tween<double>(begin: 0.0, end: 1.0),
        duration: duration,
        curve: AppMotion.curveEffects,
        builder: (context, t, _) {
          final current = _interpolate(_fromValues, _toValues, t);
          _lastRendered = current;
          // Jump revision by more than capacity so LineChart redraws the full
          // interpolated series cleanly on every frame.
          _chartRevision += capacity + 4;
          return LineChart(
            values: current,
            revision: _chartRevision,
            capacity: capacity,
            minScale: 1.0,
            color: seriesColor,
            baselineRatio: 0.22,
          );
        },
      ),
    );
  }
}
