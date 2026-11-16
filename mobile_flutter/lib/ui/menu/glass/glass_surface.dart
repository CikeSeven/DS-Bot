import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'glass_backdrop_sample.dart';
import 'glass_bottom_fade_painter.dart';
import 'glass_reveal.dart';
import 'outer_shadow_painter.dart';

/// A general frosted glass surface: outer shadow → rounded clip → backdrop
/// blur → translucent base color + border / bottom hairline → content. The
/// menu, the floating bottom bar and the glass top bar all share this
/// approach.
///
/// Input: the base color (opacity included), the blur strength and switch,
/// an optional border / bottom hairline / shadow, and the overall reveal
/// progress [progress]. Output: a piece of glass that appears by progress.
/// No side effects.
///
/// Constraints (callers must follow them):
/// - Never put a glass surface as a whole in an `Opacity` /
///   `FadeTransition`: the backdrop blur samples the page under the surface,
///   and inside an opacity layer it can only sample the transparent layer
///   itself, so a base without blur flashes first while appearing. To fade
///   in, use [progress]: it scales the opacity of the base color, border,
///   hairline and shadow and the blur strength proportionally; the content
///   fades in separately. To fade in the whole block (glass with content),
///   use an ancestor [GlassReveal]: its progress multiplies with
///   [progress], and this surface puts the content in an Opacity inside the
///   glass to fade in with it.
/// - The shadow is painted only outside ([OuterShadowPainter]): the base is
///   translucent, so a plain elevation would show through from underneath
///   and darken the middle of the surface.
/// - The base color is painted by a canvas-type [Material], so InkWell
///   ripples in the content can paint straight onto the glass.
/// - When fading from top to bottom ([fadeToBottom]), the base color is
///   painted by [GlassBottomFadePainter] instead, and the backdrop read is
///   not shared with other glass; see that field's docs.
class BackdropGlass extends StatelessWidget {
  const BackdropGlass({
    super.key,
    this.borderRadius = BorderRadius.zero,
    required this.fill,
    this.blurSigma = 20,
    this.saturation = 1,
    this.blur = true,
    this.border,
    this.bottomHairline,
    this.bottomHairlineWidth = hairlineWidth,
    this.shadowColor,
    this.progress = 1,
    this.fadeToBottom,
    this.extendAbove = 0,
    this.extendAboveVisible,
    this.grouped = false,
    this.backdropKey,
    this.backdropSample,
    required this.child,
  }) : assert(
         extendAbove >= 0 &&
             (extendAbove == 0 && extendAboveVisible == null ||
                 fadeToBottom != null),
         'extendAbove must not be negative; it and extendAboveVisible are only '
         'for the fade structure (fadeToBottom non-null).',
       ),
       assert(
         !grouped || backdropKey == null,
         'Use only one of grouped and backdropKey: the former takes the nearest '
         'BackdropGroup, the latter names the shared backdrop key directly.',
       );

  /// Default thickness of the bottom hairline (the same spec as the top
  /// divider of solid bars).
  static const double hairlineWidth = 0.6;

  /// Corner radius; [BorderRadius.zero] when the top bar fills edge to edge.
  final BorderRadius borderRadius;

  /// Base color (opacity included; when opaque, this is a solid surface).
  final Color fill;
  final double blurSigma;

  /// Saturation multiplier of the blurred backdrop (1 = unchanged). Above 1
  /// the colors showing through are more vivid, so even with a very light
  /// base it reads as glass rather than a gray layer; it moves from 1 to the
  /// target value with [progress]. At 1 the filter is exactly the same as
  /// blur alone (other glass such as menus and cards is not affected).
  final double saturation;

  /// Whether to blur the backdrop; false when falling back to an opaque base
  /// color, such as in high contrast.
  final bool blur;

  /// Border all around (for floating pills); null draws none.
  final BorderSide? border;

  /// Bottom hairline color (for the glass top bar); null draws none. Only
  /// for square-cornered surfaces: with rounded corners, the ends of the
  /// hairline get clipped by the corners.
  final Color? bottomHairline;

  /// Thickness of the bottom hairline; defaults to [hairlineWidth], and the
  /// glass top bar passes the user's setting.
  final double bottomHairlineWidth;

  /// Outer shadow color; null draws no shadow.
  final Color? shadowColor;

  /// Reveal progress (0 fully transparent, 1 fully shown).
  final double progress;

