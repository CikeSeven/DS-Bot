import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// Glass that fades to transparent from top to bottom: the upper half of
/// the visible glass is full glass; in the lower half ([fadeFraction]) the
/// base color and the backdrop blur (with its saturation boost) fade
/// together along one curve from full to nothing, with nothing left at the
/// bottom edge. `BackdropGlass` paints it inside the backdrop blur layer,
/// before the content, in place of the uniform base color.
///
/// Only the lower half fades: the upper half holds the top bar's title, the
/// status bar icons and buttons, and a fade starting from the very top
/// would leave that part so thin it looks like it has no base; with the
/// lower half fading out, content scrolling up shows through gradually near
/// the bottom edge, and the bottom edge blends into the page. Controls with
/// their own base color inside the fade (the search pill, tabs) need a more
/// solid base, or they vanish along with the glass.
///
/// The curve is an S shape with zero slope at both ends ([strengthAt]): the
/// top joins the full glass smoothly, so no row shows where the fade starts;
/// the bottom ends flat at 0, leaving no line at the bottom edge.
///
/// The glass can be taller than its visible part
/// (`BackdropGlass.extendAbove`: the glass of a pinned tab bar extends up
/// behind the header above it, and when that header collapses the part
/// above is outside the scroll view). The gradient is computed over the
/// height of "the visible part": the top [overhang] of the canvas is the
/// part extended upward, of which the height visible right now is given by
/// [visibleOverhang] (null means all of it is visible); the hidden part is
/// not painted, and is erased when erasing is possible. The visible height
/// changes during layout and only needs a repaint here, so it is used
/// directly as the repaint listenable, without a rebuild.
///
/// How the blur fades out ([eraseBackdrop]): the backdrop blur opens an
/// offscreen layer whose initial content is "the blurred backdrop". Here a
/// rect going from opaque at the top to transparent at the bottom is
/// painted with [BlendMode.dstIn], so the pixels already in the layer are
/// erased along this opacity curve; when the layer is composited back onto
/// the page, the erased parts show the unblurred page below. So erase first
/// and paint the base color after (otherwise the base color is erased too
/// and the curve is applied twice).
///
/// Erasing only works when the backdrop blur really opened its own
/// offscreen layer. In two cases there is no such layer, and
/// [eraseBackdrop] must be false, or it erases the page itself outside the
/// layer:
/// - Blur is off (`BackdropFilter.enabled` is false);
/// - Several glass pieces share one backdrop read
///   (`BackdropFilter.grouped` / `backdropGroupKey`) with the same filter:
///   Impeller computes the blur once and paints the result straight into
///   the parent layer without opening a new layer, and the children paint
///   straight onto the parent layer too, so erasing would make the page
///   transparent, which shows as a black patch on screen. That is why
///   `BackdropGlass` does not share the backdrop read when fading.
///
/// Why not other approaches:
/// - Putting the glass in a `ShaderMask` / `Opacity`: the blur can only
///   sample the mask layer itself (empty), and the whole glass loses its
///   blur (the same constraint as in `BackdropGlass`);
/// - Stacking several `BackdropFilter`s with decreasing blur radius: each
///   one adds another backdrop read and blur, and the boundaries between
///   neighbors show as horizontal lines across text;
/// - A fragment shader for a continuously varying blur: only Impeller
///   supports it, not Skia on desktop and in tests, and the coordinates
///   also depend on whether there are other layers outside.
/// This only adds a few rect draws, with no extra layer or blur.
///
/// Both gradients are one color that varies only in opacity (one of them
/// does not even use its color); they are masks, not a color scheme.
class GlassBottomFadePainter extends CustomPainter {
  GlassBottomFadePainter({
    required this.fade,
    required this.fill,
    required this.eraseBackdrop,
    this.overhang = 0,
    this.visibleOverhang,
  }) : assert(overhang >= 0),
       super(repaint: visibleOverhang);

  /// Whether to fade from top to bottom; when false, the visible part is a
  /// uniform base color (when the top bar divider is on, or in high
  /// contrast).
  final bool fade;

  /// The glass's base color (opacity included); when fading, it fades from
  /// this to fully transparent.
  final Color fill;

