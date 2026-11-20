import 'dart:async';

import 'package:dsbot_mobile/data/chat_items.dart';
import 'package:dsbot_mobile/data/chat_session.dart';
import 'package:dsbot_mobile/data/seen.dart';
import 'package:dsbot_mobile/data/store.dart';
import 'package:dsbot_mobile/data/team_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_link.dart';

/// A computer with one Bot whose chat holds [items]; `send` waits for [gate].
class _Desk {
  _Desk(String botId, {this.echo = true}) {
    link = FakeLinkClient((endpoint, payload, state) async {
      switch (endpoint) {
        case 'hello':
          return ok(hello());
        case 'notices':
          return ok({'boot': 'b1', 'seq': 0, 'notices': []});
        case 'chat':
          return ok({'sessionId': 's-$botId', 'items': [...items], 'cursor': null});
        case 'send':
          // The real computer tells of the message before `send` answers.
          if (echo) add(botId, '${payload['text']}');
          await gate.future;
          return ok(true);
        default:
          return ok({
            'revision': 1,
            'bots': [
              {'id': botId, 'name': 'Chief', 'sessionId': 's-$botId'},
            ],
          });
      }
    });
  }

  final bool echo;
  late final FakeLinkClient link;
  final items = <Map<String, Object?>>[
    {'kind': 'bot', 'text': 'Hello', 'seq': 1, 'time': 1000},
  ];
  final gate = Completer<void>();

  void add(String botId, String text) {
    final item = {'kind': 'user', 'text': text, 'seq': items.length + 1, 'time': 1000 + items.length};
    items.add(item);
    link.emit('message', {'botId': botId, 'sessionId': 's-$botId', 'item': item});
  }
}

Future<ChatSession> _open(_Desk desk, String botId) async {
  final team = TeamSession(
    computer: testComputer,
    identity: testIdentity,
    open: (computer, identity, {pairingCode}) async => desk.link,
    pollEvery: const Duration(hours: 1),
  )..start();
  addTearDown(team.dispose);
  await settle();
  final chat = ChatSession(team: team, hostId: 'd-host', room: false, id: botId, seen: SeenStore(MemoryStore()), pollEvery: const Duration(hours: 1))..start();
  addTearDown(chat.dispose);
  await settle();
  return chat;
}

List<({String text, bool local})> _users(ChatSession chat) =>
    [for (final row in chat.rows.where((row) => row.kind == 'user')) (text: '${row.item['text']}', local: row.local)];

