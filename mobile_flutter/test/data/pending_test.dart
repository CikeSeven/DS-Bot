import 'package:dsbot_mobile/data/pending.dart';
import 'package:dsbot_mobile/data/team_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all five pending kinds are listed, and orphaned or unanswerable ones are not', () {
    final team = TeamState({
      'revision': 1,
      'bots': [
        {'id': 'b1', 'name': 'A', 'sessionId': 's1'},
        {'id': 'b2', 'name': 'B', 'sessionId': 's2'},
      ],
      'rooms': [
        {'id': 'r1', 'name': 'G', 'members': ['b1', 'b2']},
      ],
      'questions': {
        's1': {'id': 'q1', 'question': 'Which?'},
        'gone': {'id': 'q2', 'question': 'Old'},
      },
      'views': {
        's2': {'id': 'v1', 'title': 'Pick'},
      },
      'secretRequests': {
        'b1': [
          {'id': 'k1', 'name': 'TOKEN', 'status': 'pending'},
          {'id': 'k2', 'name': 'OLD', 'status': 'done'},
        ],
      },
      'browserHolds': {
        'b2': {'callId': 'h1', 'note': 'Log in'},
      },
      'work': {
        'approvals': [
          {'id': 'a1', 'botId': 'b1', 'roomId': 'r1', 'tool': 'bash', 'reason': 'rm'},
          {'id': 'a2', 'botId': 'b2', 'tool': 'x', 'reason': 'y', 'answerable': false},
        ],
      },
    });
    final items = pendingItemsOf(team);
    expect(items.map((item) => item.kind).toSet(), {PendingKind.question, PendingKind.approval, PendingKind.secret, PendingKind.handoff, PendingKind.view});
    expect(items.length, 5);
    expect(items.firstWhere((item) => item.kind == PendingKind.approval).summary, 'bash · rm');
    expect(botHasPending(items, 'b1'), isTrue);
    expect(roomHasPending(items, 'r1'), isTrue);
    expect(pendingItemsOf(null), isEmpty);
  });

  test('learning proposals and pending connector and mail requests need the user too', () {
    final team = TeamState({
      'revision': 1,
      'bots': [
        {'id': 'b1', 'name': 'A', 'sessionId': 's1'},
      ],
      'learning': {
        'b1': [
          {'id': 'l1', 'kind': 'skill', 'name': 'release-notes'},
        ],
      },
      'connectorRequests': {
        'b1': [
          {'id': 'c1', 'name': 'GitHub', 'status': 'pending'},
          {'id': 'c2', 'name': 'Slack', 'status': 'connected'},
        ],
      },
      'mailRequests': {
        'b1': [
          {'id': 'm1', 'subject': 'Weekly report', 'status': 'pending'},
        ],
      },
    });
    final items = pendingItemsOf(team);
    expect(items.map((item) => item.kind).toList(), [PendingKind.learning, PendingKind.connector, PendingKind.mail]);
    expect(items.map((item) => item.summary).toList(), ['release-notes', 'GitHub', 'Weekly report']);
  });
}
