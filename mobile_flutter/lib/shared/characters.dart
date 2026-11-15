// Port of the look rules in ds-bot/src/client/characters.js, and a painter for
// the characters: body, fixed-color decals and a shade, with the eyes cut out of
// every layer so they show whatever sits behind the avatar.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:path_drawing/path_drawing.dart';

import 'shared_data.dart';

class Look {
  const Look({required this.shape, required this.color, this.image});

  final String shape;
  final String color;
  final String? image;
}

int _imul(int a, int b) {
  final result = (a.toUnsigned(32) * b.toUnsigned(32)) & 0xffffffff;
  return result.toSigned(32);
}

int _ushr(int value, int bits) => value.toUnsigned(32) >> bits;

/// FNV-1a over UTF-16 code units, the same as the JavaScript version.
int fnv1a(String text) {
  var value = 2166136261.toSigned(32);
  for (final unit in text.codeUnits) {
    value = _imul(value ^ unit, 16777619);
  }
  return value.toUnsigned(32);
}

/// The default color comes from the Bot id (FNV-1a, then mulberry32), so it is
/// the same on every device.
String defaultColor(String id, [SharedData? data]) {
  final colors = (data ?? SharedData.instance).defaultColors;
  final t = (fnv1a(id) + 1831565813).toSigned(32);
  var n = _imul(t ^ _ushr(t, 15), 1 | t);
  n = (n + _imul(n ^ _ushr(n, 7), 61 | n)).toSigned(32) ^ n;
  final unit = _ushr(n ^ _ushr(n, 14), 0) / 4294967296;
  return colors[(unit * colors.length).floor()];
}

/// The default shape comes from the Bot id (FNV-1a, then murmur3's fmix32).
String defaultShape(String id, [SharedData? data]) {
  final shapes = (data ?? SharedData.instance).defaultShapes;
  var value = fnv1a(id).toSigned(32);
  value = _imul(value ^ _ushr(value, 16), 73244475);
  value = _imul(value ^ _ushr(value, 13), 3266489909);
  return shapes[_ushr(value ^ _ushr(value, 16), 0) % shapes.length];
}

/// A stored shape or color wins; then the id. With no Bot it is a black gumdrop.
Look lookOf({String? id, String? shape, String? color, String? image, SharedData? data}) {
  final shared = data ?? SharedData.instance;
  final hasId = id != null && id.isNotEmpty;
  return Look(
    shape: shape != null && shared.characters.containsKey(shape) ? shape : (hasId ? defaultShape(id, shared) : shared.fallbackShape),
    color: shared.isColor(color) ? color! : (hasId ? defaultColor(id, shared) : 'black'),
    image: image,
  );
}

class _ParsedCharacter {
  _ParsedCharacter(CharacterDef def)
      : body = parseSvgPathData(def.body)..fillType = PathFillType.evenOdd,
        shade = parseSvgPathData(def.shade)..fillType = PathFillType.evenOdd,
        paints = [for (final paint in def.paints) (path: parseSvgPathData(paint.d)..fillType = PathFillType.evenOdd, fill: paint.fill, opacity: paint.opacity)],
        eyes = def.eyes;

  final Path body;
  final Path shade;
  final List<({Path path, Color fill, double opacity})> paints;
  final List<List<double>> eyes;
}

final Map<String, _ParsedCharacter> _parsed = {};

class CharacterPainter extends CustomPainter {
  CharacterPainter({required this.look, required this.dark, this.blink = 0, SharedData? data})
      : data = data ?? SharedData.instance;

  final Look look;
  final bool dark;

  /// 0 open, 1 closed: eyes squash vertically for a blink.
  final double blink;
  final SharedData data;

  @override
  void paint(Canvas canvas, Size size) {
    final def = data.characters[look.shape] ?? data.characters[data.fallbackShape];
    if (def == null) return;
    final character = _parsed.putIfAbsent(def.id, () => _ParsedCharacter(def));
    final scale = size.width / 100;
    canvas.save();
    canvas.scale(scale);
    final bounds = const Offset(-10, -10) & const Size(120, 120);
    canvas.saveLayer(bounds, Paint());

    final fill = Paint()..isAntiAlias = true;
    final stops = data.gradients[look.color];
    if (stops != null) {
      fill.shader = LinearGradient(
        colors: [for (final stop in stops) stop.color],
        stops: [for (final stop in stops) stop.offset],
      ).createShader(Rect.fromPoints(const Offset(18, 10), const Offset(78, 92)));
    } else {
      fill.color = data.ink(look.color, dark: dark);
    }
    canvas.drawPath(character.body, fill);
    for (final paint in character.paints) {
      canvas.drawPath(paint.path, Paint()..color = paint.fill.withValues(alpha: paint.opacity));
    }
    canvas.drawPath(character.shade, Paint()..color = const Color(0x12000000));

    final cut = Paint()..blendMode = BlendMode.clear;
    for (final eye in character.eyes) {
      final w = eye[2];
      final h = eye[3] * (1 - 0.85 * blink.clamp(0, 1));
      canvas.save();
      canvas.translate(eye[0], eye[1]);
      canvas.rotate(eye[4] * math.pi / 180);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: w, height: h), Radius.circular(math.min(w, h) / 2)),
        cut,
      );
      canvas.restore();
    }
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(CharacterPainter old) =>
      old.look.shape != look.shape || old.look.color != look.color || old.dark != dark || old.blink != blink;
}
