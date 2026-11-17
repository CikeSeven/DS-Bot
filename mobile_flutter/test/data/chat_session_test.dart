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
