// Floating islands: the small glass panes that hover over a chat (its top
// buttons and title, the message box). Clear frosted glass with a lit rim and a
// soft shadow; a solid card when the user asks for less transparency.
import 'package:flutter/material.dart';

import 'glass.dart';
import 'liquid_glass.dart';
import 'theme.dart';

class GlassIsland extends StatelessWidget {
  const GlassIsland({super.key, required this.child, this.radius = 22, this.padding});

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final glass = GlassScope.of(context);
    final shape = BorderRadius.circular(radius);
    final tint = !glass
        ? p.card
        : p.dark
            ? Color.lerp(p.main, Colors.white, 0.08)!.withValues(alpha: 0.62)
            : Color.lerp(p.main, Colors.white, 0.6)!.withValues(alpha: 0.6);
    final body = CustomPaint(
      painter: _IslandBody(radius: radius, tint: tint, dark: p.dark, lit: glass),
      foregroundPainter: _IslandRim(radius: radius, dark: p.dark, line: p.line2, lit: glass),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: p.dark ? 0.32 : 0.07), blurRadius: 18, offset: const Offset(0, 6)),
          BoxShadow(color: Colors.black.withValues(alpha: p.dark ? 0.18 : 0.03), blurRadius: 3, offset: const Offset(0, 1)),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: glass ? BackdropFilter.grouped(filter: glassFilter(18), child: body) : body,
      ),
    );
  }
}

class _IslandBody extends CustomPainter {
  _IslandBody({required this.radius, required this.tint, required this.dark, required this.lit});

  final double radius;
  final Color tint;
  final bool dark;
  final bool lit;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(shape, Paint()..color = tint);
    if (!lit) return;
    // A sheen across the upper half, as light falling on a curved pane.
    final top = Rect.fromLTWH(0, 0, size.width, (size.height * 0.5).clamp(0, 60));
    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRect(
      top,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withValues(alpha: dark ? 0.07 : 0.32), Colors.white.withValues(alpha: 0)],
        ).createShader(top),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_IslandBody old) => old.radius != radius || old.tint != tint || old.dark != dark || old.lit != lit;
}

class _IslandRim extends CustomPainter {
  _IslandRim({required this.radius, required this.dark, required this.line, required this.lit});

  final double radius;
  final bool dark;
  final Color line;
  final bool lit;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius));
    // A hairline that holds the edge on a light page, where a white rim alone vanishes.
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = dark ? Colors.white.withValues(alpha: 0.06) : line.withValues(alpha: line.a * 0.55),
    );
    if (!lit) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(1), Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: dark ? 0.26 : 0.95),
            Colors.white.withValues(alpha: dark ? 0.03 : 0.2),
            Colors.white.withValues(alpha: dark ? 0.12 : 0.6),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_IslandRim old) => old.radius != radius || old.dark != dark || old.line != line || old.lit != lit;
}

/// A round island holding one icon button.
class IslandButton extends StatelessWidget {
  const IslandButton({super.key, required this.child, this.size = 44});

  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(dimension: size, child: GlassIsland(radius: size / 2, child: Center(child: child)));
  }
}
