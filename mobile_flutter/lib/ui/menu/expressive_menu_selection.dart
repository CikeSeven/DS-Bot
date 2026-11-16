import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'expressive_motion.dart';
import 'expressive_menu_geometry.dart';
import 'expressive_menu_motion.dart';

/// A row registered in a panel: its render box, whether it can be tapped,
/// and what to do when tapped.
class ExpressiveMenuRowHandle {
  RenderBox? box;
  bool enabled = false;
  VoidCallback? activate;
}

/// Drag-to-select and the highlight pill of one panel (ported from
/// NexioSchedule's DropdownPanelDragSelect, the Sliding mask).
///
/// - Rows register through [ExpressiveMenuSelectionScope]; the panel's only
///   tap gesture lives here: on press the pill lights up on the row under
///   the finger; while held and sliding up or down, the pill slides smoothly
///   to the new row on a spring (damping ratio 0.85, stiffness 700), with one
///   light haptic per row change; on release the row under the finger runs.
///   Sliding off the rows fades the pill out and leaves it on the nearest
///   row, and release runs nothing.
/// - It does not take over before the panel has grown to 98% (taps during
///   the opening are ignored); when the content does not fit and needs to
///   scroll there is no drag-to-select: a finger move of more than 12dp
///   counts as scrolling and release runs nothing; only tap-to-select stays.
/// - Hover, keyboard focus and highlight set from outside use the same pill
///   (priority: held > set from outside > focused > hovered); the pill fades
///   in over 90ms and out over 220ms.
/// - Pressing also drives the panel's deformation [jelly].
/// - With reduced motion the pill jumps into place, with no deformation.
class ExpressiveMenuSelection extends ChangeNotifier {
  ExpressiveMenuSelection({required TickerProvider vsync})
    : maskTop = AnimationController.unbounded(vsync: vsync),
      maskBottom = AnimationController.unbounded(vsync: vsync),
      maskAlpha = AnimationController(vsync: vsync);

