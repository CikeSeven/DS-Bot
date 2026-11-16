import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import 'expressive_motion.dart';

/// Which kind of trigger control the menu grows out of; decides the opacity
/// timing (both ported from NexioSchedule).
enum ExpressiveMenuMorphStyle {
  /// Icon button (LiquidGlassDropdownMenu): the glass is in at f × 5, the
  /// content fades in over f 0.3–0.7, and the button icon fades out before f
  /// reaches 0.4; closing has one spring-back.
  button,

  /// Text triggers, cards and right-click menus (ListPopup): opening uses
  /// glass f × 7 and content 0.22–0.62, closing uses glass f × 3.6 and
  /// content 0.30–0.78 (fade in early on entry, fade out late on exit); the
  /// trigger control fades out at f × 3.2 when opening and f × 1.7 when
  /// closing; no spring-back.
  dropdown,
}

/// All motion progress of the pop-up menu (ported from NexioSchedule's
/// container transform, with its parameters copied value for value); the
/// anchor holds it and the overlay reads it every frame.
///
/// The menu itself ([open] / [close]):
/// - [fraction]: size, growing from the trigger control into the panel
///   (width and height interpolate separately, not clamped to 0…1, so
///   overshoot is kept). Opening is an underdamped spring (damping ratio
///   0.77, stiffness 220, about 2% spring-back at the end); closing is a
///   stiffer spring (0.85, 650).
/// - [origin]: the anchor shift, which reaches 1 sooner than the size (0.77,
///   420): the panel first moves from the trigger control's corner toward its
///   own center, then grows. Closing uses a 340ms Cubic(0, 0, 0, 1), and the
///   close ends when it finishes.
/// - [settle]: an underdamped spring (0.52, 220) that only the icon button
///   ([ExpressiveMenuMorphStyle.button]) has when closing; the part past 0
///   ([settlePulse]) makes the glass overshoot along the closing direction by
///   up to 12dp and spring back.
///
/// Submenu ([expandSecondary] / [collapseSecondary], following miuix's
/// cascade):
/// - [expand]: the trigger row's pill grows into the new panel while the
///   main menu shrinks to 0.95 and gets a scrim, all on one spring:
///   folme(0.95, 0.3) to expand, folme(0.95, 0.2) to collapse; once the
///   collapse settles, [onSecondaryCollapsed] tells the anchor to remove the
///   submenu.
/// - [arrow]: the turn of the title row's › (0 → 1 is 0° → ∓90°),
///   folme(0.95, 0.2 / 0.3).
///
/// For the press deformation ([primaryJelly] / [secondaryJelly]) see
/// [ExpressiveMenuJelly].
///
/// Every progress continues from its current value and velocity. The status
/// ([status]) means the same as an AnimationController's and is reported to
/// the anchor through [onStatusChanged]. With reduced motion, [snapOpen] /
/// [snapClosed] jump straight to the end.
class ExpressiveMenuMotion extends ChangeNotifier {
  ExpressiveMenuMotion({
    required TickerProvider vsync,
    required this.onStatusChanged,
    this.onSecondaryCollapsed,
  }) : fraction = AnimationController.unbounded(vsync: vsync),
       origin = AnimationController.unbounded(vsync: vsync),
       settle = AnimationController.unbounded(vsync: vsync),
       expand = AnimationController.unbounded(vsync: vsync),
       arrow = AnimationController.unbounded(vsync: vsync),
       primaryJelly = ExpressiveMenuJelly(vsync: vsync),
       secondaryJelly = ExpressiveMenuJelly(vsync: vsync) {
    for (final listenable in <Listenable>[
      fraction,
      origin,
      settle,
      expand,
      arrow,
      primaryJelly,
      secondaryJelly,
    ]) {
      listenable.addListener(notifyListeners);
    }
  }

  /// miuix's folmeSpring: describes a spring by damping ratio and "response
  /// time" (seconds); stiffness = (2π / response)², mass 1.
  static SpringDescription folmeSpring(double damping, double response) {
    final omega = 2 * math.pi / response;
    return SpringDescription.withDampingRatio(
      mass: 1,
      stiffness: omega * omega,
      ratio: damping,
    );
  }

