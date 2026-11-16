// The first Main Bot heads the Team page as one large character, with no card
// around it: its name and role, and one line for what it is doing now.
// Large avatars carry no badges (ui-standard 8.2), so a ring shows its state.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../data/chat_items.dart';
import '../../data/json.dart';
import '../../data/pending.dart';
import '../../data/team_state.dart';
import '../../shared/shared_data.dart';
import '../../ui/avatar.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/motion.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../chat/work_row.dart';
import '../inbox/needs_sheet.dart';
import '../manage/bot_pages.dart';
import '../manage/model_picker.dart';

enum BotLineKind { waiting, working, idle }

/// What a Bot says under its name, most pressing first: what waits for you,
/// the step in hand, then its last message.
({String? text, BotLineKind kind}) botLine(TeamState team, List<PendingItem> pending, Bot bot) {
  if (team.questions.containsKey(bot.chatSession)) return (text: t('Waiting for your answer'), kind: BotLineKind.waiting);
  if (pending.any((item) => item.kind == PendingKind.approval && item.botId == bot.id && item.roomId == null)) {
    return (text: t('Waiting for your approval'), kind: BotLineKind.waiting);
  }
  final doing = team.workBots[bot.id];
  if (doing != null) return (text: workPhrase(doing), kind: BotLineKind.working);
  return (text: cleanPreview(bot.preview), kind: BotLineKind.idle);
}

class MainHero extends StatelessWidget {
  const MainHero({super.key, required this.team, required this.pending, required this.unread});

  final TeamState team;
  final List<PendingItem> pending;

  /// The first Main Bot's chat has news the user has not opened.
  final bool unread;

  static const _avatar = 96.0;

