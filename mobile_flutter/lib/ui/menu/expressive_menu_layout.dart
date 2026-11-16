import 'dart:math' as math;
import 'dart:ui' show ImageFilter, TileMode, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'expressive_menu_geometry.dart';
import 'expressive_menu_motion.dart';
import 'expressive_menu_row.dart';

export 'expressive_menu_geometry.dart'
    show ExpressiveMenuPlacement, ExpressiveMenuSide;

/// The area the menu may use: the safe area, minus system bars, the keyboard
/// and display features.
class ExpressiveMenuArea {
  const ExpressiveMenuArea({required this.bounds});

  final Rect bounds;

  static ExpressiveMenuArea of(
    BuildContext context,
    Size overlaySize,
    Rect near,
  ) {
    // System bars and the keyboard come from the view itself: a Scaffold body
    // or a bottom sheet clears the top padding in its local MediaQuery, and
    // using local values would let a menu flipped above slip into the status
    // bar.
    final view = MediaQueryData.fromView(View.of(context));
    final viewport = view.padding.deflateRect(
      view.viewInsets.deflateRect(Offset.zero & overlaySize),
    );
    // Each side of a display feature such as a foldable's hinge counts as one
    // screen; the menu goes only on the one closest to the anchor.
    final screens = DisplayFeatureSubScreen.subScreensInBounds(
      viewport,
      DisplayFeatureSubScreen.avoidBounds(view),
    );
    final screen = screens.isEmpty
        ? viewport
        : screens.reduce(
            (Rect a, Rect b) =>
                (a.center - near.center).distanceSquared <=
                    (b.center - near.center).distanceSquared
                ? a
                : b,
          );
    return ExpressiveMenuArea(bounds: screen);
  }
}

/// Places and morphs the main menu and the submenu (all in one render
/// object, so no frame grows from the wrong corner).
///
/// - Input: the anchor rect and the safe area (overlay coordinates). When
///   [cover] is true the panel covers the trigger control and grows out of
///   the seed [seed] ([placeCoveringMenu]); otherwise it sits [gap] away from
///   the anchor and grows out of a small circle on the corner that touches
///   the anchor ([placeOutsideMenu]). The motion is [motion]. While a submenu
///   is open there is also the trigger row's pill [submenuPill] (main menu
///   content coordinates, fixed when pressed).
/// - Children in order: main menu glass, main menu content, and (while a
///   submenu is open) submenu glass, submenu content. Content is laid out
///   once at its final size; glass is laid out at the panel (or the union of
///   the main menu and the submenu) grown by [overshootRoom], and clipped to
///   the panel's current shape.
/// - Painting (NexioSchedule's ListPopupContent): the panel rect comes from
///   [expressiveMenuMorphRect]. First the ring shadow, outside the panel
///   only; then the glass, clipped to a superellipse with radius 22; the
///   content is scaled uniformly by "rect width / panel width" to the rect's
///   center, fades in with contentAlpha and is blurred midway; last a thin
///   border along the shape. When an icon-button menu closes, the whole group
///   springs back along the closing direction. While a submenu is open the
///   main menu shrinks to 0.95 about the corner on the seed; the submenu
///   interpolates from the trigger row's pill (radius 16) to where it lands
///   (radius 22), and its content slides with it from the pill to that spot.
///   While held, the pressed panel gets the press deformation
///   ([ExpressiveMenuJelly]).
/// - Hit testing uses the same transforms as painting and only hits inside
///   the visible shape; a tap outside the shape passes through this box, and
///   the outer TapRegion treats it as a tap outside.
class ExpressiveMenuCascade extends MultiChildRenderObjectWidget {
  const ExpressiveMenuCascade({
    super.key,
    required this.anchor,
    required this.bounds,
    required this.cover,
    required this.placement,
    required this.textDirection,
    required this.motion,
    required this.shadowColor,
    required this.borderColor,
    required super.children,
    this.seed,
    this.gap = 0,
    this.submenuPill,
  }) : assert(children.length == 2 || children.length == 4),
       assert(!cover || seed != null);

