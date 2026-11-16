import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Expressive handles spatial motion and color transitions separately: only
/// translation / scale may overshoot on a spring; color, corner radius and
/// opacity use the non-overshooting effects curve. All new motion respects
/// the system's reduced-motion setting. There are two kinds of spring: the
/// fixed-duration curve [spatial] (with [duration], for implicit animation
/// widgets) and true springs driven by physics simulation ([springSpatial]
/// and others, through [springTo], which can change target while keeping
/// velocity).
///
/// Duration tiers (aligned with the M3 duration tokens; the UI layer no
/// longer hard-codes milliseconds):
/// - [fast]: micro-interactions: icon / color switches, showing and hiding
///   small elements, scrim fade in and out;
/// - [medium]: content changes: list items entering and leaving, section
///   cross-fades, panel snapping, page turns;
/// - [standard]: spatial transitions: page-level transitions, larger
///   translation / deformation, showing and hiding the FAB;
/// - [long]: emphasized / ceremonial motion.
abstract final class ExpressiveMotion {
  static const fast = Duration(milliseconds: 180);
  static const medium = Duration(milliseconds: 250);
  static const standard = Duration(milliseconds: 350);
  static const long = Duration(milliseconds: 500);

  /// Periods of looping animations (not the duration of one transition):
  /// with reduced motion these loops never start, and they do not go through
  /// [duration].
  /// - [pulseLoop]: one ring of a radar ripple (three rings, each a third of
  ///   a period apart);
  /// - [flowLoop]: one trip of the dot along the connection track;
  /// - [scanLoop]: one round trip of the scan line on the QR scan page.
  static const pulseLoop = Duration(milliseconds: 3600);
  static const flowLoop = Duration(milliseconds: 1800);
  static const scanLoop = Duration(milliseconds: 2400);

  /// The pop-up menu (ported from NexioSchedule's ListPopup /
  /// LiquidGlassDropdownMenu), matching the original value for value; the
  /// panel growing and the submenu expanding are springs, see
  /// `ExpressiveMenuMotion`.
  /// - [menuMorphExit] / [menuMorphExitCurve]: duration and curve of the
  ///   anchor shift back to the trigger control when closing; the overlay is
  ///   removed when it finishes;
  /// - [menuHighlightIn] / [menuHighlightOut]: fade in and fade out of the
  ///   row highlight pill ([menuHighlightCurve]); the fade-out spans the
  ///   spring's whole slide to the edge item.
  static const menuMorphExit = Duration(milliseconds: 340);
  static const menuMorphExitCurve = Cubic(0, 0, 0, 1);
  static const menuHighlightIn = Duration(milliseconds: 90);
  static const menuHighlightOut = Duration(milliseconds: 220);

  /// The default curve of Compose's `tween`: FastOutSlowIn.
  static const menuHighlightCurve = Curves.fastOutSlowIn;

  /// Container expand (list card ↔ full page, see
  /// `ContainerTransformPageRoute`):
  /// - [containerOpen]: expand (M3 long1, 450ms);
  /// - [containerClose]: back into the card (M3 medium4, 400ms); going back
  ///   is a little faster than going in;
  /// - [containerSpring]: the spatial curve shared by position, size and
  ///   corner radius, modeled on a phone OS opening an app: it moves as soon
  ///   as it is pressed, the speed rises and falls smoothly, it settles
  ///   slowly and does not bounce. When closing, the same curve acts on "the
  ///   progress away from the full page", so it also leaves at once and lands
  ///   gently in the card.
  ///
  /// Why not M3 emphasized: it barely moves for the first ~40ms, then its
  /// peak speed shoots to about 10× the average and it covers 80% in about
  /// 100ms, spending the rest of the time on the last 2%; cross-fades tied to
  /// the progress are squeezed into about 70ms too. It looks like "a pause, a
  /// fling, a flash". A critically damped spring peaks at only about 3.3× the
  /// average speed, and in the same duration its cross-fades last about 50%
  /// longer.
  static const containerOpen = Duration(milliseconds: 450);
  static const containerClose = Duration(milliseconds: 400);
  static const containerSpring = _CriticallyDampedSpringCurve(9);

  /// Entry and state changes: decelerates to the end, no overshoot.
  static const effects = Curves.easeOutCubic;

  /// Exit: accelerates away, symmetric with [effects]; for
  /// AnimatedSwitcher.switchOutCurve and the like.
  static const exit = Curves.easeInCubic;
  static const spatial = _ExpressiveSpringCurve();

