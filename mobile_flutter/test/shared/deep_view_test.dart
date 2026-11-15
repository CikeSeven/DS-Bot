// The Dart deep-view against cases tool/gen_deep_view_cases.mjs writes from the
// JavaScript package.
import 'dart:convert';
import 'dart:io';

import 'package:dsbot_mobile/shared/deep_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final data = jsonDecode(File('test/fixtures/deep_view_cases.json').readAsStringSync()) as Map<String, dynamic>;
  final inputs = (data['inputs'] as Map).cast<String, Object?>();
  final lookup = createScope(inputs, {
    'subtotal': compileFormula('price * qty').tree!,
    'loop': compileFormula('loop + 1').tree!,
  });

  test('formulas compile, evaluate and print like the JavaScript engine', () {
    for (final entry in (data['cases'] as List).cast<Map<String, dynamic>>()) {
      final source = entry['source'] as String;
      final compiled = compileFormula(source);
      if (entry.containsKey('error')) {
        expect(compiled.error, entry['error'], reason: source);
        continue;
      }
      expect(compiled.error, isNull, reason: source);
      expect(compiled.names.toSet(), (entry['names'] as List).cast<String>().toSet(), reason: source);
      final result = evaluate(compiled.tree!, lookup);
      if (entry.containsKey('evalError')) {
        expect(result.error, entry['evalError'], reason: source);
        continue;
      }
      expect(result.error, isNull, reason: source);
      expect(show(result.value), entry['shown'], reason: source);
      final want = entry['value'];
      if (want is num) {
        expect((result.value! as num).toDouble(), want.toDouble(), reason: source);
      } else if (want != null) {
        expect(result.value, want, reason: source);
      }
    }
  });

  test('answers are checked and worded like the computer does', () {
    final view = data['view'];
    for (final entry in (data['answerCases'] as List).cast<Map<String, dynamic>>()) {
      final checked = validateViewAnswer(view, entry['action'], entry['values']);
      final want = (entry['checked'] as Map).cast<String, Object?>();
      expect(jsonEncode(checked), jsonEncode(want), reason: '${entry['action']} ${entry['values']}');
      if (entry['text'] != null) {
        expect(viewAnswerText(view, {'action': entry['action'], 'values': checked}), entry['text'], reason: '${entry['action']}');
      }
    }
  });

  test('a view scope reads inputs, defaults and let names', () {
    final scope = viewScope(data['view'], {'qty': 5});
    for (final entry in (data['resolved'] as List).cast<Map<String, dynamic>>()) {
      final name = entry['name'] as String;
      if (entry.containsKey('error')) {
        expect(() => scope(name), throwsA(isA<FormulaError>().having((error) => error.message, 'message', entry['error'])), reason: name);
      } else {
        final got = scope(name);
        expect(got is num ? got.toDouble() : got, entry['value'] is num ? (entry['value'] as num).toDouble() : entry['value'], reason: name);
      }
    }
    expect(resolve({'=': 'qty * 2'}, scope), 10);
    expect(resolve({'=': 'nope +'}, scope, 'x'), 'x');
    expect(resolve('plain', scope), 'plain');
  });
}