  /// Extra room the glass has beyond the panel on each side, for spring
  /// overshoot and the anchor shift.
  static const double overshootRoom = 14;

  final Rect anchor;
  final Rect bounds;
  final bool cover;
  final Rect? seed;
  final double gap;
  final ExpressiveMenuPlacement placement;
  final TextDirection textDirection;
  final ExpressiveMenuMotion motion;

  /// Color of the shadow and border when fully shown.
  final Color shadowColor;
  final Color borderColor;
  final Rect? submenuPill;

  @override
  RenderExpressiveMenuCascade createRenderObject(BuildContext context) =>
      RenderExpressiveMenuCascade(
        anchor: anchor,
        bounds: bounds,
        cover: cover,
        seed: seed,
        gap: gap,
        placement: placement,
        textDirection: textDirection,
        motion: motion,
        shadowColor: shadowColor,
        borderColor: borderColor,
        submenuPill: submenuPill,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderExpressiveMenuCascade renderObject,
  ) {
    renderObject
      ..anchor = anchor
      ..bounds = bounds
      ..cover = cover
      ..seed = seed
      ..gap = gap
      ..placement = placement
      ..textDirection = textDirection
      ..motion = motion
      ..shadowColor = shadowColor
      ..borderColor = borderColor
      ..submenuPill = submenuPill;
  }
}

class _CascadeParentData extends ContainerBoxParentData<RenderBox> {}

/// One panel's paint parameters for this frame (overlay coordinates).
class _PanelFrame {
  const _PanelFrame({
    required this.transform,
    required this.shape,
    required this.surfaceOffset,
    required this.contentTransform,
    required this.shadowOpacity,
  });

  /// Transform of the whole panel (shadow, glass, content, border).
  final Matrix4 transform;

  /// The current shape (inside [transform]).
  final RSuperellipse shape;
  final Offset surfaceOffset;

  /// Transform of the content from its layout position to its current
  /// position (inside [transform], including the layout offset).
  final Matrix4 contentTransform;
  final double shadowOpacity;
}

class RenderExpressiveMenuCascade extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _CascadeParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _CascadeParentData> {
  RenderExpressiveMenuCascade({
    required this._anchor,
    required this._bounds,
    required this._cover,
    required this._seed,
    required this._gap,
    required this._placement,
    required this._textDirection,
    required this._motion,
    required this._shadowColor,
    required this._borderColor,
    required this._submenuPill,
  });

  /// Minimum panel height (miuix's MinPopupHeight).
  static const double minPanelHeight = 50;

  /// Ring shadow: spread 2, blur radius 12 (NexioSchedule's
  /// popupPanelShadow).
  static const double shadowSpread = 2;
  static const double shadowBlur = 12;

  Rect _anchor;
  set anchor(Rect value) {
    if (value == _anchor) return;
    _anchor = value;
    markNeedsLayout();
  }

  Rect _bounds;
  set bounds(Rect value) {
    if (value == _bounds) return;
    _bounds = value;
    markNeedsLayout();
  }

  bool _cover;
  set cover(bool value) {
    if (value == _cover) return;
    _cover = value;
    markNeedsLayout();
  }

