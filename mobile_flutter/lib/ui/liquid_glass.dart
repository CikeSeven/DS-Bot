// Glass for the onboarding screens. Where the engine can run a fragment shader
// as a backdrop filter (Impeller), the pane is real glass: shaders/liquid_glass.frag
// refracts the blurred backdrop through a bevel along the edge, mirrors the
// grazing rim and lights it. Elsewhere (older renderers, tests) it falls back
// to a blurred, saturated pane with a painted rim.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'glass.dart';
import 'theme.dart';

/// The glass shader, loaded once at startup when the engine supports it.
abstract final class LiquidGlassShader {
  static ui.FragmentProgram? _program;

  static ui.FragmentProgram? get program => _program;

  static Future<void> load() async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    try {
      _program = await ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');
    } on Object {
      _program = null;
    }
  }
}

/// Saturation as a color matrix (Rec. 709 luma).
List<double> _saturate(double s) {
  const r = 0.2126, g = 0.7152, b = 0.0722;
  final i = 1 - s;
  return [
    r * i + s, g * i, b * i, 0, 0, //
    r * i, g * i + s, b * i, 0, 0,
    r * i, g * i, b * i + s, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

ui.ImageFilter glassFilter(double blur) => ui.ImageFilter.compose(
      outer: ui.ColorFilter.matrix(_saturate(1.6)),
      inner: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.mirror),
    );

class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.radius = 24,
    this.blur = 10,
    this.edge,
    this.refract,
    this.shadow = true,
    this.frosted = true,
    this.appear,
  });

  final Widget child;
  final double radius;

  /// Blur of the backdrop before it is refracted, in logical pixels.
  final double blur;

  /// The bevel's width and how far its rim pulls the backdrop in; both scale
  /// with the pane when left out.
  final double? edge;
  final double? refract;
  final bool shadow;

  /// False inside a pane that is already glass: the rim and tint only.
  final bool frosted;

  /// 0..1 while the pane comes or goes. Never fade an ancestor of the glass
  /// instead: in a fading layer the engine renders it offscreen and the shader
  /// loses its coordinates and its backdrop.
  final Animation<double>? appear;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final enabled = GlassScope.of(context);
    final program = LiquidGlassShader.program;
    final appear = this.appear;
    final content = appear == null ? child : FadeTransition(opacity: appear, child: child);
    final Widget pane;
    if (frosted && enabled && program != null) {
      pane = _ShaderGlass(
        appear: appear,
        look: _Look(
          radius: radius,
          blur: blur,
          edge: edge ?? (radius * 0.75).clamp(8.0, 22.0),
          refract: refract ?? (radius * 0.6).clamp(6.0, 18.0),
          tint: p.dark ? 0.03 : 0.1,
          shade: p.dark ? 0.2 : 0,
          saturation: p.dark ? 1.55 : 1.45,
          light: p.dark ? 0.85 : 1.0,
        ),
        dpr: MediaQuery.devicePixelRatioOf(context),
        child: content,
      );
    } else {
      final tint = !enabled
          ? (p.dark ? const Color(0xFF1A1F35) : const Color(0xFFF6F7FB))
          : Colors.white.withValues(alpha: p.dark ? 0.07 : 0.3);
      final painted = CustomPaint(
        painter: _BodyPainter(radius: radius, tint: tint, dark: p.dark),
        foregroundPainter: _RimPainter(radius: radius, dark: p.dark),
        child: child,
      );
      final clipped = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: frosted && enabled ? BackdropFilter.grouped(filter: glassFilter(blur * 2), child: painted) : painted,
      );
      // A plain blur keeps working in a fading layer.
      pane = appear == null ? clipped : FadeTransition(opacity: appear, child: clipped);
    }
    if (!shadow) return pane;
    final shadowAlpha = p.dark ? 0.28 : 0.07;
    Widget shadowed(double shown) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: shadowAlpha * shown), blurRadius: 30, offset: const Offset(0, 12)),
            ],
          ),
          child: pane,
        );
    if (appear == null) return shadowed(1);
    return AnimatedBuilder(animation: appear, builder: (context, _) => shadowed(appear.value));
  }
}

@immutable
class _Look {
  const _Look({
    required this.radius,
    required this.blur,
    required this.edge,
    required this.refract,
    required this.tint,
    required this.shade,
    required this.saturation,
    required this.light,
  });

  final double radius;
  final double blur;
  final double edge;
  final double refract;
  final double tint;
  final double shade;
  final double saturation;
  final double light;

  @override
  bool operator ==(Object other) =>
      other is _Look &&
      other.radius == radius &&
      other.blur == blur &&
      other.edge == edge &&
      other.refract == refract &&
      other.tint == tint &&
      other.shade == shade &&
      other.saturation == saturation &&
      other.light == light;

  @override
  int get hashCode => Object.hash(radius, blur, edge, refract, tint, shade, saturation, light);
}

