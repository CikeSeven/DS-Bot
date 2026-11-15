import 'package:dsbot_mobile/data/notices.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reconnect replays the first missed notice even when the first hello seq was zero', () {
    final cursor = NoticeCursor();
    expect(cursor.connect(boot: 'b1', seq: 0), (sameBoot: false, since: 0));
    expect(cursor.acceptCatchUp('b1', {'boot': 'b1', 'seq': 0, 'reset': true, 'notices': []}).replay, isEmpty);
    expect(cursor.connect(boot: 'b1', seq: 1), (sameBoot: true, since: 0));
    final caught = cursor.acceptCatchUp('b1', {
      'boot': 'b1',
      'seq': 1,
      'reset': false,
      'notices': [
        {'seq': 1, 'kind': 'message', 'botId': 'a', 'text': 'hi'},
      ],
    });
    expect(caught.reset, isFalse);
    expect(caught.replay, [
      {'seq': 1, 'kind': 'message', 'botId': 'a', 'text': 'hi'},
    ]);
    expect(cursor.snapshot, (boot: 'b1', seq: 1));
  });

  test('the first connect starts at the hello seq and skips older history', () {
    final cursor = NoticeCursor();
    expect(cursor.connect(boot: 'b1', seq: 10), (sameBoot: false, since: 10));
    final caught = cursor.acceptCatchUp('b1', {
      'boot': 'b1',
      'seq': 10,
      'reset': true,
      'notices': [
        {'seq': 9},
        {'seq': 10},
      ],
    });
    expect(caught.reset, isTrue);
    expect(caught.replay, isEmpty);
  });

  test('a live notice before the catch-up is not replayed twice and seq stays monotonic', () {
    final cursor = NoticeCursor();
    cursor.connect(boot: 'b1', seq: 3);
    cursor.acceptCatchUp('b1', {'boot': 'b1', 'seq': 3, 'reset': true, 'notices': []});
    expect(cursor.connect(boot: 'b1', seq: 4), (sameBoot: true, since: 3));
    expect(cursor.acceptLive('b1', {'seq': 5, 'text': 'newest'}), isTrue);
    expect(cursor.acceptLive('b1', {'seq': 5, 'text': 'duplicate'}), isFalse);
    final caught = cursor.acceptCatchUp('b1', {
      'boot': 'b1',
      'seq': 5,
      'reset': false,
      'notices': [
        {'seq': 4, 'text': 'older'},
        {'seq': 5, 'text': 'newest'},
      ],
    });
    expect(caught.replay, isEmpty);
    expect(cursor.snapshot, (boot: 'b1', seq: 5));
  });

  test('a computer restart switches the boot cleanly and a gap reset replays nothing stale', () {
    final cursor = NoticeCursor();
    cursor.connect(boot: 'b1', seq: 5);
    expect(cursor.connect(boot: 'b2', seq: 2), (sameBoot: false, since: 2));
    expect(cursor.acceptCatchUp('b2', {'boot': 'b2', 'seq': 2, 'reset': true, 'notices': [{'seq': 1}]}).replay, isEmpty);
    expect(cursor.connect(boot: 'b2', seq: 9), (sameBoot: true, since: 2));
    expect(cursor.acceptCatchUp('b2', {'boot': 'b2', 'seq': 9, 'reset': true, 'notices': [{'seq': 8}]}).replay, isEmpty);
    expect(cursor.snapshot, (boot: 'b2', seq: 9));
  });
}
