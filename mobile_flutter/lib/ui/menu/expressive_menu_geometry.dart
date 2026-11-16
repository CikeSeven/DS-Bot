import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Geometry for the pop-up menu (pure functions): where the panel lands
/// (NexioSchedule's liquidDropdownPositionProvider and miuix's
/// dropdownPositionProvider), the panel rect during the container transform
/// (rectOf in NexioSchedule's ListPopup) and where the submenu lands.

/// How the menu aligns horizontally with its anchor, resolved by reading
/// direction (left and right swap under RTL).
enum ExpressiveMenuPlacement {
  /// The menu's start edge lines up with the anchor's start edge and the
  /// menu grows toward the end; suits text triggers at the start of a row.
  start,

  /// The menu's end edge lines up with the anchor's end edge and the menu
  /// grows toward the start; suits the ⋮ buttons in the top bar and at the
  /// end of a row.
  end,
}

/// Which side of the anchor the menu ends up on; decides which corner it
/// grows from.
enum ExpressiveMenuSide {
  /// Grows down: the panel's top corner sits on the seed.
  below,

  /// Grows up: the panel's bottom corner sits on the seed.
  above,

  /// Fits neither below nor above; centered on the seed.
  middle,
}

/// Panel corner radius (NexioSchedule's PanelCornerRadius is 25, reduced to
/// 22 to go with the smaller rows; it is a continuous curve, drawn here as a
/// superellipse).
const double kExpressiveMenuRadius = 22;

/// Corner radius of a row's highlight pill: the panel radius minus the row
/// inset (6), so it is concentric with the panel.
const double kExpressiveMenuRowRadius = 16;

/// Side length of the small seed circle when the menu does not grow out of
/// its trigger control (cards, the pointer position) (NexioSchedule's
/// fallback when there is no trigger size).
const double kExpressiveMenuSeedFallback = 28;

/// Minimum room left on the left and right when clamping into the safe area
/// (a panel aligned with its anchor usually does not reach it).
const double kExpressiveMenuScreenMargin = 8;

/// Where the main menu lands: the panel rect, its side, which vertical edge
/// touches the seed, and the seed rect (the panel grows out of it; overlay
/// coordinates).
@immutable
class ExpressiveMenuPlacementResult {
  const ExpressiveMenuPlacementResult({
    required this.rect,
    required this.side,
    required this.alignRight,
    required this.seed,
  });

  final Rect rect;
  final ExpressiveMenuSide side;
  final bool alignRight;
  final Rect seed;

  /// The panel corner that sits on the seed (overlay coordinates); when
  /// centered, the midpoint of that vertical edge. The main menu shrinks
  /// about this point while a submenu is open.
  Offset get pivot =>
      Offset(alignRight ? rect.right : rect.left, switch (side) {
        ExpressiveMenuSide.below => rect.top,
        ExpressiveMenuSide.above => rect.bottom,
        ExpressiveMenuSide.middle => rect.center.dy,
      });
}

/// The panel covers the trigger control and grows out of it (NexioSchedule's
/// dropdown and the top bar "more" menu): a corner of the panel sits on the
/// seed [seed] (the end-side corner for `end`, the start-side corner for
/// `start`). If there is room below the seed, the top corner sits on it and
/// the panel grows down; otherwise, if there is room above, the bottom corner
/// sits on it and the panel grows up; if neither fits, it is centered on the
/// seed. Finally it is clamped into [bounds] ([kExpressiveMenuScreenMargin]
/// on the left and right, no margin at the top and bottom).
ExpressiveMenuPlacementResult placeCoveringMenu({
  required Rect seed,
  required Size size,
  required Rect bounds,
  required ExpressiveMenuPlacement placement,
  required TextDirection textDirection,
}) {
  final endAligned =
      (placement == ExpressiveMenuPlacement.end) ==
      (textDirection == TextDirection.ltr);
  var x = endAligned ? seed.right - size.width : seed.left;
  ExpressiveMenuSide side;
  double y;
  if (bounds.bottom - seed.top >= size.height) {
    side = ExpressiveMenuSide.below;
    y = seed.top;
  } else if (seed.bottom - bounds.top >= size.height) {
    side = ExpressiveMenuSide.above;
    y = seed.bottom - size.height;
  } else {
    side = ExpressiveMenuSide.middle;
    y = seed.center.dy - size.height / 2;
  }
  const margin = kExpressiveMenuScreenMargin;
  x = x.clamp(
    bounds.left + margin,
    math.max(bounds.left + margin, bounds.right - margin - size.width),
  );
  y = y.clamp(bounds.top, math.max(bounds.top, bounds.bottom - size.height));
  final rect = Rect.fromLTWH(x, y, size.width, size.height);
  return ExpressiveMenuPlacementResult(
    rect: rect,
    side: side,
    alignRight: _closerToRight(rect, seed, endAligned),
    seed: seed,
  );
}

