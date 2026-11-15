// The pairing card: one frosted square whose content follows the stages of
// pairing: a breathing QR motif, the live camera with a frame that locks on, the
// encrypted handshake, and the connected check. Each stage owns its own
// short-lived controllers and painters, so only the visible one ticks.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../ui/liquid_glass.dart';
import '../../ui/glass_button.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/motion.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

enum ScanStage { idle, camera, connecting, success }

class ScannerCard extends StatelessWidget {
  const ScannerCard({
    super.key,
    required this.stage,
    required this.size,
    required this.scanner,
    required this.onOpenCamera,
    required this.onCloseCamera,
    required this.onDetect,
    this.locked = false,
    this.connectedName = '',
    this.appear,
  });

  final ScanStage stage;
  final double size;
  final MobileScannerController scanner;
  final VoidCallback onOpenCamera;
  final VoidCallback onCloseCamera;
  final ValueChanged<String> onDetect;

  /// A pairing code was read: the camera frame locks on.
  final bool locked;
  final String connectedName;
  final Animation<double>? appear;

  @override
  Widget build(BuildContext context) {
    final corner = size * 0.11;
    final content = AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(animation), child: child),
      ),
      child: switch (stage) {
        ScanStage.idle => _Idle(key: const ValueKey('idle'), onTap: onOpenCamera),
        ScanStage.camera => _Camera(key: const ValueKey('camera'), scanner: scanner, onClose: onCloseCamera, onDetect: onDetect, locked: locked),
        ScanStage.connecting => const _Handshake(key: ValueKey('connecting')),
        ScanStage.success => _Success(key: const ValueKey('success'), name: connectedName),
      },
    );
    return LiquidGlass(radius: corner, blur: 14, appear: appear, child: SizedBox.square(dimension: size, child: content));
  }
}

/// Starts a repeating controller unless the system asks for less motion.
void _loop(BuildContext context, AnimationController controller, {bool reverse = false}) {
  if (reduceMotion(context)) {
    controller.stop();
  } else if (!controller.isAnimating) {
    controller.repeat(reverse: reverse);
  }
}

// --- Idle: a stylized code with light rippling across it ---------------------

class _Idle extends StatefulWidget {
  const _Idle({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  State<_Idle> createState() => _IdleState();
}

class _IdleState extends State<_Idle> with SingleTickerProviderStateMixin {
  late final _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop(context, _wave);
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Align(
            alignment: const Alignment(0, -0.3),
            child: FractionallySizedBox(
              widthFactor: 0.46,
              heightFactor: 0.46,
              child: RepaintBoundary(child: CustomPaint(painter: _QrPainter(wave: _wave, ink: p.ink, accent: p.accent, dark: p.dark))),
            ),
          ),
          RepaintBoundary(child: CustomPaint(painter: _BracketsPainter(color: p.accent, inset: 0.08, breath: _wave))),
          Align(
            alignment: const Alignment(0, 0.66),
            child: HighlightGlassButton(label: t('Scan QR code'), icon: AppIcon.camera, height: 48, frosted: false, expand: false, onTap: widget.onTap),
          ),
        ],
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter({required this.wave, required this.ink, required this.accent, required this.dark}) : super(repaint: wave);

  final Animation<double> wave;
  final Color ink;
  final Color accent;
  final bool dark;

  static const _n = 11;

  static bool _finder(int i, int j) => (i < 3 && j < 3) || (i < 3 && j >= _n - 3) || (i >= _n - 3 && j < 3);

  // A fixed pattern, the same on every frame.
  static final _on = [
    for (var i = 0; i < _n; i++)
      for (var j = 0; j < _n; j++) !_finder(i, j) && ((i * 7 + j * 13 + i * j * 5) % 11) < 7,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / _n;
    final t = wave.value * 2 * math.pi;
    final dim = ink.withValues(alpha: dark ? 0.28 : 0.22);
    final paint = Paint()..isAntiAlias = true;
    for (var i = 0; i < _n; i++) {
      for (var j = 0; j < _n; j++) {
        if (!_on[i * _n + j]) continue;
        final v = 0.5 + 0.5 * math.sin(t - (i + j) * 0.55);
        paint.color = Color.lerp(dim, accent, v * 0.85)!;
        final d = cell * (0.5 + 0.14 * v);
        final c = Offset((j + 0.5) * cell, (i + 0.5) * cell);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: d, height: d), Radius.circular(d * 0.32)), paint);
      }
    }
    // The three finder squares: a ring and a center, pulsing gently.
    final pulse = 0.5 + 0.5 * math.sin(t);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = cell * 0.36
      ..color = Color.lerp(accent, ink, dark ? 0.0 : 0.15)!.withValues(alpha: 0.75 + 0.25 * pulse);
    final dot = Paint()..color = ring.color;
    for (final (i, j) in const [(0, 0), (0, _n - 3), (_n - 3, 0)]) {
      final box = Rect.fromLTWH(j * cell, i * cell, cell * 3, cell * 3);
      canvas.drawRRect(RRect.fromRectAndRadius(box.deflate(cell * 0.2), Radius.circular(cell * 0.7)), ring);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: box.center, width: cell * 0.95, height: cell * 0.95), Radius.circular(cell * 0.3)), dot);
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.ink != ink || old.accent != accent || old.dark != dark;
}

