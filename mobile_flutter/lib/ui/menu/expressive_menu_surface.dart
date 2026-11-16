import 'package:flutter/material.dart';

import '../glass.dart';
import '../theme.dart';
import 'expressive_motion.dart';
import 'glass/glass_surface.dart';

/// The menu's glass surface (modeled on phase's FrostedSurface): translucent
/// base color + backdrop blur + thin border + a soft shadow painted only
/// outside, with a 28 corner radius.
///
/// - Base color: in light, pure white surfaceContainerLowest (the same level
///   as cards; the old surfaceContainer looked gray on white cards); in dark,
///   the top level surfaceContainerHighest (the old base was almost the same
///   color as dark cards, so the menu sank into the page). Both are slightly
///   transparent so the blurred page color shows through.
/// - Opening animation: the progress drives the opacity of the base color,
///   border and shadow and the blur strength separately; the content fades
///   in on its own. The whole surface is not put in a FadeTransition: the
///   backdrop blur must sample the page under the menu, and inside a whole
///   opacity layer it can only sample that transparent layer itself, so a
///   base without blur would flash first during opening.
/// - The shadow is painted only outside the surface: the base is
///   translucent, so a plain BoxShadow / elevation would show through from
///   underneath and darken the middle of the menu. For how the surface
///   itself is painted see [BackdropGlass].
/// - With reduced motion or high contrast it falls back to an opaque base
///   with no blur, so text stays stable and readable.
class ExpressiveMenuSurface extends StatelessWidget {
  const ExpressiveMenuSurface({
    super.key,
    required this.reveal,
    required this.child,
  });

  static const double radius = 28;
  static const double blurSigma = 20;
  static const BorderRadius borderRadius = BorderRadius.all(
    Radius.circular(radius),
  );

  /// Opening progress (0 closed, 1 open).
  final Animation<double> reveal;
  final Widget child;

  /// Translucent base color.
  static Color tintOf(Palette p) => p.dark
      ? p.bubble.withValues(alpha: 0.84)
      : p.card.withValues(alpha: 0.82);

  /// Border: in light it has to be darker on the white base for the outline
  /// to show.
  static Color borderOf(Palette p) =>
      p.ink.withValues(alpha: p.dark ? 0.10 : 0.12);

  /// Outer shadow color: uses the shadow role color; on dark pages it has to
  /// be deeper for the layering to show.
  static Color shadowOf(ColorScheme colors) => colors.shadow.withValues(
    alpha: colors.brightness == Brightness.light ? 0.12 : 0.32,
  );

  /// Ring outer shadow color of the pop-up menu panel (NexioSchedule's
  /// popupPanelShadow: black at 0x1A / 0x2E with a 3.2× gain, 33% light /
  /// 58% dark). The ring is only 2dp wide and is then spread by blur, so it
  /// looks much lighter than this opacity.
  static Color ringShadowOf(ColorScheme colors) => colors.shadow.withValues(
    alpha: colors.brightness == Brightness.light ? 0.326 : 0.577,
  );

  /// Whether to fall back to an opaque base with no blur.
  static bool solidOf(BuildContext context) =>
      !GlassScope.of(context) || ExpressiveMotion.reduceMotion(context);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: reveal,
    child: FadeTransition(
      opacity: reveal,
      alwaysIncludeSemantics: true,
      child: child,
    ),
    builder: (BuildContext context, Widget? child) =>
        _buildSurface(context, reveal.value.clamp(0.0, 1.0), child!),
  );

  Widget _buildSurface(BuildContext context, double progress, Widget child) {
    final colors = Theme.of(context).colorScheme;
    final p = context.p;
    final solid = solidOf(context);
    final tint = tintOf(p);
    return BackdropGlass(
      borderRadius: borderRadius,
      fill: solid ? Color.alphaBlend(tint, p.main) : tint,
      blurSigma: blurSigma,
      blur: !solid,
      border: BorderSide(color: borderOf(p)),
      shadowColor: shadowOf(colors),
      progress: progress,
      child: child,
    );
  }
}