/// The panel sits next to the anchor (long press on a card, right click at
/// the pointer): miuix's dropdown rule. It goes [gap] below the anchor if it
/// fits there, otherwise above, and is centered on the anchor if neither
/// fits; it is clamped into [bounds] with [kExpressiveMenuScreenMargin] on
/// the left and right and [gap] at the top and bottom. The seed is a small
/// circle of [kExpressiveMenuSeedFallback] on the corner that touches the
/// anchor.
ExpressiveMenuPlacementResult placeOutsideMenu({
  required Rect anchor,
  required Size size,
  required Rect bounds,
  required ExpressiveMenuPlacement placement,
  required TextDirection textDirection,
  required double gap,
}) {
  final endAligned =
      (placement == ExpressiveMenuPlacement.end) ==
      (textDirection == TextDirection.ltr);
  var x = endAligned ? anchor.right - size.width : anchor.left;
  double y;
  if (bounds.bottom - anchor.bottom > size.height) {
    y = anchor.bottom + gap;
  } else if (anchor.top - bounds.top > size.height) {
    y = anchor.top - size.height - gap;
  } else {
    y = anchor.center.dy - size.height / 2;
  }
  const margin = kExpressiveMenuScreenMargin;
  x = x.clamp(
    bounds.left + margin,
    math.max(bounds.left + margin, bounds.right - margin - size.width),
  );
  final maxY = bounds.bottom - size.height - gap;
  y = y.clamp(math.min(bounds.top + gap, maxY), maxY);
  final rect = Rect.fromLTWH(x, y, size.width, size.height);
  final side = rect.center.dy > anchor.center.dy
      ? ExpressiveMenuSide.below
      : rect.center.dy < anchor.center.dy
      ? ExpressiveMenuSide.above
      : ExpressiveMenuSide.middle;
  final alignRight = _closerToRight(rect, anchor, endAligned);
  const s = kExpressiveMenuSeedFallback;
  final seedLeft = alignRight ? rect.right - s : rect.left;
  final seedTop = switch (side) {
    ExpressiveMenuSide.below => rect.top,
    ExpressiveMenuSide.above => rect.bottom - s,
    ExpressiveMenuSide.middle => rect.center.dy - s / 2,
  };
  return ExpressiveMenuPlacementResult(
    rect: rect,
    side: side,
    alignRight: alignRight,
    seed: Rect.fromLTWH(seedLeft, seedTop, s, s),
  );
}

/// After clamping into the safe area the panel may no longer touch the seed:
/// decide by which vertical edge is closer to the seed.
bool _closerToRight(Rect rect, Rect seed, bool endAligned) {
  if (rect.width <= 0) return endAligned;
  final left = (rect.left - seed.left).abs();
  final right = (rect.right - seed.right).abs();
  return left == right ? endAligned : right < left;
}

/// The panel rect at this point of the container transform (in the panel's
/// own coordinates): width and height each interpolate from the seed to the
/// panel ([fraction], not clamped, so overshoot is kept); the position moves
/// from "the corner on the seed" toward the panel center ([origin]). When
/// both are 0 it is the seed; when both are 1 it is the whole panel.
///
/// Equivalent to NexioSchedule's rectOf: its shift W·0.5·p·(1 − w/W) is
/// exactly what interpolates the corner-attached center to the panel center.
Rect expressiveMenuMorphRect({
  required Size size,
  required Rect seed,
  required double fraction,
  required double origin,
  required ExpressiveMenuSide side,
  required bool alignRight,
}) {
  final w = math.max(0.0, lerpDouble(seed.width, size.width, fraction)!);
  final h = math.max(0.0, lerpDouble(seed.height, size.height, fraction)!);
  final cornerX = alignRight ? seed.right - w / 2 : seed.left + w / 2;
  final cornerY = switch (side) {
    ExpressiveMenuSide.below => seed.top + h / 2,
    ExpressiveMenuSide.above => seed.bottom - h / 2,
    ExpressiveMenuSide.middle => seed.center.dy,
  };
  final cx = lerpDouble(cornerX, size.width / 2, origin)!;
  final cy = lerpDouble(cornerY, size.height / 2, origin)!;
  return Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
}

/// Where the submenu lands: its title row lies over the trigger row's pill
/// [pill] (the panel's top-left corner is [inset] outward from the pill's
/// top-left). If it does not fit toward the end, it sits against the end
/// edge of the safe area (leaving [kExpressiveMenuScreenMargin]); if it does
/// not fit below, its bottom edge aligns [inset] below the trigger row;
/// failing that, it is clamped into the safe area.
Rect placeExpressiveSubmenu({
  required Rect pill,
  required Size size,
  required Rect bounds,
  required TextDirection textDirection,
  required double inset,
}) {
  const margin = kExpressiveMenuScreenMargin;
  final minLeft = bounds.left + margin;
  final maxLeft = math.max(minLeft, bounds.right - margin - size.width);
  final left = textDirection == TextDirection.ltr
      ? (pill.left - inset).clamp(minLeft, maxLeft)
      : (pill.right + inset - size.width).clamp(minLeft, maxLeft);
  var top = pill.top - inset;
  if (top + size.height > bounds.bottom) {
    top = pill.bottom + inset - size.height;
  }
  top = top.clamp(
    bounds.top,
    math.max(bounds.top, bounds.bottom - size.height),
  );
  return Rect.fromLTWH(left, top, size.width, size.height);
}

/// A superellipse on [rect], with a corner radius of at most half the short
/// side (the small seed circle is a true circle).
RSuperellipse expressiveMenuShape(Rect rect, double radius) {
  final r = math.min(radius, math.max(0.0, rect.shortestSide / 2));
  return RSuperellipse.fromRectAndRadius(rect, Radius.circular(r));
}

/// Interpolates between two rects by [t] (t is not clamped, so the spring's
/// overshoot is kept).
Rect lerpExpressiveRect(Rect a, Rect b, double t) => Rect.fromLTRB(
  lerpDouble(a.left, b.left, t)!,
  lerpDouble(a.top, b.top, t)!,
  lerpDouble(a.right, b.right, t)!,
  lerpDouble(a.bottom, b.bottom, t)!,
);
