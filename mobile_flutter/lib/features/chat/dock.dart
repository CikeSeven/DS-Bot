// Everything above the message box: the group's goal, a failure only the user
// can fix, computer-use asks, what the Bot is doing (with Stop), the cards that
// wait for the user, and quick actions.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../data/json.dart';
import '../../data/team_state.dart';
import '../../ui/avatar.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../manage/bot_pages.dart';
import '../manage/browser_page.dart';
import '../settings/connections_pages.dart';
import '../settings/providers_page.dart';
import 'pending_cards.dart';
import 'view_card.dart';

class _Card {
  const _Card(this.key, this.title, this.icon, this.needs, this.body);

  final String key;
  final String title;
  final AppIcon icon;
  final bool needs;
  final Widget body;
}

/// The cards waiting in this chat, one open at a time. The first that needs the
/// user opens by itself; the others show a dot.
class PendingDock extends StatefulWidget {
  const PendingDock({super.key, required this.team, required this.sessionId, this.bot, this.room});

  final TeamState team;
  final String sessionId;
  final Bot? bot;
  final Room? room;

  @override
  State<PendingDock> createState() => _PendingDockState();
}

class _PendingDockState extends State<PendingDock> {
  String? _chosen;

  List<_Card> _cards(BuildContext context) {
    final team = widget.team;
    final sessionId = widget.sessionId;
    final bot = widget.bot;
    final room = widget.room;
    final cards = <_Card>[];
    for (final approval in team.approvals) {
      final mine = jStr(approval, 'sessionId') == sessionId || (room != null && jStr(approval, 'roomId') == room.id);
      if (!mine) continue;
      cards.add(_Card('approval-${approval['id']}', jStr(approval, 'tool') ?? t('Approval'), AppIcon.shield, true, ApprovalBody(approval: approval)));
    }
    final question = team.questions[sessionId];
    if (question is Map) {
      cards.add(_Card('question', jStr(question, 'question') ?? t('Question'), AppIcon.question, true, QuestionBody(question: asJson(question), sessionId: sessionId)));
    }
    if (bot != null) {
      for (final request in jList(team.secretRequests, bot.id).whereType<Map>().map(asJson)) {
        if (request['status'] != 'pending') continue;
        final allow = request['kind'] == 'allow';
        cards.add(_Card(
          'secret-${request['id']}',
          allow ? t('Allow a secret') : t('{name} needs a key', {'name': jStr(request, 'name') ?? ''}),
          AppIcon.key,
          true,
          SecretBody(request: request, botName: bot.name),
        ));
      }
      final hold = jMap(team.browserHolds, bot.id);
      if (hold != null && jStr(hold, 'callId') != null) {
        cards.add(_Card('handoff', t('Browser handoff'), AppIcon.globe, true, HandoffBody(hold: hold, botId: bot.id, onView: () => push(context, BrowserPage(botId: bot.id)))));
      }
    }
    final view = team.views[sessionId];
    if (view is Map) {
      cards.add(_Card(
        'view-${view['id'] ?? 'view'}',
        jStr(view, 'title') ?? t('Card'),
        AppIcon.board,
        true,
        ViewCard(sessionId: sessionId, id: jStr(view, 'id'), title: jStr(view, 'title'), root: view['view'], framed: false),
      ));
    }
    if (bot != null) {
      for (final proposal in jList(team.learning, bot.id).whereType<Map>().map(asJson)) {
        cards.add(_Card('learning-${proposal['id']}', t('{name} learned something', {'name': bot.name}), AppIcon.brain, true, LearningBody(proposal: proposal)));
      }
      for (final request in jList(team.connectorRequests, bot.id).whereType<Map>().map(asJson)) {
        if (request['status'] != 'pending') continue;
        cards.add(_Card('connector-${request['id']}', t('Connect {name}', {'name': jStr(request, 'name') ?? ''}), AppIcon.plug, true,
            ConnectorRequestBody(request: request, onConnect: () => push(context, const ConnectorsPage()))));
      }
      for (final request in jList(team.mailRequests, bot.id).whereType<Map>().map(asJson)) {
        if (request['status'] != 'pending') continue;
        cards.add(_Card('mail-${request['id']}', t('Send mail: {subject}', {'subject': jStr(request, 'subject') ?? ''}), AppIcon.mail, true, MailRequestBody(request: request)));
      }
      for (final card in jList(team.btwCards, bot.id).whereType<Map>().map(asJson)) {
        final part = jStr(card, 'partId');
        if (part != null && part != sessionId) continue;
        cards.add(_Card('btw-${card['id']}', jStr(card, 'question') ?? t('Aside'), AppIcon.sparkle, false, AsideBody(card: card, sessionId: sessionId)));
      }
    }
    return cards;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final cards = _cards(context);
    if (cards.isEmpty) return const SizedBox.shrink();
    final chosen = cards.where((card) => card.key == _chosen).firstOrNull;
    final active = chosen ?? cards.where((card) => card.needs).firstOrNull ?? cards.first;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
        child: Column(children: [
          for (final card in cards)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                decoration: BoxDecoration(
                  color: p.card.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(Radii.dialog),
                  border: Border.all(color: card.key == active.key && card.needs ? p.accent.withValues(alpha: 0.5) : p.line),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(Radii.dialog),
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _chosen = card.key == active.key && chosen != null ? null : card.key);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      child: Row(children: [
                        Ico(card.icon, size: 18, color: card.needs ? p.accent : p.ink3),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(card.title, maxLines: card.key == active.key ? 4 : 1, overflow: TextOverflow.ellipsis, style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
                        ),
                        if (card.needs && card.key != active.key)
                          Container(width: 7, height: 7, margin: const EdgeInsets.only(right: 6), decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle)),
                        AnimatedRotation(turns: card.key == active.key ? 0.25 : 0, duration: const Duration(milliseconds: 220), child: Ico(AppIcon.forward, size: 16, color: p.ink3)),
                      ]),
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: SpringCurve.shape,
                    child: card.key == active.key ? Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 14), child: card.body) : const SizedBox(width: double.infinity),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

/// A group's goal, as the desktop's goal island shows it: the goal and its
/// stage, the stage bar, and every stage on a tap.
class GoalBar extends StatefulWidget {
  const GoalBar({super.key, required this.goal, required this.roomId});

