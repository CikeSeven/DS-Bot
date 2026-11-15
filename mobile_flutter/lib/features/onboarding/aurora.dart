// The onboarding sky: a deep base, four soft color fields that drift on slow
// loops, a few dozen twinkling stars and a vignette. It is all radial gradients
// and circles in one painter: no saveLayer and no blur filter, so a frame costs
// a handful of draw calls. It sits under both onboarding pages and keeps going
// across the switch between them.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../ui/motion.dart';
import '../../ui/theme.dart';

class AuroraBackdrop extends StatefulWidget {
  const AuroraBackdrop({super.key, required this.child, this.intensity = 1, this.parallax});

  final Widget child;

  /// 1 on the welcome page; the pairing page dims it so its card reads.
  final double intensity;
  final ValueListenable<Offset>? parallax;

  @override
  State<AuroraBackdrop> createState() => _AuroraBackdropState();
}

class _AuroraBackdropState extends State<AuroraBackdrop> with TickerProviderStateMixin {
  late final _drift = AnimationController(vsync: this, duration: const Duration(seconds: 28));
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  late final _intensity = AnimationController(vsync: this, duration: const Duration(milliseconds: 700), value: widget.intensity);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _drift.stop();
    } else if (!_drift.isAnimating) {
      _drift.repeat();
    }
  }

  @override
  void didUpdateWidget(AuroraBackdrop old) {
    super.didUpdateWidget(old);
    if (widget.intensity != old.intensity) _intensity.animateTo(widget.intensity, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _drift.dispose();
    _fade.dispose();
    _intensity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            painter: _AuroraPainter(
              accent: p.accent,
              dark: p.dark,
              drift: _drift,
              fade: _fade,
              intensity: _intensity,
              parallax: widget.parallax,
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _Star {
  const _Star(this.x, this.y, this.radius, this.phase, this.speed);

  final double x;
  final double y;
  final double radius;
  final double phase;
  final int speed;
}

final _stars = () {
  final random = math.Random(7);
  return List.generate(44, (_) => _Star(random.nextDouble(), random.nextDouble() * 0.82, 0.5 + random.nextDouble() * 1.1, random.nextDouble(), 1 + random.nextInt(4)));
}();

/// Orbs with soft but defined edges, placed where the glass sits (the card,
/// the chips, the button): blur over a smooth gradient is invisible, over an
/// edge it is what makes glass read as glass.
class _Orb {
  const _Orb(this.x, this.y, this.radius, this.hue, this.fx, this.fy, this.phase, this.depth);

  final double x;
  final double y;
  final double radius;
  final double hue;
  final int fx;
  final int fy;
  final double phase;
  final double depth;
}

const _orbs = [
  _Orb(0.14, 0.6, 0.14, 0, 1, 1, 0.4, 0.9),
  _Orb(0.9, 0.48, 0.11, 42, 1, 2, 2.1, 1.3),
  // Across the right edge of the round button on the welcome page.
  _Orb(0.62, 0.79, 0.1, -34, 2, 1, 3.6, 1.1),
  // Under the pairing page's bottom pills.
  _Orb(0.22, 0.95, 0.1, 78, 1, 1, 5.0, 1.5),
];

class _AuroraPainter extends CustomPainter {
  _AuroraPainter({
    required this.accent,
    required this.dark,
    required this.drift,
    required this.fade,
    required this.intensity,
    this.parallax,
  }) : super(repaint: Listenable.merge([drift, fade, intensity, ?parallax]));

  final Color accent;
  final bool dark;
  final Animation<double> drift;
  final Animation<double> fade;
  final Animation<double> intensity;
  final ValueListenable<Offset>? parallax;

  Color _hue(double shift, {double? saturation, double? lightness}) {
    final hsl = HSLColor.fromColor(accent);
    return hsl
        .withHue((hsl.hue + shift) % 360)
        .withSaturation(saturation ?? hsl.saturation)
        .withLightness(lightness ?? hsl.lightness)
        .toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final w = size.width;
    final h = size.height;
    final shown = Curves.easeOut.transform(fade.value);
    final strength = intensity.value * shown;
    final tilt = parallax?.value ?? Offset.zero;
    final t = drift.value * 2 * math.pi;

    // The base: night blue in the dark, pearl in the light, both tinted by the accent.
    final base = dark
        ? [Color.lerp(const Color(0xFF060914), accent, 0.06)!, Color.lerp(const Color(0xFF0A0F24), accent, 0.1)!]
        : [Color.lerp(const Color(0xFFF8F9FD), accent, 0.03)!, Color.lerp(const Color(0xFFEDEFF8), accent, 0.07)!];
    canvas.drawRect(
      rect,
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: base).createShader(rect),
    );

    // Four color fields on Lissajous loops; integer frequencies keep the loop seamless.
    // Deeper fields move less with the parallax, nearer ones more.
    void field(Offset home, double radius, Color color, double alpha, int fx, int fy, double phase, double depth) {
      final center = Offset(
        home.dx * w + math.sin(t * fx + phase) * w * 0.10 + tilt.dx * depth * w * 0.06,
        home.dy * h + math.cos(t * fy + phase) * h * 0.06 + tilt.dy * depth * h * 0.04,
      );
      final r = radius * math.max(w, h);
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(colors: [color.withValues(alpha: alpha * strength), color.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }

    // Dark keeps the night deep: the fields glow, they do not flood.
    final a = dark ? 0.5 : 0.42;
    field(const Offset(0.18, 0.16), 0.55, accent, 0.55 * a, 1, 1, 0, 0.6);
    field(const Offset(0.86, 0.26), 0.48, _hue(42, lightness: dark ? 0.55 : 0.62), 0.42 * a, 2, 1, 1.7, 1.0);
    field(const Offset(0.3, 0.62), 0.5, _hue(-34, lightness: dark ? 0.5 : 0.64), 0.34 * a, 1, 2, 3.1, 0.8);
    field(const Offset(0.78, 0.82), 0.42, _hue(78, saturation: 0.55, lightness: dark ? 0.42 : 0.7), 0.26 * a, 2, 2, 4.4, 1.2);

    for (final orb in _orbs) {
      final center = Offset(
        orb.x * w + math.sin(t * orb.fx + orb.phase) * w * 0.05 + tilt.dx * orb.depth * w * 0.05,
        orb.y * h + math.cos(t * orb.fy + orb.phase) * h * 0.03 + tilt.dy * orb.depth * h * 0.03,
      );
      final r = orb.radius * w;
      final color = _hue(orb.hue, lightness: dark ? 0.58 : 0.72);
      final alpha = (dark ? 0.5 : 0.55) * strength;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [color.withValues(alpha: alpha), color.withValues(alpha: alpha * 0.8), color.withValues(alpha: 0)],
            stops: const [0, 0.72, 1],
          ).createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }

    // Stars twinkle at whole multiples of the drift loop.
    if (dark || strength > 0) {
      final star = Paint()..isAntiAlias = true;
      for (final s in _stars) {
        final twinkle = 0.5 + 0.5 * math.sin(t * s.speed + s.phase * 2 * math.pi);
        final alpha = (dark ? 0.75 : 0.35) * twinkle * shown;
        if (alpha < 0.02) continue;
        star.color = (dark ? Colors.white : accent).withValues(alpha: alpha);
        canvas.drawCircle(Offset(s.x * w + tilt.dx * 6 * s.radius, s.y * h + tilt.dy * 4 * s.radius), s.radius, star);
      }
    }

    // The vignette keeps the edges quiet and the eye in the middle.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.2),
          radius: 1.1,
          colors: [Colors.black.withValues(alpha: 0), Colors.black.withValues(alpha: dark ? 0.42 : 0.06)],
          stops: const [0.55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.accent != accent || old.dark != dark || old.parallax != parallax;
}
