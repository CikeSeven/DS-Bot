import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'glass_backdrop_sample.dart';

/// Cache of pre-blurred backdrops: the same backdrop at the same size,
/// alignment and blur parameters is generated only once.
///
/// - Input: [GlassBackdropSample] (image, alignment, base color), the Leader
///   size, the blur radius and the saturation. Output: the blurred bitmap
///   (at logical pixels × [_scaleFor] resolution, scaled up by bilinear
///   interpolation when painted; the content is already blurred, so no grain
///   shows when scaled up);
/// - Generation: first paint "base color + cover image" into one image, then
///   paint it again with the blur (clamped edges, matching the backdrop blur
///   against the screen edges) and the saturation matrix; recorded only on
///   the UI thread and done once on the raster thread;
/// - Keeps at most [_capacity] entries, evicting the least recently used one
///   and releasing the cache's own handle (references already recorded into
///   a picture are counted by the engine and are not affected). Each entry
///   keeps a clone of the source image to check "is it still the same
///   image", released with the entry on eviction.
abstract final class GlassBackdropBlurCache {
  static const int _capacity = 4;
  static const int _maxBytes = 32 * 1024 * 1024;
  static final List<_BlurEntry> _entries = <_BlurEntry>[];

  /// Generation count (for tests, to confirm the same input is not generated
  /// twice).
  @visibleForTesting
  static int debugGenerations = 0;

  @visibleForTesting
  static void debugClear() {
    for (final entry in _entries) {
      entry.dispose();
    }
    _entries.clear();
    debugGenerations = 0;
  }