  /// Fades to transparent from top to bottom (for the glass top bar): from
  /// the visible top edge of the glass to the bottom edge of the surface,
  /// the base color and the backdrop blur (with its saturation boost) fade
  /// together along one curve from full to nothing, so at the bottom edge
  /// only the unblurred page remains and no edge shows. Content (text,
  /// buttons) is not affected.
  ///
  /// - null (default): no fade, and the tree is exactly the same as without
  ///   this parameter;
  /// - false: no fade (a uniform base color), but the nodes used for the
  ///   fade are kept. Callers that switch between "fade / no fade" pass false
  ///   rather than null, so the tree does not change and the content is not
  ///   remounted;
  /// - true: fade. The blur fades out with it only when blur is on (with
  ///   [blur] false or [progress] 0, only the base color fades): it works by
  ///   erasing inside the backdrop blur's offscreen layer, and without that
  ///   layer it would erase the page below directly. For the same reason, a
  ///   fading surface does not share the backdrop read with other glass
  ///   (ignoring [grouped] and [backdropKey]): when several pieces of glass
  ///   share a backdrop with the same filter, Impeller opens no new layer
  ///   and paints the children straight into the parent layer, and erasing
  ///   would turn the page black.
  ///
  /// Only for square-cornered surfaces with no border or shadow (top bars).
  final bool? fadeToBottom;

  /// How far the glass extends upward past the surface's top edge (painted
  /// only; it takes no layout space and no taps): when one top bar is built
  /// from several stacked pieces (a header + a pinned tab bar), the whole bar uses only this glass of the bottom piece, extended
  /// up behind the pieces above, and the pieces above paint only content.
  /// They do not each paint their own: when the later piece reads the
  /// backdrop, the earlier piece, with its tabs and buttons, is already on
  /// the canvas and gets blurred into its bottom edge, so a line shows at the
  /// seam; a fade also cannot run continuously across two pieces of glass.
  /// Use the largest possible total height of the pieces above; the part
  /// that extends too far lands outside the scroll view. Only for the fade
  /// structure ([fadeToBottom] non-null).
  final double extendAbove;

  /// How much of the upward extension is visible right now (the current
  /// total height of the pieces above, which changes during layout); null
  /// means all of [extendAbove] is visible. The fade starts from the visible
  /// top edge, and the hidden part is not painted; a change in the value
  /// only triggers a repaint.
  final ValueListenable<double>? extendAboveVisible;

  /// Whether to share the nearest [BackdropGroup] through
  /// `BackdropFilter.grouped`: neighboring pieces of glass (such as the top
  /// bar and the bottom bar) under the same BackdropGroup read the backdrop
  /// only once, saving repeated backdrop readbacks. Without a BackdropGroup
  /// ancestor it is the same as a plain blur.
  final bool grouped;

  /// Sets the key for a shared backdrop read directly
  /// (`BackdropFilter.backdropGroupKey`): pieces of glass under the same key
  /// read the backdrop only once. For glass that is not in the same
  /// [BackdropGroup] subtree but sits over the same backdrop (such as a key
  /// that a page backdrop hands to its content cards). Mutually exclusive
  /// with [grouped].
  final BackdropKey? backdropKey;

  /// Pre-blurred backdrop sample for content glass (see
  /// [GlassBackdropSample]): when non-null, no backdrop blur is opened, and
  /// the pre-blurred page backdrop is painted under the base color instead.
  /// Only takes effect for content glass that shares the page backdrop read
  /// ([backdropKey] non-null); in such glass the sample layer's slot is
  /// always kept (an empty placeholder when there is no sample), so the
  /// content is not remounted when the backdrop image appears or goes away.
  final GlassBackdropSample? backdropSample;
  final Widget child;

  static Color _scaled(Color color, double factor) =>
      color.withValues(alpha: color.a * factor);