/// Four rounded corner brackets. [progress] moves them in from the card's
/// edges to the frame; [lock] closes them in and lights them up.
class _BracketsPainter extends CustomPainter {
  _BracketsPainter({required this.color, required this.inset, this.breath, this.progress, this.lock})
      : super(repaint: Listenable.merge([?breath, ?progress, ?lock]));

  final Color color;
  final double inset;
  final Animation<double>? breath;
  final Animation<double>? progress;
  final Animation<double>? lock;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final into = progress?.value ?? 1;
    final locked = lock?.value ?? 0;
    final b = breath == null ? 0.0 : 0.5 + 0.5 * math.sin(breath!.value * 2 * math.pi);
    final f = 0.025 + (inset - 0.025) * into + locked * 0.06 - b * 0.012;
    final half = Offset(w * (0.5 - f), size.height * (0.5 - f));
    final arm = w * 0.1;
    final round = w * 0.045;
    final corner = Path()
      ..moveTo(-half.dx, -half.dy + arm)
      ..lineTo(-half.dx, -half.dy + round)
      ..arcToPoint(Offset(-half.dx + round, -half.dy), radius: Radius.circular(round))
      ..lineTo(-half.dx + arm, -half.dy);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = (w * 0.012).clamp(3.0, 4.5)
      ..color = Color.lerp(color, Colors.white, locked * 0.35)!;
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke.strokeWidth * 3.2
      ..color = color.withValues(alpha: 0.28 * locked);
    canvas.save();
    canvas.translate(w / 2, size.height / 2);
    for (final (sx, sy) in const [(1.0, 1.0), (-1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)]) {
      canvas.save();
      canvas.scale(sx, sy);
      if (locked > 0.01) canvas.drawPath(corner, glow);
      canvas.drawPath(corner, stroke);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BracketsPainter old) => old.color != color || old.inset != inset;
}

// --- Camera: the live preview inside a frame that locks on ------------------

class _Camera extends StatefulWidget {
  const _Camera({super.key, required this.scanner, required this.onClose, required this.onDetect, required this.locked});

  final MobileScannerController scanner;
  final VoidCallback onClose;
  final ValueChanged<String> onDetect;
  final bool locked;

  @override
  State<_Camera> createState() => _CameraState();
}

class _CameraState extends State<_Camera> with TickerProviderStateMixin {
  static const _frame = 0.17;
  late final _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 650))..forward();
  late final _laser = AnimationController(vsync: this, duration: const Duration(milliseconds: 1900));
  late final _lock = AnimationController(vsync: this, duration: const Duration(milliseconds: 320), value: widget.locked ? 1 : 0);
  late final _into = _in.drive(CurveTween(curve: SpringCurve.shape));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop(context, _laser, reverse: true);
  }

  @override
  void didUpdateWidget(_Camera old) {
    super.didUpdateWidget(old);
    if (widget.locked != old.locked) _lock.animateTo(widget.locked ? 1 : 0, curve: Curves.easeOutBack);
  }

  @override
  void dispose() {
    _in.dispose();
    _laser.dispose();
    _lock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final light = Color.lerp(p.accent, Colors.white, 0.25)!;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Colors.black),
        MobileScanner(
          controller: widget.scanner,
          fit: BoxFit.cover,
          onDetect: (capture) {
            final value = capture.barcodes.firstOrNull?.rawValue;
            if (value != null && value.startsWith('dsbot://pair')) widget.onDetect(value);
          },
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                t('The camera is not available. Paste the link instead.'),
                textAlign: TextAlign.center,
                style: TypeScale.small.copyWith(color: Colors.white70),
              ),
            ),
          ),
        ),
        IgnorePointer(child: RepaintBoundary(child: CustomPaint(painter: _ShadePainter(progress: _into, lock: _lock, inset: _frame)))),
        IgnorePointer(child: RepaintBoundary(child: CustomPaint(painter: _LaserPainter(laser: _laser, lock: _lock, inset: _frame, color: light)))),
        IgnorePointer(child: RepaintBoundary(child: CustomPaint(painter: _BracketsPainter(color: light, inset: _frame, progress: _into, lock: _lock)))),
        Positioned(
          left: 16,
          right: 10,
          bottom: 10,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  t('Fit the QR code on your computer inside the frame'),
                  maxLines: 2,
                  style: TypeScale.caption.copyWith(color: Colors.white.withValues(alpha: 0.9), height: 1.35),
                ),
              ),
              const SizedBox(width: 8),
              _CamButton(icon: AppIcon.bolt, label: t('Flashlight'), onTap: () => widget.scanner.toggleTorch()),
              const SizedBox(width: 6),
              _CamButton(icon: AppIcon.close, label: t('Close camera'), onTap: widget.onClose),
            ],
          ),
        ),
      ],
    );
  }
}

