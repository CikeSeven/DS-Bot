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
    test('gives the call its own description first', () {
      expect(workPhrase({'tool': 'bash', 'note': 'Run the unit tests.', 'said': 'Let me check', 'target': 'src'}), 'Run the unit tests');
    });

    test('words a call without a description by what its tool does, with what it works on', () {
      expect(workPhrase({'tool': 'web_search', 'target': 'flutter shimmer', 'said': 'Let me look it up'}), 'Searching online · flutter shimmer');
      expect(workPhrase({'tool': 'web_fetch', 'target': 'docs.flutter.dev'}), 'Reading a page · docs.flutter.dev');
      expect(workPhrase({'tool': 'read', 'target': 'chat_page.dart'}), 'Opening a file · chat_page.dart');
      expect(workPhrase({'tool': 'grep'}), 'Looking through files');
      expect(workPhrase({'tool': 'todo_write'}), 'Updating the to-do list');
      expect(workPhrase({'tool': 'message_bot'}), 'Asking another Bot');
    });

    test('falls back to the words of the step, then to a plain phrase, for a tool it cannot read', () {
      expect(workPhrase({'tool': 'mcp__notion__query', 'said': 'Looking at the board…'}), 'Looking at the board');
      expect(workPhrase({'tool': 'mcp__notion__query'}), 'Working on it');
    });

    test('is thinking between calls', () {
      expect(workPhrase({'since': 1}), 'Thinking it over');
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

    testWidgets('keeps the steps done earlier in the turn above the one in hand', (tester) async {
      await show(tester, {'since': 1, 'tool': 'bash', 'note': 'List the files'});
      expect(find.text('List the files'), findsOneWidget);

      await show(tester, {'since': 1, 'tool': 'web_search', 'target': 'flutter shimmer'});
      expect(find.text('Searching online · flutter shimmer'), findsOneWidget);
      expect(find.text('List the files'), findsOneWidget);

      for (final step in ['Run the tests', 'Fix the failing case', 'Check the build']) {
        await show(tester, {'since': 1, 'tool': 'bash', 'note': step});
      }
      // Four done, three listed: the oldest folds into a count.
      expect(find.text('List the files'), findsNothing);
      expect(find.text('1 earlier'), findsOneWidget);
      expect(find.text('Searching online · flutter shimmer'), findsOneWidget);
      expect(find.text('Check the build'), findsOneWidget);

      await show(tester, {'since': 2, 'tool': 'bash', 'note': 'Start over'});
      expect(find.text('Fix the failing case'), findsNothing);
      expect(find.textContaining('earlier'), findsNothing);
      expect(find.text('Start over'), findsOneWidget);
    });

    testWidgets('a call that ends at once stays up a moment before the Bot is shown thinking', (tester) async {
      await show(tester, {'since': 1, 'call': 'k1', 'tool': 'read', 'target': 'notes.md'});
      expect(find.text('Opening a file · notes.md'), findsOneWidget);

      await show(tester, {'since': 1});
      expect(find.text('Thinking it over'), findsNothing);
      expect(find.text('Opening a file · notes.md'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Thinking it over'), findsOneWidget);
      // The call it just made is listed as done above.
      expect(find.text('Opening a file · notes.md'), findsOneWidget);
    });

    testWidgets('a next call takes over at once, even while the last one is held', (tester) async {
      await show(tester, {'since': 1, 'call': 'k1', 'tool': 'read', 'target': 'notes.md'});
      await show(tester, {'since': 1});
      await show(tester, {'since': 1, 'call': 'k2', 'tool': 'bash', 'note': 'Run the tests'});
      expect(find.text('Run the tests'), findsOneWidget);
      expect(find.text('Opening a file · notes.md'), findsOneWidget);
      expect(find.text('Thinking it over'), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Run the tests'), findsOneWidget);
    });

    testWidgets('a call the model is still writing stays one step as its path comes in', (tester) async {
      await show(tester, {'since': 1, 'call': 'k1', 'tool': 'write'});
      expect(find.text('Writing changes'), findsOneWidget);

      await show(tester, {'since': 1, 'call': 'k1', 'tool': 'write', 'target': 'notes.md'});
      expect(find.text('Writing changes · notes.md'), findsOneWidget);
      expect(find.text('Writing changes'), findsNothing);
    });
  });
}
