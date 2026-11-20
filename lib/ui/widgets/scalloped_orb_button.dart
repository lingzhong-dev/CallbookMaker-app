import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:prism_ui/shapes/shapes.dart';

import '../theme/app_motion.dart';
import '../theme/app_tokens.dart';
import 'callbook_glyphs.dart';

final Morph _startMorph = Morph(
  MaterialShapes.circle,
  MaterialShapes.cookie9Sided,
);

/// M3 Expressive Circle -> Cookie-9Sided Play/Stop Orb button driven by
/// `prism_ui`'s [dropletSpring] [SpringSimulation].
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
  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
    value: widget.running ? 1.0 : 0.0,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.disableAnimations && _controller.isAnimating) {
      _controller.stop();
      _controller.value = widget.running ? 1.0 : 0.0;
    }
  }

  @override
  void didUpdateWidget(covariant ScallopedOrbButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running) {
      final target = widget.running ? 1.0 : 0.0;
      if (context.disableAnimations) {
        _controller.stop();
        _controller.value = target;
      } else {
        final simulation = SpringSimulation(
          dropletSpring,
          _controller.value,
          target,
          _controller.velocity,
        );
        _controller.animateWith(simulation);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final fill = scheme.primary;
    final fg = scheme.onPrimary;
    final shadow = scheme.primary.withValues(alpha: 0.34);

    final label = widget.running ? '停止' : '播放';
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: '$label（Space）',
        child: PressSurface(
          fill: const Color(0x00000000),
          shape: AppShape.circle,
          look: PressLook.none,
          ringStandsOff: true,
          tapTarget: AppTokens.minTapTargetSize,
          onPressed: widget.onToggle,
          child: ElasticPress(
            child: SizedBox.square(
              dimension: widget.size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (_, _) => CustomPaint(
                      size: Size.square(widget.size),
                      painter: _OrbMorphPainter(
                        progress: _controller.value,
                        color: fill,
                        shadow: shadow,
                      ),
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: AppMotion.d(context, AppMotion.effectsFast),
                    switchInCurve: AppMotion.curveEffects,
                    switchOutCurve: AppMotion.curveEffectsReverse,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.6, end: 1.0).animate(
                          animation,
                        ),
                        child: child,
                      ),
                    ),
                    child: GlyphIcon(
                      widget.running ? CallbookGlyphs.stop : CallbookGlyphs.play,
                      key: ValueKey<bool>(widget.running),
                      color: fg,
                      fill: 1,
                      size: widget.size * 0.38,
                    ),
                  ),
                ],
              ),
            ),
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
    final clamped = progress.clamp(0.0, 1.0);
    final path = _startMorph.toPath(progress: clamped);
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