  @override
  Widget build(BuildContext context) {
    final bot = team.bot(team.mainBotIds.firstOrNull);
    if (bot == null) return const SizedBox.shrink();
    final p = context.p;
    final doing = team.workBots[bot.id];
    final working = doing != null;
    final line = _line(bot);
    final subtitle = [bot.role ?? t('Main Bot'), ?bot.engine].where((part) => part.isNotEmpty).join(' · ');
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: [
        bot.name,
        t('Main Bot'),
        if (line.kind != BotLineKind.idle) ?line.text,
        if (unread) t('Unread activity'),
      ].join(', '),
      child: Pressable(
        scale: 0.97,
        onTap: () => openChat(context, botId: bot.id),
        onLongPress: () => _menu(context, bot, working),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _Portrait(
              bot: bot,
              size: _avatar,
              ring: switch (line.kind) {
                BotLineKind.waiting => p.accent,
                BotLineKind.working => Palette.green,
                BotLineKind.idle => null,
              },
              breathe: line.kind == BotLineKind.working,
            ),
            const SizedBox(height: 14),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(bot.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.sectionTitle.copyWith(color: p.ink))),
              const SizedBox(width: 6),
              const SizedBox.square(dimension: 18, child: MainStar()),
            ]),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink2)),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: AnimatedSize(
                duration: reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _status(context, bot, line, doing),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// The row's line, and past it anything else of this Bot's that waits for
  /// you (a card, a secret request…), which beats its last message.
  ({String? text, BotLineKind kind, AppIcon? icon}) _line(Bot bot) {
    final line = botLine(team, pending, bot);
    final need = pending.where((item) => item.botId == bot.id && item.roomId == null).firstOrNull;
    if (line.kind == BotLineKind.waiting) return (text: line.text, kind: line.kind, icon: need == null ? null : pendingKind(need.kind).$1);
    if (line.kind == BotLineKind.working || need == null) return (text: line.text, kind: line.kind, icon: null);
    final (icon, label) = pendingKind(need.kind);
    final summary = need.summary;
    return (text: summary == null || summary.isEmpty ? label : '$label · $summary', kind: BotLineKind.waiting, icon: icon);
  }

  Widget _status(BuildContext context, Bot bot, ({String? text, BotLineKind kind, AppIcon? icon}) line, Object? doing) {
    final p = context.p;
    final text = line.text;
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    Widget row(List<Widget> children) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        );
    Widget dot(Color color) => Container(width: 7, height: 7, margin: const EdgeInsets.only(right: 6), decoration: BoxDecoration(color: color, shape: BoxShape.circle));
    Text say(String text, Color color) => Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.small.copyWith(color: color));

    switch (line.kind) {
      case BotLineKind.waiting:
        final icon = line.icon;
        return row([
          if (icon != null) ...[Ico(icon, size: 15, color: p.accent), const SizedBox(width: 5)],
          Flexible(child: say(text, p.accent)),
        ]);
      case BotLineKind.working:
        final room = team.room(jStr(doing, 'roomId'));
        final since = jInt(doing, 'since');
        return Column(mainAxisSize: MainAxisSize.min, children: [
          row([dot(Palette.green), Flexible(child: say(room == null ? text : '${room.name} · $text', Palette.green))]),
          if (since != null) Padding(padding: const EdgeInsets.only(top: 2), child: WorkElapsed(since: since)),
        ]);
      case BotLineKind.idle:
        final lastAt = bot.lastAt;
        return row([
          if (unread) dot(p.accent),
          Flexible(child: say(text, unread ? p.ink : p.ink2)),
          if (lastAt != null) Text(' · ${shortWhen(lastAt)}', style: TypeScale.small.copyWith(color: unread ? p.accent : p.ink3)),
        ]);
    }
  }

  void _menu(BuildContext context, Bot bot, bool working) {
    showActions(
      context,
      [
        MenuAction(t('New conversation'), AppIcon.plus, () => run(context, 'bot-new-part', {'botId': bot.id})),
        if (unread)
          MenuAction(t('Mark as read'), AppIcon.check, () {
            final session = TeamScope.read(context);
            unawaited(AppScope.read(context).seen.markSeen(session.computer.hostDeviceId, bot.id, bot.lastAt ?? DateTime.now().millisecondsSinceEpoch));
          }),
        MenuAction(t('Model'), AppIcon.model, () => showModelSheet(context, bot)),
        MenuAction(t('Details'), AppIcon.forward, () => openBotDetails(context, bot.id)),
        if (working) MenuAction(t('Stop'), AppIcon.stop, () => unawaited(run(context, 'stop-chat', {'botId': bot.id})), danger: true),
      ],
      header: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Text(bot.name, style: TypeScale.headerTitle.copyWith(color: context.p.ink)),
      ),
    );
  }
}

/// The character on a soft glow of its own color, inside a ring that is green
/// while it works (breathing) and the accent while it waits for you.
class _Portrait extends StatefulWidget {
  const _Portrait({required this.bot, required this.size, required this.ring, required this.breathe});

  final Bot bot;
  final double size;
  final Color? ring;
  final bool breathe;

  @override
  State<_Portrait> createState() => _PortraitState();
}

class _PortraitState extends State<_Portrait> with SingleTickerProviderStateMixin {
  static const _stroke = 3.0;
  static const _gap = 4.0;

  late final AnimationController _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600), value: 1);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Portrait old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.breathe && !reduceMotion(context)) {
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
      _breath
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final look = botLook(widget.bot);
    final glow = SharedData.instance.ink(look.color, dark: p.dark);
    final frame = widget.size + (_stroke + _gap) * 2;
    final spread = widget.size * 0.55;
    return SizedBox.square(
      dimension: frame,
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
        Positioned(
          left: -spread,
          top: -spread,
          right: -spread,
          bottom: -spread,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [glow.withValues(alpha: p.dark ? 0.22 : 0.18), glow.withValues(alpha: 0)]),
              ),
            ),
          ),
        ),
        FadeTransition(
          opacity: Tween(begin: 0.4, end: 1.0).animate(_breath),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            width: frame,
            height: frame,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: widget.ring ?? Colors.transparent, width: _stroke)),
          ),
        ),
        CharacterMark(look: look, size: widget.size),
      ]),
    );
  }
}
