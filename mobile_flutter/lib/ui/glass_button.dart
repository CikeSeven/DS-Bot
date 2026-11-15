// The onboarding call to action: a clear glass pill with a specular band and
// rim, a sheen that sweeps across now and then, a light that follows the finger,
// and a 3D tilt toward the press point that springs back with a little
// overshoot. Each moving part repaints only its own layer.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'liquid_glass.dart';
import 'icons.dart';
import 'motion.dart';
import 'theme.dart';

class HighlightGlassButton extends StatefulWidget {
  const HighlightGlassButton({
    super.key,
    required this.label,
    this.onTap,
    this.icon = AppIcon.forward,
    this.busy = false,
    this.height = 60,
    this.frosted = true,
    this.expand = true,
    this.appear,
    this.round = false,
  });

  final String label;
  final VoidCallback? onTap;
  final AppIcon? icon;
  final bool busy;
  final double height;

  /// False inside a pane that is already frosted: same look, no second blur.
  final bool frosted;

  /// Fills the width it is given; false hugs the label.
  final bool expand;

  /// 0..1 while the button comes or goes; the glass fades itself (see
  /// [LiquidGlass.appear]), so never fade an ancestor of the button.
  final Animation<double>? appear;

  /// A glass disc [height] across with only the icon on it; [label] then only
  /// names the button for accessibility.
  final bool round;

  @override
  State<HighlightGlassButton> createState() => _HighlightGlassButtonState();
}

class _HighlightGlassButtonState extends State<HighlightGlassButton> with TickerProviderStateMixin {
  late final _press = AnimationController.unbounded(vsync: this);
  late final _sheen = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  // The finger, in the pill's own pixels and as -1..1 from its center.
  final _touch = ValueNotifier<(Offset, Offset)>((Offset.zero, Offset.zero));
  Timer? _next;
  bool _reduce = false;
  bool _primed = false;

  bool get _enabled => widget.onTap != null && !widget.busy;

  @override
  void initState() {
    super.initState();
    _sheen.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_reduce) {
        _next?.cancel();
        _next = Timer(const Duration(milliseconds: 2600), () => _sheen.forward(from: 0));
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = reduceMotion(context);
    if (reduce == _reduce && _primed) return;
    _primed = true;
    _reduce = reduce;
    if (reduce) {
      _next?.cancel();
      _sheen.stop();
    } else {
      // The first sweep lands once the button has risen into place.
      _next?.cancel();
      _next = Timer(const Duration(milliseconds: 700), () => _sheen.forward(from: 0));
    }
  }

  @override
  void dispose() {
    _next?.cancel();
    _press.dispose();
    _sheen.dispose();
    _touch.dispose();
    super.dispose();
  }

  void _spring(double target, SpringDescription spring) {
    _press.animateWith(SpringSimulation(spring, _press.value, target, _press.velocity));
  }

  void _follow(Offset local) {
    final size = context.size;
    if (size == null || size.isEmpty) return;
    final clamped = Offset(local.dx.clamp(0, size.width), local.dy.clamp(0, size.height));
    final unit = Offset(clamped.dx / size.width * 2 - 1, clamped.dy / size.height * 2 - 1);
    _touch.value = (clamped, unit);
  }

  void _down(PointerDownEvent event) {
    if (!_enabled) return;
    _follow(event.localPosition);
    HapticFeedback.lightImpact();
    if (_reduce) {
      _press.value = 1;
    } else {
      _spring(1, Springs.tap);
    }
  }

  void _up() {
    if (_reduce) {
      _press.value = 0;
    } else {
      _spring(0, Springs.pop);
    }
  }

