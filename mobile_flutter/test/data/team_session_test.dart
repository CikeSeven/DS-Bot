import 'package:dsbot_mobile/api/link_client.dart';
import 'package:dsbot_mobile/data/pending.dart';
import 'package:dsbot_mobile/data/team_session.dart';
import 'package:dsbot_mobile/link/link.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_link.dart';

TeamSession session(FakeLinkClient Function() make, {Duration poll = const Duration(milliseconds: 80)}) {
  return TeamSession(
    computer: testComputer,
    identity: testIdentity,
    open: (computer, identity, {pairingCode}) async => make(),
    pollEvery: poll,
    retryAfter: const Duration(milliseconds: 40),
  );
}

void main() {
  test('polling keeps going after a transient error and settles pending items', () async {
    var phase = 0;
    final link = FakeLinkClient((endpoint, payload, state) {
      if (endpoint == 'hello') return ok(hello());
      if (endpoint == 'notices') return ok({'boot': 'b1', 'seq': 0, 'reset': false, 'notices': []});
      phase += 1;
      if (phase == 1) {
        return ok({
          'revision': 5,
          'bots': [
            {'id': 'b1', 'name': 'Chief', 'sessionId': 's1'},
          ],
          'questions': {
            's1': {'id': 'q1', 'question': 'Confirm?'},
          },
        });
      }
      if (phase == 2) return refuse('RPC_TIMEOUT', 'Transient relay timeout');
      return ok({
        'revision': 6,
        'bots': [
          {'id': 'b1', 'name': 'Chief', 'sessionId': 's1'},
        ],
        'questions': {},
      });
    });
    final team = session(() => link)..start();
    await settle();
    expect(pendingItemsOf(team.team).length, 1);
    expect(team.online, isTrue);
    await settle(100);
    expect(team.error, isA<BotError>());
    await settle(100);
    expect(pendingItemsOf(team.team), isEmpty);
    expect(team.error, isNull);
    await team.stop();
  });

  test('a write with no state in its reply still settles approvals and browser holds by polling', () async {
    var settled = false;
    final open = {
      'revision': 10,
      'liveKey': 'run:1',
      'bots': [
        {'id': 'b1', 'name': 'Chief', 'sessionId': 's1'},
      ],
      'browserHolds': {
        'b1': {'callId': 'hold-1', 'reason': 'verification', 'note': 'Log in'},
      },
      'work': {
        'approvals': [
          {'id': 'a1', 'sessionId': 's1', 'botId': 'b1', 'tool': 'bash', 'reason': 'test', 'answerable': true},
        ],
      },
    };
    final link = FakeLinkClient((endpoint, payload, state) {
      if (endpoint == 'hello') return ok(hello());
      if (endpoint == 'notices') return ok({'boot': 'b1', 'seq': 0, 'notices': []});
      if (endpoint == 'approval-answer') {
        settled = true;
        return ok(true);
      }
      if (!settled) return ok(open);
      return ok({
        'revision': 10,
        'unchanged': true,
        'liveKey': 'run:2',
        'browserHolds': {},
        'work': {'approvals': []},
      });
    });
    final team = session(() => link, poll: const Duration(seconds: 30))..start();
    await settle();
    expect(pendingItemsOf(team.team).length, 2);
    await team.call('approval-answer', {'id': 'a1', 'choice': 'allow'});
    await settle();
    expect(pendingItemsOf(team.team), isEmpty);
    expect(team.team!.bots.single.name, 'Chief');

    settled = false;
    link.emit('live', {});
    await settle();
    expect(pendingItemsOf(team.team).length, 2);
    settled = true;
    team.refresh();
    await settle();
    expect(pendingItemsOf(team.team), isEmpty);
    await team.stop();
  });

  test('an older poll never overwrites a newer write reply, and writes show at once', () async {
    final link = FakeLinkClient((endpoint, payload, state) async {
      if (endpoint == 'hello') return ok(hello());
      if (endpoint == 'notices') return ok({'boot': 'b1', 'seq': 0, 'notices': []});
      if (endpoint == 'update-bot') {
        await settle(60);
        return ok({'id': 'b1'}, {
          'revision': 3,
          'bots': [
            {'id': 'b1', 'name': 'Boss'},
          ],
        });
      }
      return ok({
        'revision': 2,
        'bots': [
          {'id': 'b1', 'name': 'Chief'},
        ],
      });
    });
    final team = session(() => link, poll: const Duration(seconds: 30))..start();
    await settle();
    final write = team.call('update-bot', {'id': 'b1', 'name': 'Boss'});
    await settle(10);
    expect(team.team!.bots.single.name, 'Boss');
    team.refresh();
    await settle(10);
    expect(team.team!.bots.single.name, 'Boss', reason: 'a read that lands mid-write keeps the guess');
    await write;
    team.refresh();
    await settle();
    expect(team.team!.revision, 3);
    expect(team.team!.bots.single.name, 'Boss');
    await team.stop();
  });

  test('a failed optimistic write snaps back to the computer state', () async {
    final link = FakeLinkClient((endpoint, payload, state) {
      if (endpoint == 'hello') return ok(hello());
      if (endpoint == 'notices') return ok({'boot': 'b1', 'seq': 0, 'notices': []});
      if (endpoint == 'update-bot') return refuse('bot/refused', 'No');
      return ok({
        'revision': 2,
        'bots': [
          {'id': 'b1', 'name': 'Chief'},
        ],
      });
    });
    final team = session(() => link, poll: const Duration(seconds: 30))..start();
    await settle();
    await expectLater(team.call('update-bot', {'id': 'b1', 'name': 'Boss'}), throwsA(isA<BotError>()));
    await settle();
    expect(team.team!.bots.single.name, 'Chief');
    await team.stop();
  });

  test('an outdated computer is reported and retried, and a dropped link reconnects', () async {
    var opens = 0;
    var api = 0;
    late FakeLinkClient current;
    final team = session(() {
      opens += 1;
      return current = FakeLinkClient((endpoint, payload, state) {
        if (endpoint == 'hello') {
          api += 1;
          return ok(api == 1 ? {...hello(), 'api': null} : hello());
        }
        if (endpoint == 'notices') return ok({'boot': 'b1', 'seq': 0, 'notices': []});
        return ok({'revision': 1, 'bots': []});
      });
    })
      ..start();
    await settle(20);
    expect((team.error as BotError?)?.code, 'link/outdated');
    await settle(120);
    expect(team.online, isTrue);
    expect(opens, 2);
    current.drop();
    expect(team.online, isFalse);
    await settle(120);
    expect(opens, 3);
    expect(team.online, isTrue);
    await team.stop();
  });

  test('a phone the computer no longer accepts stops retrying', () async {
    var opens = 0;
    final team = TeamSession(
      computer: testComputer,
      identity: testIdentity,
      open: (computer, identity, {pairingCode}) async {
        opens += 1;
        throw LinkError('NOT_PAIRED', 'not paired');
      },
      retryAfter: const Duration(milliseconds: 20),
    )..start();
    await settle(100);
    expect(opens, 1);
    expect(isRejected(team.error), isTrue);
    await team.stop();
  });

  test('missed notices replay into the feed and duplicates are dropped', () async {
    final link = FakeLinkClient((endpoint, payload, state) {
      if (endpoint == 'hello') return ok(hello(seq: 4));
      if (endpoint == 'notices') {
        return ok({
          'boot': 'b1',
          'seq': 5,
          'notices': [
            {'seq': 5, 'kind': 'question', 'botId': 'b1', 'text': 'Which?'},
          ],
        });
      }
      return ok({'revision': 1, 'bots': []});
    });
    final team = session(() => link, poll: const Duration(seconds: 30));
    final seen = <Object?>[];
    team.feed.listen((event) => seen.add(event.data));
    team.start();
    await settle();
    link.emit('notice', {'seq': 5, 'kind': 'question'});
    link.emit('notice', {'seq': 6, 'kind': 'approval'});
    await settle();
    expect(seen.map((entry) => (entry! as Map)['seq']).toList(), [5, 6]);
    await team.stop();
  });
}
