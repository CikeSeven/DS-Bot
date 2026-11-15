// Small readers for the JSON the computer sends. Wrong or missing types read as
// absent, never as a crash: the phone skips what it does not understand.
typedef Json = Map<String, dynamic>;

String? jStr(Object? map, String key) {
  if (map is! Map) return null;
  final value = map[key];
  return value is String ? value : null;
}

num? jNum(Object? map, String key) {
  if (map is! Map) return null;
  final value = map[key];
  return value is num ? value : null;
}

int? jInt(Object? map, String key) => jNum(map, key)?.toInt();

bool? jBool(Object? map, String key) {
  if (map is! Map) return null;
  final value = map[key];
  return value is bool ? value : null;
}

Json? jMap(Object? map, String key) {
  if (map is! Map) return null;
  final value = map[key];
  return value is Map ? value.cast<String, dynamic>() : null;
}

List<Object?> jList(Object? map, String key) {
  if (map is! Map) return const [];
  final value = map[key];
  return value is List ? value : const [];
}

List<Json> jMaps(Object? map, String key) =>
    jList(map, key).whereType<Map>().map((entry) => entry.cast<String, dynamic>()).toList();

List<String> jStrings(Object? map, String key) => jList(map, key).whereType<String>().toList();

Json asJson(Object? value) => value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};