  static final SpringDescription maskSpring =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 700, ratio: 0.85);

  /// When the content does not fit, a finger move beyond this distance
  /// counts as scrolling.
  static const double scrollSlop = 12;

  final AnimationController maskTop;
  final AnimationController maskBottom;
  final AnimationController maskAlpha;

  /// Row positions are all relative to this box (the panel's scroll content,
  /// including the top and bottom padding). It must be the pill's canvas
  /// itself and share its origin with the gesture layer, or the pill and the
  /// rows drift apart.
  RenderBox? Function() contentBox = () => null;

  /// Whether the panel can take over taps yet (the menu has grown to 98% and
  /// is not covered by a submenu).
  bool Function() ready = () => true;

  /// Whether the content fits on one screen (no drag-to-select when it does
  /// not).
  bool Function() fits = () => true;

  /// Whether to reduce motion.
  bool Function() reduceMotion = () => false;

  /// The press deformation of this panel.
  ExpressiveMenuJelly? jelly;

  final List<ExpressiveMenuRowHandle> _rows = <ExpressiveMenuRowHandle>[];
  ExpressiveMenuRowHandle? _pressed;
  ExpressiveMenuRowHandle? _dragTarget;
  ExpressiveMenuRowHandle? _hovered;
  ExpressiveMenuRowHandle? _focused;
  ExpressiveMenuRowHandle? _highlighted;
  ExpressiveMenuRowHandle? _maskRow;
  int? _pointer;

  /// The pill's current goal (shown / hidden): press and release can land in
  /// the same frame, when the opacity has not yet left 0; looking only at the
  /// current value would miss the "hide", and the pill would stay lit after
  /// fading in.
  bool _maskShown = false;

  /// Where the pill's top and bottom edges are currently springing to. While
  /// the finger moves, every touch event runs [_updateMask], and the spring
  /// must not restart if the target has not changed: the first frame after a
  /// restart has zero elapsed time and does not move, so when touch events
  /// come faster than frames the pill would stay put until the finger stops.
  double? _maskTopTarget;
  double? _maskBottomTarget;
  Offset _down = Offset.zero;
  bool _scrolled = false;

  /// The row being held (for tests and debugging).
  ExpressiveMenuRowHandle? get pressed => _pressed;

  void register(ExpressiveMenuRowHandle row) {
    if (!_rows.contains(row)) _rows.add(row);
  }

  void unregister(ExpressiveMenuRowHandle row) {
    _rows.remove(row);
    var changed = false;
    if (identical(_pressed, row)) {
      _pressed = null;
      changed = true;
    }
    if (identical(_dragTarget, row)) _dragTarget = null;
    if (identical(_hovered, row)) _hovered = null;
    if (identical(_focused, row)) _focused = null;
    if (identical(_highlighted, row)) _highlighted = null;
    if (changed) _updateMask();
  }

  /// The vertical span of [row] in the content; null when it is not laid out
  /// yet or already unmounted.
  (double, double)? _span(ExpressiveMenuRowHandle row) {
    final box = row.box;
    final content = contentBox();
    if (box == null ||
        content == null ||
        !box.attached ||
        !content.attached ||
        !box.hasSize) {
      return null;
    }
    final top = MatrixUtils.transformPoint(
      box.getTransformTo(content),
      Offset.zero,
    ).dy;
    return (top, top + box.size.height);
  }

  ExpressiveMenuRowHandle? _rowAt(double y) {
    for (final row in _rows) {
      if (!row.enabled) continue;
      final span = _span(row);
      if (span != null && y >= span.$1 && y < span.$2) return row;
    }
    return null;
  }

  /// Not on any row: take the nearest row (past the bottom is the last item,
  /// past the top is the first).
  ExpressiveMenuRowHandle? _nearest(double y) {
    ExpressiveMenuRowHandle? best;
    var distance = double.infinity;
    for (final row in _rows) {
      if (!row.enabled) continue;
      final span = _span(row);
      if (span == null) continue;
      final d = ((span.$1 + span.$2) / 2 - y).abs();
      if (d < distance) {
        distance = d;
        best = row;
      }
    }
    return best;
  }

  static bool _isPrimary(PointerEvent event) =>
      event.kind != PointerDeviceKind.mouse ||
      event.buttons & kPrimaryMouseButton != 0;

  void handlePointerDown(PointerDownEvent event) {
    if (_pointer != null || !_isPrimary(event) || !ready()) return;
    _pointer = event.pointer;
    _down = event.localPosition;
    _scrolled = false;
    if (!reduceMotion()) jelly?.down();
    final hit = _rowAt(_down.dy);
    _pressed = hit;
    _dragTarget = hit ?? _nearest(_down.dy);
    _updateMask();
  }

  void handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final delta = event.localPosition - _down;
    if (!reduceMotion()) jelly?.move(delta);
    if (_scrolled) return;
    if (!fits()) {
      if (delta.dx.abs() > scrollSlop || delta.dy.abs() > scrollSlop) {
        _scrolled = true;
        _pressed = null;
        _updateMask();
      }
      return;
    }
    final hit = _rowAt(event.localPosition.dy);
    if (hit != null && !identical(hit, _pressed)) {
      HapticFeedback.selectionClick();
    }
    _pressed = hit;
    _dragTarget = hit ?? _nearest(event.localPosition.dy);
    _updateMask();
  }

  void handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final target = _scrolled ? null : _pressed;
    _endPointer();
    if (target != null && target.enabled) target.activate?.call();
  }

  void handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _endPointer();
  }

  void _endPointer() {
    _pointer = null;
    _pressed = null;
    _dragTarget = null;
    jelly?.up();
    _updateMask();
  }

  void setHovered(ExpressiveMenuRowHandle row, bool value) {
    if (value) {
      _hovered = row;
    } else if (identical(_hovered, row)) {
      _hovered = null;
    }
    _updateMask();
  }

  void setFocused(ExpressiveMenuRowHandle row, bool value) {
    if (value) {
      _focused = row;
    } else if (identical(_focused, row)) {
      _focused = null;
    }
    _updateMask();
  }

  void setHighlighted(ExpressiveMenuRowHandle row, bool value) {
    if (value) {
      _highlighted = row;
    } else if (identical(_highlighted, row)) {
      _highlighted = null;
    }
    _updateMask();
  }

  /// Works out which row the pill should be on now and whether it is
  /// visible, and starts the matching transition.
  void _updateMask() {
    final pointerDown = _pointer != null;
    final visibleRow = pointerDown
        ? _pressed
        : (_highlighted ?? _focused ?? _hovered);
    final geometryRow = pointerDown ? (_dragTarget ?? _maskRow) : visibleRow;
    final span = geometryRow == null ? null : _span(geometryRow);
    final reduced = reduceMotion();
    if (span != null) {
      _maskRow = geometryRow;
      // When not visible, jump into place (fade in from nothing instead of
      // sliding over from the last position).
      final jump = reduced || maskAlpha.value < 0.01;
      _maskTopTarget = _moveMask(maskTop, _maskTopTarget, span.$1, jump: jump);
      _maskBottomTarget = _moveMask(
        maskBottom,
        _maskBottomTarget,
        span.$2,
        jump: jump,
      );
    }
    final visible = visibleRow != null && span != null;
    final target = visible ? 1.0 : 0.0;
    final changed = visible != _maskShown;
    _maskShown = visible;
    if (reduced) {
      maskAlpha.value = target;
    } else if (changed) {
      maskAlpha.animateTo(
        target,
        duration: visible
            ? ExpressiveMotion.menuHighlightIn
            : ExpressiveMotion.menuHighlightOut,
        curve: ExpressiveMotion.menuHighlightCurve,
      );
    }
    notifyListeners();
  }

  /// Sends one edge of the pill to [target] and returns the new target.
  /// [current] is the target this edge is springing to: when they are the
  /// same, the running (or finished) spring carries on and is not restarted
  /// (see [_maskTopTarget]).
  double _moveMask(
    AnimationController c,
    double? current,
    double target, {
    required bool jump,
  }) {
    if (jump) {
      c.value = target;
    } else if (current != target) {
      c.animateWith(
        SpringSimulation(
          maskSpring,
          c.value,
          target,
          c.velocity,
          tolerance: const Tolerance(distance: 0.01, velocity: 0.1),
        ),
      );
    }
    return target;
  }

  @override
  void dispose() {
    maskTop.dispose();
    maskBottom.dispose();
    maskAlpha.dispose();
    super.dispose();
  }
}

