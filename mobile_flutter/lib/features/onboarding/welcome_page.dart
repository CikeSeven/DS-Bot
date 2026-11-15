// The first screen of a fresh install: the living logo, a short welcome and
// one way forward. One entrance controller choreographs everything in about
// 1.8 s; leaving sends the ring past the viewer before the pairing page rises.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/glass_button.dart';
import '../../ui/i18n.dart';
import '../../ui/motion.dart';
import '../../ui/theme.dart';
import 'orbit.dart';
import 'parallax.dart';

class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key, required this.onEnter, required this.parallax});

  final Future<void> Function() onEnter;
  final ParallaxController parallax;

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> with TickerProviderStateMixin {
  late final _entrance = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..forward();
  late final _warp = AnimationController(vsync: this, duration: const Duration(milliseconds: 460));
  bool _leaving = false;

  @override
  void dispose() {
    _entrance.dispose();
    _warp.dispose();
    super.dispose();
  }

  Future<void> _enter() async {
    if (_leaving) return;
    _leaving = true;
    if (!reduceMotion(context)) await _warp.forward();
    await widget.onEnter();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final hero = math.min(box.maxWidth * 0.92, box.maxHeight * 0.46).clamp(200.0, 440.0);
        final leaving = _warp.drive(CurveTween(curve: Curves.easeIn));
        // What stays: text fades on it, the glass appears and leaves with it.
        final staying = ReverseAnimation(leaving);
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanUpdate: (details) => widget.parallax.drag(Offset(details.delta.dx / box.maxWidth, details.delta.dy / box.maxHeight)),
          onPanEnd: (_) => widget.parallax.release(),
          onPanCancel: widget.parallax.release,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: [
                  // Low in its space: the ring sits near the words and leaves air
                  // under the status bar.
                  Expanded(
                    child: Align(
                      alignment: const Alignment(0, 0.8),
                      child: OrbitHero(size: hero, entrance: _entrance, warp: _warp, parallax: widget.parallax),
                    ),
                  ),
                  // Leaving moves this block down; only its text fades, since the
                  // glass in it must not sit in a fading layer.
                  AnimatedBuilder(
                    animation: leaving,
                    builder: (context, child) => Transform.translate(offset: Offset(0, 28 * leaving.value), child: child),
                    child: Column(
                      children: [
                        _Copy(entrance: _entrance, staying: staying),
                        const SizedBox(height: 40),
                        Reveal(
                          animation: _entrance,
                          start: 0.58,
                          end: 0.95,
                          offset: 36,
                          scale: 0.7,
                          curve: SpringCurve.pop,
                          fade: false,
                          child: HighlightGlassButton(
                            label: t('Get started'),
                            round: true,
                            height: 76,
                            onTap: _enter,
                            appear: AnimationProduct(appearing(_entrance, 0.58, 0.82), staying),
                          ),
                        ),
                        // The words and the button sit well above the bottom edge.
                        SizedBox(height: (box.maxHeight * 0.15).clamp(48.0, 160.0)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Copy extends StatelessWidget {
  const _Copy({required this.entrance, required this.staying});

  final Animation<double> entrance;
  final Animation<double> staying;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return FadeTransition(
      opacity: staying,
      child: Column(
        children: [
          Reveal(
            animation: entrance,
            start: 0.36,
            end: 0.7,
            child: Text(
              'DS BOT',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 4.2,
                color: p.dark ? Color.lerp(p.accent, Colors.white, 0.4) : p.accent,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Reveal(
            animation: entrance,
            start: 0.4,
            end: 0.76,
            child: _ShimmerTitle(text: t('Welcome to DS Bot')),
          ),
          const SizedBox(height: 10),
          Reveal(
            animation: entrance,
            start: 0.46,
            end: 0.82,
            child: Text(
              t('Your Bot team, wherever you are.'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, height: 1.5, color: p.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

/// The title, with a band of light that crosses it as it lands and every few
/// seconds after. Between sweeps nothing ticks, so the text stays a cached layer.
class _ShimmerTitle extends StatefulWidget {
  const _ShimmerTitle({required this.text});

  final String text;

  @override
  State<_ShimmerTitle> createState() => _ShimmerTitleState();
}

class _ShimmerTitleState extends State<_ShimmerTitle> with SingleTickerProviderStateMixin {
  late final _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
  Timer? _next;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || reduceMotion(context)) return;
    _started = true;
    _sweep.addStatusListener((status) {
      if (status == AnimationStatus.completed) _next = Timer(const Duration(seconds: 6), () => _sweep.forward(from: 0));
    });
    _next = Timer(const Duration(milliseconds: 950), () => _sweep.forward(from: 0));
  }

  @override
  void dispose() {
    _next?.cancel();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final shine = p.dark ? Color.lerp(p.accent, Colors.white, 0.72)! : Color.lerp(p.accent, Colors.white, 0.1)!;
    final text = Text(
      widget.text,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 32, height: 1.2, fontWeight: FontWeight.w600, letterSpacing: -0.4, color: p.ink),
    );
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _sweep,
        child: text,
        builder: (context, child) {
          final t = _sweep.value;
          if (t == 0 || t == 1) return child!;
          final at = -0.25 + Curves.easeInOut.transform(t) * 1.5;
          return ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) => LinearGradient(
              begin: const Alignment(-1, -0.4),
              end: const Alignment(1, 0.4),
              colors: [p.ink, p.ink, shine, p.ink, p.ink],
              stops: [0, (at - 0.16).clamp(0.0, 1.0), at.clamp(0.0, 1.0), (at + 0.16).clamp(0.0, 1.0), 1],
            ).createShader(bounds),
            child: child,
          );
        },
      ),
    );
  }
}
