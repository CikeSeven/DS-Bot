import 'package:dsbot_mobile/data/optimistic.dart';
import 'package:dsbot_mobile/data/team_state.dart';
import 'package:flutter_test/flutter_test.dart';

TeamState team() => TeamState({
      'revision': 7,
      'bots': [
        {'id': 'b1', 'name': 'Chief', 'color': '#111111', 'effort': 'medium', 'workDir': '/work/a', 'capabilities': ['shell']},
        {'id': 'b2', 'name': 'Coder', 'capabilities': <String>[]},
      ],
      'rooms': [
        {'id': 'r1', 'name': 'Standup', 'members': ['b1', 'b2']},
        {'id': 'r2', 'name': 'Quiet', 'members': ['b2']},
      ],
      'mainBotIds': ['b1'],
      'mainBotId': 'b1',
    });

void main() {
  test('update-bot shallow-merges the patch into that bot', () {
    final before = team();
    final next = optimistic(before, 'update-bot', {'id': 'b1', 'color': '#abcdef', 'name': 'Boss'})!;
    expect(next.bots[0].color, '#abcdef');
    expect(next.bots[0].name, 'Boss');
    expect(next.bots[0].effort, 'medium');
    expect(next.bots[1].name, 'Coder');
    expect(before.bots[0].color, '#111111');
  });

  test('update-bot clears effort on null and workDir on empty', () {
    final next = optimistic(team(), 'update-bot', {'id': 'b1', 'effort': null, 'workDir': ''})!;
    expect(next.bots[0].raw.containsKey('effort'), isFalse);
    expect(next.bots[0].raw.containsKey('workDir'), isFalse);
  });

  test('update-bot replaces the whole avatar object', () {
    final withAvatar = optimistic(team(), 'update-bot', {
      'id': 'b1',
      'avatar': {'shape': 'star', 'image': 'data:x'},
    })!;
    final next = optimistic(withAvatar, 'update-bot', {
      'id': 'b1',
      'avatar': {'shape': 'moon'},
    })!;
    expect(next.bots[0].avatar, {'shape': 'moon'});
  });

  test('set-main adds and removes in mainBotIds and keeps mainBotId', () {
    final added = optimistic(team(), 'set-main', {'id': 'b2', 'main': true})!;
    expect(added.mainBotIds, ['b1', 'b2']);
    expect(added.mainBotId, 'b1');
    final removed = optimistic(added, 'set-main', {'id': 'b1', 'main': false})!;
    expect(removed.mainBotIds, ['b2']);
    expect(removed.mainBotId, 'b2');
    final none = optimistic(removed, 'set-main', {'id': 'b2', 'main': false})!;
    expect(none.mainBotIds, isEmpty);
    expect(none.mainBotId, isNull);
  });

  test('bot-capability adds and removes the name in that bot', () {
    final added = optimistic(team(), 'bot-capability', {'botId': 'b2', 'name': 'shell', 'attached': true})!;
    expect(added.bots[1].capabilities, ['shell']);
    final removed = optimistic(team(), 'bot-capability', {'botId': 'b1', 'name': 'shell', 'attached': false})!;
    expect(removed.bots[0].capabilities, isEmpty);
  });

  test('update-room shallow-merges the patch into that room', () {
    final next = optimistic(team(), 'update-room', {'id': 'r1', 'name': 'Daily', 'notice': 'Bring updates'})!;
    expect(next.rooms[0].name, 'Daily');
    expect(next.rooms[0].notice, 'Bring updates');
    expect(next.rooms[0].members, ['b1', 'b2']);
  });

  test('set-flags pins, hides and moves Bots and groups between sections', () {
    final pinned = optimistic(team(), 'set-flags', {'id': 'b2', 'pinned': true})!;
    expect(pinned.bots[1].pinned, isTrue);
    final hidden = optimistic(pinned, 'set-flags', {'id': 'r2', 'hidden': true, 'sectionId': 'sec-1'})!;
    expect(hidden.rooms[1].hidden, isTrue);
    expect(hidden.rooms[1].sectionId, 'sec-1');
    final out = optimistic(hidden, 'set-flags', {'id': 'r2', 'sectionId': null})!;
    expect(out.rooms[1].sectionId, isNull);
    expect(out.rooms[1].hidden, isTrue);
  });

  test('unknown ids, unknown endpoints and an empty team change nothing', () {
    final before = team();
    expect(identical(optimistic(before, 'update-bot', {'id': 'nope', 'name': 'X'}), before), isTrue);
    expect(identical(optimistic(before, 'delete-bot', {'id': 'b1'}), before), isTrue);
    expect(optimistic(null, 'update-bot', {'id': 'b1'}), isNull);
  });

  test('a stale read keeps the guess of a write still in flight', () {
    final write = Write('update-bot', {'id': 'b1', 'name': 'Boss'});
    final read = TeamState({...team().raw, 'revision': 6});
    expect(withWrites(read, [write]).bots[0].name, 'Boss');
  });
}
