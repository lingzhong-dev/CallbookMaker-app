import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../state/callbook_controller.dart';
import '../theme/app_motion.dart';

/// Beat pulse dot strip driven directly by [CallbookController.beatListenable]
/// with [riseAndFall] scaling (1.0 -> 1.35 -> 1.0; downbeat 1.0 -> 1.5 -> 1.0),
/// isolated inside a [RepaintBoundary]. When reduced motion is active, only dot
/// colors update without scale pulsation.
class BeatDotsIndicator extends StatefulWidget {
  const BeatDotsIndicator({
    super.key,
    required this.controller,
    required this.downbeatColor,
    required this.beatColor,
    required this.inactiveColor,
    this.dotSize = 9.0,
    this.downbeatSize,
    this.spacing = 4.0,
    this.showBarBeatLabel = false,
  });

  final CallbookController controller;
  final Color downbeatColor;
  final Color beatColor;
  final Color inactiveColor;
  final double dotSize;
  final double? downbeatSize;
  final double spacing;
  final bool showBarBeatLabel;

  @override
  State<BeatDotsIndicator> createState() => _BeatDotsIndicatorState();
}

class _BeatDotsIndicatorState extends State<BeatDotsIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl = AnimationController(
    vsync: this,
    duration: AppMotion.beatPulseDuration,
  );
  int _pulsingBeat = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.beatListenable.addListener(_onBeat);
    widget.controller.playbackListenable.addListener(_onPlaybackChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pulseCtrl.duration = AppMotion.d(context, AppMotion.beatPulseDuration);
    if (context.disableAnimations && _pulseCtrl.isAnimating) {
      _pulseCtrl.stop();
      _pulseCtrl.value = 0.0;
    }
  }

  @override
  void didUpdateWidget(covariant BeatDotsIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.beatListenable.removeListener(_onBeat);
      oldWidget.controller.playbackListenable.removeListener(
        _onPlaybackChanged,
      );
      widget.controller.beatListenable.addListener(_onBeat);
      widget.controller.playbackListenable.addListener(_onPlaybackChanged);
    }
  }

  void _onBeat() {
    if (!mounted) return;
    final c = widget.controller;
    _pulsingBeat = c.currentBeatInBar;
    if (context.disableAnimations || !c.isPlaying) {
      setState(() {});
      return;
    }
    _pulseCtrl.duration = AppMotion.d(context, AppMotion.beatPulseDuration);
    _pulseCtrl.forward(from: 0.0);
    setState(() {});
  }

  void _onPlaybackChanged() {
    if (!mounted) return;
    if (!widget.controller.isPlaying && _pulseCtrl.isAnimating) {
      _pulseCtrl.stop();
      _pulseCtrl.value = 0.0;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.beatListenable.removeListener(_onBeat);
    widget.controller.playbackListenable.removeListener(_onPlaybackChanged);
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = context.colorScheme;
    final beats = c.project.meta.beatsPerBar;
    final reducedMotion = context.disableAnimations;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _pulseCtrl,
        builder: (context, _) {
          final t = _pulseCtrl.value;
          final wave = (!reducedMotion && c.isPlaying && t > 0 && t < 1)
              ? riseAndFall(t, 0.25, 2.2)
              : 0.0;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var b = 1; b <= beats; b++) ...[
                Builder(
                  builder: (context) {
                    final isActive = c.isPlaying && c.currentBeatInBar == b;
                    final isPulsing = isActive && _pulsingBeat == b;
                    final peakDelta = b == 1 ? 0.5 : 0.35;
                    final scale = isPulsing ? 1.0 + peakDelta * wave : 1.0;
                    final size =
                        b == 1 ? (widget.downbeatSize ?? widget.dotSize) : widget.dotSize;
                    final color = isActive
                        ? (b == 1 ? widget.downbeatColor : widget.beatColor)
                        : widget.inactiveColor;
                    return Transform.scale(
                      scale: scale,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color,
                        ),
                        child: SizedBox.square(dimension: size),
                      ),
                    );
                  },
                ),
                if (b < beats || widget.showBarBeatLabel)
                  SizedBox(width: widget.spacing),
              ],
              if (widget.showBarBeatLabel) ...[
                const SizedBox(width: 2),
                Text(
                  '${c.currentBar}.${c.currentBeatInBar}',
                  style: AppTextStyle.caption1
                      .of(context, emphasized: true)
                      .copyWith(
                        fontFamily: 'GoogleSans',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