  final Json goal;
  final String roomId;

  @override
  State<GoalBar> createState() => _GoalBarState();
}

class _GoalBarState extends State<GoalBar> {
  bool _open = false;

  void _control(BuildContext context, String action) =>
      run(context, 'goal-control', {'roomId': widget.roomId, 'goalId': widget.goal['id'], 'action': action});

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final goal = widget.goal;
    final stages = jMaps(goal, 'stages');
    final at = jInt(goal, 'current') ?? 0;
    final status = jStr(goal, 'status') ?? '';
    final running = status == 'active' || status == 'paused';
    final current = running && at < stages.length ? stages[at] : null;
    final checking = current != null && jMaps(current, 'tasks').every((task) => const {'reported', 'done'}.contains(jStr(task, 'status')));
    final number = status == 'drafting'
        ? null
        : status == 'stopped'
            ? stages.where((stage) => jStr(stage, 'status') == 'passed').length
            : current != null
                ? at + 1
                : stages.length;
    final title = jStr(current, 'title') ?? '';
    final label = switch (status) {
      'drafting' => t('Aligning the goal with you'),
      'stopped' => t('Stopped'),
      'complete' => t('Goal reached'),
      'paused' => current != null ? t('Paused · {title}', {'title': title}) : t('Paused'),
      _ when jBool(goal, 'idle') == true => current != null ? t('Waiting for you · {title}', {'title': title}) : t('Waiting for you'),
      _ when current == null => t('Final check'),
      _ => checking ? t('Checking · {title}', {'title': title}) : title,
    };
    return GestureDetector(
      onTap: () => setState(() => _open = !_open),
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(color: p.card.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(Radii.dialog), border: Border.all(color: p.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Ico(AppIcon.target, size: 16, color: p.accent),
            const SizedBox(width: 8),
            Expanded(child: Text(jStr(goal, 'title') ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.rowNameStrong.copyWith(color: p.ink))),
            if (number != null) Text('$number/${stages.length}', style: TypeScale.caption.copyWith(color: p.ink3)),
          ]),
          const SizedBox(height: 2),
          Text(label, maxLines: _open ? null : 1, overflow: _open ? null : TextOverflow.ellipsis, style: TypeScale.small.copyWith(color: p.ink2)),
          if (stages.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(children: [
              for (final (i, stage) in stages.indexed) ...[
                if (i > 0) const SizedBox(width: 3),
                Expanded(
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      color: jStr(stage, 'status') == 'passed' ? Palette.green : (i == at && running ? p.accent : p.line),
                    ),
                  ),
                ),
              ],
            ]),
          ],
          if (_open) ...[
            for (final (i, stage) in stages.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  SizedBox(width: 20, child: Text('${i + 1}', style: TypeScale.small.copyWith(color: p.ink3))),
                  Expanded(child: Text(jStr(stage, 'title') ?? '', style: TypeScale.small.copyWith(color: jStr(stage, 'status') == 'passed' ? p.ink3 : p.ink))),
                  if (jStr(stage, 'status') == 'passed') const Ico(AppIcon.check, size: 14, color: Palette.green),
                ]),
              ),
            const SizedBox(height: 8),
            Row(children: [
              if (status == 'active') Expanded(child: Btn(t('Pause'), kind: BtnKind.secondary, small: true, onTap: () => _control(context, 'pause'))),
              if (status == 'paused') Expanded(child: Btn(t('Resume'), small: true, onTap: () => _control(context, 'resume'))),
              if (running || status == 'drafting') ...[
                if (running) const SizedBox(width: 8),
                Expanded(child: Btn(t('Stop'), kind: BtnKind.danger, small: true, onTap: () => _control(context, 'stop'))),
              ],
              if (status == 'complete' || status == 'stopped') Expanded(child: Btn(t('Clear'), kind: BtnKind.secondary, small: true, onTap: () => _control(context, 'clear'))),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// The desktop's repair card for a failure only the user can fix, by DSH's code.
class BlockedCard extends StatelessWidget {
  const BlockedCard({super.key, required this.bot, required this.team});

  final Bot bot;
  final TeamState team;

  String _text(String code, String provider, int? status) => switch (code) {
        'MISSING_CREDENTIAL' => t("{name}'s model has no API key yet.", {'name': bot.name}),
        'INVALID_CREDENTIAL' => t('This API key is not in the right format.'),
        'AUTH' => status == null ? t('{provider} did not accept the current API key.', {'provider': provider}) : t('{provider} did not accept the current API key ({status}).', {'provider': provider, 'status': status}),
        'QUOTA' => status == null ? t('{provider} is out of balance or quota.', {'provider': provider}) : t('{provider} is out of balance or quota ({status}).', {'provider': provider, 'status': status}),
        'ACCOUNT_QUOTA' => t('The DeepSeek account balance is too low.'),
        'ACCOUNT_SIGN_IN_REQUIRED' || 'ACCOUNT_SIGNED_OUT' || 'ACCOUNT_TOKEN_INVALID' => t('The DeepSeek account sign-in has expired.'),
        _ => t('This turn failed.'),
      };

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final blocked = bot.blocked!;
    final code = jStr(blocked, 'code') ?? '';
    final providerId = jStr(blocked, 'provider');
    final provider = team.models.where((model) => model.ref.split('/').first == providerId).firstOrNull?.providerName ?? providerId ?? '';
    final key = const {'MISSING_CREDENTIAL', 'INVALID_CREDENTIAL', 'AUTH'}.contains(code);
    final topUp = (code == 'QUOTA' && providerId == 'deepseek-official') || code == 'ACCOUNT_QUOTA';
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Palette.danger.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Radii.dialog), border: Border.all(color: Palette.danger.withValues(alpha: 0.3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Ico(AppIcon.alert, size: 18, color: Palette.danger),
          const SizedBox(width: 8),
          Expanded(child: Text(_text(code, provider, jInt(blocked, 'status')), style: TypeScale.settingsRow.copyWith(color: p.ink))),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (key) Btn(code == 'MISSING_CREDENTIAL' ? t('Enter API key') : t('Enter the key again'), small: true, onTap: () => push(context, const ProvidersPage())),
          if (topUp) Btn(t('Top up ↗'), small: true, onTap: () => launchUrl(Uri.parse('https://platform.deepseek.com/top_up'), mode: LaunchMode.externalApplication)),
          Btn(t('Retry'), kind: BtnKind.secondary, small: true, icon: AppIcon.refresh, onTap: () => run(context, 'resume', {'botId': bot.id})),
          Btn(t('Pick another model'), kind: BtnKind.secondary, small: true, onTap: () => openBotDetails(context, bot.id)),
        ]),
      ]),
    );
  }
}

