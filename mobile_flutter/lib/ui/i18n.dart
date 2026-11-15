// Interface copy. English is the key, as on the desktop. Chinese comes from the
// desktop dictionary, then the RN app's phone-only entries, then this app's own
// entries (app_zh.dart). assets/i18n/zh.json is written by tool/sync_shared.mjs.
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';

import 'app_zh.dart';

enum LangPref { system, zh, en }

class I18n {
  static Map<String, String> _desktop = const {};
  static Map<String, String> _mobile = const {};
  static Set<String> _mobileSense = const {};
  static List<(RegExp, String)> _hostErrors = const [];
  static LangPref pref = LangPref.system;

  static Future<void> load([AssetBundle? bundle]) async {
    loadText(await (bundle ?? rootBundle).loadString('assets/i18n/zh.json'));
  }

  static void loadText(String text) {
    final raw = jsonDecode(text) as Map<String, dynamic>;
    _desktop = (raw['desktop'] as Map).cast<String, String>();
    _mobile = (raw['mobile'] as Map).cast<String, String>();
    _mobileSense = (raw['mobileSense'] as List).cast<String>().toSet();
    _hostErrors = [
      for (final entry in raw['hostErrors'] as List) (RegExp((entry as List)[0] as String), entry[1] as String),
    ];
  }

  static bool get systemZh => PlatformDispatcher.instance.locale.languageCode.toLowerCase() == 'zh';

  static bool get zh => pref == LangPref.zh || (pref == LangPref.system && systemZh);
}

final _placeholder = RegExp(r'\{(\w+)\}');
final _hanLatin = RegExp(r'([一-鿿])([A-Za-z0-9])');
final _latinHan = RegExp(r'([A-Za-z0-9])([一-鿿])');

String _fill(String text, Map<String, Object?>? params) {
  if (params == null) return text;
  return text.replaceAllMapped(_placeholder, (match) {
    final value = params[match[1]];
    return value == null ? match[0]! : '$value';
  });
}

/// The desktop gets a gap between Han characters and Latin letters or digits
/// from CSS text-autospace; here the composed string gets the space.
String autospace(String text) =>
    text.replaceAllMapped(_hanLatin, (m) => '${m[1]} ${m[2]}').replaceAllMapped(_latinHan, (m) => '${m[1]} ${m[2]}');

String t(String key, [Map<String, Object?>? params]) {
  if (!I18n.zh) return _fill(key, params);
  final text = (I18n._mobileSense.contains(key) ? I18n._mobile[key] : null) ??
      appZh[key] ??
      I18n._desktop[key] ??
      I18n._mobile[key] ??
      key;
  return autospace(_fill(text, params));
}

/// A message from the computer, in the interface language.
String hostText(String message) {
  if (!I18n.zh) return message;
  final direct = appZh[message] ?? I18n._desktop[message] ?? I18n._mobile[message];
  if (direct != null) return autospace(direct);
  for (final (pattern, template) in I18n._hostErrors) {
    final match = pattern.firstMatch(message);
    if (match == null) continue;
    return autospace(message.replaceFirstMapped(pattern, (m) {
      return template.replaceAllMapped(RegExp(r'\$(\d)'), (ref) => m.group(int.parse(ref[1]!)) ?? '');
    }));
  }
  return message;
}

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _weekZh = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
const _weekEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _isoWeekZh = ['一', '二', '三', '四', '五', '六', '日'];

String _pad(int n) => n.toString().padLeft(2, '0');

String _clock(DateTime d) => '${d.hour}:${_pad(d.minute)}';

int _daysBefore(DateTime time, DateTime now) =>
    DateTime(now.year, now.month, now.day).difference(DateTime(time.year, time.month, time.day)).inHours ~/ 24;

DateTime _at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

String dayLabel(int ms) {
  final d = _at(ms);
  return I18n.zh ? '${d.month}月${d.day}日' : '${_months[d.month - 1]} ${d.day}';
}

String timeLabel(int ms) {
  final d = _at(ms);
  return '${dayLabel(ms)} ${_pad(d.hour)}:${_pad(d.minute)}';
}

/// ISO weekday 1 (Monday) to 7 (Sunday).
String weekdayShort(int day) => day < 1 || day > 7 ? '$day' : (I18n.zh ? _isoWeekZh[day - 1] : _weekEn[day - 1]);

String clockLabel(int ms, [int? nowMs]) {
  final time = _at(ms);
  final now = _at(nowMs ?? DateTime.now().millisecondsSinceEpoch);
  final days = _daysBefore(time, now);
  if (days == 0) return t('Today {time}', {'time': _clock(time)});
  if (days == 1) return t('Yesterday {time}', {'time': _clock(time)});
  final sameYear = time.year == now.year;
  if (I18n.zh) return '${sameYear ? '' : '${time.year}年'}${time.month}月${time.day}日 ${_weekZh[time.weekday - 1]} ${_clock(time)}';
  return '${_weekEn[time.weekday - 1]}, ${_months[time.month - 1].substring(0, 3)} ${time.day}${sameYear ? '' : ', ${time.year}'} ${_clock(time)}';
}

String messageClock(int ms, [int? nowMs]) {
  final now = _at(nowMs ?? DateTime.now().millisecondsSinceEpoch);
  return _daysBefore(_at(ms), now) == 0 ? _clock(_at(ms)) : clockLabel(ms, nowMs);
}

/// A short relative time for lists: "now", "5m", "3h", a weekday or a date.
String shortWhen(int ms, [int? nowMs]) {
  final now = _at(nowMs ?? DateTime.now().millisecondsSinceEpoch);
  final time = _at(ms);
  final minutes = now.difference(time).inMinutes;
  if (minutes < 1) return t('now');
  final days = _daysBefore(time, now);
  if (days == 0) return _clock(time);
  if (days == 1) return t('Yesterday');
  if (days < 7) return I18n.zh ? _weekZh[time.weekday - 1] : _weekEn[time.weekday - 1];
  return I18n.zh ? '${time.month}/${time.day}' : '${time.month}/${time.day}';
}

const _toolPhrases = [
  (r'web_?search|search_?web', 'Searching online'),
  (r'fetch|browse|browser|web', 'Reading a page'),
  (r'shell|bash|pwsh|powershell|exec|command|terminal', 'Running shell commands'),
  (r'^(read|view|cat)\b|read_', 'Opening a file'),
  (r'write|edit|patch|create_file', 'Writing a file'),
  (r'recall|memory|remember', 'Checking memory'),
];

/// What a Bot is doing, worded like the desktop's workPhrase (cells.js).
String workPhrase(Object? doing) {
  final map = doing is Map ? doing : (doing is String ? {'tool': doing} : const {});
  if (map['switching'] == true) return map['folder'] == true ? t('Switching working folder') : t('Moving to a fresh conversation');
  final said = map['said'] is String && (map['said'] as String).isNotEmpty ? map['said'] as String : map['note'] as String?;
  final own = said?.replaceAll(RegExp(r'[\s.。…]+$'), '');
  if (own != null && own.isNotEmpty) return own;
  final tool = map['tool'];
  if (tool is! String || tool.isEmpty) return t('Thinking about it');
  String? matched;
  for (final (pattern, phrase) in _toolPhrases) {
    if (RegExp(pattern, caseSensitive: false).hasMatch(tool)) {
      matched = phrase;
      break;
    }
  }
  final label = t(matched ?? 'On it');
  final target = map['target'];
  return target is String && target.isNotEmpty ? '$label · $target' : label;
}
