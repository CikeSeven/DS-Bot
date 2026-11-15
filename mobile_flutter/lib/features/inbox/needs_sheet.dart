// One thing that waits for the user, as a card that can be answered where it
// shows: on the home strip (compact), in the inbox and in the Needs you sheet.
import 'package:flutter/material.dart';

import '../../app/nav.dart';
import '../../data/json.dart';
import '../../data/pending.dart';
import '../../data/team_state.dart';
import '../../ui/avatar.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../chat/pending_cards.dart';
import '../chat/view_card.dart';
import '../manage/browser_page.dart';
import '../settings/connections_pages.dart';

class NeedCard extends StatelessWidget {
  const NeedCard({super.key, required this.item, required this.team, this.compact = false});

  final PendingItem item;
  final TeamState team;
  final bool compact;

  (AppIcon, String) get _kind => switch (item.kind) {
        PendingKind.question => (AppIcon.question, t('Question')),
        PendingKind.approval => (AppIcon.shield, t('Approval')),
        PendingKind.secret => (AppIcon.key, t('Secret request')),
        PendingKind.handoff => (AppIcon.globe, t('Browser handoff')),
        PendingKind.view => (AppIcon.board, t('Card')),
        PendingKind.learning => (AppIcon.brain, t('Learned')),
        PendingKind.connector => (AppIcon.plug, t('Connector')),
        PendingKind.mail => (AppIcon.mail, t('Mail')),
      };

  void _open(BuildContext context) {
    final roomId = item.roomId;
    openChat(context, roomId: roomId, botId: roomId == null ? item.botId : null);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final bot = team.bot(item.botId);
    final room = team.room(item.roomId);
    final (icon, label) = _kind;
    final header = Row(children: [
      BotAvatar(bot: bot, size: 26, ring: p.card),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          room != null ? '${bot?.name ?? ''} · ${room.name}' : (bot?.name ?? ''),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TypeScale.smallStrong.copyWith(color: p.ink),
        ),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(Radii.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Ico(icon, size: 13, color: p.accent),
          const SizedBox(width: 4),
          Text(label, style: TypeScale.caption.copyWith(color: p.accent, fontWeight: FontWeight.w500)),
        ]),
      ),
    ]);
    final body = compact ? _compactBody(context, p) : _fullBody(context, bot);
    return Pressable(
      onTap: compact ? () => showNeedSheet(context, item, team) : null,
      scale: compact ? 0.98 : 1,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: p.card.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(Radii.dialog + 2),
          border: Border.all(color: p.line),
          boxShadow: compact ? [BoxShadow(color: p.glassShadow.withValues(alpha: 0.05), blurRadius: 18, offset: const Offset(0, 6))] : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min, children: [
          header,
          const SizedBox(height: 10),
          if (compact) Expanded(child: body) else body,
          if (!compact)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _open(context),
                icon: Ico(AppIcon.chat, size: 16, color: p.ink2),
                label: Text(t('Open chat'), style: TypeScale.small.copyWith(color: p.ink2)),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _compactBody(BuildContext context, Palette p) {
    final summary = Text(
      item.summary ?? '',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TypeScale.rowPreview.copyWith(color: p.ink),
    );
    final action = switch (item.kind) {
      PendingKind.approval when jBool(item.data, 'answerable') != false => ApprovalBody(approval: item.data, compact: true),
      _ => Align(alignment: Alignment.bottomLeft, child: Btn(t('Answer'), small: true, onTap: () => showNeedSheet(context, item, team))),
    };
    if (item.kind == PendingKind.approval) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(jStr(item.data, 'tool') ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
        const Spacer(),
        action,
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [summary, const Spacer(), action]);
  }

  Widget _fullBody(BuildContext context, Bot? bot) {
    switch (item.kind) {
      case PendingKind.question:
        return QuestionBody(question: item.data, sessionId: item.sessionId ?? '', showTitle: true);
      case PendingKind.approval:
        return ApprovalBody(approval: item.data, showTitle: true);
      case PendingKind.secret:
        return SecretBody(request: item.data, botName: bot?.name ?? t('the Bot'), showTitle: true);
      case PendingKind.handoff:
        return HandoffBody(hold: item.data, botId: item.botId, onView: () => push(context, BrowserPage(botId: item.botId)));
      case PendingKind.view:
        return ViewCard(sessionId: item.sessionId ?? '', id: jStr(item.data, 'id'), title: jStr(item.data, 'title'), root: item.data['view']);
      case PendingKind.learning:
        return LearningBody(proposal: item.data);
      case PendingKind.connector:
        return ConnectorRequestBody(request: item.data, onConnect: () => push(context, const ConnectorsPage()));
      case PendingKind.mail:
        return MailRequestBody(request: item.data);
    }
  }
}

/// One pending item, answered in a sheet without leaving the screen.
Future<void> showNeedSheet(BuildContext context, PendingItem item, TeamState team) {
  return showGlassSheet<void>(
    context,
    builder: (sheet) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: NeedCard(item: item, team: team),
    ),
  );
}
