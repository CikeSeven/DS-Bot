// Helpers for the display items the computer sends for a chat (parts.js
// displayItems, mobile.js roomItems). Ports of the Expo app's src/screens/chat/settled.ts
// and the pure parts of items.tsx.
import 'dart:convert';

import '../ui/i18n.dart';
import 'json.dart';

/// Row keys that stay the same when older pages load above or new rows arrive
/// below. A row is named by its seq or time; rows that share one are told apart
/// by their order.
List<String> keysOf(List<Json> items) {
  final seen = <String, int>{};
  return [
    for (final item in items)
      () {
        final local = jStr(item, 'localId');
        final session = jStr(item, 'sessionId');
        final kind = jStr(item, 'kind') ?? '';
        final base = local != null
            ? 'local-$local'
            : '${session == null ? '' : '$session:'}$kind-${item['seq'] ?? item['time'] ?? (kind == 'steps' ? 't${item['turn'] ?? ''}' : '')}';
        final count = seen[base] ?? 0;
        seen[base] = count + 1;
        return count == 0 ? base : '$base#$count';
      }(),
  ];
}

bool samePushedRow(Json a, Json b) {
  if (a['sessionId'] != b['sessionId'] || a['kind'] != b['kind']) return false;
  final seq = jInt(a, 'seq');
  if (seq == null) return a['time'] == b['time'] && a['callId'] == b['callId'] && a['text'] == b['text'];
  if (seq != jInt(b, 'seq')) return false;
  final index = jInt(a, 'feedIndex');
  final otherIndex = jInt(b, 'feedIndex');
  return index != null && otherIndex != null ? index == otherIndex : a['text'] == b['text'];
}

/// A run of computer steps with nothing between them is one row: the card
/// lists the steps and their screenshots instead of a line per click. The run
/// keeps its first step's seq, so its row stays put as steps arrive.
List<Json> groupActs(List<Json> items) {
  final out = <Json>[];
  for (final item in items) {
    if (!_isComputerStep(item)) {
      out.add(item);
      continue;
    }
    final last = out.isEmpty ? null : out.last;
    if (last != null && last['sessionId'] == item['sessionId'] && jStr(last, 'act') == 'computer-run') {
      out[out.length - 1] = {...last, 'steps': [...jMaps(last, 'steps'), item]};
    } else {
      out.add({'kind': 'act', 'act': 'computer-run', 'sessionId': ?item['sessionId'], 'seq': ?item['seq'], 'turn': ?item['turn'], 'time': ?item['time'], 'steps': [item]});
    }
  }
  return out;
}

bool _isComputerStep(Json item) => jStr(item, 'kind') == 'act' && jStr(item, 'act') == 'computer';

/// A refreshed page reuses the item maps that did not change, so rows keep their
/// identity and only new or changed rows rebuild.
List<Json> keepSame(List<Json> prev, List<Json> next) {
  final prevKeys = keysOf(prev);
  final known = {for (final (index, item) in prev.indexed) prevKeys[index]: item};
  final nextKeys = keysOf(next);
  var same = prev.length == next.length;
  final merged = <Json>[];
  for (final (index, item) in next.indexed) {
    final old = known[nextKeys[index]];
    if (old != null && jsonEncode(old) == jsonEncode(item)) {
      if (index >= prev.length || !identical(prev[index], old)) same = false;
      merged.add(old);
    } else {
      same = false;
      merged.add(item);
    }
  }
  return same ? prev : merged;
}

final _longNote = RegExp(r'^\[A long message: \d+ characters\.[^\]\n]*\]\r?\n');

String stripLongNote(String text) => text.replaceFirst(_longNote, '');

/// Host previews frame card replies as "[Browser handoff] …" or "[Answer to
/// question card] …" for compaction context; the list shows the plain words.
String? cleanPreview(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final text = stripLongNote(raw).trim();
  final handoff = RegExp(r'^\[Browser handoff\]\s*([^\s—]+)(?:\s*—\s*(.+?))?\s+Answer:\s*\S+$', dotAll: true).firstMatch(text);
  if (handoff != null) {
    final title = handoffTitleOf(handoff[1]);
    return handoff[2] != null ? '$title · ${handoff[2]!.trim()}' : title;
  }
  final answer = RegExp(r'^\[Answer to question card\]\s*(.+?)\s+Answer:\s*(.+)$', dotAll: true).firstMatch(text);
  if (answer != null) return answer[2]!.trim() == '(skipped)' ? answer[1]!.trim() : answer[2]!.trim();
  final card = RegExp(r'^\[Question card\]\s*(.+?)(?:\s+Options:\s*.+)?$', dotAll: true).firstMatch(text);
  if (card != null) return card[1]!.trim();
  return text;
}

/// The chosen rows of an answered question, each with its option's letter; a
/// custom answer takes the letter after the last option.
List<({String label, String letter})> settledQuestionPicks(Json? question, Json? answer) {
  final options = jList(question, 'options').map((option) => option is String ? option : jStr(option, 'label') ?? '').toList();
  final selected = jStrings(answer, 'selected');
  final custom = (jStr(answer, 'custom') ?? '').trim();
  return [
    for (final (j, label) in selected.indexed)
      (label: label, letter: String.fromCharCode(65 + (options.contains(label) ? options.indexOf(label) : j))),
    if (custom.isNotEmpty) (label: custom, letter: String.fromCharCode(65 + options.length)),
  ];
}

String handoffTitleOf(String? reason) => switch (reason) {
      'sign-in' => t('Sign-in needed'),
      'verification' => t('Verification needed'),
      'confirmation' => t('Confirmation needed'),
      _ => t('Your turn in the browser'),
    };