  static final SpringDescription openSpring =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 220, ratio: 0.77);
  static final SpringDescription openOriginSpring =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 420, ratio: 0.77);
  static final SpringDescription closeSpring =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 650, ratio: 0.85);
  static final SpringDescription settleSpring =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 220, ratio: 0.52);

  /// Submenu expand: miuix's original folme(0.99, 0.45) is slow on a real
  /// device (about 0.47s to settle); sped up to 0.3 (about 0.32s) after user
  /// feedback, with slightly lower damping to keep a little bounce.
  static final SpringDescription expandSpring = folmeSpring(0.95, 0.3);
  static final SpringDescription collapseSpring = folmeSpring(0.95, 0.2);
  static final SpringDescription arrowExpandSpring = folmeSpring(0.95, 0.2);
  static final SpringDescription arrowCollapseSpring = folmeSpring(0.95, 0.3);

  /// Scale the main menu shrinks to while a submenu is open.
  static const double primaryShrunkScale = 0.95;

  /// Maximum offset of the closing spring-back.
  static const double settleDistance = 12;

  /// Content blur sigma at its blurriest, midway through the morph
  /// (converted from NexioSchedule's 6dp blur radius).
  static const double maxContentBlurSigma = 3.6;

  /// The menu takes over drag-to-select only after opening this far
  /// (NexioSchedule's DragSelectReadyFraction).
  static const double dragSelectReady = 0.98;

  static const Tolerance _tolerance = Tolerance(distance: 1e-4, velocity: 1e-3);

  final ValueChanged<AnimationStatus> onStatusChanged;

  /// Called when the submenu's collapse spring settles (not when a new
  /// expand interrupts it).
  final VoidCallback? onSecondaryCollapsed;

  final AnimationController fraction;
  final AnimationController origin;
  final AnimationController settle;
  final AnimationController expand;
  final AnimationController arrow;
  final ExpressiveMenuJelly primaryJelly;
  final ExpressiveMenuJelly secondaryJelly;

  /// Opacity timing for this opening.
  ExpressiveMenuMorphStyle style = ExpressiveMenuMorphStyle.dropdown;

  AnimationStatus get status => _status;
  AnimationStatus _status = AnimationStatus.dismissed;

  /// Opening or open (NexioSchedule's isEntering: entry and exit use
  /// different opacity timing).
  bool get entering => _status.isForwardOrCompleted;

  /// Whether the submenu is currently headed for expanded.
  bool get secondaryExpanded => _secondaryExpanded;
  bool _secondaryExpanded = false;

  /// Extra scale of the main menu while a submenu is open.
  double get primaryScale => 1 + (primaryShrunkScale - 1) * expand.value;

  /// How far the closing spring-back passes the end (0 to about 0.15).
  double get settlePulse => math.max(0, -settle.value);

  /// Whether drag-to-select can take over (the panel has grown to 98%).
  bool get dragSelectReadyNow => entering && fraction.value >= dragSelectReady;

  /// How much of the glass (base color, blur, shadow, border) shows.
  double get containerAlpha {
    final f = fraction.value;
    final gain = switch (style) {
      ExpressiveMenuMorphStyle.button => 5.0,
      ExpressiveMenuMorphStyle.dropdown => entering ? 7.0 : 3.6,
    };
    return (f * gain).clamp(0.0, 1.0);
  }

  /// The content's visible window.
  double get contentAlpha {
    final f = fraction.value;
    final (from, to) = switch (style) {
      ExpressiveMenuMorphStyle.button => (0.3, 0.7),
      ExpressiveMenuMorphStyle.dropdown =>
        entering ? (0.22, 0.62) : (0.3, 0.78),
    };
    return ((f - from) / (to - from)).clamp(0.0, 1.0);
  }

  /// Content blur: sharp → blurriest midway → sharp.
  double get contentBlurSigma =>
      maxContentBlurSigma *
      (1 - (2 * fraction.value - 1).abs()).clamp(0.0, 1.0);

  /// Opacity of the trigger control itself: fades out while the panel grows
  /// over it, and fades back in early while the panel shrinks back.
  late final Animation<double> triggerOpacity = _MotionValue(fraction, () {
    final k = switch (style) {
      ExpressiveMenuMorphStyle.button => entering ? 2.5 : 1.7,
      ExpressiveMenuMorphStyle.dropdown => entering ? 3.2 : 1.7,
    };
    return 1 - (fraction.value * k).clamp(0.0, 1.0);
  });

  bool get isAnimating =>
      fraction.isAnimating ||
      origin.isAnimating ||
      settle.isAnimating ||
      expand.isAnimating ||
      arrow.isAnimating;

  void _setStatus(AnimationStatus value) {
    if (value == _status) return;
    _status = value;
    onStatusChanged(value);
  }

  TickerFuture _spring(
    AnimationController controller,
    SpringDescription spring,
    double target,
  ) => controller.animateWith(
    SpringSimulation(
      spring,
      controller.value,
      target,
      controller.velocity,
      tolerance: _tolerance,
    ),
  );

  /// Opens (when called mid-close, continues from the current progress and
  /// velocity).
  void open() {
    _setStatus(AnimationStatus.forward);
    // Reset the spring-back to zero (at value 1 the part past the end is 0);
    // this also stops the closing spring-back.
    settle.value = 1;
    _spring(origin, openOriginSpring, 1);
    _spring(fraction, openSpring, 1).then((_) {
      if (_status != AnimationStatus.forward) return;
      // The spring stops within tolerance, not exactly at 1: snap to the end
      // so the panel no longer needs a transform layer.
      fraction.value = 1;
      origin.value = 1;
      _setStatus(AnimationStatus.completed);
    });
  }

  /// Moves to a new position (a right-click menu opened at another point):
  /// grows out of the trigger control again.
  void restart() {
    fraction.value = 0;
    origin.value = 0;
    open();
  }

  /// Closes: the submenu collapses back into its trigger row at the same
  /// time; the close ends when the anchor-shift tween finishes (as in the
  /// reference implementation; by then the size spring is already near 0).
  void close() {
    _setStatus(AnimationStatus.reverse);
    if (_secondaryExpanded || expand.value != 0) collapseSecondary();
    if (style == ExpressiveMenuMorphStyle.button) {
      settle.value = 1;
      _spring(settle, settleSpring, 0);
    }
    _spring(fraction, closeSpring, 0);
    origin
        .animateTo(
          0,
          duration: ExpressiveMotion.menuMorphExit,
          curve: ExpressiveMotion.menuMorphExitCurve,
        )
        .then((_) {
          if (_status != AnimationStatus.reverse) return;
          _snapAll(0);
          _setStatus(AnimationStatus.dismissed);
        });
  }

  /// Reduced motion: open / close instantly.
  void snapOpen() {
    fraction.value = 1;
    origin.value = 1;
    settle.value = 1;
    _setStatus(AnimationStatus.completed);
  }

  void snapClosed() {
    _snapAll(0);
    _setStatus(AnimationStatus.dismissed);
  }

  void _snapAll(double value) {
    fraction.value = value;
    origin.value = value;
    // Open is 1 (the part past the end is 0), closed is 0: neither has a
    // spring-back.
    settle.value = value;
    if (value == 0) {
      _secondaryExpanded = false;
      expand.value = 0;
      arrow.value = 0;
      primaryJelly.reset();
      secondaryJelly.reset();
    }
  }

  /// Expands the submenu (it grows out of the trigger row's pill).
  void expandSecondary({required bool reduced}) {
    _secondaryExpanded = true;
    if (reduced) {
      expand.value = 1;
      arrow.value = 1;
      return;
    }
    _spring(expand, expandSpring, 1);
    _spring(arrow, arrowExpandSpring, 1);
  }

  /// Collapses the submenu; once it settles, [onSecondaryCollapsed] removes
  /// it.
  void collapseSecondary({bool reduced = false}) {
    _secondaryExpanded = false;
    secondaryJelly.reset();
    if (reduced) {
      expand.value = 0;
      arrow.value = 0;
      onSecondaryCollapsed?.call();
      return;
    }
    _spring(arrow, arrowCollapseSpring, 0);
    _spring(expand, collapseSpring, 0).then((_) {
      if (_secondaryExpanded) return;
      expand.value = 0;
      onSecondaryCollapsed?.call();
    });
  }

  /// Switches to reduced motion while the menu is open: running progress
  /// jumps straight to its end.
  void settleNow() {
    if (_status == AnimationStatus.forward) {
      snapOpen();
    } else if (_status == AnimationStatus.reverse) {
      snapClosed();
    }
    if (expand.isAnimating || arrow.isAnimating) {
      if (_secondaryExpanded) {
        expandSecondary(reduced: true);
      } else {
        collapseSecondary(reduced: true);
      }
    }
  }

  @override
  void dispose() {
    fraction.dispose();
    origin.dispose();
    settle.dispose();
    expand.dispose();
    arrow.dispose();
    primaryJelly.dispose();
    secondaryJelly.dispose();
    super.dispose();
  }
}

