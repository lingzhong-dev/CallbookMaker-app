import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

/// Wraps `prism_ui`'s native `LineChart` inside a soft bottom-bleed Gaussian curve container
/// matching FlClash's Speed & Coverage metric cards.
class SparklineMetricFooter extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final seriesColor = color ?? scheme.primary;
    final capacity = math.max(12, values.length);

    return SizedBox(
      height: height,
      width: double.infinity,
      child: LineChart(
        values: values,
        revision: revision,
        capacity: capacity,
        minScale: 1.0,
        color: seriesColor,
        baselineRatio: 0.22,
      ),
    );
  }
}
