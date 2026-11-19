import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:prism_ui/shapes/shapes.dart';

import 'callbook_glyphs.dart';

final Morph _startMorph = Morph(
  MaterialShapes.circle,
  MaterialShapes.cookie9Sided,
);

/// FlClash signature M3 Expressive Circle -> Cookie-9Sided Play/Stop Orb button.
class ScallopedOrbButton extends StatefulWidget {
  const ScallopedOrbButton({
    super.key,
    required this.running,
    this.size = 86,
    required this.onToggle,
  });

  final bool running;
  final double size;
  final VoidCallback onToggle;

  @override
  State<ScallopedOrbButton> createState() => _ScallopedOrbButtonState();
}

class _ScallopedOrbButtonState extends State<ScallopedOrbButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
    value: widget.running ? 1.0 : 0.0,
  );
  late final CurvedAnimation _progress = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didUpdateWidget(covariant ScallopedOrbButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running) {
      if (widget.running) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final fill = scheme.primary;
    final fg = scheme.onPrimary;
    final shadow = scheme.primary.withValues(alpha: 0.34);

    return GestureDetector(
      onTap: widget.onToggle,
      child: ElasticPress(
        child: SizedBox.square(
          dimension: widget.size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _progress,
                builder: (_, _) => CustomPaint(
                  size: Size.square(widget.size),
                  painter: _OrbMorphPainter(
                    progress: _progress.value.clamp(0.0, 1.0),
                    color: fill,
                    shadow: shadow,
                  ),
                ),
              ),
              GlyphIcon(
                widget.running ? CallbookGlyphs.stop : CallbookGlyphs.play,
                color: fg,
                fill: 1,
                size: widget.size * 0.38,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrbMorphPainter extends CustomPainter {
  const _OrbMorphPainter({
    required this.progress,
    required this.color,
    required this.shadow,
  });

  final double progress;
  final Color color;
  final Color shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _startMorph.toPath(progress: progress);
    final turn = progress * 2 * math.pi / 9;

    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..rotate(turn)
      ..scale(size.width, size.height)
      ..translate(-0.5, -0.5);

    canvas.save();
    canvas
      ..translate(0, 6 / size.height)
      ..drawPath(
        path,
        Paint()
          ..color = shadow
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 7 / size.width),
      );
    canvas.restore();

    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbMorphPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.shadow != shadow;
}