/// Press deformation of a panel (NexioSchedule's InteractiveHighlight +
/// computeDragTransform, glass-tier parameters): when pressed the panel grows
/// by 2dp; when dragged it stretches slightly along the drag direction
/// (factor 0.012) and follows the finger with a tanh-damped offset (factor
/// 0.032); on release, both the press and the offset return on a spring
/// (damping ratio 0.5, stiffness 300). No deformation with reduced motion.
class ExpressiveMenuJelly extends ChangeNotifier {
  ExpressiveMenuJelly({required TickerProvider vsync})
    : press = AnimationController.unbounded(vsync: vsync),
      dx = AnimationController.unbounded(vsync: vsync),
      dy = AnimationController.unbounded(vsync: vsync) {
    press.addListener(notifyListeners);
    dx.addListener(notifyListeners);
    dy.addListener(notifyListeners);
  }

  static final SpringDescription spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 300,
    ratio: 0.5,
  );
  static const double pressGrow = 2;
  static const double stretchRatio = 0.012;
  static const double translationDamping = 0.032;
  static const double verticalRefScale = 0.6;
  static const double aspectPenaltyFloor = 0.97;
  static const Tolerance _tolerance = Tolerance(distance: 1e-3, velocity: 1e-2);

  final AnimationController press;
  final AnimationController dx;
  final AnimationController dy;

  Offset get offset => Offset(dx.value, dy.value);

  void _springTo(AnimationController c, double target) => c.animateWith(
    SpringSimulation(
      spring,
      c.value,
      target,
      c.velocity,
      tolerance: _tolerance,
    ),
  );

  void down() {
    dx.value = 0;
    dy.value = 0;
    _springTo(press, 1);
  }

  void move(Offset delta) {
    dx.value = delta.dx;
    dy.value = delta.dy;
  }

  void up() {
    _springTo(press, 0);
    _springTo(dx, 0);
    _springTo(dy, 0);
  }

  void reset() {
    press.value = 0;
    dx.value = 0;
    dy.value = 0;
  }

  /// The current deformation of the panel ([size]): scale and offset about
  /// its center. The larger [fraction], the smaller the reference size for
  /// vertical stretch (once grown into a panel it stretches vertically more
  /// easily).
  Matrix4 transformFor(Size size, double fraction) {
    final p = press.value;
    final o = offset;
    if (p == 0 && o == Offset.zero) return Matrix4.identity();
    final width = size.width;
    final height = math.max(1.0, size.height);
    final minDim = math.max(1.0, math.min(width, height));
    final pressScale = 1 + pressGrow / height * math.max(0, p);
    final refY =
        minDim * (1 - (1 - verticalRefScale) * fraction.clamp(0.0, 1.0));
    final penaltyX = math.min(width / height, aspectPenaltyFloor);
    final penaltyY = math.min(
      height / math.max(1.0, width),
      aspectPenaltyFloor,
    );
    final angle = math.atan2(o.dy, o.dx);
    final sx =
        pressScale +
        stretchRatio * (math.cos(angle) * o.dx / minDim).abs() * penaltyX;
    final sy =
        pressScale +
        stretchRatio * (math.sin(angle) * o.dy / refY).abs() * penaltyY;
    final tx = minDim * _tanh(translationDamping * o.dx / minDim);
    final ty = minDim * _tanh(translationDamping * o.dy / minDim);
    final cx = width / 2;
    final cy = height / 2;
    return Matrix4.diagonal3Values(sx, sy, 1)
      ..setTranslationRaw(cx * (1 - sx) + tx, cy * (1 - sy) + ty, 0);
  }

  static double _tanh(double x) {
    final e = math.exp(2 * x.clamp(-20.0, 20.0));
    return (e - 1) / (e + 1);
  }

  @override
  void dispose() {
    press.dispose();
    dx.dispose();
    dy.dispose();
    super.dispose();
  }
}

/// A value derived from one progress; listeners and status are forwarded to
/// [parent].
class _MotionValue extends Animation<double>
    with AnimationWithParentMixin<double> {
  _MotionValue(this.parent, this._compute);

  @override
  final Animation<double> parent;
  final double Function() _compute;

  @override
  double get value => _compute();
}
