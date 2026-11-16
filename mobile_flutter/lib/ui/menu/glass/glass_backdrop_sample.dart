import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'glass_backdrop_blur_cache.dart';

export 'glass_backdrop_blur_cache.dart';

/// Notifies only the sample painter to repaint when the Leader's actual size
/// changes. The card's own size may not have changed (for example when only
/// a desktop window's height changes), so CustomPaint's relayout alone
/// cannot update the cover framing.
class GlassBackdropLink extends LayerLink with ChangeNotifier {
  bool _disposed = false;

  @override
  set leaderSize(Size? value) {
    if (value == super.leaderSize) return;
    super.leaderSize = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Backdrop sample for content glass: a pre-blurred page backdrop in place
/// of a per-frame backdrop blur.
///
/// Why: content glass (cards, groups, the calendar card) only blurs the page
/// backdrop. One page shares one backdrop read, which happens before the
/// first glass paints, and content painted after it never goes into the blur
/// anyway. But `BackdropFilter`
/// still reads back the whole screen every frame and runs a Gaussian blur
/// over the whole area; on a real device, while scrolling a long page, this
/// alone pushed the raster time of about 10% of frames past
/// the 120Hz budget, mostly in the first few frames after a scroll starts
/// from rest. The page backdrop is a still image (only the content moves
/// with the page), and the blur result is constant while the backdrop, size
/// and parameters stay the same, so it only needs to be computed once:
///
/// - The background layer is wrapped in a [CompositedTransformTarget] (the
///   Leader of [link]);
/// - The glass puts a [CompositedTransformFollower] inside its own rounded
///   clip, which paints the pre-blurred image in the Leader's coordinate
///   space, filling the Leader. The Follower's transform is recomputed from
///   the Leader's actual position at each frame's compositing, so when
///   content scrolls, the home screen pages or overscroll stretches, the
///   sampled area stays aligned with the backdrop and the card itself need
///   not repaint; a screenshot (`toImageSync`) also works out the relative
///   position along the main tree, so it captures the right part too;
/// - The scrim is a uniform color, and blur and saturation are both linear:
///   blurring the backdrop and then laying the scrim on top gives the same
///   result as blurring "backdrop + scrim", so [scrim] is laid on when the
///   cache is generated.
///   Used only once the backdrop has settled and the backdrop paints its own
///   scrim; live blur stays when the backdrop is cross-fading, when the
///   backdrop differs between areas, or when the page tints the scrim by its
///   tone.
///
/// Input: the backdrop image handle (not owned by this class), the cover
/// alignment, the page base color under the image, and the scrim. Compared
/// by value; dependents rebuild when the backdrop swaps its image or changes
/// its focal point or scrim.
@immutable
class GlassBackdropSample {
  const GlassBackdropSample({
    required this.link,
    required this.image,
    required this.alignment,
    required this.underColor,
    this.scrim,
  });

  /// The link of the [CompositedTransformTarget] on the background layer.
  final GlassBackdropLink link;

  /// The image the background layer paints (`BoxFit.cover`, filling the
  /// Leader).
  final ui.Image image;

  /// The focal point for cover, the same as the background layer's
  /// `RawImage.alignment`.
  final Alignment alignment;

  /// The color the background layer puts under the image (images with
  /// transparent areas let it show through).
  final Color underColor;

  /// The scrim laid over the backdrop; null means none.
  final Color? scrim;

  @override
  bool operator ==(Object other) =>
      other is GlassBackdropSample &&
      identical(other.link, link) &&
      other.image.isCloneOf(image) &&
      other.alignment == alignment &&
      other.underColor == underColor &&
      other.scrim == scrim;

  @override
  int get hashCode => Object.hash(
    link,
    image.width,
    image.height,
    alignment,
    underColor,
    scrim,
  );
}

/// Paints the pre-blurred backdrop of [sample] in the Leader's coordinate
/// space; the outer rounded clip cuts out the part under the glass.
///
/// Goes inside the glass clip, below the base color; [opacity] matches the
/// glass's fade-in progress (the blur radius does not follow the progress:
/// changing the radius every frame would regenerate the pre-blurred image
/// every frame). Paints nothing when the Leader is absent (the backdrop has
/// not been painted yet). Takes no taps.
class GlassBackdropSampleView extends StatelessWidget {
  const GlassBackdropSampleView({
    super.key,
    required this.sample,
    required this.sigma,
    this.saturation = 1,
    this.opacity = 1,
  });

  final GlassBackdropSample sample;
  final double sigma;
  final double saturation;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CompositedTransformFollower(
        link: sample.link,
        showWhenUnlinked: false,
        child: CustomPaint(
          painter: _GlassBackdropSamplePainter(
            sample: sample,
            sigma: sigma,
            saturation: saturation,
            opacity: opacity,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _GlassBackdropSamplePainter extends CustomPainter {
  _GlassBackdropSamplePainter({
    required this.sample,
    required this.sigma,
    required this.saturation,
    required this.opacity,
  }) : super(repaint: sample.link);

  final GlassBackdropSample sample;
  final double sigma;
  final double saturation;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    // This widget is laid out at the glass's own size but paints the whole
    // Leader: the Follower switches the coordinate space to the Leader's,
    // and the outer clip keeps only the part under the glass.
    final leaderSize = sample.link.leaderSize;
    if (leaderSize == null || leaderSize.isEmpty || opacity <= 0) {
      return;
    }
    final blurred = GlassBackdropBlurCache.resolve(
      sample: sample,
      size: leaderSize,
      sigma: sigma,
      saturation: saturation,
    );
    if (blurred == null) {
      return;
    }
    final dst = Offset.zero & leaderSize;
    canvas.drawImageRect(
      blurred,
      Offset.zero & Size(blurred.width.toDouble(), blurred.height.toDouble()),
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0)),
    );
  }

  @override
  bool shouldRepaint(_GlassBackdropSamplePainter oldDelegate) =>
      oldDelegate.sample != sample ||
      oldDelegate.sigma != sigma ||
      oldDelegate.saturation != saturation ||
      oldDelegate.opacity != opacity;
}