class _ShaderGlass extends SingleChildRenderObjectWidget {
  const _ShaderGlass({required this.look, required this.dpr, this.appear, super.child});

  final _Look look;
  final double dpr;
  final Animation<double>? appear;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderShaderGlass(look, dpr, appear);

  @override
  void updateRenderObject(BuildContext context, _RenderShaderGlass renderObject) {
    renderObject
      ..look = look
      ..dpr = dpr
      ..appear = appear;
  }
}

/// Clips to the pane and filters the backdrop through the glass shader. The
/// shader works in render-target pixels, so every paint hands it the pane's
/// current rect on screen, transforms of animated ancestors included.
///
/// An ancestor can move the pane without repainting it (a repaint boundary in
/// between keeps its layer), so after each frame the pane compares where it is
/// with where it last painted and repaints when they differ: at most a frame
/// behind while something moves, exact at rest.
class _RenderShaderGlass extends RenderProxyBox {
  _RenderShaderGlass(this._look, this._dpr, this._appear);

  Animation<double>? _appear;
  set appear(Animation<double>? value) {
    if (value == _appear) return;
    if (attached) _appear?.removeListener(markNeedsPaint);
    _appear = value;
    if (attached) _appear?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  _Look _look;
  set look(_Look value) {
    if (value == _look) return;
    _look = value;
    markNeedsPaint();
  }

  double _dpr;
  set dpr(double value) {
    if (value == _dpr) return;
    _dpr = value;
    markNeedsPaint();
  }

  ui.FragmentShader? _shader;
  final _clip = LayerHandle<ClipRRectLayer>();
  final _filter = LayerHandle<BackdropFilterLayer>();
  Matrix4? _painted;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _appear?.addListener(markNeedsPaint);
    _watch();
  }

  @override
  void detach() {
    _appear?.removeListener(markNeedsPaint);
    super.detach();
  }

  void _watch() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!attached) return;
      if (_painted != null && hasSize && getTransformTo(null) != _painted) markNeedsPaint();
      _watch();
    });
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final shader = _shader ??= LiquidGlassShader.program!.fragmentShader();
    final toScreen = getTransformTo(null);
    _painted = toScreen;
    final onScreen = MatrixUtils.transformRect(toScreen, Offset.zero & size);
    final scale = size.width > 0 ? onScreen.width / size.width : 1.0;
    final k = _dpr;
    final look = _look;
    final shown = (_appear?.value ?? 1).clamp(0.0, 1.0);
    // 0 and 1 are uSize, which the engine sets.
    shader
      ..setFloat(2, onScreen.left * k)
      ..setFloat(3, onScreen.top * k)
      ..setFloat(4, onScreen.width * k)
      ..setFloat(5, onScreen.height * k)
      ..setFloat(6, look.radius * scale * k)
      ..setFloat(7, look.edge * scale * k)
      ..setFloat(8, look.refract * scale * k)
      ..setFloat(9, look.tint)
      ..setFloat(10, look.shade)
      ..setFloat(11, look.saturation)
      ..setFloat(12, look.light)
      ..setFloat(13, shown);
    final filter = ui.ImageFilter.compose(
      outer: ui.ImageFilter.shader(shader),
      inner: ui.ImageFilter.blur(sigmaX: look.blur, sigmaY: look.blur, tileMode: TileMode.mirror),
    );
    final bounds = Offset.zero & size;
    _clip.layer = context.pushClipRRect(
      needsCompositing,
      offset,
      bounds,
      RRect.fromRectAndRadius(bounds, Radius.circular(look.radius)),
      (context, offset) {
        // The filter runs even while the pane is not shown yet (its output is
        // then clear): adding filters mid-animation makes the GPU's load jump,
        // and the frames until it clocks up and has its targets drop.
        final layer = _filter.layer ??= BackdropFilterLayer();
        layer.filter = filter;
        context.pushLayer(layer, super.paint, offset);
      },
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    _filter.layer = null;
    _shader?.dispose();
    super.dispose();
  }
}

class _BodyPainter extends CustomPainter {
  _BodyPainter({required this.radius, required this.tint, required this.dark});

  final double radius;
  final Color tint;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(shape, Paint()..color = tint);
    canvas.save();
    canvas.clipRRect(shape);
    final top = Rect.fromLTWH(0, 0, size.width, (size.height * 0.42).clamp(0, 120));
    canvas.drawRect(
      top,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withValues(alpha: dark ? 0.1 : 0.24), Colors.white.withValues(alpha: 0)],
        ).createShader(top),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BodyPainter old) => old.radius != radius || old.tint != tint || old.dark != dark;
}

class _RimPainter extends CustomPainter {
  _RimPainter({required this.radius, required this.dark});

  final double radius;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.6), Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: dark ? 0.5 : 0.9),
            Colors.white.withValues(alpha: dark ? 0.06 : 0.25),
            Colors.white.withValues(alpha: dark ? 0.2 : 0.6),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RimPainter old) => old.radius != radius || old.dark != dark;
}