  Rect? _seed;
  set seed(Rect? value) {
    if (value == _seed) return;
    _seed = value;
    markNeedsLayout();
  }

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  ExpressiveMenuPlacement _placement;
  set placement(ExpressiveMenuPlacement value) {
    if (value == _placement) return;
    _placement = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  ExpressiveMenuMotion _motion;
  set motion(ExpressiveMenuMotion value) {
    if (value == _motion) return;
    if (attached) _motion.removeListener(markNeedsPaint);
    _motion = value;
    if (attached) _motion.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Color _shadowColor;
  set shadowColor(Color value) {
    if (value == _shadowColor) return;
    _shadowColor = value;
    markNeedsPaint();
  }

  Color _borderColor;
  set borderColor(Color value) {
    if (value == _borderColor) return;
    _borderColor = value;
    markNeedsPaint();
  }

  Rect? _submenuPill;
  set submenuPill(Rect? value) {
    if (value == _submenuPill) return;
    _submenuPill = value;
    markNeedsLayout();
  }

  /// Where the main menu landed in this layout; for tests and debugging.
  ExpressiveMenuPlacementResult? get primaryPlacement => _primary;
  ExpressiveMenuPlacementResult? _primary;

  /// The fully open submenu rect and the trigger row's pill (overlay
  /// coordinates); null when there is no submenu.
  Rect? get submenuRect => _submenuRect;
  Rect? _submenuRect;
  Rect? get submenuPillRect => _pillRect;
  Rect? _pillRect;
  Rect _union = Rect.zero;

  final LayerHandle<TransformLayer> _primaryLayer =
      LayerHandle<TransformLayer>();
  final LayerHandle<ClipRSuperellipseLayer> _primaryClip =
      LayerHandle<ClipRSuperellipseLayer>();
  final LayerHandle<OpacityLayer> _primaryOpacity = LayerHandle<OpacityLayer>();
  final LayerHandle<ImageFilterLayer> _primaryBlur =
      LayerHandle<ImageFilterLayer>();
  final LayerHandle<TransformLayer> _primaryContent =
      LayerHandle<TransformLayer>();
  final LayerHandle<TransformLayer> _secondaryLayer =
      LayerHandle<TransformLayer>();
  final LayerHandle<ClipRSuperellipseLayer> _secondaryClip =
      LayerHandle<ClipRSuperellipseLayer>();
  final LayerHandle<OpacityLayer> _secondaryOpacity =
      LayerHandle<OpacityLayer>();
  final LayerHandle<ImageFilterLayer> _secondaryBlur =
      LayerHandle<ImageFilterLayer>();
  final LayerHandle<TransformLayer> _secondaryContent =
      LayerHandle<TransformLayer>();

  List<RenderBox> get _children => getChildrenAsList();

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _CascadeParentData) {
      child.parentData = _CascadeParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _motion.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _motion.removeListener(markNeedsPaint);
    super.detach();
  }

  void _clearLayers() {
    for (final handle in <LayerHandle<Layer>>[
      _primaryLayer,
      _primaryClip,
      _primaryOpacity,
      _primaryBlur,
      _primaryContent,
      _secondaryLayer,
      _secondaryClip,
      _secondaryOpacity,
      _secondaryBlur,
      _secondaryContent,
    ]) {
      handle.layer = null;
    }
  }

  @override
  void dispose() {
    _clearLayers();
    super.dispose();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    size = constraints.biggest;
    final children = _children;
    if (children.length < 2) {
      _primary = null;
      _submenuRect = null;
      return;
    }
    final room = ExpressiveMenuCascade.overshootRoom;
    final verticalReserve = _cover ? 0.0 : 2 * _gap;
    final horizontalReserve = _cover ? 0.0 : 2 * kExpressiveMenuScreenMargin;
    final maxHeight = math.max(
      minPanelHeight,
      _bounds.height - verticalReserve,
    );
    final maxWidth = math.max(0.0, _bounds.width - horizontalReserve);
    final content = children[1];
    content.layout(
      BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      parentUsesSize: true,
    );
    final placed = _cover
        ? placeCoveringMenu(
            seed: _seed!,
            size: content.size,
            bounds: _bounds,
            placement: _placement,
            textDirection: _textDirection,
          )
        : placeOutsideMenu(
            anchor: _anchor,
            size: content.size,
            bounds: _bounds,
            placement: _placement,
            textDirection: _textDirection,
            gap: _gap,
          );
    _primary = placed;
    children[0].layout(
      BoxConstraints.tight(placed.rect.size + Offset(room * 2, room * 2)),
    );

    final pill = _submenuPill;
    if (children.length < 4 || pill == null) {
      _submenuRect = null;
      _pillRect = null;
      _union = placed.rect;
      return;
    }
    final secondary = children[3];
    secondary.layout(
      BoxConstraints(
        minWidth: math.min(content.size.width, maxWidth),
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ),
      parentUsesSize: true,
    );
    final pillRect = pill.shift(placed.rect.topLeft);
    _pillRect = pillRect;
    final submenu = placeExpressiveSubmenu(
      pill: pillRect,
      size: secondary.size,
      bounds: _bounds,
      textDirection: _textDirection,
      inset: ExpressiveMenuRowMetrics.inset,
    );
    _submenuRect = submenu;
    _union = placed.rect.expandToInclude(submenu);
    children[2].layout(
      BoxConstraints.tight(_union.size + Offset(room * 2, room * 2)),
    );
  }

  /// Scales by [scale] about [pivot].
  static Matrix4 _scaleAbout(Offset pivot, double scale) =>
      Matrix4.diagonal3Values(scale, scale, 1)
        ..setTranslationRaw(pivot.dx * (1 - scale), pivot.dy * (1 - scale), 0);

  /// Moves [local] (a transform with the top-left of [rect] as origin, at the
  /// size of [rect]) onto [rect].
  static Matrix4 _at(Rect rect, Matrix4 local) =>
      Matrix4.translationValues(rect.left, rect.top, 0)
        ..multiply(local)
        ..multiply(Matrix4.translationValues(-rect.left, -rect.top, 0));

  /// Spring-back offset when an icon-button menu closes: along the closing
  /// direction (toward the corner on the seed).
  Offset _settleOffset(ExpressiveMenuPlacementResult placed) {
    final b = _motion.settlePulse * ExpressiveMenuMotion.settleDistance;
    if (b == 0) return Offset.zero;
    return Offset(
      placed.alignRight ? b : -b,
      placed.side == ExpressiveMenuSide.above ? b : -b,
    );
  }

  /// The current main menu rect (overlay coordinates).
  Rect _primaryRect(ExpressiveMenuPlacementResult placed) {
    final natural = placed.rect;
    return expressiveMenuMorphRect(
      size: natural.size,
      seed: placed.seed.shift(-natural.topLeft),
      fraction: _motion.fraction.value,
      origin: _motion.origin.value,
      side: placed.side,
      alignRight: placed.alignRight,
    ).shift(natural.topLeft);
  }

  /// Panel layout rect → current rect: scales uniformly by the width ratio
  /// to the center of the current rect.
  static Matrix4 _morphTransform(Rect natural, Rect current) {
    final s = natural.width > 0 ? current.width / natural.width : 1.0;
    return Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(
      current.center.dx - s * natural.center.dx,
      current.center.dy - s * natural.center.dy,
      0,
    );
  }

  _PanelFrame? _primaryFrame() {
    final placed = _primary;
    if (placed == null) return null;
    final room = ExpressiveMenuCascade.overshootRoom;
    final rect = _primaryRect(placed);
    final group = Matrix4.translationValues(
      _settleOffset(placed).dx,
      _settleOffset(placed).dy,
      0,
    )..multiply(_scaleAbout(placed.pivot, _motion.primaryScale));
    final jelly = _motion.primaryJelly.transformFor(
      rect.size,
      _motion.fraction.value,
    );
    return _PanelFrame(
      transform: group..multiply(_at(rect, jelly)),
      shape: expressiveMenuShape(rect, kExpressiveMenuRadius),
      surfaceOffset: placed.rect.topLeft - const Offset(1, 1) * room,
      contentTransform: _morphTransform(placed.rect, rect)
        ..multiply(
          Matrix4.translationValues(placed.rect.left, placed.rect.top, 0),
        ),
      shadowOpacity: _motion.containerAlpha,
    );
  }

  _PanelFrame? _secondaryFrame() {
    final placed = _primary;
    final submenu = _submenuRect;
    final pill = _pillRect;
    if (placed == null || submenu == null || pill == null) return null;
    final room = ExpressiveMenuCascade.overshootRoom;
    final e = _motion.expand.value;
    final rect = lerpExpressiveRect(pill, submenu, e);
    const inset = ExpressiveMenuRowMetrics.inset;
    final contentOffset = Offset.lerp(
      pill.topLeft - const Offset(inset, inset),
      submenu.topLeft,
      e,
    )!;
    final settle = _settleOffset(placed);
    final group = Matrix4.translationValues(settle.dx, settle.dy, 0)
      ..multiply(_morphTransform(placed.rect, _primaryRect(placed)));
    final jelly = _motion.secondaryJelly.transformFor(
      rect.size,
      _motion.fraction.value,
    );
    return _PanelFrame(
      transform: group..multiply(_at(rect, jelly)),
      shape: expressiveMenuShape(
        rect,
        lerpDouble(kExpressiveMenuRowRadius, kExpressiveMenuRadius, e)!,
      ),
      surfaceOffset: _union.topLeft - const Offset(1, 1) * room,
      contentTransform: Matrix4.translationValues(
        contentOffset.dx,
        contentOffset.dy,
        0,
      ),
      shadowOpacity: _motion.containerAlpha * e.clamp(0.0, 1.0),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final children = _children;
    final primary = _primaryFrame();
    final containerAlpha = _motion.containerAlpha;
    final contentAlpha = _motion.contentAlpha;
    if (primary == null ||
        children.length < 2 ||
        (containerAlpha <= 0 && contentAlpha <= 0)) {
      _clearLayers();
      return;
    }
    _paintPanel(
      context,
      offset,
      primary,
      surface: children[0],
      content: children[1],
      layer: _primaryLayer,
      clip: _primaryClip,
      opacity: _primaryOpacity,
      blur: _primaryBlur,
      contentLayer: _primaryContent,
    );
    final secondary = _secondaryFrame();
    if (secondary == null || children.length < 4) {
      _secondaryLayer.layer = null;
      _secondaryClip.layer = null;
      _secondaryOpacity.layer = null;
      _secondaryBlur.layer = null;
      _secondaryContent.layer = null;
      return;
    }
    _paintPanel(
      context,
      offset,
      secondary,
      surface: children[2],
      content: children[3],
      layer: _secondaryLayer,
      clip: _secondaryClip,
      opacity: _secondaryOpacity,
      blur: _secondaryBlur,
      contentLayer: _secondaryContent,
    );
  }

  void _paintPanel(
    PaintingContext context,
    Offset offset,
    _PanelFrame frame, {
    required RenderBox surface,
    required RenderBox content,
    required LayerHandle<TransformLayer> layer,
    required LayerHandle<ClipRSuperellipseLayer> clip,
    required LayerHandle<OpacityLayer> opacity,
    required LayerHandle<ImageFilterLayer> blur,
    required LayerHandle<TransformLayer> contentLayer,
  }) {
    final contentAlpha = _motion.contentAlpha;
    final sigma = _motion.contentBlurSigma;
    layer.layer = context.pushTransform(
      needsCompositing,
      offset,
      frame.transform,
      (PaintingContext context, Offset offset) {
        final shape = frame.shape;
        if (shape.width <= 0 || shape.height <= 0) {
          clip.layer = null;
          return;
        }
        _paintShadow(context.canvas, shape.shift(offset), frame.shadowOpacity);
        clip.layer = context.pushClipRSuperellipse(
          needsCompositing,
          offset,
          shape.outerRect,
          shape,
          (PaintingContext context, Offset offset) {
            context.paintChild(surface, offset + frame.surfaceOffset);
            if (contentAlpha <= 0) {
              opacity.layer = null;
              blur.layer = null;
              contentLayer.layer = null;
              return;
            }
            void paintContent(PaintingContext context, Offset offset) {
              contentLayer.layer = context.pushTransform(
                needsCompositing,
                offset,
                frame.contentTransform,
                (PaintingContext context, Offset offset) =>
                    context.paintChild(content, offset),
                oldLayer: contentLayer.layer,
              );
            }

            void paintBlurred(PaintingContext context, Offset offset) {
              if (sigma < 0.05) {
                blur.layer = null;
                paintContent(context, offset);
                return;
              }
              final layer = blur.layer ?? ImageFilterLayer();
              layer.imageFilter = ImageFilter.blur(
                sigmaX: sigma,
                sigmaY: sigma,
                tileMode: TileMode.decal,
              );
              blur.layer = layer;
              context.pushLayer(layer, paintContent, offset);
            }

            if (contentAlpha >= 1) {
              opacity.layer = null;
              paintBlurred(context, offset);
            } else {
              opacity.layer = context.pushOpacity(
                offset,
                (contentAlpha * 255).round(),
                paintBlurred,
                oldLayer: opacity.layer,
              );
            }
          },
          oldLayer: clip.layer,
        );
        _paintBorder(context.canvas, shape.shift(offset), frame.shadowOpacity);
      },
      oldLayer: layer.layer,
    );
  }

  /// Ring shadow: the outer ring (grown by [shadowSpread]) minus the panel
  /// itself, then blurred as a whole.
  void _paintShadow(Canvas canvas, RSuperellipse shape, double opacity) {
    final s = opacity.clamp(0.0, 1.0);
    final color = _shadowColor.withValues(alpha: _shadowColor.a * s);
    if (color.a <= 0.002) return;
    final spread = shadowSpread * s;
    final radius = shape.tlRadiusX;
    final ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addRSuperellipse(
        RSuperellipse.fromRectAndRadius(
          shape.outerRect.inflate(spread),
          Radius.circular(radius + spread),
        ),
      )
      ..addRSuperellipse(shape);
    canvas.drawPath(
      ring,
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          Shadow.convertRadiusToSigma(math.max(0.1, shadowBlur * s)),
        ),
    );
  }

  /// A thin 1dp border along the inside of the shape.
  void _paintBorder(Canvas canvas, RSuperellipse shape, double opacity) {
    final color = _borderColor.withValues(alpha: _borderColor.a * opacity);
    if (color.a == 0 || shape.width <= 1 || shape.height <= 1) return;
    canvas.drawRSuperellipse(
      shape.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final children = _children;
    if (children.length >= 4) {
      final secondary = _secondaryFrame();
      if (secondary != null &&
          _hitPanel(result, position, secondary, children[3])) {
        return true;
      }
    }
    final primary = _primaryFrame();
    if (primary == null || children.length < 2) return false;
    return _hitPanel(result, position, primary, children[1]);
  }

  bool _hitPanel(
    BoxHitTestResult result,
    Offset position,
    _PanelFrame frame,
    RenderBox content,
  ) => result.addWithPaintTransform(
    transform: frame.transform,
    position: position,
    hitTest: (BoxHitTestResult result, Offset position) {
      if (!frame.shape.contains(position)) return false;
      return result.addWithPaintTransform(
        transform: frame.contentTransform,
        position: position,
        hitTest: (BoxHitTestResult result, Offset position) =>
            content.hitTest(result, position: position),
      );
    },
  );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final children = _children;
    final index = children.indexOf(child);
    final frame = index < 2 ? _primaryFrame() : _secondaryFrame();
    if (frame == null) return;
    transform.multiply(frame.transform);
    if (index.isOdd) {
      transform.multiply(frame.contentTransform);
    } else {
      transform.multiply(
        Matrix4.translationValues(
          frame.surfaceOffset.dx,
          frame.surfaceOffset.dy,
          0,
        ),
      );
    }
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) {
    final children = _children;
    final index = children.indexOf(child as RenderBox);
    final frame = index < 2 ? _primaryFrame() : _secondaryFrame();
    if (frame == null) return null;
    // Clip bounds in this box's coordinates; the semantics tree maps them to
    // the children through applyPaintTransform.
    return MatrixUtils.transformRect(frame.transform, frame.shape.outerRect);
  }
}
