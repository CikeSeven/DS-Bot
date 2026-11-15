// What the phone shares with the desktop UI (themes, inks, characters, IM
// platforms), read from assets/shared/shared.json. tool/sync_shared.mjs writes
// that file from ds-bot/src/client, so the two stay in step.
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import '../data/json.dart';

class ThemeColors {
  ThemeColors(Json raw)
      : bg = parseHex(jStr(raw, 'bg')),
        sidebar = parseHex(jStr(raw, 'sidebar')),
        bubble = parseHex(jStr(raw, 'bubble')),
        card = parseHex(jStr(raw, 'card')),
        text = parseHex(jStr(raw, 'text')),
        user = parseHex(jStr(raw, 'user')),
        userText = parseHex(jStr(raw, 'userText')),
        accent = parseHex(jStr(raw, 'accent'));

  final Color bg;
  final Color sidebar;
  final Color bubble;
  final Color card;
  final Color text;
  final Color user;
  final Color userText;
  final Color accent;
}

class ThemeDef {
  ThemeDef(this.id, Json raw)
      : label = jStr(raw, 'label') ?? id,
        light = ThemeColors(jMap(raw, 'light') ?? const {}),
        dark = ThemeColors(jMap(raw, 'dark') ?? const {});

  final String id;
  final String label;
  final ThemeColors light;
  final ThemeColors dark;
}

class CharacterDef {
  CharacterDef(this.id, Json raw)
      : label = jStr(raw, 'label') ?? id,
        body = jStr(raw, 'body') ?? '',
        shade = jStr(raw, 'shade') ?? '',
        paints = jList(raw, 'paints')
            .whereType<List>()
            .map((paint) => (d: '${paint[0]}', fill: parseHex('${paint[1]}'), opacity: (paint[2] as num).toDouble()))
            .toList(),
        eyes = jList(raw, 'eyes')
            .whereType<List>()
            .map((eye) => eye.map((value) => (value as num).toDouble()).toList())
            .toList();

  final String id;
  final String label;
  final String body;
  final String shade;
  final List<({String d, Color fill, double opacity})> paints;

  /// Each eye is [cx, cy, width, height, tilt in degrees], in a 100-unit box.
  final List<List<double>> eyes;
}

class SharedData {
  SharedData(Json raw)
      : themes = {for (final entry in (jMap(raw, 'themes') ?? const {}).entries) entry.key: ThemeDef(entry.key, asJson(entry.value))},
        inks = {
          for (final entry in (jMap(raw, 'inks') ?? const {}).entries)
            entry.key: [for (final value in entry.value as List) parseHex('$value')],
        },
        gradients = {
          for (final entry in (jMap(raw, 'gradients') ?? const {}).entries)
            entry.key: [for (final stop in entry.value as List) (offset: ((stop as List)[0] as num).toDouble(), color: parseHex('${stop[1]}'))],
        },
        accentInks = jStrings(raw, 'accentInks'),
        characterColors = jStrings(raw, 'characterColors'),
        defaultColors = jStrings(raw, 'defaultColors'),
        defaultShapes = jStrings(raw, 'defaultShapes'),
        fallbackShape = jStr(raw, 'fallbackShape') ?? 'gumdrop',
        mainLook = jMap(raw, 'mainLook') ?? const {'shape': 'whale', 'color': 'deepseek'},
        characters = {
          for (final entry in (jMap(raw, 'characters') ?? const {}).entries) entry.key: CharacterDef(entry.key, asJson(entry.value)),
        },
        imPlatforms = jMaps(raw, 'imPlatforms');

  final Map<String, ThemeDef> themes;

  /// Inks for characters, names and mentions: [light, dark].
  final Map<String, List<Color>> inks;
  final Map<String, List<({double offset, Color color})>> gradients;
  final List<String> accentInks;
  final List<String> characterColors;
  final List<String> defaultColors;
  final List<String> defaultShapes;
  final String fallbackShape;
  final Json mainLook;
  final Map<String, CharacterDef> characters;
  final List<Json> imPlatforms;

  static SharedData? _instance;

  static SharedData get instance {
    final data = _instance;
    if (data == null) throw StateError('SharedData.load() has not run');
    return data;
  }

  static Future<SharedData> load([AssetBundle? bundle]) async {
    final text = await (bundle ?? rootBundle).loadString('assets/shared/shared.json');
    return _instance = SharedData(jsonDecode(text) as Json);
  }

  static SharedData fromJsonText(String text) => _instance = SharedData(jsonDecode(text) as Json);

  ThemeDef theme(String? id) => themes[id] ?? themes['deepseek'] ?? themes.values.first;

  /// A Bot's color the way names and marks resolve it: a named ink has a light
  /// and a dark value, a #rrggbb color is used as is, anything else is gray.
  Color ink(String? color, {required bool dark}) {
    final named = inks[color];
    if (named != null) return named[dark ? 1 : 0];
    if (color != null && isHex(color)) return parseHex(color);
    final gray = inks['gray'];
    return gray == null ? const Color(0xFF8A8F98) : gray[dark ? 1 : 0];
  }

  bool isColor(String? color) => color != null && (isHex(color) || inks.containsKey(color));
}

final _hex = RegExp(r'^#[0-9a-fA-F]{6}$');

bool isHex(String? value) => value != null && _hex.hasMatch(value);

Color parseHex(String? value) {
  if (value == null || !isHex(value)) return const Color(0xFF808080);
  return Color(0xFF000000 | int.parse(value.substring(1), radix: 16));
}

/// WCAG relative luminance of a color, as inks.js computes it.
double luminance(Color color) {
  double channel(double c) => c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b);
}
