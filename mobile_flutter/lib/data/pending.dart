// Port of mobile/src/nav/pending.ts: everything the Needs you page lists. The
// count, the badges, the team-list indicators and the page all derive from this
// one list.
import 'json.dart';
import 'team_state.dart';

enum PendingKind { question, approval, secret, handoff, view }

class PendingItem {
  const PendingItem({
    required this.kind,
    required this.key,
    required this.botId,
    this.roomId,
    this.summary,
    this.sessionId,
    this.data = const {},
  });

  final PendingKind kind;
  final String key;
  final String botId;
  final String? roomId;
  final String? summary;
  final String? sessionId;

  /// The item as the computer sent it, for answering in place.
  final Json data;
}

List<PendingItem> pendingItemsOf(TeamState? team) {
  if (team == null) return const [];
  final items = <PendingItem>[];
  for (final entry in team.questions.entries) {
    final bot = team.botOfSession(entry.key);
    final question = asJson(entry.value);
    if (bot == null || entry.value is! Map) continue;
    items.add(PendingItem(
      kind: PendingKind.question,
      key: 'q-${question['id']}',
      botId: bot.id,
      sessionId: entry.key,
      summary: jStr(question, 'question'),
      data: question,
    ));
  }
  for (final approval in team.approvals) {
    final botId = jStr(approval, 'botId');
    if (jBool(approval, 'answerable') == false || team.bot(botId) == null) continue;
    items.add(PendingItem(
      kind: PendingKind.approval,
      key: 'a-${approval['id']}',
      botId: botId!,
      roomId: jStr(approval, 'roomId'),
      sessionId: jStr(approval, 'sessionId'),
      summary: [jStr(approval, 'tool'), jStr(approval, 'reason')].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
      data: approval,
    ));
  }
  for (final entry in team.secretRequests.entries) {
    if (team.bot(entry.key) == null || entry.value is! List) continue;
    for (final request in (entry.value as List).whereType<Map>()) {
      final req = request.cast<String, dynamic>();
      if (req['status'] != 'pending') continue;
      items.add(PendingItem(kind: PendingKind.secret, key: 's-${req['id']}', botId: entry.key, summary: jStr(req, 'name'), data: req));
    }
  }
  for (final entry in team.browserHolds.entries) {
    final hold = asJson(entry.value);
    if (jStr(hold, 'callId') == null || team.bot(entry.key) == null) continue;
    items.add(PendingItem(kind: PendingKind.handoff, key: 'h-${hold['callId']}', botId: entry.key, summary: jStr(hold, 'note'), data: hold));
  }
  for (final entry in team.views.entries) {
    final bot = team.botOfSession(entry.key);
    if (bot == null || entry.value is! Map) continue;
    final view = asJson(entry.value);
    items.add(PendingItem(
      kind: PendingKind.view,
      key: 'v-${jStr(view, 'id') ?? entry.key}',
      botId: bot.id,
      sessionId: entry.key,
      summary: jStr(view, 'title'),
      data: view,
    ));
  }
  return items;
}

bool botHasPending(List<PendingItem> items, String botId) => items.any((item) => item.botId == botId);

bool roomHasPending(List<PendingItem> items, String roomId) =>
    items.any((item) => item.kind == PendingKind.approval && item.roomId == roomId);
