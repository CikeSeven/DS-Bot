import 'package:dsbot_mobile/api/link_client.dart';
import 'package:dsbot_mobile/data/pending.dart';
import 'package:dsbot_mobile/data/team_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_link.dart';

TeamSession session(FakeLinkClient Function() make, {Duration poll = const Duration(milliseconds: 80)}) {
  return TeamSession(
    computer: testComputer,
    identity: testIdentity,
    open: (computer, identity, {pairingCode}) async => make(),
    pollEvery: poll,
  );
}

/// A computer that is current and has an empty team; counts hellos.
FakeLinkClient current(void Function() onHello) => FakeLinkClient((endpoint, payload, state) {
      if (endpoint == 'hello') {
        onHello();
        return ok(hello());
      }
      if (endpoint == 'notices') return ok({'boot': 'b1', 'seq': 0, 'notices': []});
      return ok({'revision': 1, 'bots': []});
    });

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
    var liveVersion = 0;
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
      final liveKey = 'run:${++liveVersion}';
      if (!settled) return ok({...open, 'liveKey': liveKey});
      return ok({
        'revision': 10,
        'unchanged': true,
        'liveKey': liveKey,
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

  test('only a hello that answers without an api means an outdated computer', () async {
    var hellos = 0;
    var opens = 0;
    late FakeLinkClient link;
    final team = session(() {
      opens += 1;
      return link = FakeLinkClient((endpoint, payload, state) {
        if (endpoint == 'hello') {
          hellos += 1;
          if (hellos == 1) throw LinkError('RPC_TIMEOUT', 'The computer did not answer in time.');
          return ok(hellos == 2 ? {...hello(), 'api': null} : hello());
        }
        if (endpoint == 'notices') return ok({'boot': 'b1', 'seq': 0, 'notices': []});
        return ok({'revision': 1, 'bots': []});
      });
    }, poll: const Duration(milliseconds: 40))
      ..start();
    await settle(10);
    expect(errorCode(team.error), 'RPC_TIMEOUT', reason: 'a call lost in transit is not an old computer');
    await settle(60);
    expect(hellos, 2, reason: 'hello goes again while the link is up');
    expect(errorCode(team.error), 'link/outdated');
    expect(team.online, isFalse);
    expect(team.linked, isTrue);
    // The computer updates DS Bot and restarts: a new handshake, a new hello.
    link.renew();
    await settle();
    expect(team.online, isTrue);
    expect(team.error, isNull);
    expect(opens, 1, reason: 'the session never opens a second link');
    await team.stop();
  });

  test('a resumed link does not say hello again, a new handshake does', () async {
    var hellos = 0;
    late FakeLinkClient link;
    final team = session(() => link = current(() => hellos += 1), poll: const Duration(seconds: 30))..start();
    await settle();
    expect(team.online, isTrue);
    expect(hellos, 1);

    link.setStatus(const LinkStatus(LinkPhase.reconnecting));
    expect(team.online, isFalse);
    expect(team.reconnecting, isTrue);
    link.setStatus(const LinkStatus(LinkPhase.online, resumed: true));
    await settle();
    expect(team.online, isTrue);
    expect(hellos, 1);
    expect(link.calls.where((endpoint) => endpoint == 'state').length, greaterThan(1), reason: 'a state read is fine');

    link.renew();
    await settle();
    expect(team.online, isTrue);
    expect(hellos, 2);
    expect(link.calls.where((endpoint) => endpoint == 'notices').length, 2);
    await team.stop();
  });

  test('a new handshake accepts a fresh host state with a lower revision', () async {
    var revision = 12;
    final link = FakeLinkClient((endpoint, payload, state) => switch (endpoint) {
          'hello' => ok(hello()),
          'notices' => ok({'boot': 'b1', 'seq': 0, 'notices': []}),
          _ => ok({'revision': revision, 'bots': [{'id': 'chief', 'name': revision == 12 ? 'Before' : 'After'}]}),
        });
    final team = session(() => link, poll: const Duration(hours: 1))..start();
    addTearDown(team.dispose);
    await settle();
    expect(team.team!.bot('chief')!.name, 'Before');
    revision = 2;
    link.renew();
    await settle();
    expect(team.team!.bot('chief')!.name, 'After');
  });

  test('going to the background and back never strands the session', () async {
    var hellos = 0;
    var opens = 0;
    late FakeLinkClient link;
    final team = session(() {
      opens += 1;
      return link = current(() => hellos += 1);
    }, poll: const Duration(milliseconds: 40))
      ..start();
    await settle();
    expect(team.online, isTrue);

    team.setForeground(false);
    link.setStatus(const LinkStatus(LinkPhase.reconnecting));
    await settle(100);
    // The link comes back on its own, even in the background.
    link.setStatus(const LinkStatus(LinkPhase.online, resumed: true));
    await settle();
    expect(team.online, isTrue);
    team.setForeground(true);
    await settle();
    expect(team.online, isTrue);
    expect(link.foregrounds, [false, true]);
    expect(opens, 1);
    expect(hellos, 1);
    expect(await team.call('state'), isNotNull);
    await team.stop();
  });

  test('the computer being away is told apart from this phone reconnecting', () async {
    late FakeLinkClient link;
    final team = session(() => link = current(() {}), poll: const Duration(seconds: 30))..start();
    await settle();
    link.setStatus(const LinkStatus(LinkPhase.hostAway));
    expect(team.online, isFalse);
    expect(team.computerAway, isTrue);
    expect(team.reconnecting, isFalse);
    link.setStatus(const LinkStatus(LinkPhase.reconnecting));
    expect(team.computerAway, isFalse);
    expect(team.reconnecting, isTrue);
    team.networkChanged();
    expect(link.networkChanges, 1);
    await team.stop();
  });

  test('a phone the computer no longer accepts stops, and the team is cleared', () async {
    var opens = 0;
    late FakeLinkClient link;
    final team = session(() {
      opens += 1;
      return link = current(() {});
    }, poll: const Duration(milliseconds: 20))
      ..start();
    await settle();
    expect(team.team, isNotNull);
    link.setStatus(const LinkStatus(LinkPhase.rejected, code: 'NOT_PAIRED', message: 'not paired'));
    await settle(100);
    expect(opens, 1);
    expect(isRejected(team.error), isTrue);
    expect(team.team, isNull);
    expect(team.online, isFalse);
    await team.stop();
  });

  test('a link someone else closed is joined again', () async {
    final links = <FakeLinkClient>[];
    final team = session(() {
      final link = current(() {});
      links.add(link);
      return link;
    }, poll: const Duration(seconds: 30))
      ..start();
    await settle();
    links.single.setStatus(LinkStatus.closed);
    await settle();
    expect(links, hasLength(2));
    expect(team.online, isTrue);
    await team.stop();
    expect(links.last.closed, isTrue);
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
