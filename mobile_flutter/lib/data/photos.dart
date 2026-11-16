import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_image_compress/flutter_image_compress.dart';

/// The long side of a photo sent from the phone: as much as the models look at.
const photoEdge = 2048;
const photoQuality = 82;

/// A GIF up to this size goes as it is, so the computer can show a Bot its motion. One
/// link message carries 4 MiB, and base64 makes the GIF a third larger.
const maxGifBytes = 2560 * 1024;

/// The image type the bytes really have, or null when they are none the computer takes.
/// A file name can be wrong: a picker that re-encodes a photo keeps its old name.
String? imageTypeOf(List<int> b) {
  bool at(int start, List<int> sig) => b.length >= start + sig.length && Iterable<int>.generate(sig.length).every((i) => b[start + i] == sig[i]);
  if (at(0, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return 'image/png';
  if (at(0, const [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (at(0, const [0x47, 0x49, 0x46, 0x38]) && (at(4, const [0x37, 0x61]) || at(4, const [0x39, 0x61]))) return 'image/gif';
  if (at(0, const [0x52, 0x49, 0x46, 0x46]) && at(8, const [0x57, 0x45, 0x42, 0x50])) return 'image/webp';
  return null;
}

/// Whether a picked photo goes as it is: a GIF the link can carry. Any other photo is
/// made a JPEG with its long side at most [photoEdge].
bool keepsOriginal(List<int> bytes) => imageTypeOf(bytes) == 'image/gif' && bytes.length <= maxGifBytes;

/// The bytes to send for a photo picked at full size.
Future<Uint8List> photoToSend(Uint8List original) async {
  if (keepsOriginal(original)) return original;
  final size = await _size(original);
  final side = size == null ? photoEdge * 3 ~/ 4 : minSideFor(size.$1, size.$2);
  return FlutterImageCompress.compressWithList(original, minWidth: side, minHeight: side, quality: photoQuality);
}

/// The `minWidth` and `minHeight` for flutter_image_compress that bring the long side to
/// at most [photoEdge]: it scales by min(width / minWidth, height / minHeight), never up,
/// so a square bound of short * edge / long scales by long / edge either way round.
int minSideFor(int width, int height) {
  if (width <= 0 || height <= 0) return photoEdge * 3 ~/ 4;
  final long = math.max(width, height);
  final short = math.min(width, height);
  return math.max(1, photoEdge * short ~/ long);
}

// Width and height from the image's header, without decoding it; null for a format
// the engine does not read, which then gets a 4:3 bound.
Future<(int, int)?> _size(Uint8List bytes) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = (descriptor.width, descriptor.height);
    descriptor.dispose();
    buffer.dispose();
    return size;
  } on Object {
    return null;
  }
}
