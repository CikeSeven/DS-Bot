// The welcome hero, the README logo brought to life (ds-bot/dev/logo.mjs): the
// whale in a glass core and the other first characters on a ring around it,
// tilted back into an ellipse. Characters grow and brighten as they come round
// the front and pass behind the core at the back.
//
// The ring is a Flow: each frame only changes the transform and opacity it
// paints every cached character with, so motion costs no layout and no repaint
// of the characters themselves.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../shared/characters.dart';
import '../../ui/avatar.dart';
import '../../ui/motion.dart';
import '../../ui/theme.dart';

/// The ring, clockwise from the top, as in the README logo.
const _ring = [
  ('star', 'aurora'),
  ('wave', 'rose'),
  ('squircle', 'tangerine'),
  ('moon', 'charcoal'),
  ('hex', 'cobalt'),
  ('zed', 'graphite'),
];

/// cos of the ring's tilt away from the viewer (about 62°).
const _squash = 0.47;

class OrbitHero extends StatefulWidget {
  const OrbitHero({super.key, required this.size, required this.entrance, required this.warp, this.parallax});

  final double size;

  /// 0..1 over the page's entrance; the core pops, then the ring flies out.
  final Animation<double> entrance;

  /// 0..1 when leaving: the ring flies past the viewer and fades.
  final Animation<double> warp;
  final ValueListenable<Offset>? parallax;

  @override
  State<OrbitHero> createState() => _OrbitHeroState();
}

class _OrbitHeroState extends State<OrbitHero> with TickerProviderStateMixin {
  late final _spin = AnimationController(vsync: this, duration: const Duration(seconds: 60));
  late final _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 4200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _spin.stop();
      _breath.stop();
    } else {
      if (!_spin.isAnimating) _spin.repeat();
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final mark = size * 0.17;
    final core = size * 0.42;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(painter: _TrackPainter(color: context.p.accent, dark: context.p.dark, spin: _spin, entrance: widget.entrance, warp: widget.warp)),
            ),
          ),
          Flow(
            clipBehavior: Clip.none,
            delegate: _OrbitDelegate(
              spin: _spin,
              entrance: widget.entrance,
              warp: widget.warp,
              parallax: widget.parallax,
              mark: mark,
              core: core,
            ),
            children: [
              for (final (shape, color) in _ring) CharacterMark(look: lookOf(shape: shape, color: color), size: mark),
              _GlassCore(size: core, breath: _breath),
            ],
          ),
        ],
      ),
    );
  }
}

class _OrbitDelegate extends FlowDelegate {
  _OrbitDelegate({required this.spin, required this.entrance, required this.warp, required this.parallax, required this.mark, required this.core})
      : super(repaint: Listenable.merge([spin, entrance, warp, ?parallax]));

  final Animation<double> spin;
  final Animation<double> entrance;
  final Animation<double> warp;
  final ValueListenable<Offset>? parallax;
  final double mark;
  final double core;

  static double _interval(double t, double begin, double end, Curve curve) => curve.transform(((t - begin) / (end - begin)).clamp(0.0, 1.0));

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints.tight(Size.square(i == _ring.length ? core : mark));

  @override
  void paintChildren(FlowPaintingContext context) {
    final size = context.size;
    final center = size.center(Offset.zero);
    final tilt = parallax?.value ?? Offset.zero;
    final e = entrance.value;
    // Leaving: the ring grows toward the viewer and is gone well before it
    // gets big, since every character paints through its own layer.
    final w = Curves.easeInCubic.transform(warp.value);
    final gone = Curves.easeOut.transform(warp.value);
    final radius = size.width * 0.38;

    final seats = <(int, double, Matrix4, double)>[];
    for (var i = 0; i < _ring.length; i++) {
      // Each character leaves the core in turn, overshooting a little into its seat.
      final out = _interval(e, 0.17 + i * 0.035, 0.6 + i * 0.035, Curves.easeOutBack);
      final angle = -math.pi / 2 + (spin.value + i / _ring.length) * 2 * math.pi;
      final depth = math.sin(angle); // -1 far, +1 near
      final near = (depth + 1) / 2;
      final r = radius * out * (1 + 1.2 * w);
      final x = math.cos(angle) * r + tilt.dx * (10 + 10 * near);
      final y = math.sin(angle) * r * _squash + tilt.dy * (6 + 8 * near);
      final scale = (0.68 + 0.46 * near) * (0.4 + 0.6 * out) * (1 + 0.8 * w);
      final opacity = ((0.42 + 0.58 * near) * out.clamp(0.0, 1.0) * (1 - gone)).clamp(0.0, 1.0);
      final matrix = Matrix4.translationValues(center.dx + x, center.dy + y, 0)
        ..scaleByDouble(scale, scale, 1, 1)
        ..translateByDouble(-mark / 2, -mark / 2, 0, 1);
      seats.add((i, depth, matrix, opacity));
    }
    seats.sort((a, b) => a.$2.compareTo(b.$2));

    void paint((int, double, Matrix4, double) seat) {
      if (seat.$4 <= 0.01) return;
      context.paintChild(seat.$1, transform: seat.$3, opacity: seat.$4);
    }

    // Far side first, then the core, then the near side over it.
    for (final seat in seats.where((s) => s.$2 < 0)) {
      paint(seat);
    }
    final pop = _interval(e, 0.08, 0.5, SpringCurve.pop);
    final coreScale = (0.6 + 0.4 * pop) * (1 - 0.25 * w);
    final coreMatrix = Matrix4.translationValues(center.dx + tilt.dx * 5, center.dy + tilt.dy * 4, 0)
      ..scaleByDouble(coreScale, coreScale, 1, 1)
      ..translateByDouble(-core / 2, -core / 2, 0, 1);
    final coreOpacity = (_interval(e, 0.08, 0.3, Curves.easeOut) * (1 - gone)).clamp(0.0, 1.0);
    if (coreOpacity > 0.01) context.paintChild(_ring.length, transform: coreMatrix, opacity: coreOpacity);
    for (final seat in seats.where((s) => s.$2 >= 0)) {
      paint(seat);
    }
  }