/// Computer use: a Bot's ask to use an app (Deny / This time / Always), and a
/// bar with Stop while it holds the computer.
class ComputerCards extends StatelessWidget {
  const ComputerCards({super.key, required this.bot, required this.team});

  final Bot bot;
  final TeamState team;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final live = team.computerLive;
    final asks = (jMap(live, 'asks') ?? const {}).values.whereType<Map>().map(asJson).where((ask) => ask['botId'] == bot.id).toList();
    final control = jMap(jMap(live, 'bots'), bot.id);
    final acting = control != null && jStr(control, 'state') != null && jStr(control, 'state') != 'idle';
    if (asks.isEmpty && !acting) return const SizedBox.shrink();
    return Column(children: [
      for (final ask in asks)
        Container(
          margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: p.card.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(Radii.dialog), border: Border.all(color: p.line)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t('Allow {name} to use {app}?', {'name': bot.name, 'app': jStr(ask, 'appName') ?? ''}), style: TypeScale.settingsRow.copyWith(color: p.ink)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Btn(t('Deny'), kind: BtnKind.secondary, small: true, onTap: () => run(context, 'computer-app-answer', {'id': ask['id'], 'answer': 'deny'}))),
              const SizedBox(width: 6),
              Expanded(child: Btn(t('This time'), kind: BtnKind.secondary, small: true, onTap: () => run(context, 'computer-app-answer', {'id': ask['id'], 'answer': 'once'}))),
              const SizedBox(width: 6),
              Expanded(child: Btn(t('Always'), small: true, onTap: () => run(context, 'computer-app-answer', {'id': ask['id'], 'answer': 'always'}))),
            ]),
          ]),
        ),
      if (acting)
        Container(
          margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          decoration: BoxDecoration(color: p.card.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(Radii.dialog), border: Border.all(color: p.line)),
          child: Row(children: [
            Ico(AppIcon.monitor, size: 16, color: p.accent),
            const SizedBox(width: 8),
            Expanded(child: Text(jStr(control, 'app') != null ? '${t('Computer use')} · ${jStr(control, 'app')}' : t('Computer use'), style: TypeScale.small.copyWith(color: p.ink))),
            Btn(t('Stop'), kind: BtnKind.danger, small: true, onTap: () => run(context, 'computer-stop', {'botId': bot.id})),
          ]),
        ),
    ]);
  }
}