  /// True springs (driven by physics simulation, unlike the fixed-duration
  /// curve of [spatial]): only for translation, size and scale. When the
  /// target changes midway they carry on with the current velocity instead
  /// of restarting from zero speed like a tween, so repeated taps and
  /// reversals mid-scroll stay smooth. Parameters match the M3 Expressive
  /// spatial springs (damping ratio / stiffness); driven through [springTo].
  /// - [springSpatial]: the default, about 2% overshoot, for larger moves
  ///   (showing and hiding the bottom bar, expanding a slot);
  /// - [springSpatialFast]: fast and bouncy, about 10% overshoot, for press
  ///   rebounds of small elements and icons popping in;
  /// - [springIndicator]: the selection indicator sliding between navigation
  ///   items. Softer, about 2.5% overshoot: a gentle start, then it lands a
  ///   little past the spot and pulls back; with the speed-based stretch on
  ///   the way, it looks like a drop of water sliding over rather than a
  ///   board bouncing over.
  /// - [springPage]: home page paging (tapping the bottom bar to switch pages
  ///   and snapping to a page on release). Its response is close to
  ///   [springIndicator], so the two land together; a high damping ratio,
  ///   overshoot under 0.2% (under 1 pixel even across a full screen): a
  ///   whole page of content wobbling looks cheap, so the bounce is left to
  ///   the indicator.
  static final SpringDescription springSpatial =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 380, ratio: 0.8);
  static final SpringDescription springSpatialFast =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 800, ratio: 0.6);
  static final SpringDescription springIndicator =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 320, ratio: 0.76);
  static final SpringDescription springPage =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 340, ratio: 0.9);

  /// Drives the unbounded controller [controller] with the spring [spring]
  /// from its current value and velocity toward [target].
  ///
  /// [controller] must be created with `AnimationController.unbounded` (the
  /// spring passes the target and falls back; a bounded controller would cut
  /// off the overshoot). With reduced motion it jumps straight to the target
  /// without starting a simulation; it also does nothing when already at the
  /// target, to avoid a wasted frame. [tolerance] is the distance and
  /// velocity threshold for "settled", in the units of the driven value (the
  /// default is fine for pixel values).
  ///
  /// [kick] is an initial velocity added to the current velocity (units per
  /// second, in the units of the driven value): give it a velocity toward
  /// the target and the spring passes the end by a bit more before falling
  /// back. The "pop" when an icon is selected uses it, with no separate
  /// animation. With [kick] it starts even when already at the target.
  static void springTo(
    BuildContext context,
    AnimationController controller,
    double target, {
    SpringDescription? spring,
    Tolerance tolerance = Tolerance.defaultTolerance,
    double kick = 0,
  }) {
    if (reduceMotion(context)) {
      controller.value = target;
      return;
    }
    if (kick == 0 && !controller.isAnimating && controller.value == target) {
      return;
    }
    controller.animateWith(
      SpringSimulation(
        spring ?? springSpatial,
        controller.value,
        target,
        (controller.isAnimating ? controller.velocity : 0) + kick,
        tolerance: tolerance,
        // Land exactly on the target value when settled, not somewhere within
        // tolerance of it: only then are the position and size at rest exact
        // values, with no sub-pixel error.
        snapToEnd: true,
      ),
    );
  }

  /// Whether the system has "reduce motion" turned on.
  static bool reduceMotion(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  static Duration duration(BuildContext context, [Duration value = standard]) =>
      reduceMotion(context) ? Duration.zero : value;

  /// Near instant (1ms), only for APIs that do not accept a zero duration;
  /// see [durationNonZero].
  static const nearInstant = Duration(milliseconds: 1);

  /// Same as [duration], but returns [nearInstant] instead of 0 with reduced
  /// motion.
  ///
  /// For APIs that cannot take a zero duration: with a zero duration,
  /// `AnimatedSize` forwards synchronously in its own performLayout and
  /// notifies its listeners as soon as the child's size changes, which marks
  /// itself dirty again (in debug this trips the "mutated in its own
  /// performLayout" assert). 1ms looks the same as 0.
  static Duration durationNonZero(
    BuildContext context, [
    Duration value = standard,
  ]) => reduceMotion(context) ? nearInstant : value;
}

class _ExpressiveSpringCurve extends Curve {
  const _ExpressiveSpringCurve();

  static final _spring = SpringSimulation(
    const SpringDescription(mass: 1, stiffness: 500, damping: 30),
    0,
    1,
    0,
  );

  @override
  double transformInternal(double t) => _spring.x(t * 0.6);
}

/// The displacement of a critically damped spring that starts at rest and
/// heads for 1, squeezed into a fixed duration (see
/// [ExpressiveMotion.containerSpring]).
///
/// The displacement is `x(u) = 1 − (1 + u)·e^(−u)` (`u = ωt`): the start
/// velocity is 0 but the acceleration is at its maximum, so it moves from the
/// first frame; the velocity peaks at `u = 1` and then falls smoothly, with
/// no spike, and it never passes the end.
///
/// Why a fixed-duration curve and not a true spring
/// ([ExpressiveMotion.springTo]): the total duration of a transition must be
/// controllable (set by the duration tokens), and the route's gate
/// simulation is timed by duration too.
///
/// Why deliberately no bounce: the route controller's progress is clamped to
/// 0–1, so an underdamped spring's overshoot would be cut into a plateau,
/// and around the end the page would switch back and forth between the
/// "container" and "settled" painting; a whole page wobbling also looks
/// cheap.
class _CriticallyDampedSpringCurve extends Curve {
  const _CriticallyDampedSpringCurve(this.settle);

  /// The `ωt` the spring has covered when the duration ends. Larger values
  /// move the motion earlier (a sharper start, a longer settling phase). At
  /// 9 the end is only about 0.12% short of 1; once normalization makes up
  /// that gap, the speed at the moment it stops is only about 1% of the
  /// average, so no jolt shows on arrival.
  final double settle;

  static double _raw(double u) => 1 - (1 + u) * math.exp(-u);

  @override
  double transformInternal(double t) => _raw(settle * t) / _raw(settle);
}
