import 'dart:io';

import 'package:dsbot_mobile/features/chat/work_row.dart';
import 'package:dsbot_mobile/shared/shared_data.dart';
import 'package:dsbot_mobile/ui/i18n.dart';
import 'package:dsbot_mobile/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() {
    SharedData.fromJsonText(File('assets/shared/shared.json').readAsStringSync());
    I18n.pref = LangPref.en;
  });

  group('workPhrase', () {
    test('gives the call its own description before the words of its step', () {
      expect(workPhrase({'tool': 'bash', 'note': 'Run the unit tests.', 'said': 'Let me check'}), 'Run the unit tests');
      expect(workPhrase({'tool': 'read_file', 'said': 'Looking at the config…'}), 'Looking at the config');
    });

    test('never names a tool or what it works on', () {
      expect(workPhrase({'tool': 'read_file', 'target': 'chat_page.dart'}), 'Working on it');
      expect(workPhrase({'tool': 'web_search', 'target': 'flutter'}), 'Working on it');
      expect(workPhrase(const <String, Object?>{}), 'Thinking it over');
      expect(workPhrase('thinking'), 'Thinking it over');
      expect(workPhrase('working'), 'Working on it');
    });

    test('still names a move to a fresh conversation', () {
      expect(workPhrase({'switching': true}), 'Moving to a fresh conversation');
      expect(workPhrase({'switching': true, 'folder': true}), 'Switching working folder');
    });
  });

  group('WorkRow', () {
    Future<void> show(WidgetTester tester, Object? doing) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Palette.of(dark: false)),
        home: Scaffold(body: Center(child: SizedBox(width: 360, child: WorkRow(key: const ValueKey('work'), bot: null, doing: doing)))),
      ));
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('keeps the steps it described earlier in the turn above the one in hand', (tester) async {
      await show(tester, {'since': 1, 'tool': 'bash', 'note': 'List the files'});
      expect(find.text('List the files'), findsOneWidget);

      await show(tester, {'since': 1, 'tool': 'read_file'});
      expect(find.text('Working on it'), findsOneWidget);
      expect(find.text('List the files'), findsOneWidget);

      for (final step in ['Run the tests', 'Fix the failing case', 'Run the tests again', 'Check the build']) {
        await show(tester, {'since': 1, 'tool': 'bash', 'note': step});
      }
      // Four done, three listed: the oldest folds into a count.
      expect(find.text('List the files'), findsNothing);
      expect(find.text('1 earlier'), findsOneWidget);
      expect(find.text('Run the tests again'), findsOneWidget);
      expect(find.text('Check the build'), findsOneWidget);

      await show(tester, {'since': 2, 'tool': 'bash', 'note': 'Start over'});
      expect(find.text('Run the tests again'), findsNothing);
      expect(find.textContaining('earlier'), findsNothing);
      expect(find.text('Start over'), findsOneWidget);
    });

    testWidgets('names no tool while it has no description', (tester) async {
      await show(tester, {'since': 1, 'tool': 'read_file', 'target': 'secret_plan.md'});
      expect(find.textContaining('secret_plan'), findsNothing);
      expect(find.textContaining('file'), findsNothing);
      expect(find.text('Working on it'), findsOneWidget);
    });
  });
}
