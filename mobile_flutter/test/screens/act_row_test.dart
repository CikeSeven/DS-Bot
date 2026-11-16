import 'dart:io';

import 'package:dsbot_mobile/app/app_state.dart';
import 'package:dsbot_mobile/data/chat_items.dart';
import 'package:dsbot_mobile/data/team_session.dart';
import 'package:dsbot_mobile/data/team_state.dart';
import 'package:dsbot_mobile/features/chat/act_row.dart';
import 'package:dsbot_mobile/features/chat/exchange_page.dart';
import 'package:dsbot_mobile/shared/shared_data.dart';
import 'package:dsbot_mobile/ui/i18n.dart';
import 'package:dsbot_mobile/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_link.dart';

const _teamRaw = <String, Object?>{
  'revision': 1,
  'bots': [
    {'id': 'b-chief', 'name': 'Chief', 'sessionId': 's-chief'},
    {'id': 'b-writer', 'name': 'Writer', 'sessionId': 's-writer'},
  ],
  'rooms': [
    {
      'id': 'r-launch',
      'name': 'Launch',
      'members': ['b-chief', 'b-writer'],
    },
  ],
};

Map<String, Object?> _step(int seq, String method, {String state = 'done'}) =>
    {'kind': 'act', 'act': 'computer', 'state': state, 'method': method, 'app': 'Notes', 'seq': seq, 'time': 1};

Widget _host(Widget child, {TeamSession? session}) {
  final app = MaterialApp(
    theme: buildTheme(Palette.of(dark: false)),
    home: Scaffold(body: Center(child: SizedBox(width: 380, child: child))),
  );
  return session == null ? app : TeamScope(session: session, child: app);
}

void main() {
  setUpAll(() {
    SharedData.fromJsonText(File('assets/shared/shared.json').readAsStringSync());
    I18n.pref = LangPref.en;
  });

  test('a run of computer steps folds into one row that keeps its first seq', () {
    final rows = groupActs([
      {'kind': 'bot', 'text': 'On it', 'seq': 1},
      _step(2, 'click'),
      _step(3, 'typeText'),
      {'kind': 'act', 'act': 'message', 'seq': 4},
      _step(5, 'screenshot'),
    ]);
    expect(rows.map((row) => row['act'] ?? row['kind']), ['bot', 'computer-run', 'message', 'computer-run']);
    expect((rows[1]['steps']! as List).length, 2);
    expect(keysOf(rows)[1], 'act-2');
  });

  test('a computer step reads as its action', () {
    expect(actionName('typeText'), 'Type text');
    expect(actionName('getApp'), 'Open app');
    expect(actionName('moveWindowTo'), 'Move window to');
    expect(actionName(null), 'Computer');
  });

  testWidgets('team actions read as the desktop lines, and a failure says so', (tester) async {
    final team = TeamState(_teamRaw);
    Future<void> show(Map<String, Object?> item) =>
        tester.pumpWidget(_host(ActRow(item: {'kind': 'act', 'seq': 1, 'time': 1, ...item}, team: team, sessionId: 's-chief', maxWidth: 340)));

    await show({'act': 'create-bot', 'state': 'done', 'bot': {'id': 'b-writer', 'name': 'Writer'}});
    expect(find.text('Created'), findsOneWidget);
    expect(find.text('Writer'), findsOneWidget);

    await show({'act': 'read-group', 'state': 'done', 'room': {'id': 'r-launch', 'name': 'Launch'}});
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Launch'), findsOneWidget);

    await show({'act': 'memory', 'tool': 'remember', 'state': 'done', 'outcome': 'saved', 'whose': 'bot', 'bot': {'id': 'b-writer', 'name': 'Writer'}, 'open': {'botId': 'b-writer'}});
    expect(find.text("Updated Writer's memory"), findsOneWidget);

    await show({'act': 'memory', 'tool': 'forget', 'state': 'failed', 'outcome': 'failed', 'code': 'memory/no-match'});
    expect(find.text("Couldn't remove from memory · No saved entry matched"), findsOneWidget);

    await show({'act': 'group', 'verb': 'created', 'state': 'failed'});
    expect(find.text("Couldn't create the group"), findsOneWidget);
  });

  testWidgets('a computer run lists its latest steps and opens to all of them', (tester) async {
    final run = groupActs([_step(10, 'click'), _step(11, 'typeText'), _step(12, 'scroll'), _step(13, 'pressKey'), _step(14, 'screenshot')]).single;
    await tester.pumpWidget(_host(ActRow(item: run, team: TeamState(_teamRaw), sessionId: 's-chief', maxWidth: 340)));
    expect(find.textContaining('Used the computer · Notes', findRichText: true), findsOneWidget);
    expect(find.text('5 steps'), findsOneWidget);
    expect(find.text('2 earlier steps'), findsOneWidget);
    expect(find.text('Click'), findsNothing);
    expect(find.text('Screenshot'), findsOneWidget);

    await tester.tap(find.text('5 steps'));
    await tester.pumpAndSettle();
    expect(find.text('Click'), findsOneWidget);
    expect(find.text('Type text'), findsOneWidget);
    expect(find.textContaining('earlier'), findsNothing);
  });

  testWidgets('a message line opens the two Bots’ exchange', (tester) async {
    final link = FakeLinkClient((endpoint, payload, state) async => switch (endpoint) {
          'hello' => ok(hello()),
          'notices' => ok({'boot': 'b1', 'seq': 0, 'notices': []}),
          'exchange' => ok([
              {'id': 'e1', 'from': payload['a'], 'to': payload['b'], 'text': 'Draft the launch post', 'time': 1000},
            ]),
          _ => ok(_teamRaw),
        });
    final session = TeamSession(
      computer: testComputer,
      identity: testIdentity,
      open: (computer, identity, {pairingCode}) async => link,
      pollEvery: const Duration(hours: 1),
    );
    await tester.runAsync(() async {
      session.start();
      await settle();
    });
    addTearDown(session.dispose);

    final item = {'kind': 'act', 'act': 'message', 'state': 'done', 'seq': 4, 'time': 1, 'from': 'b-chief', 'bot': {'id': 'b-writer', 'name': 'Writer'}};
    await tester.pumpWidget(_host(ActRow(item: item, team: session.team!, sessionId: 's-chief', maxWidth: 340), session: session));
    expect(find.text('Messaged'), findsOneWidget);

    await tester.tap(find.text('Writer'));
    await tester.pumpAndSettle();
    expect(find.byType(ExchangePage), findsOneWidget);
    await tester.runAsync(() => settle());
    await tester.pump();
    expect(link.calls, contains('exchange'));
    expect(find.textContaining('Draft the launch post', findRichText: true), findsOneWidget);
  });
}