  /// Whether to erase the backdrop blur too; can be true only when painted
  /// inside a `BackdropFilter` that has opened an offscreen layer (see the
  /// class comment).
  final bool eraseBackdrop;

  /// Height at the top of the canvas that extends upward
  /// (`BackdropGlass.extendAbove`).
  final double overhang;

  /// How much of the upward extension is visible right now; null means all
  /// of [overhang] is visible.
  final ValueListenable<double>? visibleOverhang;

  /// Share of the glass's visible height taken by the fade (measured up from
  /// the bottom edge); above it is full glass.
  static const double fadeFraction = 0.5;

  /// Number of samples on the opacity curve (including both ends). A linear
  /// gradient is a straight line between two samples; 9 points follow the S
  /// shape of [strengthAt] closely enough that no kinks show.
  static const int _sampleCount = 9;

  /// Strength from top (0) to bottom (1): 1 − smoothstep. Both ends have
  /// zero slope.
  static double strengthAt(double fraction) {
    final u = fraction.clamp(0.0, 1.0);
    return 1 - u * u * (3 - 2 * u);
  }

  /// Recently used gradient shaders: the top bar repaints every frame while
  /// scrolling, but its geometry and colors rarely change, so there is no
  /// need to create two gradient objects in the engine every frame.
  static final Map<(double, double, Color), ui.Shader> _shaders =
      <(double, double, Color), ui.Shader>{};

  /// A shader that fades [color] to fully transparent from [top] to
  /// [bottom] along [strengthAt].
  static ui.Shader _fadeShader(double top, double bottom, Color color) {
    final key = (top, bottom, color);
    final cached = _shaders.remove(key);
    if (cached != null) {
      _shaders[key] = cached;
      return cached;
    }
    final colors = <Color>[];
    final stops = <double>[];
    for (var i = 0; i < _sampleCount; i++) {
      final fraction = i / (_sampleCount - 1);
      stops.add(fraction);
      colors.add(color.withValues(alpha: color.a * strengthAt(fraction)));
    }
    final shader = ui.Gradient.linear(
      Offset(0, top),
      Offset(0, bottom),
      colors,
      stops,
    );
    _shaders[key] = shader;
    if (_shaders.length > 8) {
      _shaders.remove(_shaders.keys.first);
    }
    return shader;
  }

  /// Where the visible top edge is in the canvas.
  double _visibleTop(Size size) {
    final visible = (visibleOverhang?.value ?? overhang).clamp(0.0, overhang);
    return (overhang - visible).clamp(0.0, size.height);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final top = _visibleTop(size);
    // The hidden part (outside the scroll view): no base color; when erasing
    // is possible, erase the blur too, so no frosted patch appears if it
    // ever shows.
    if (top > 0 && eraseBackdrop) {
      canvas.drawRect(
        Rect.fromLTRB(0, 0, size.width, top),
        Paint()..blendMode = BlendMode.clear,
      );
    }
    if (top >= size.height) return;
    if (!fade) {
      canvas.drawRect(
        Rect.fromLTRB(0, top, size.width, size.height),
        Paint()..color = fill,
      );
      return;
    }
    // Full base color in the upper half, gradient in the lower half.
    final fadeTop = size.height - (size.height - top) * fadeFraction;
    canvas.drawRect(
      Rect.fromLTRB(0, top, size.width, fadeTop),
      Paint()..color = fill,
    );
    final rect = Rect.fromLTRB(0, fadeTop, size.width, size.height);
    if (eraseBackdrop) {
      canvas.drawRect(
        rect,
        Paint()
          ..blendMode = BlendMode.dstIn
          // dstIn looks only at the source's opacity; any color works.
          ..shader = _fadeShader(fadeTop, size.height, const Color(0xFF000000)),
      );
    }
    canvas.drawRect(
      rect,
      Paint()..shader = _fadeShader(fadeTop, size.height, fill),
    );
  }

  @override
  bool shouldRepaint(covariant GlassBottomFadePainter oldDelegate) =>
      oldDelegate.fade != fade ||
      oldDelegate.fill != fill ||
      oldDelegate.eraseBackdrop != eraseBackdrop ||
      oldDelegate.overhang != overhang ||
      oldDelegate.visibleOverhang != visibleOverhang;
}