  /// Gets (generating it if needed) the pre-blurred image; returns null when
  /// the background layer has already released the source image handle (the
  /// frame that swaps the image has not rebuilt down to here yet), and this
  /// frame paints no sample.
  static ui.Image? resolve({
    required GlassBackdropSample sample,
    required Size size,
    required double sigma,
    required double saturation,
  }) {
    if (size.isEmpty || !size.isFinite) return null;
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (entry.matches(sample, size, sigma, saturation)) {
        if (i != _entries.length - 1) {
          _entries
            ..removeAt(i)
            ..add(entry);
        }
        return entry.blurred;
      }
    }
    final ui.Image source;
    try {
      source = sample.image.clone();
    } on StateError {
      return null;
    }
    final entry = _BlurEntry(
      source: source,
      alignment: sample.alignment,
      underColor: sample.underColor,
      scrim: sample.scrim,
      size: size,
      sigma: sigma,
      saturation: saturation,
      blurred: _generate(source, sample, size, sigma, saturation),
    );
    _entries.add(entry);
    // A source image clone does not copy pixels but extends the source
    // image's life, so it still counts toward the budget; keep at least the
    // current entry, since a single source image over budget is held by the
    // page on screen anyway.
    var bytes = _entries.fold<int>(0, (sum, entry) => sum + entry.bytes);
    while (_entries.length > 1 &&
        (_entries.length > _capacity || bytes > _maxBytes)) {
      bytes -= _entries.first.bytes;
      _entries.removeAt(0).dispose();
    }
    return entry.blurred;
  }

  /// Resolution of the pre-blurred image relative to logical pixels: the
  /// blur radius is at least about 6 pixels in the bitmap, so no blocks show
  /// when scaled up; at least 1/4 and at most 1 (never above the logical
  /// resolution).
  static double _scaleFor(double sigma) =>
      sigma <= 0 ? 1 : (6 / sigma).clamp(0.25, 1.0);

  static ui.Image _generate(
    ui.Image image,
    GlassBackdropSample sample,
    Size size,
    double sigma,
    double saturation,
  ) {
    debugGenerations++;
    // Limit the total pixels rather than shortening each side: an extra wide
    // / tall window keeps the cover ratio, and one entry is at most about
    // 4 MiB (about 16 MiB for the four-entry limit), so a small blur radius
    // does not take full-screen resolution.
    final scale = math.min(
      _scaleFor(sigma),
      math.min(
        math.sqrt(1048576 / (size.width * size.height)),
        4096 / math.max(size.width, size.height),
      ),
    );
    final width = (size.width * scale).ceil().clamp(1, 4096);
    final height = (size.height * scale).ceil().clamp(1, 4096);
    final bounds = Offset.zero & size;

    final composeRecorder = ui.PictureRecorder();
    final compose = Canvas(composeRecorder)..scale(scale);
    compose.drawRect(bounds, Paint()..color = sample.underColor);
    paintImage(
      canvas: compose,
      rect: bounds,
      image: image,
      fit: BoxFit.cover,
      alignment: sample.alignment,
      filterQuality: FilterQuality.medium,
    );
    final composePicture = composeRecorder.endRecording();
    final composed = composePicture.toImageSync(width, height);
    composePicture.dispose();

    final blurRecorder = ui.PictureRecorder();
    final blurCanvas = Canvas(blurRecorder);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    if (sigma > 0) {
      paint.imageFilter = ui.ImageFilter.blur(
        sigmaX: sigma * scale,
        sigmaY: sigma * scale,
        tileMode: TileMode.clamp,
      );
    }
    if (saturation != 1) {
      paint.colorFilter = ColorFilter.matrix(saturationMatrix(saturation));
    }
    blurCanvas.drawImage(composed, Offset.zero, paint);
    // Bake the scrim into the cache too, so the fade-in applies opacity only
    // once to the finished result. Painting them separately would stack the
    // scrim twice midway through the fade-in and make the sampled area
    // darker than the backdrop around it.
    final scrim = sample.scrim;
    if (scrim != null && scrim.a > 0) {
      blurCanvas.drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = saturate(scrim, saturation),
      );
    }
    final blurPicture = blurRecorder.endRecording();
    final blurred = blurPicture.toImageSync(width, height);
    blurPicture.dispose();
    composed.dispose();
    return blurred;
  }

  /// Saturation matrix (the same as the layer over the glass backdrop blur,
  /// with Rec. 709 luma weights).
  static List<double> saturationMatrix(double s) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    final k = 1 - s;
    return <double>[
      r * k + s, g * k, b * k, 0, 0, //
      r * k, g * k + s, b * k, 0, 0, //
      r * k, g * k, b * k + s, 0, 0, //
      0, 0, 0, 1, 0,
    ];
  }

  /// Applies [saturationMatrix] to one color (the scrim's saturation is
  /// adjusted along with the backdrop).
  static Color saturate(Color color, double s) {
    if (s == 1) return color;
    final m = saturationMatrix(s);
    double channel(int row) =>
        (m[row * 5] * color.r +
                m[row * 5 + 1] * color.g +
                m[row * 5 + 2] * color.b)
            .clamp(0.0, 1.0);
    return Color.from(
      alpha: color.a,
      red: channel(0),
      green: channel(1),
      blue: channel(2),
    );
  }
}

class _BlurEntry {
  _BlurEntry({
    required this.source,
    required this.alignment,
    required this.underColor,
    required this.scrim,
    required this.size,
    required this.sigma,
    required this.saturation,
    required this.blurred,
  });

  final ui.Image source;
  final Alignment alignment;
  final Color underColor;
  final Color? scrim;
  final Size size;
  final double sigma;
  final double saturation;
  final ui.Image blurred;

  int get bytes =>
      (source.width * source.height + blurred.width * blurred.height) * 4;

  bool matches(
    GlassBackdropSample sample,
    Size size,
    double sigma,
    double saturation,
  ) =>
      source.isCloneOf(sample.image) &&
      alignment == sample.alignment &&
      underColor == sample.underColor &&
      scrim == sample.scrim &&
      this.size == size &&
      this.sigma == sigma &&
      this.saturation == saturation;

  void dispose() {
    source.dispose();
    blurred.dispose();
  }
}