  @override
  bool shouldRepaint(_OrbitDelegate old) => old.mark != mark || old.core != core || old.parallax != parallax;
}

/// The dashed orbit track: a circle of dashes drawn rotated, then squashed, so
/// the dashes travel along the fixed ellipse.
class _TrackPainter extends CustomPainter {
  _TrackPainter({required this.color, required this.dark, required this.spin, required this.entrance, required this.warp})
      : super(repaint: Listenable.merge([spin, entrance, warp]));

  final Color color;
  final bool dark;
  final Animation<double> spin;
  final Animation<double> entrance;
  final Animation<double> warp;

  @override
  void paint(Canvas canvas, Size size) {
    final shown = Curves.easeOut.transform(((entrance.value - 0.3) / 0.4).clamp(0.0, 1.0)) * (1 - warp.value);
    if (shown <= 0.01) return;
    final radius = size.width * 0.38 * (1 + 0.6 * warp.value);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: (dark ? 0.42 : 0.3) * shown);
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(1, _squash);
    canvas.rotate(spin.value * 2 * math.pi * 0.5);
    const dashes = 72;
    for (var i = 0; i < dashes; i++) {
      final a = i / dashes * 2 * math.pi;
      final from = Offset(math.cos(a), math.sin(a)) * radius;
      final to = Offset(math.cos(a + 0.012), math.sin(a + 0.012)) * radius;
      canvas.drawLine(from, to, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TrackPainter old) => old.color != color || old.dark != dark;
}

/// The whale in a glass sphere: gradients and a specular highlight stand in for
/// real refraction, so the core costs no backdrop blur. Its glow breathes and
/// the whale floats.
class _GlassCore extends StatelessWidget {
  const _GlassCore({required this.size, required this.breath});

  final double size;
  final Animation<double> breath;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final whale = RepaintBoundary(child: CharacterMark(look: lookOf(shape: 'whale', color: 'deepseek'), size: size * 0.6));
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Positioned(
          left: -size * 0.45,
          top: -size * 0.45,
          right: -size * 0.45,
          bottom: -size * 0.45,
          child: RepaintBoundary(child: CustomPaint(painter: _CoreGlowPainter(color: p.accent, dark: p.dark, breath: breath))),
        ),
        CustomPaint(size: Size.square(size), painter: _SpherePainter(accent: p.accent, dark: p.dark)),
        AnimatedBuilder(
          animation: breath,
          child: whale,
          builder: (context, child) {
            final b = Curves.easeInOut.transform(breath.value);
            return Transform.translate(offset: Offset(0, (b - 0.5) * size * 0.05), child: child);
          },
        ),
        // The highlight sits over the whale, as on the glass in front of it.
        IgnorePointer(child: CustomPaint(size: Size.square(size), painter: _HighlightPainter())),
      ],
    );
  }
}

class _CoreGlowPainter extends CustomPainter {
  _CoreGlowPainter({required this.color, required this.dark, required this.breath}) : super(repaint: breath);

  final Color color;
  final bool dark;
  final Animation<double> breath;

  @override
  void paint(Canvas canvas, Size size) {
    final b = Curves.easeInOut.transform(breath.value);
    final center = size.center(Offset.zero);
    final radius = size.width / 2 * (0.92 + 0.08 * b);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: (dark ? 0.55 : 0.32) * (0.75 + 0.25 * b)), color.withValues(alpha: 0)],
          stops: const [0.35, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_CoreGlowPainter old) => old.color != color || old.dark != dark;
}

class _SpherePainter extends CustomPainter {
  _SpherePainter({required this.accent, required this.dark});

  final Color accent;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = size.width / 2;
    final deep = Color.lerp(accent, Colors.black, dark ? 0.55 : 0.2)!;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 1.05,
          colors: [
            Colors.white.withValues(alpha: dark ? 0.2 : 0.75),
            Color.lerp(accent, Colors.white, 0.55)!.withValues(alpha: dark ? 0.1 : 0.45),
            deep.withValues(alpha: dark ? 0.6 : 0.28),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(rect),
    );
    // A soft light inside, so the whale stands clear of the glass behind it.
    canvas.drawCircle(
      center,
      radius * 0.62,
      Paint()
        ..shader = RadialGradient(colors: [Colors.white.withValues(alpha: dark ? 0.16 : 0.3), Colors.white.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: center, radius: radius * 0.62)),
    );
    // The rim: light on the lit edge, a colored return low on the far one.
    canvas.drawCircle(
      center,
      radius - 0.75,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: 0.85), Colors.white.withValues(alpha: 0.08), accent.withValues(alpha: 0.6)],
          stops: const [0, 0.5, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SpherePainter old) => old.accent != accent || old.dark != dark;
}

class _HighlightPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final spot = Rect.fromCenter(center: Offset(r * 0.66, r * 0.48), width: r * 0.9, height: r * 0.5);
    canvas.save();
    canvas.translate(spot.center.dx, spot.center.dy);
    canvas.rotate(-0.5);
    final local = Rect.fromCenter(center: Offset.zero, width: spot.width, height: spot.height);
    canvas.drawOval(
      local,
      Paint()
        ..shader = RadialGradient(colors: [Colors.white.withValues(alpha: 0.55), Colors.white.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: Offset.zero, radius: spot.width / 2)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HighlightPainter old) => false;
}
