import 'dart:typed_data';

import 'package:dsbot_mobile/data/photos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('imageTypeOf reads the type from the bytes, not the name', () {
    expect(imageTypeOf([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0]), 'image/png');
    expect(imageTypeOf([0xff, 0xd8, 0xff, 0xe0]), 'image/jpeg');
    expect(imageTypeOf('GIF89a..'.codeUnits), 'image/gif');
    expect(imageTypeOf('GIF87a..'.codeUnits), 'image/gif');
    expect(imageTypeOf('RIFF\x00\x00\x00\x00WEBPVP8 '.codeUnits), 'image/webp');
    expect(imageTypeOf('GIF8'.codeUnits), isNull);
    expect(imageTypeOf('<html>'.codeUnits), isNull);
  });

  test('only a GIF the link can carry goes as it is', () {
    final gif = Uint8List(1000)..setAll(0, 'GIF89a'.codeUnits);
    expect(keepsOriginal(gif), isTrue);
    expect(keepsOriginal(Uint8List(maxGifBytes + 1)..setAll(0, 'GIF89a'.codeUnits)), isFalse);
    expect(keepsOriginal(Uint8List(1000)..setAll(0, [0xff, 0xd8, 0xff])), isFalse);
  });

  test('minSideFor brings the long side to the edge whichever way the photo turns', () {
    // flutter_image_compress: scale = max(1, min(width / minWidth, height / minHeight)).
    int longAfter(int w, int h) {
      final side = minSideFor(w, h);
      final scale = [1.0, [w / side, h / side].reduce((a, b) => a < b ? a : b)].reduce((a, b) => a > b ? a : b);
      return [w ~/ scale, h ~/ scale].reduce((a, b) => a > b ? a : b);
    }

    expect(longAfter(4000, 3000), photoEdge);
    expect(longAfter(3000, 4000), photoEdge);
    expect(longAfter(1080, 2400), lessThanOrEqualTo(photoEdge));
    expect(longAfter(12000, 3000), lessThanOrEqualTo(photoEdge));
    // A small photo keeps its size.
    expect(longAfter(1000, 800), 1000);
  });
}
