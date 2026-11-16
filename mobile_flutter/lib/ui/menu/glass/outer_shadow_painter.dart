import 'package:flutter/material.dart';

/// A shadow painted outside a rounded rect, offset slightly down; the
/// inside of the surface is cut out, so it does not darken a translucent
/// base color.
///
/// A glass surface's base color is translucent, so a plain BoxShadow /
/// elevation would show through from underneath and darken the middle of
/// the surface; this uses an even-odd fill to cut out the surface itself and
/// keep only the ring outside. Shared by the menu (`ExpressiveMenuSurface`)
/// and `BackdropGlass`.
class OuterShadowPainter extends CustomPainter {
  const OuterShadowPainter({required this.color, required this.borderRadius});

  static const Offset offset = Offset(0, 6);
  static const double blur = 18;

  final Color color;
  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    final bounds = Offset.zero & size;
    final shape = borderRadius.toRRect(bounds);
    // Even-odd fill: the outer frame minus the surface itself, leaving only
    // the outside.
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(bounds.inflate(blur * 2 + offset.distance))
      ..addRRect(shape);
    canvas
      ..save()
      ..clipPath(outside)
      ..drawRRect(
        shape.shift(offset),
        Paint()
          ..color = color
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            Shadow.convertRadiusToSigma(blur),
          ),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(OuterShadowPainter oldDelegate) =>
      color != oldDelegate.color || borderRadius != oldDelegate.borderRadius;
}
