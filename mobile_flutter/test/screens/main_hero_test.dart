import 'dart:io';

import 'package:dsbot_mobile/data/pending.dart';
import 'package:dsbot_mobile/data/team_state.dart';
import 'package:dsbot_mobile/features/team/main_hero.dart';
import 'package:dsbot_mobile/shared/shared_data.dart';
import 'package:dsbot_mobile/ui/i18n.dart';
import 'package:dsbot_mobile/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TeamState _team({
  Map<String, dynamic> chief = const {},
  Map<String, dynamic> work = const {},
  Map<String, dynamic> questions = const {},
  Map<String, dynamic> views = const {},
  List<String>? mains,
}) =>
    TeamState({
      'mainBotIds': mains ?? ['b-chief'],
      'bots': [
        {'id': 'b-chief', 'name': 'Chief', 'role': 'Runs the team', 'color': 'deepseek', 'avatar': {'shape': 'whale'}, 'sessionId': 's-chief', ...chief},
        {'id': 'b-coder', 'name': 'Coder', 'sessionId': 's-coder'},
      ],
      'rooms': [
        {'id': 'r-launch', 'name': 'Launch plan', 'members': ['b-chief', 'b-coder']},
      ],
      'models': [
        {'ref': 'deepseek-official/deepseek-v4.1', 'name': 'DeepSeek v4.1'},
      ],
      'defaultModel': 'deepseek-official/deepseek-v4.1',
      'work': work,
      'questions': questions,
      'views': views,
    });

void main() {
  setUpAll(() {
    SharedData.fromJsonText(File('assets/shared/shared.json').readAsStringSync());
    I18n.pref = LangPref.en;
  });

  Future<void> show(WidgetTester tester, TeamState team, {bool unread = false}) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Palette.of(dark: false)),
      home: Scaffold(body: ListView(children: [MainHero(team: team, pending: pendingItemsOf(team), unread: unread)])),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('shows the first Main Bot with its role, model and last message', (tester) async {
    final lastAt = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;
    await show(tester, _team(chief: {'preview': 'Here is the plan, in order', 'lastAt': lastAt}));
    expect(find.text('Chief'), findsOneWidget);
    expect(find.text('Runs the team · DeepSeek v4.1'), findsOneWidget);
    expect(find.text('Here is the plan, in order'), findsOneWidget);
    expect(find.text(' · ${shortWhen(lastAt)}'), findsOneWidget);
  });

  testWidgets('falls back to "Main Bot" without a role', (tester) async {
    await show(tester, _team(chief: {'role': null}));
    expect(find.text('Main Bot · DeepSeek v4.1'), findsOneWidget);
  });

  testWidgets('shows the step in hand, where, and for how long', (tester) async {
    final since = DateTime.now().subtract(const Duration(seconds: 75)).millisecondsSinceEpoch;
    await show(tester, _team(work: {
      'bots': {
        'b-chief': {'since': since, 'tool': 'bash', 'note': 'Run the unit tests', 'roomId': 'r-launch'},
      },
    }));
    expect(find.text('Launch plan · Run the unit tests'), findsOneWidget);
    expect(find.textContaining('Working for'), findsOneWidget);
  });

  testWidgets('puts a question for you before the work', (tester) async {
    await show(tester, _team(
      work: {
        'bots': {
          'b-chief': {'since': 1, 'tool': 'bash'},
        },
      },
      questions: {
        's-chief': {'question': 'Which one?'},
      },
    ));
    expect(find.text('Waiting for your answer'), findsOneWidget);
    expect(find.textContaining('Working for'), findsNothing);
  });

  testWidgets('puts anything else that waits for you before the last message', (tester) async {
    await show(tester, _team(
      chief: {'preview': 'Here is the plan, in order', 'lastAt': 1},
      views: {
        's-chief': {'id': 'v-1', 'title': 'Release readiness'},
      },
    ));
    expect(find.text('Card · Release readiness'), findsOneWidget);
    expect(find.text('Here is the plan, in order'), findsNothing);
  });

  testWidgets('shows nothing without a Main Bot', (tester) async {
    await show(tester, _team(mains: const []));
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('long-press offers the Main Bot actions, with Stop while it works', (tester) async {
    await show(tester, _team(work: {
      'bots': {
        'b-chief': {'since': 1, 'tool': 'bash'},
      },
    }), unread: true);
    await tester.longPress(find.text('Chief'));
    await tester.pump(const Duration(milliseconds: 600));
    for (final label in ['New conversation', 'Mark as read', 'Model', 'Details', 'Stop']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Hide'), findsNothing);
  });
}