  void _tap() {
    HapticFeedback.mediumImpact();
    if (!_reduce) {
      _next?.cancel();
      _sheen.forward(from: 0);
    }
    widget.onTap!();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final h = widget.height;
    final ink = p.ink;
    final Widget row = widget.round
        ? _Arrow(icon: widget.icon ?? AppIcon.forward, ink: ink, dark: p.dark, sheen: _sheen, press: _press, bare: h * 0.36)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: TextStyle(fontSize: h >= 56 ? 17 : 16, height: 1.2, fontWeight: FontWeight.w600, letterSpacing: 0.4, color: ink),
              ),
              if (widget.icon != null || widget.busy) ...[
                const SizedBox(width: 12),
                widget.busy
                    ? SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: ink))
                    : _Arrow(icon: widget.icon!, ink: ink, dark: p.dark, sheen: _sheen, press: _press),
              ],
            ],
          );
    // Disabled dims the label inside the glass, never the glass itself.
    final label = AnimatedOpacity(opacity: widget.onTap == null ? 0.45 : 1, duration: const Duration(milliseconds: 200), child: row);
    final pill = LiquidGlass(
      radius: h / 2,
      blur: 8,
      edge: h * 0.32,
      refract: h * 0.24,
      shadow: false,
      frosted: widget.frosted,
      appear: widget.appear,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _PillOverlay(dark: p.dark, sheen: _sheen, press: _press, touch: _touch),
          child: widget.round
              ? SizedBox.square(
                  dimension: h,
                  child: Center(child: label),
                )
              : SizedBox(
                  height: h,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: h * 0.5),
                    child: Center(widthFactor: widget.expand ? null : 1, child: label),
                  ),
                ),
        ),
      ),
    );
    final body = Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: h * 0.3,
          right: h * 0.3,
          top: h * 0.45,
          height: h * 0.95,
          child: IgnorePointer(
            child: CustomPaint(
              painter: _ShadowPainter(dark: p.dark, inPane: !widget.frosted, appear: widget.appear),
            ),
          ),
        ),
        if (widget.expand && !widget.round) SizedBox(width: double.infinity, child: pill) else pill,
      ],
    );
    return Semantics(
      container: true,
      button: true,
      enabled: _enabled,
      label: widget.label,
      excludeSemantics: true,
      child: Listener(
        onPointerDown: _down,
        onPointerMove: (event) {
          if (_enabled) _follow(event.localPosition);
        },
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _enabled ? _tap : null,
          child: AnimatedBuilder(
            animation: Listenable.merge([_press, _touch]),
            child: body,
            builder: (context, child) {
              final v = _press.value;
              final unit = _touch.value.$2;
              final tilt = _reduce ? 0.0 : v;
              final s = 1 - 0.04 * v;
              final matrix = Matrix4.identity()
                ..setEntry(3, 2, 0.0014)
                ..rotateX(-unit.dy * 0.22 * tilt)
                ..rotateY(unit.dx * 0.10 * tilt)
                ..scaleByDouble(s, s, 1, 1);
              return Transform(alignment: Alignment.center, transform: matrix, child: child);
            },
          ),
        ),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.icon, required this.ink, required this.dark, required this.sheen, required this.press, this.bare});

  final AppIcon icon;
  final Color ink;
  final bool dark;
  final Animation<double> sheen;
  final Animation<double> press;

  /// The icon alone at this size, for the round button; otherwise it sits on
  /// a small disc beside the label.
  final double? bare;

  @override
  Widget build(BuildContext context) {
    final bare = this.bare;
    final disc = bare != null
        ? Ico(icon, size: bare, color: ink)
        : DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dark ? Colors.white.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.55),
              border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.22 : 0.9), width: 0.8),
            ),
            child: SizedBox.square(
              dimension: 30,
              child: Center(child: Ico(icon, size: 17, color: ink)),
            ),
          );
    return AnimatedBuilder(
      animation: Listenable.merge([sheen, press]),
      child: disc,
      builder: (context, child) {
        // A nudge to the right as the sheen leaves, and a slide while pressed.
        final t = sheen.value;
        final nudge = t > 0.55 && t < 0.9 ? math.sin((t - 0.55) / 0.35 * math.pi) * 4 : 0.0;
        return Transform.translate(offset: Offset(nudge + 4 * press.value.clamp(0, 1.2), 0), child: child);
      },
    );
  }
}

/// What moves on the glass: the finger's light and the sheen. The glass
/// itself (refraction, rim light, tint) comes from [LiquidGlass].
class _PillOverlay extends CustomPainter {
  _PillOverlay({required this.dark, required this.sheen, required this.press, required this.touch}) : super(repaint: Listenable.merge([sheen, press, touch]));

  final bool dark;
  final Animation<double> sheen;
  final Animation<double> press;
  final ValueNotifier<(Offset, Offset)> touch;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final h = size.height;
    const white = Colors.white;
    final pressed = press.value.clamp(0.0, 1.0);
    if (pressed > 0.01) {
      final at = touch.value.$1;
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              white.withValues(alpha: (dark ? 0.22 : 0.4) * pressed),
              white.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: at, radius: h * 1.4)),
      );
    }
    final t = sheen.value;
    if (t > 0 && t < 1) {
      final x = -0.3 * size.width + Curves.easeInOutCubic.transform(t) * size.width * 1.6;
      const half = 26.0;
      final streak = Path()
        ..moveTo(x - half - 18, h)
        ..lineTo(x - half + 18, 0)
        ..lineTo(x + half + 18, 0)
        ..lineTo(x + half - 18, h)
        ..close();
      canvas.drawPath(
        streak,
        Paint()
          ..shader = LinearGradient(
            colors: [
              white.withValues(alpha: 0),
              white.withValues(alpha: dark ? 0.22 : 0.42),
              white.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromLTRB(x - half - 18, 0, x + half + 18, h)),
      );
    }
  }

  @override
  bool shouldRepaint(_PillOverlay old) => old.dark != dark;
}

/// A soft, neutral shadow under the pill: a squashed radial falloff, so it
/// renders soft everywhere and never needs a blur.
class _ShadowPainter extends CustomPainter {
  _ShadowPainter({required this.dark, required this.inPane, this.appear}) : super(repaint: appear);

  final bool dark;
  final bool inPane;
  final Animation<double>? appear;

  @override
  void paint(Canvas canvas, Size size) {
    final strength = (dark ? 0.4 : 0.12) * (inPane ? 0.6 : 1) * (appear?.value ?? 1);
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(1, size.height / size.width);
    final radius = size.width / 2;
    canvas.drawCircle(
      Offset.zero,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.black.withValues(alpha: strength),
            Colors.black.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: radius)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShadowPainter old) => old.dark != dark || old.inPane != inPane;
}