class _CamButton extends StatelessWidget {
  const _CamButton({required this.icon, required this.label, required this.onTap});

  final AppIcon icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        onTap: onTap,
        haptic: true,
        scale: 0.9,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.38),
            border: Border.all(color: Colors.white.withValues(alpha: 0.22), width: 0.8),
          ),
          child: SizedBox.square(dimension: 38, child: Center(child: Ico(icon, size: 18, color: Colors.white))),
        ),
      ),
    );
  }
}

/// Dims the preview outside the frame.
class _ShadePainter extends CustomPainter {
  _ShadePainter({required this.progress, required this.lock, required this.inset}) : super(repaint: Listenable.merge([progress, lock]));

  final Animation<double> progress;
  final Animation<double> lock;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final f = inset + lock.value * 0.06;
    final hole = RRect.fromRectAndRadius(
      Rect.fromLTRB(size.width * f, size.height * f, size.width * (1 - f), size.height * (1 - f)),
      Radius.circular(size.width * 0.05),
    );
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(hole);
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.46 * progress.value.clamp(0.0, 1.0)));
  }

  @override
  bool shouldRepaint(_ShadePainter old) => old.inset != inset;
}

/// A line of light sweeping the frame, with a soft glow around it.
class _LaserPainter extends CustomPainter {
  _LaserPainter({required this.laser, required this.lock, required this.inset, required this.color}) : super(repaint: Listenable.merge([laser, lock]));

  final Animation<double> laser;
  final Animation<double> lock;
  final double inset;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final shown = 1 - lock.value.clamp(0.0, 1.0);
    if (shown <= 0.01) return;
    final left = size.width * (inset + 0.03);
    final right = size.width * (1 - inset - 0.03);
    final top = size.height * (inset + 0.04);
    final bottom = size.height * (1 - inset - 0.04);
    final y = top + (bottom - top) * Curves.easeInOut.transform(laser.value);
    final glow = Rect.fromLTRB(left, y - 22, right, y + 22);
    canvas.drawRect(
      glow,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.22 * shown), color.withValues(alpha: 0)],
        ).createShader(glow),
    );
    final line = Rect.fromLTRB(left, y - 1.2, right, y + 1.2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(line, const Radius.circular(2)),
      Paint()
        ..shader = LinearGradient(
          colors: [color.withValues(alpha: 0), color.withValues(alpha: shown), Colors.white.withValues(alpha: shown), color.withValues(alpha: shown), color.withValues(alpha: 0)],
          stops: const [0, 0.25, 0.5, 0.75, 1],
        ).createShader(line),
    );
  }

  @override
  bool shouldRepaint(_LaserPainter old) => old.inset != inset || old.color != color;
}

// --- Handshake: phone and computer, with light flowing between them ---------

class _Handshake extends StatefulWidget {
  const _Handshake({super.key});

  @override
  State<_Handshake> createState() => _HandshakeState();
}

