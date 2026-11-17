import 'dart:io';

import 'package:dsbot_mobile/app/app_state.dart';
import 'package:dsbot_mobile/data/team_session.dart';
import 'package:dsbot_mobile/data/team_state.dart';
import 'package:dsbot_mobile/data/turn_failure.dart';
import 'package:dsbot_mobile/features/chat/failure_card.dart';
import 'package:dsbot_mobile/shared/shared_data.dart';
import 'package:dsbot_mobile/ui/i18n.dart';
import 'package:dsbot_mobile/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_link.dart';

Map<String, Object?> _team({Map<String, Object?>? blocked, bool working = false}) => {
      'revision': 1,
      'bots': [
        {'id': 'b-writer', 'name': 'Writer', 'sessionId': 's-writer', 'model': 'deepseek-official/deepseek-v4', 'blocked': ?blocked},
      ],
      'models': [
        {'ref': 'deepseek-official/deepseek-v4', 'provider': 'deepseek-official', 'providerName': 'DeepSeek'},
      ],
      'rooms': [],
      if (working) 'work': {'bots': {'b-writer': {'step': 'Thinking'}}},
    };

const _server = {'kind': 'failed', 'code': 'SERVER', 'status': 503, 'message': 'upstream busy', 'seq': 7, 'turn': 2, 'time': 1};

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

  test('a failure reads by its code, never by the provider message', () {
    expect(failureText('SERVER', name: 'Writer', provider: 'DeepSeek'), 'The model service failed.');
    expect(failureText('TIMEOUT', name: 'Writer', provider: 'DeepSeek'), 'Could not reach the model service.');
    expect(failureText('AUTH', name: 'Writer', provider: 'DeepSeek', status: 401), 'DeepSeek did not accept the current API key (401).');
    expect(failureText('INVALID_REQUEST', name: 'Writer', provider: 'DeepSeek'), 'The model service refused the request');
    expect(failureText('SOMETHING_NEW', name: 'Writer', provider: 'DeepSeek'), 'This turn failed.');
    expect(providerName(null, 'deepseek-account'), 'DeepSeek account');
    expect(providerName(null, null), 'The model service');
  });

  test('fixes and Retry follow the desktop card', () {
    expect(failureFixes('SERVER', provider: 'deepseek-official'), isEmpty);
    expect(failureFixes('AUTH', provider: 'acme'), [FailureFix.rekey, FailureFix.model]);
    // The account route never takes a key.
    expect(failureFixes('AUTH', provider: 'deepseek-account'), isEmpty);
    expect(failureFixes('QUOTA', provider: 'deepseek-official'), [FailureFix.topUp]);
    expect(failureFixes('QUOTA', provider: 'acme'), isEmpty);
    expect(retryShown('AUTH', {'code': 'AUTH'}), isFalse);
    expect(retryShown('AUTH', null), isTrue);
    expect(retryShown('SERVER', {'code': 'QUOTA'}), isTrue);
  });

  test('Technical details never show an AUTH message', () {
    final facts = failureFacts({'code': 'AUTH', 'status': 401, 'message': 'bad key', 'requestId': 'r-1'}, null);
    expect(facts.map((fact) => fact.$1), ['Code', 'HTTP status', 'Request ID']);
    expect(failureFacts(_server, null).map((fact) => fact.$3), ['SERVER', '503', 'upstream busy']);
  });

  testWidgets('the newest failure offers Retry, which resumes the Bot', (tester) async {
    final link = FakeLinkClient((endpoint, payload, state) async => switch (endpoint) {
          'hello' => ok(hello()),
          'notices' => ok({'boot': 'b1', 'seq': 0, 'notices': []}),
          'resume' => ok(true),
          _ => ok(_team()),
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

    await tester.pumpWidget(_host(FailureCard(item: _server, team: session.team!, botId: 'b-writer', latest: true, maxWidth: 340), session: session));
    expect(find.text('The model service failed.'), findsOneWidget);
    expect(find.text('upstream busy'), findsNothing);
    await tester.tap(find.text('Technical details'));
    await tester.pump();
    expect(find.text('upstream busy'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.text('Retrying…'), findsOneWidget);
    await tester.runAsync(() => settle());
    await tester.pump();
    expect(link.calls, contains('resume'));
    expect(find.text('Retrying…'), findsOneWidget);
    // Nothing came of it: Retry comes back.
    await tester.pump(const Duration(seconds: 11));
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a failure the chat moved past, or that something else handles, is a quiet line', (tester) async {
    Future<void> show(TeamState team, {Map<String, Object?> item = _server, bool latest = true}) =>
        tester.pumpWidget(_host(FailureCard(item: item, team: team, botId: 'b-writer', latest: latest, maxWidth: 340)));

    await show(TeamState(_team()), latest: false);
    expect(find.text('The model service failed.'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await tester.tap(find.text('The model service failed.'));
    await tester.pump();
    expect(find.text('503'), findsOneWidget);

    // The Bot is already at work again.
    await show(TeamState(_team(working: true)));
    expect(find.text('Retry'), findsNothing);

    // A turn another Bot asked for.
    await show(TeamState(_team()), item: {..._server, 'asked': true});
    expect(find.text('Retry'), findsNothing);

    // The key block's card above the message box has the fixes.
    const auth = {'kind': 'failed', 'code': 'AUTH', 'status': 401, 'seq': 3, 'turn': 1, 'time': 1};
    await show(TeamState(_team(blocked: {'code': 'AUTH', 'status': 401, 'provider': 'deepseek-official'})), item: auth);
    expect(find.text('DeepSeek did not accept the current API key (401).'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Enter the key again'), findsNothing);

    // Once the key changed the block lifts: Retry leads, the fixes follow.
    await show(TeamState(_team()), item: auth);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Enter the key again'), findsOneWidget);
  });
}