/// What the Bot (or each group member) is doing, with Stop in reach.
class WorkLine extends StatefulWidget {
  const WorkLine({super.key, required this.entries, required this.onStop});

  final List<({Bot? bot, String text, VoidCallback? stop})> entries;
  final VoidCallback onStop;

  @override
  State<WorkLine> createState() => _WorkLineState();
}

class _WorkLineState extends State<WorkLine> with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _shimmer.stop();
    } else if (!_shimmer.isAnimating) {
      _shimmer.repeat();
    }
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 0),
      child: Column(children: [
        for (final entry in widget.entries)
          Row(children: [
            BotAvatar(bot: entry.bot, size: 22, working: true),
            const SizedBox(width: 8),
            Expanded(
              child: AnimatedBuilder(
                animation: _shimmer,
                builder: (context, child) => ShaderMask(
                  shaderCallback: (rect) => LinearGradient(
                    colors: [p.ink2, p.ink, p.ink2],
                    stops: [(_shimmer.value - 0.3).clamp(0, 1), _shimmer.value, (_shimmer.value + 0.3).clamp(0, 1)],
                  ).createShader(rect),
                  child: child,
                ),
                child: Text(entry.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.small.copyWith(color: Colors.white)),
              ),
            ),
            if (entry.stop != null)
              TextButton(onPressed: entry.stop, child: Text(t('Stop'), style: TypeScale.smallStrong.copyWith(color: Palette.danger))),
          ]),
      ]),
    );
  }
}

/// Quick actions above the message box.
class QuickChips extends StatelessWidget {
  const QuickChips({super.key, required this.chips});

  final List<({AppIcon icon, String label, VoidCallback onTap})> chips;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    if (chips.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
        children: [
          for (final chip in chips)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Pressable(
                onTap: chip.onTap,
                haptic: true,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(color: p.card.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(Radii.pill), border: Border.all(color: p.line)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Ico(chip.icon, size: 15, color: p.ink2),
                    const SizedBox(width: 6),
                    Text(chip.label, style: TypeScale.small.copyWith(color: p.ink)),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