/// Hands the panel's [ExpressiveMenuSelection] to its rows.
class ExpressiveMenuSelectionScope extends InheritedWidget {
  const ExpressiveMenuSelectionScope({
    super.key,
    required this.selection,
    required super.child,
  });

  final ExpressiveMenuSelection selection;

  static ExpressiveMenuSelection? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ExpressiveMenuSelectionScope>()
      ?.selection;

  @override
  bool updateShouldNotify(ExpressiveMenuSelectionScope oldWidget) =>
      !identical(selection, oldWidget.selection);
}

/// The highlight pill painted behind the rows: inset [inset] on the left and
/// right (matching the row's pill), a superellipse with radius 17,
/// `onSurface` at 6% in light / 10% in dark (NexioSchedule's hit mask
/// color).
class ExpressiveMenuMaskPainter extends CustomPainter {
  ExpressiveMenuMaskPainter({
    required this.selection,
    required this.color,
    required this.inset,
  }) : super(
         repaint: Listenable.merge(<Listenable>[
           selection.maskTop,
           selection.maskBottom,
           selection.maskAlpha,
         ]),
       );

  final ExpressiveMenuSelection selection;
  final Color color;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = selection.maskAlpha.value.clamp(0.0, 1.0);
    if (alpha <= 0) return;
    final rect = Rect.fromLTRB(
      inset,
      selection.maskTop.value,
      size.width - inset,
      selection.maskBottom.value,
    );
    if (rect.width <= 0 || rect.height <= 0) return;
    canvas.drawRSuperellipse(
      expressiveMenuShape(rect, kExpressiveMenuRowRadius),
      Paint()..color = color.withValues(alpha: color.a * alpha),
    );
  }

  @override
  bool shouldRepaint(ExpressiveMenuMaskPainter oldDelegate) =>
      !identical(selection, oldDelegate.selection) ||
      color != oldDelegate.color ||
      inset != oldDelegate.inset;
}
