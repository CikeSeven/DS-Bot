// Shared motion pieces for the onboarding screens. Everything here animates
// through layers (opacity, transform) driven by an Animation, so a frame only
// recomposites; nothing rebuilds a large subtree per tick.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// True when the system asks for less motion: loops stop and only fades stay.
bool reduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Fades [child] in and lifts it by [offset] pixels over [start]..[end] (0..1)
/// of [animation].
class Reveal extends StatelessWidget {
  const Reveal({
    super.key,
    required this.animation,
    required this.child,
    this.start = 0,
    this.end = 1,
    this.offset = 16,
    this.scale = 1,
    this.curve = Curves.easeOutCubic,
    this.fade = true,
  });

  final Animation<double> animation;
  final Widget child;
  final double start;
  final double end;
  final double offset;

  /// The scale the child starts from (1: no scaling).
  final double scale;
  final Curve curve;

  /// False around shader glass, which must not sit in a fading layer; the
  /// glass then fades itself through its own appear animation.
  final bool fade;

  @override
  Widget build(BuildContext context) {
    final progress = animation.drive(CurveTween(curve: Interval(start, end, curve: curve)));
    final moving = AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (context, child) {
        final t = progress.value;
        final s = scale + (1 - scale) * t;
        return Transform(alignment: Alignment.center, transform: Matrix4.translationValues(0, offset * (1 - t), 0)..scaleByDouble(s, s, 1, 1), child: child);
      },
    );
    if (!fade) return moving;
    return FadeTransition(opacity: appearing(animation, start, end), child: moving);
  }
}

/// [animation] eased in over [start]..[end], for a fade or a glass appear.
Animation<double> appearing(Animation<double> animation, double start, double end) =>
    animation.drive(CurveTween(curve: Interval(start, end, curve: Curves.easeOut)));

/// Two animations multiplied, as in "has come in" times "has not left yet".
class AnimationProduct extends CompoundAnimation<double> {
  AnimationProduct(Animation<double> first, Animation<double> next) : super(first: first, next: next);

  @override
  double get value => first.value * next.value;
}

/// Shakes [child] sideways each time [trigger] changes, like a refused input.
class Shake extends StatefulWidget {
  const Shake({super.key, required this.trigger, required this.child, this.distance = 10});

  final int trigger;
  final Widget child;
  final double distance;

  @override
  State<Shake> createState() => _ShakeState();
}

class _ShakeState extends State<Shake> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 460));

  @override
  void didUpdateWidget(Shake old) {
    super.didUpdateWidget(old);
    if (widget.trigger != old.trigger) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = _controller.value;
        // A damped sine: three swings that settle, as a spring would.
        final dx = math.sin(t * math.pi * 6) * (1 - t) * (1 - t) * widget.distance;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}