class _HandshakeState extends State<_Handshake> with TickerProviderStateMixin {
  late final _flow = AnimationController(vsync: this, duration: const Duration(milliseconds: 1700));
  late final _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 650))..forward();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop(context, _flow);
  }

  @override
  void dispose() {
    _flow.dispose();
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return LayoutBuilder(
      builder: (context, box) {
        final s = box.maxWidth;
        final node = s * 0.21;
        final lock = s * 0.15;
        return Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(child: CustomPaint(painter: _HandshakePainter(flow: _flow, enter: _enter, accent: p.accent, ink: p.ink, dark: p.dark))),
            ),
            Positioned(left: s * 0.2 - node / 2, top: s * 0.5 - node / 2, child: _Node(size: node, icon: AppIcon.phone)),
            Positioned(left: s * 0.8 - node / 2, top: s * 0.5 - node / 2, child: _Node(size: node, icon: AppIcon.monitor)),
            Positioned(
              left: s / 2 - lock / 2,
              top: s * 0.315 - lock / 2,
              child: ScaleTransition(
                scale: _enter.drive(CurveTween(curve: SpringCurve.pop)),
                child: _LockBadge(size: lock, pulse: _flow),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: s * 0.13,
              child: FadeTransition(
                opacity: _enter,
                child: Text(
                  t('Setting up an end-to-end encrypted link…'),
                  textAlign: TextAlign.center,
                  style: TypeScale.rowPreview.copyWith(color: p.ink2),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Node extends StatelessWidget {
  const _Node({required this.size, required this.icon});

  final double size;
  final AppIcon icon;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: p.dark
              ? [Colors.white.withValues(alpha: 0.16), Colors.white.withValues(alpha: 0.05)]
              : [Colors.white, Colors.white.withValues(alpha: 0.75)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: p.dark ? 0.25 : 0.9), width: 1),
        boxShadow: [BoxShadow(color: p.accent.withValues(alpha: 0.25), blurRadius: 18)],
      ),
      child: SizedBox.square(dimension: size, child: Center(child: Ico(icon, size: size * 0.42, color: p.dark ? Colors.white : p.accent))),
    );
  }
}

class _LockBadge extends StatelessWidget {
  const _LockBadge({required this.size, required this.pulse});

  final double size;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final badge = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(p.accent, Colors.white, 0.25)!, Color.lerp(p.accent, Colors.black, 0.15)!],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1),
        boxShadow: [BoxShadow(color: p.accent.withValues(alpha: 0.45), blurRadius: 20)],
      ),
      child: SizedBox.square(dimension: size, child: Center(child: Ico(AppIcon.lock, size: size * 0.46, color: Colors.white))),
    );
    return AnimatedBuilder(
      animation: pulse,
      child: badge,
      builder: (context, child) {
        final s = 1 + 0.06 * math.sin(pulse.value * 2 * math.pi);
        return Transform.scale(scale: s, child: child);
      },
    );
  }
}

class _HandshakePainter extends CustomPainter {
  _HandshakePainter({required this.flow, required this.enter, required this.accent, required this.ink, required this.dark})
      : super(repaint: Listenable.merge([flow, enter]));

  final Animation<double> flow;
  final Animation<double> enter;
  final Color accent;
  final Color ink;
  final bool dark;

  Size? _for;
  ui.PathMetric? _metric;
  Path? _arc;

  @override
  void paint(Canvas canvas, Size size) {
    if (_for != size) {
      final s = size.width;
      _arc = Path()
        ..moveTo(s * 0.2, s * 0.5)
        ..quadraticBezierTo(s * 0.5, s * 0.13, s * 0.8, s * 0.5);
      _metric = _arc!.computeMetrics().first;
      _for = size;
    }
    final metric = _metric!;
    final e = Curves.easeOutCubic.transform(enter.value);
    final s = size.width;

    // The arc draws itself out from both nodes toward the lock.
    final half = metric.length / 2;
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = ink.withValues(alpha: dark ? 0.2 : 0.14);
    canvas.drawPath(metric.extractPath(0, half * e), base);
    canvas.drawPath(metric.extractPath(metric.length - half * e, metric.length), base);

    // Pulses ripple out of both nodes.
    for (final (center, phase) in [(Offset(s * 0.2, s * 0.5), 0.0), (Offset(s * 0.8, s * 0.5), 0.5)]) {
      final k = (flow.value + phase) % 1;
      canvas.drawCircle(
        center,
        s * 0.105 * (1 + 0.65 * k),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = accent.withValues(alpha: 0.4 * (1 - k) * e),
      );
    }

    // Light travels both ways along the arc.
    final dot = Paint()..isAntiAlias = true;
    for (var k = 0; k < 8; k++) {
      final forward = k.isEven;
      var at = (flow.value + k / 8) % 1;
      if (!forward) at = 1 - at;
      final tangent = metric.getTangentForOffset(metric.length * at);
      if (tangent == null) continue;
      final fade = math.sin(at * math.pi);
      dot.color = (forward ? accent : Color.lerp(accent, Colors.white, 0.5)!).withValues(alpha: 0.9 * fade * e);
      canvas.drawCircle(tangent.position, 2.2 + 1.6 * fade, dot);
    }
  }

