import 'dart:convert';
import 'dart:io';

import 'package:dsbot_mobile/shared/characters.dart';
import 'package:dsbot_mobile/shared/shared_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final data = SharedData.fromJsonText(File('assets/shared/shared.json').readAsStringSync());
  final cases = (jsonDecode(File('test/fixtures/character_cases.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();

  test('default looks match the desktop generator for every id', () {
    for (final entry in cases) {
      final id = entry['id'] as String;
      expect(fnv1a(id), entry['fnv1a'], reason: id);
      if (id.isNotEmpty) {
        expect(defaultColor(id, data), entry['color'], reason: id);
        expect(defaultShape(id, data), entry['shape'], reason: id);
      }
      final look = entry['look'] as Map<String, dynamic>;
      final got = id.isEmpty
          ? lookOf(data: data)
          : lookOf(id: id, shape: id == 'bot-1' ? 'whale' : null, color: id == 'x' ? '#123456' : null, data: data);
      expect(got.shape, look['shape'], reason: id);
      expect(got.color, look['color'], reason: id);
    }
  });

  test('all twenty characters parse and paint', () {
    expect(data.characters.length, 20);
    for (final id in data.characters.keys) {
      final painter = CharacterPainter(look: Look(shape: id, color: 'aurora'), dark: false, data: data);
      expect(painter.data.characters[id]!.eyes.length, 2, reason: id);
    }
  });

  test('inks and themes resolve like the desktop', () {
    expect(data.ink('deepseek', dark: false), parseHex('#4D6BFE'));
    expect(data.ink('deepseek', dark: true), parseHex('#6A84FF'));
    expect(data.ink('#123456', dark: true), parseHex('#123456'));
    expect(data.ink('nope', dark: false), parseHex('#8A8F98'));
    expect(data.theme('missing').id, 'deepseek');
    expect(luminance(parseHex('#ffffff')), closeTo(1, 1e-9));
  });
}