String? roundEventText(String name, String? event, [String? text, String? code]) {
  switch (event) {
    case 'failed':
      return t('{name} could not answer: {reason}', {'name': name, 'reason': text ?? code ?? ''});
    case 'lookup':
      return text != null && text.isNotEmpty
          ? t('{name} looked up its own chat for “{text}”', {'name': name, 'text': text})
          : t('{name} looked up its own chat', {'name': name});
    case 'missed':
      return t("{name} didn't answer in time", {'name': name});
    case 'admin-passed':
      return t('{name} did not answer or call anyone; call a member with @Name', {'name': name});
    case 'resumed':
      return t('{name} was cut off by a restart and picked its work back up', {'name': name});
    case 'cut':
      return t('{name} was cut off by a restart again and stopped', {'name': name});
    case 'approval':
      return t('{name} paused for your approval', {'name': name});
    case 'working':
      return t('{name} started on it', {'name': name});
    case 'folder' || 'schedule':
      return text ?? '';
    case 'stopped':
      return t("You stopped {name}'s work", {'name': name});
    case 'done':
      return t('{name} finished its work', {'name': name});
    default:
      return null;
  }
}

String? relayReplyText(Json? reply) {
  if (reply == null) return null;
  final kind = jStr(reply, 'kind') ?? jStr(reply, 'event');
  final name = jStr(reply, 'name') ?? t('a Bot');
  if (kind == 'paused') {
    final joiner = t(' and ');
    final count = jInt(reply, 'count') ?? 0;
    return jBool(reply, 'idle') == true
        ? t('{names} went back and forth {count} times without progress and paused. Write here to go on',
            {'count': count, 'names': [name, ...jStrings(reply, 'names')].join(joiner)})
        : t('Paused after {count} Bot relays. Waiting: {names}', {'count': count, 'names': jStrings(reply, 'names').join(joiner)});
  }
  return roundEventText(name, kind, jStr(reply, 'text'), jStr(reply, 'code'));
}

/// As on the desktop, a run of one Bot's bubbles ends with the time of its last
/// one, and each user message carries its own.
String? stampOf(List<Json> items, int index) {
  final item = items[index];
  final time = jInt(item, 'time');
  if (time == null) return null;
  final kind = jStr(item, 'kind');
  if (kind == 'user') return messageClock(time);
  if (kind != 'bot' && kind != 'post') return null;
  if (index + 1 < items.length) {
    final next = items[index + 1];
    final nextKind = jStr(next, 'kind');
    if ((nextKind == 'bot' || nextKind == 'post') && (jStr(next, 'name') ?? '') == (jStr(item, 'name') ?? '')) return null;
  }
  return messageClock(time);
}

/// The text a long-press copies from a row.
String sourceTextOf(Json item) {
  final answers = jMaps(item, 'answers');
  if (item.containsKey('answers')) {
    return answers
        .map((answer) => [...jStrings(answer, 'selected'), if ((jStr(answer, 'custom') ?? '').isNotEmpty) jStr(answer, 'custom')!].join(', '))
        .join('\n');
  }
  return bodyTextsOf(item).join('\n\n');
}

/// A row's text parts: `texts` when the reply came in several bubbles.
List<String> bodyTextsOf(Json item) {
  final texts = jStrings(item, 'texts').where((entry) => entry.trim().isNotEmpty).toList();
  if (texts.isNotEmpty) return texts;
  final text = jStr(item, 'text') ?? '';
  if (text.isEmpty) return const [];
  final whole = wholeFileOf(item) != null;
  return [whole ? stripLongNote(text) : text];
}

/// The file that holds a long message in full, when the row shows only its start.
Json? wholeFileOf(Json item) {
  final file = jMap(item, 'file');
  if (jStr(file, 'attachmentId') != null) return file;
  final whole = jMap(jMap(item, 'whole'), 'file');
  if (jStr(whole, 'attachmentId') != null) return whole;
  return null;
}

// The note a computer adds for the model before an animated GIF's sheet of frames; an
// older computer leaves it in the message's text.
final _gifNote = RegExp(
    r'^This picture is an animated GIF, shown as \d+ of its \d+ frames in order: left to right, then top to bottom\.( The GIF itself is the file after it\.)?$');

String _sentText(String text) => text.split('\n').where((line) => !_gifNote.hasMatch(line.trim())).join('\n').trim();

/// The same message as the phone sent: the text the computer keeps (trimmed) and as many photos.
bool sameMessage(Json item, Json sent) {
  if (jStr(item, 'kind') != 'user') return false;
  if (_sentText(jStr(item, 'text') ?? '') != (jStr(sent, 'text') ?? '').trim()) return false;
  final photos = jList(item, 'imageRefs').isNotEmpty ? jList(item, 'imageRefs').length : (jInt(item, 'images') ?? 0);
  return photos == (jInt(sent, 'localImageCount') ?? 0);
}

/// What the warning before a recall says about the files the Bot changed after
/// the message (`recall-check`); empty when it changed none, and then nothing asks.
String recallWarning(Json check, String name) {
  final count = jInt(check, 'count') ?? 0;
  if (count == 1) return t('{name} changed a file after this message. Recalling leaves it as it is.', {'name': name});
  if (count > 1) return t('{name} changed {count} files after this message. Recalling leaves them as they are.', {'name': name, 'count': count});
  return jBool(check, 'maybe') == true ? t('{name} may have changed files after this message. Recalling leaves them as they are.', {'name': name}) : '';
}