void main() {
  test('a pushed reply updates the list and is visible before a cold chat read answers', () async {
    final gate = Completer<Map<String, Object?>>();
    const bot = {
      'id': 'cold',
      'sessionId': 's-cold',
      'lastAt': 1000,
      'preview': 'Old preview',
    };
    const reply = {'kind': 'bot', 'seq': 8, 'time': 1008, 'text': 'New reply'};
    final link = FakeLinkClient((endpoint, payload, state) => switch (endpoint) {
          'hello' => ok(hello()),
          'notices' => ok({'boot': 'b1', 'seq': 0, 'notices': []}),
          'chat' => gate.future,
          _ => ok({'revision': 1, 'bots': [bot]}),
        });
    final team = TeamSession(computer: testComputer, identity: testIdentity, open: (c, i, {pairingCode}) async => link)..start();
    addTearDown(team.dispose);
    await settle();
    link.emit('message', {'botId': 'cold', 'sessionId': 's-cold', 'item': reply, 'index': 0});
    team.refresh();
    await settle();
    expect(team.team!.bot('cold')!.preview, 'New reply');
    expect(team.team!.bot('cold')!.lastAt, 1008);
    expect(link.calls, isNot(contains('chat')));

    final chat = ChatSession(team: team, hostId: 'd-host', room: false, id: 'cold', seen: SeenStore(MemoryStore()))..start();
    addTearDown(chat.dispose);
    expect(chat.loaded, isTrue);
    expect(chat.rows.single.item['text'], 'New reply');
    gate.complete(ok({'sessionId': 's-cold', 'firstSeq': 1, 'lastSeq': 7, 'items': [
      {'kind': 'bot', 'seq': 7, 'time': 1007, 'text': 'Previous reply'},
    ]}));
    await settle();
    expect(chat.rows.map((row) => row.item['text']), ['Previous reply', 'New reply']);
  });

  test('rollover fills a missed page and keeps older rows and session-specific keys', () async {
    var current = 'old';
    const old = {'kind': 'bot', 'seq': 3, 'time': 1003, 'text': 'Old reply'};
    const older = {'kind': 'bot', 'seq': 1, 'time': 1001, 'text': 'Earlier reply'};
    const late = {'kind': 'bot', 'seq': 4, 'time': 1004, 'text': 'Missed reply'};
    const fresh = {'kind': 'bot', 'seq': 3, 'time': 2003, 'text': 'New part reply'};
    final link = FakeLinkClient((endpoint, payload, state) {
      switch (endpoint) {
        case 'hello':
          return ok(hello());
        case 'notices':
          return ok({'boot': 'b1', 'seq': 0, 'notices': []});
        case 'state':
          return ok({'revision': current == 'old' ? 1 : 2, 'bots': [
            {'id': 'rotation', 'sessionId': current, 'parts': current == 'old' ? [] : ['old']},
          ]});
        case 'chat':
          return ok({
            'sessionId': current,
            ...switch (payload['cursor']) {
              {'beforeSeq': 3} => {'partSessionId': 'old', 'firstSeq': 1, 'lastSeq': 2, 'items': [older]},
              {'part': 0} => {'partSessionId': 'old', 'firstSeq': 3, 'lastSeq': 4, 'items': [old, late], 'cursor': {'part': 0, 'beforeSeq': 3}},
              _ when current == 'old' => {'firstSeq': 3, 'lastSeq': 3, 'items': [old], 'cursor': {'part': 0, 'beforeSeq': 3}},
              _ => {'firstSeq': 1, 'lastSeq': 3, 'items': [
                {'kind': 'divider', 'time': 2000},
                fresh,
              ], 'cursor': {'part': 0}},
            },
          });
      }
      return refuse('bot/invalid', endpoint);
    });
    final team = TeamSession(computer: testComputer, identity: testIdentity, open: (c, i, {pairingCode}) async => link)..start();
    addTearDown(team.dispose);
    await settle();
    final chat = ChatSession(team: team, hostId: 'd-host', room: false, id: 'rotation', seen: SeenStore(MemoryStore()))..start();
    addTearDown(chat.dispose);
    await settle();
    await chat.loadMore();
    final oldKey = chat.rows.last.key;
    current = 'new';
    link.emit('message', {'botId': 'rotation', 'sessionId': 'new', 'item': fresh});
    link.emit('revision', {'revision': 2});
    await settle();
    expect(chat.rows.map((row) => row.item['text']), ['Earlier reply', 'Old reply', 'Missed reply', null, 'New part reply']);
    expect(chat.rows[1].key, oldKey);
    expect(chat.rows.last.key, isNot(oldKey));
    expect(chat.rows[1].item['sessionId'], 'old');
    expect(chat.sessionId, 'new');
    expect(chat.hasMore, isFalse);
  });

  test('a sent message shows once when the computer echoes it before send answers', () async {
    final desk = _Desk('echo');
    final chat = await _open(desk, 'echo');
    chat.send('hi');
    expect(_users(chat), [(text: 'hi', local: true)]);
    await settle();
    expect(_users(chat), [(text: 'hi', local: false)]);
    desk.gate.complete();
    await settle();
    expect(_users(chat), [(text: 'hi', local: false)]);
  });

  test('the same text sent twice waits for two rows', () async {
    final desk = _Desk('twice', echo: false);
    final chat = await _open(desk, 'twice');
    chat.send('ok');
    chat.send('ok');
    expect(_users(chat), [(text: 'ok', local: true), (text: 'ok', local: true)]);
    desk.add('twice', 'ok');
    await settle();
    expect(_users(chat), [(text: 'ok', local: false), (text: 'ok', local: true)]);
    await chat.refresh();
    expect(_users(chat), [(text: 'ok', local: false), (text: 'ok', local: true)]);
    desk.add('twice', 'ok');
    await settle();
    expect(_users(chat), [(text: 'ok', local: false), (text: 'ok', local: false)]);
    desk.gate.complete();
  });

  test('a recall on the computer reloads the chat with one line where the message was', () async {
    final desk = _Desk('recall', echo: false);
    desk.items.addAll([
      {'kind': 'user', 'text': 'take this back', 'seq': 2, 'time': 1001},
      {'kind': 'bot', 'text': 'an answer to it', 'seq': 3, 'time': 1002},
    ]);
    final chat = await _open(desk, 'recall');
    expect(chat.rows.map((row) => row.kind), ['bot', 'user', 'bot']);
    desk.items
      ..removeRange(1, 3)
      ..add({'kind': 'recalled', 'seq': 2, 'time': 1001});
    desk.link.emit('recall', {'botId': 'recall', 'sessionId': 's-recall', 'seq': 2, 'until': 9});
    await settle();
    expect(chat.rows.map((row) => row.kind), ['bot', 'recalled']);
    desk.gate.complete();
  });

  test('a sent GIF settles on a row whose text still holds the note an older computer kept', () {
    const note = 'This picture is an animated GIF, shown as 4 of its 7 frames in order: left to right, then top to bottom.';
    final sent = {'kind': 'user', 'text': 'lol', 'localImageCount': 1};
    expect(sameMessage({'kind': 'user', 'text': 'lol\n$note', 'images': 1}, sent), isTrue);
    expect(sameMessage({'kind': 'user', 'text': note, 'images': 1}, {'kind': 'user', 'text': '', 'localImageCount': 1}), isTrue);
    expect(sameMessage({'kind': 'user', 'text': 'lol\nmore', 'images': 1}, sent), isFalse);
  });

  test('the recall warning speaks only of changed files', () {
    expect(recallWarning({'files': <String>[], 'count': 0, 'maybe': false}, 'Writer'), '');
    expect(recallWarning({'files': ['a.md'], 'count': 2, 'maybe': false}, 'Writer'), 'Writer changed 2 files after this message. Recalling leaves them as they are.');
    expect(recallWarning({'files': <String>[], 'count': 0, 'maybe': true}, 'Writer'), 'Writer may have changed files after this message. Recalling leaves them as they are.');
  });

  test('an older row with the same text never settles a new message', () async {
    final desk = _Desk('older', echo: false);
    desk.items.add({'kind': 'user', 'text': 'yes', 'seq': 2, 'time': 1001});
    final chat = await _open(desk, 'older');
    chat.send('yes');
    await chat.refresh();
    expect(_users(chat), [(text: 'yes', local: false), (text: 'yes', local: true)]);
    desk.add('older', 'yes');
    await settle();
    expect(_users(chat), [(text: 'yes', local: false), (text: 'yes', local: false)]);
    desk.gate.complete();
  });
}