  @override
  Widget build(BuildContext context) {
    final reveal = GlassReveal.of(context);
    final t = (progress * reveal).clamp(0.0, 1.0);
    final side = border;
    final hairline = bottomHairline;
    Widget content = child;
    // An ancestor GlassReveal replaces the outer opacity layer, so the
    // content's fade-in is handled here: the Opacity wraps only the content,
    // not the glass (inside the BackdropFilter or beside it), so it does not
    // get in the way of blur sampling.
    // This layer is added only when a scope exists; without a scope the tree
    // is exactly the same as before.
    // (This surface's own progress does not apply: it only covers the glass
    // surface, and the caller fades the content in separately.)
    if (GlassReveal.hasScope(context)) {
      content = Opacity(opacity: reveal, child: content);
    }
    // In the fade structure the hairline layer is always there (an empty
    // decoration when there is no hairline), so the content is not remounted
    // when the top bar switches between "fade" and "divider".
    if (hairline != null || fadeToBottom != null) {
      content = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: hairline == null
            ? const BoxDecoration()
            : BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: _scaled(hairline, t),
                    width: bottomHairlineWidth,
                  ),
                ),
              ),
        child: content,
      );
    }
    // Always keep the BackdropFilter node and only toggle enabled: adding or
    // removing the node rebuilds the whole content, losing focus, scroll
    // position and ripples.
    // Content glass with a pre-blurred backdrop to sample opens no backdrop
    // blur (see [backdropSample]); the fade structure does not sample (it
    // sits over the content, and what it blurs is scrolling content).
    final sampleSlot = backdropKey != null && fadeToBottom == null;
    final sample = sampleSlot ? backdropSample : null;
    final enabled = blur && t > 0 && blurSigma > 0 && sample == null;
    final sigma = blurSigma * t;
    final blurFilter = ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    final saturate = 1 + (saturation - 1) * t;
    // Blur first, then raise saturation: done within one backdrop read, with
    // no extra offscreen layer.
    final filter = saturate == 1
        ? blurFilter
        : ImageFilter.compose(
            outer: ColorFilter.matrix(
              GlassBackdropBlurCache.saturationMatrix(saturate),
            ),
            inner: blurFilter,
          );
    final fade = fadeToBottom;
    final Widget glass;
    if (fade == null) {
      final surface = Material(
        type: MaterialType.canvas,
        color: _scaled(fill, t),
        surfaceTintColor: Colors.transparent,
        // The progress already gives the color and border every frame; turn
        // off Material's own color tween so it does not trail behind.
        animationDuration: Duration.zero,
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: side == null
              ? BorderSide.none
              : side.copyWith(color: _scaled(side.color, t)),
        ),
        clipBehavior: Clip.antiAlias,
        child: content,
      );
      glass = ClipRRect(
        borderRadius: borderRadius,
        child: _backdrop(
          enabled: enabled,
          filter: filter,
          shared: true,
          child: sampleSlot
              ? Stack(
                  fit: StackFit.passthrough,
                  children: <Widget>[
                    Positioned.fill(
                      child: sample != null && blur && blurSigma > 0
                          ? GlassBackdropSampleView(
                              sample: sample,
                              sigma: blurSigma,
                              saturation: saturation,
                              opacity: t,
                            )
                          : const SizedBox.shrink(),
                    ),
                    surface,
                  ],
                )
              : surface,
        ),
      );
    } else {
      glass = _layeredGlass(
        fading: fade,
        fill: _scaled(fill, t),
        enabled: enabled,
        filter: filter,
        content: content,
      );
    }
    final shadow = shadowColor;
    // Keep the CustomPaint node even without a shadow (the painter is null),
    // so turning the shadow on or off does not change the tree.
    return CustomPaint(
      painter: shadow == null
          ? null
          : OuterShadowPainter(
              color: _scaled(shadow, t),
              borderRadius: borderRadius,
            ),
      child: glass,
    );
  }

  /// The backdrop blur node. When [shared] is true, the backdrop read is
  /// shared through [grouped] / [backdropKey]; when false, it reads the
  /// backdrop once by itself and opens its own offscreen layer (the fade
  /// erases inside this layer, see [fadeToBottom]). Both forms are the same
  /// widget type, so switching between them does not rebuild the node.
  Widget _backdrop({
    required bool enabled,
    required ImageFilter filter,
    required bool shared,
    required Widget child,
  }) {
    if (shared && grouped) {
      return BackdropFilter.grouped(
        enabled: enabled,
        filter: filter,
        child: child,
      );
    }
    return BackdropFilter(
      enabled: enabled,
      filter: filter,
      backdropGroupKey: shared ? backdropKey : null,
      child: child,
    );
  }

  /// The fade structure: the glass (blur + base color) is a piece laid under
  /// the content and extended up by [extendAbove], while the content is laid
  /// out at the surface's own size as usual.
  ///
  /// - The glass sits in a Positioned whose top goes past the Stack, so it
  ///   paints without taking space; apart from the IgnorePointer, taps
  ///   cannot land outside the Stack's bounds anyway, so the upward extension
  ///   does not block the content of the piece above;
  /// - The content is wrapped in a transparent Material that catches ripples
  ///   and hover highlights (without it, the ink would paint on a Material
  ///   further out that the glass covers), and is clipped to the surface,
  ///   the same as without the fade;
  /// - The Stack uses passthrough: it hands the outer constraints to the
  ///   content as is, so the surface's size is the same as without the fade.
  ///
  /// When [fading] is false (no fade, only keeping the structure) the base
  /// color is uniform and the backdrop read is shared as usual; the tree is
  /// exactly the same as when fading.
  Widget _layeredGlass({
    required bool fading,
    required Color fill,
    required bool enabled,
    required ImageFilter filter,
    required Widget content,
  }) {
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: <Widget>[
        Positioned(
          left: 0,
          top: -extendAbove,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: ClipRect(
              child: _backdrop(
                enabled: enabled,
                filter: filter,
                shared: !fading,
                child: CustomPaint(
                  painter: GlassBottomFadePainter(
                    fade: fading,
                    fill: fill,
                    eraseBackdrop: enabled && fading,
                    overhang: extendAbove,
                    visibleOverhang: extendAboveVisible,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
        ClipRect(
          child: Material(
            type: MaterialType.transparency,
            animationDuration: Duration.zero,
            child: content,
          ),
        ),
      ],
    );
  }
}