  @override
  bool shouldRepaint(_HandshakePainter old) => old.accent != accent || old.ink != ink || old.dark != dark;
}

// --- Success: a check that pops, draws itself and bursts --------------------

class _Success extends StatefulWidget {
  const _Success({super.key, required this.name});

  final String name;

  @override
  State<_Success> createState() => _SuccessState();
}

class _SuccessState extends State<_Success> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _c.value = 1;
    } else if (_c.value == 0) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return LayoutBuilder(
      builder: (context, box) {
        final s = box.maxWidth;
        return Stack(
          children: [
            Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _SuccessPainter(c: _c, accent: p.accent, ink: Colors.white)))),
            Positioned(
              left: 20,
              right: 20,
              bottom: s * 0.13,
              child: FadeTransition(
                opacity: _c.drive(CurveTween(curve: const Interval(0.4, 0.8, curve: Curves.easeOut))),
                child: Text(
                  t('Connected to {name}', {'name': widget.name}),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TypeScale.rowNameStrong.copyWith(color: p.ink, fontSize: 17),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SuccessPainter extends CustomPainter {
  _SuccessPainter({required this.c, required this.accent, required this.ink}) : super(repaint: c);

  final Animation<double> c;
  final Color accent;
  final Color ink;

  static double _span(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final t = c.value;
    final s = size.width;
    final center = Offset(s / 2, s * 0.43);
    final r = s * 0.16;
    final pop = SpringCurve.pop.transform(_span(t, 0, 0.5));

    // A ring of light expands and fades.
    final wave = Curves.easeOut.transform(_span(t, 0.08, 0.8));
    canvas.drawCircle(
      center,
      r * (1 + 1.25 * wave),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = accent.withValues(alpha: 0.45 * (1 - wave)),
    );

    // Sparks burst outward.
    final out = Curves.easeOutCubic.transform(_span(t, 0.12, 0.85));
    final fade = 1 - _span(t, 0.45, 1);
    final spark = Paint()..isAntiAlias = true;
    final warm = HSLColor.fromColor(accent);
    for (var k = 0; k < 20; k++) {
      final angle = k / 20 * 2 * math.pi + (k.isEven ? 0.06 : -0.04);
      final reach = r * (1.15 + (k % 3 == 0 ? 1.5 : 1.15) * out);
      spark.color = switch (k % 3) {
        0 => accent,
        1 => warm.withHue((warm.hue + 42) % 360).toColor(),
        _ => Colors.white,
      }
          .withValues(alpha: 0.9 * fade);
      canvas.drawCircle(center + Offset(math.cos(angle), math.sin(angle)) * reach, 3.2 * (1 - 0.6 * out), spark);
    }

    // The disc, with its glow.
    if (pop > 0) {
      canvas.drawCircle(
        center,
        r * 1.9 * pop,
        Paint()..shader = RadialGradient(colors: [accent.withValues(alpha: 0.4), accent.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: center, radius: r * 1.9 * pop)),
      );
      final disc = Rect.fromCircle(center: center, radius: r * pop);
      canvas.drawCircle(
        center,
        r * pop,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color.lerp(accent, Colors.white, 0.25)!, Color.lerp(accent, Colors.black, 0.18)!],
          ).createShader(disc),
      );
      canvas.drawCircle(
        center,
        r * pop - 0.75,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white.withValues(alpha: 0.55),
      );
    }

    // The check draws itself.
    final draw = Curves.easeInOutCubic.transform(_span(t, 0.28, 0.66));
    if (draw > 0) {
      final check = Path()
        ..moveTo(center.dx - r * 0.42, center.dy + r * 0.02)
        ..lineTo(center.dx - r * 0.12, center.dy + r * 0.32)
        ..lineTo(center.dx + r * 0.45, center.dy - r * 0.3);
      final metric = check.computeMetrics().first;
      canvas.drawPath(
        metric.extractPath(0, metric.length * draw),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.16
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = ink,
      );
    }
  }

  @override
  bool shouldRepaint(_SuccessPainter old) => old.accent != accent || old.ink != ink;
}
