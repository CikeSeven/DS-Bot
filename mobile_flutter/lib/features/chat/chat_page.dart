// A chat with a Bot or a group: a calm solid message list that runs under
// floating glass islands (back, the Bot, its actions) and a floating message
// box, with what the Bot is doing at the foot of the list.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../data/chat_items.dart';
import '../../data/chat_session.dart';
import '../../data/json.dart';
import '../../data/team_session.dart';
import '../../data/team_state.dart';
import '../../ui/avatar.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/island.dart';
import '../../ui/menu/action_menu.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../home/home_shell.dart';
import '../manage/bot_pages.dart';
import '../manage/browser_page.dart';
import '../manage/group_pages.dart';
import '../manage/memory_page.dart';
import '../manage/side_chat.dart';
import '../manage/work_pages.dart';
import '../search/search_page.dart';
import 'chat_item_view.dart';
import 'composer.dart';
import 'dock.dart';
import 'media.dart';
import 'work_row.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, this.botId, this.roomId});

  final String? botId;
  final String? roomId;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  ChatSession? _chat;
  final _scroll = ScrollController();
  final _composer = ComposerController();
  bool _away = false;
  double _dock = 120;

  /// How far older messages run under the top islands, 0..1: the fade behind
  /// them shows only when something is there to fade.
  final _under = ValueNotifier<double>(0);

  static const _barHeight = 52.0;

  String get _id => widget.roomId ?? widget.botId ?? '';
  bool get _room => widget.roomId != null;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_chat != null) return;
    final session = TeamScope.read(context);
    _chat = ChatSession(
      team: session,
      hostId: session.computer.hostDeviceId,
      room: _room,
      id: _id,
      seen: AppScope.read(context).seen,
    )..start();
    NoticeBanner.openChatId = _id;
  }

  @override
  void dispose() {
    _chat?.dispose();
    if (NoticeBanner.openChatId == _id) NoticeBanner.openChatId = null;
    _scroll.dispose();
    _under.dispose();
    super.dispose();
  }

  void _onScroll() {
    final away = _scroll.offset > 600;
    if (away != _away) setState(() => _away = away);
    _measureUnder(_scroll.position);
    if (_scroll.position.extentAfter < 600) unawaited(_chat?.loadMore());
  }

  // The list's top padding clears the islands by 8: past that, messages are under them.
  void _measureUnder(ScrollMetrics metrics) => _under.value = ((metrics.extentAfter - 8) / 20).clamp(0.0, 1.0);

  void _toLatest() => _scroll.animateTo(0, duration: const Duration(milliseconds: 420), curve: SpringCurve.shape);

  @override
  Widget build(BuildContext context) {
    final session = TeamScope.of(context);
    final team = session.team;
    final chat = _chat!;
    final bot = _room ? null : team?.bot(_id);
    final room = _room ? team?.room(_id) : null;
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) {
        final p = context.p;
        final media = MediaQuery.of(context);
        final barBottom = media.padding.top + _barHeight;
        final dockBottom = media.viewInsets.bottom > 0 ? 8.0 : media.padding.bottom + 8;
        return Scaffold(
          backgroundColor: p.main,
          resizeToAvoidBottomInset: true,
          body: BackdropGroup(
            child: Material(
              type: MaterialType.transparency,
              child: Stack(children: [
                Positioned.fill(child: team == null ? const SizedBox.shrink() : _list(context, team, chat, bot, room, barBottom)),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: barBottom + 22,
                  child: IgnorePointer(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _under,
                      builder: (context, under, child) => AnimatedOpacity(opacity: under, duration: const Duration(milliseconds: 180), child: child),
                      child: _Fade(color: p.main, top: true, solid: media.padding.top / (barBottom + 22)),
                    ),
                  ),
                ),
                Positioned(left: 0, right: 0, bottom: 0, height: dockBottom + 64, child: IgnorePointer(child: _Fade(color: p.main, top: false, solid: 0))),
                Positioned(
                  left: 0,
                  right: 0,
                  top: media.padding.top,
                  height: _barHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: NavigationToolbar(
                      leading: Center(widthFactor: 1, child: IslandButton(child: IconBtn(AppIcon.back, onTap: () => Navigator.maybePop(context)))),
                      middle: _TitleIsland(bot: bot, room: room, team: team, session: session),
                      trailing: _ActionsIsland(
                        onSide: bot == null ? null : () => push(context, SideChatPage(botId: bot.id)),
                        actions: team == null ? null : _moreActions(context, team, session, bot, room),
                      ),
                      middleSpacing: 10,
                    ),
                  ),
                ),
                if (team != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _Measure(onSize: (size) {
                      if ((size.height - _dock).abs() > 1) setState(() => _dock = size.height);
                    }, child: _dockView(context, team, chat, session, bot, room, dockBottom)),
                  ),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _list(BuildContext context, TeamState team, ChatSession chat, Bot? bot, Room? room, double barBottom) {
    final p = context.p;
    final media = MediaQuery.of(context);
    final width = media.size.width - 24;
    final prefs = team.prefs;
    final flat = jStr(prefs, 'layout') == 'flat';
    final widthPct = (jInt(prefs, 'width') ?? 80).clamp(50, 100);
    final narrow = width < 520;
    final span = width - (room != null && !flat ? 34 : 0);
    final botMax = narrow ? (span * 0.93).clamp(0.0, span - 8) : (span * widthPct / 100).clamp(0.0, span - 40);
    final userMax = width * (narrow ? 0.86 : widthPct / 100);
    final rows = chat.rows;
    if (!chat.loaded) {
      if (chat.loadError != null) {
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(errorText(chat.loadError), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3)),
            TextButton(onPressed: chat.refresh, child: Text(t('Retry'))),
          ]),
        );
      }
      return Center(child: CircularProgressIndicator(color: p.accent));
    }
    final streaming = chat.streaming;
    // Below the last message, top to bottom: the reply as it streams, then what
    // each Bot is doing right now.
    final foot = <Widget>[
      if (streaming.isNotEmpty)
        Padding(
          key: const ValueKey('streaming'),
          padding: const EdgeInsets.only(top: 6),
          child: ChatItemView(
            row: ChatRow({'kind': 'bot', 'text': streaming}, 'streaming', null),
            team: team,
            sessionId: chat.sessionId,
            inRoom: room != null,
            flat: flat,
            botMax: botMax,
            userMax: userMax,
            onLongPress: (_) {},
          ),
        ),
      ..._workRows(context, team, bot, room),
    ];
    final count = rows.length + foot.length + 1;
    final list = ListView.builder(
      controller: _scroll,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(12, barBottom + 8, 12, _dock + 8),
      itemCount: count,
      itemBuilder: (context, index) {
        if (index < foot.length) return foot[foot.length - 1 - index];
        final i = index - foot.length;
        if (i == rows.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: chat.loadingOlder
                  ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.ink3))
                  : (chat.hasMore ? const SizedBox(height: 18) : Text(rows.isEmpty ? '' : t('Start of this chat'), style: TypeScale.caption.copyWith(color: p.ink3))),
            ),
          );
        }
        final row = rows[rows.length - 1 - i];
        return Padding(
          key: ValueKey(row.key),
          padding: const EdgeInsets.only(top: 6),
          child: ChatItemView(
            row: row,
            team: team,
            sessionId: chat.sessionId,
            inRoom: room != null,
            flat: flat,
            botMax: botMax,
            userMax: userMax,
            admin: room?.admin,
            onLongPress: (row) => _rowMenu(context, row, chat),
            onRetry: chat.retry,
            onDiscard: chat.discard,
          ),
        );
      },
    );
    return Stack(children: [
      Positioned.fill(
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (notification) {
            // Code blocks and tables in the bubbles scroll too; only the list counts.
            if (notification.depth == 0) _measureUnder(notification.metrics);
            return false;
          },
          child: list,
        ),
      ),
      if (rows.isEmpty && streaming.isEmpty && !chat.gone) Positioned.fill(child: IgnorePointer(child: _EmptyChat(bot: bot, room: room, team: team))),
      if (chat.gone) Center(child: Text(t('No messages yet'), style: TypeScale.small.copyWith(color: p.ink3))),
      Positioned(
        right: 14,
        bottom: _dock + 10,
        child: AnimatedScale(
          scale: _away ? 1 : 0,
          duration: const Duration(milliseconds: 260),
          curve: SpringCurve.pop,
          child: IslandButton(child: IconBtn(AppIcon.arrowDown, size: 20, onTap: _toLatest, tooltip: t('Jump to latest'))),
        ),
      ),
    ]);
  }

  List<Widget> _workRows(BuildContext context, TeamState team, Bot? bot, Room? room) {
    if (bot != null) {
      if (!team.botWorking(bot.id)) return const [];
      return [WorkRow(key: ValueKey('work-${bot.id}'), bot: bot, doing: team.workBots[bot.id] ?? team.activity[bot.id])];
    }
    if (room == null) return const [];
    return [
      for (final entry in team.roomWork(room.id))
        if (team.bot(jStr(entry, 'botId')) case final member?)
          WorkRow(
            key: ValueKey('work-${member.id}'),
            bot: member,
            name: member.name,
            doing: entry,
            onStop: () => run(context, 'stop-member-work', {'roomId': room.id, 'botId': member.id}),
          ),
    ];
  }

  Widget _dockView(BuildContext context, TeamState team, ChatSession chat, TeamSession session, Bot? bot, Room? room, double bottom) {
    final p = context.p;
    final app = AppScope.of(context);
    final running = bot != null ? team.botWorking(bot.id) : (room != null && team.roomWork(room.id).isNotEmpty);
    final members = room == null ? const <Bot>[] : room.members.map(team.bot).whereType<Bot>().toList();
    final canPhotos = session.has('send-images') || session.has('images');
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (room?.goal != null) GoalBar(goal: room!.goal!, roomId: room.id),
        if (bot?.blocked != null) BlockedCard(bot: bot!, team: team),
        if (bot != null) ComputerCards(bot: bot, team: team),
        PendingDock(team: team, sessionId: chat.sessionId, bot: bot, room: room),
        if (chat.loaded && chat.loadError != null)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: floatingCard(p, tint: Palette.danger.withValues(alpha: 0.07), border: Palette.danger.withValues(alpha: 0.25)),
            child: Text(errorText(chat.loadError), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: Palette.danger)),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Composer(
            controller: _composer,
            name: bot?.name ?? room?.name ?? '',
            hint: session.online ? null : offlineLabel(session),
            running: running,
            canStop: running,
            canPhotos: canPhotos,
            canFiles: session.has('file-upload'),
            members: members,
            enterToSend: app.prefs.enterToSend,
            onStop: chat.stop,
            onSend: (text, photos, files) {
              chat.send(text, photos: photos, files: files);
              Future<void>.delayed(const Duration(milliseconds: 60), () {
                if (_scroll.hasClients) _toLatest();
              });
            },
          ),
        ),
      ]),
    );
  }

  Future<void> _newPart(BuildContext context, Bot bot) async {
    final ok = await confirmDanger(context, title: t('Start a new conversation?'), body: t('Earlier conversations stay readable.'), action: t('New conversation'));
    if (!ok || !context.mounted) return;
    await run(context, 'bot-new-part', {'botId': bot.id});
    _chat?.refresh();
  }

  void _rowMenu(BuildContext context, ChatRow row, ChatSession chat) {
    final text = sourceTextOf(row.item);
    final seq = jInt(row.item, 'seq');
    showActions(context, [
      if (text.isNotEmpty)
        MenuAction(t('Copy'), AppIcon.copy, () {
          Clipboard.setData(ClipboardData(text: text));
          toast(context, t('Copied'));
        }),
      if (text.isNotEmpty) MenuAction(t('Select text'), AppIcon.edit, () => showReader(context, text)),
      if (text.isNotEmpty) MenuAction(t('Quote'), AppIcon.quote, () => _composer.insert('${text.split('\n').map((line) => '> $line').join('\n')}\n')),
      if (text.isNotEmpty) MenuAction(t('Share'), AppIcon.share, () => SharePlus.instance.share(ShareParams(text: text))),
      if (seq != null && row.kind != 'user') MenuAction(t('File changes'), AppIcon.diff, () => openChanges(context, chat.sessionId, seq)),
    ]);
  }

  // Details (the title island) and Side chat (its own button) are not repeated here.
  List<MenuAction> _moreActions(BuildContext context, TeamState team, TeamSession session, Bot? bot, Room? room) {
    return [
      if (bot != null) ...[
        MenuAction(t('Memory'), AppIcon.memory, () => push(context, MemoryPage(botId: bot.id))),
        MenuAction(t('New conversation'), AppIcon.plus, () => _newPart(context, bot)),
        MenuAction(t('Earlier conversations'), AppIcon.history, () => push(context, EarlierPage(botId: bot.id))),
        if (team.browserEnabled) MenuAction(t('Browser'), AppIcon.globe, () => push(context, BrowserPage(botId: bot.id))),
        if (session.has('message-search')) MenuAction(t('Search messages'), AppIcon.search, () => push(context, SearchPage(botId: bot.id))),
        MenuAction(t('Usage'), AppIcon.chart, () => push(context, UsagePage(botId: bot.id))),
      ],
      if (room != null) ...[
        MenuAction(t('Memory'), AppIcon.memory, () => push(context, MemoryPage(roomId: room.id))),
        MenuAction(room.goal == null ? t('Set a goal') : t('Group goal'), AppIcon.target, () => showGoalDraft(context, room)),
        MenuAction(t('Task board'), AppIcon.board, () => push(context, TaskBoardPage(roomId: room.id))),
        MenuAction(t('Search messages'), AppIcon.search, () => push(context, SearchPage(roomId: room.id))),
      ],
    ];
  }
}

/// The Bot or group in the middle island: avatar, name and what it is doing.
class _TitleIsland extends StatelessWidget {
  const _TitleIsland({required this.bot, required this.room, required this.team, required this.session});

  final Bot? bot;
  final Room? room;
  final TeamState? team;
  final TeamSession session;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = this.team;
    final bot = this.bot;
    final room = this.room;
    if (bot == null && room == null) return const SizedBox.shrink();
    final working = team != null && (bot != null ? team.botWorking(bot.id) : team.roomWork(room!.id).isNotEmpty);
    final subtitle = !session.online
        ? offlineLabel(session)
        : working
            ? t('Working')
            : bot != null
                ? (bot.role ?? (team?.isMain(bot.id) ?? false ? t('Main Bot') : ''))
                : t('{count} members', {'count': room?.members.length ?? 0});
    return Pressable(
      onTap: () {
        if (bot != null) openBotDetails(context, bot.id);
        if (room != null) openGroupDetails(context, room.id);
      },
      child: GlassIsland(
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 16, 0),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (bot != null) BotAvatar(bot: bot, size: 32, working: working, main: team?.isMain(bot.id) ?? false, ring: p.card),
              if (room != null && team != null) RoomAvatar(room: room, team: team, size: 32, working: working, ring: p.card),
              const SizedBox(width: 8),
              Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    bot?.name ?? room?.name ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TypeScale.rowNameStrong.copyWith(color: p.ink, fontSize: 15, height: 19 / 15, fontWeight: FontWeight.w600),
                  ),
                  if (subtitle.isNotEmpty)
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        subtitle,
                        key: ValueKey(subtitle),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TypeScale.caption.copyWith(color: working ? Palette.green : p.ink3, fontSize: 11, height: 14 / 11),
                      ),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The right island: Side chat (for a Bot) and the menu, side by side.
class _ActionsIsland extends StatelessWidget {
  const _ActionsIsland({required this.onSide, required this.actions});

  final VoidCallback? onSide;
  final List<MenuAction>? actions;

  @override
  Widget build(BuildContext context) {
    final actions = this.actions;
    final more = actions == null
        ? const IconBtn(AppIcon.more)
        : ActionMenu(actions: actions, builder: (context, toggle) => IconBtn(AppIcon.more, onTap: toggle));
    if (onSide == null) return IslandButton(child: more);
    return GlassIsland(
      child: SizedBox(
        height: 44,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconBtn(AppIcon.sparkle, size: 20, tooltip: t('Side chat'), onTap: onSide),
          Container(width: 0.6, height: 18, color: context.p.line2),
          more,
        ]),
      ),
    );
  }
}

/// The page color fading out from the top or the bottom edge, so messages
/// pass softly under the floating islands.
class _Fade extends StatelessWidget {
  const _Fade({required this.color, required this.top, required this.solid});

  final Color color;
  final bool top;

  /// The share of the fade, from its outer edge, that stays solid (the status bar).
  final double solid;

  @override
  Widget build(BuildContext context) {
    final colors = [color, color.withValues(alpha: top ? 0.9 : 0.75), color.withValues(alpha: 0)];
    final stops = [solid.clamp(0.0, 0.6), top ? (solid + 1) / 2 : 0.45, 1.0];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: top ? Alignment.topCenter : Alignment.bottomCenter, end: top ? Alignment.bottomCenter : Alignment.topCenter, colors: colors, stops: stops),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.bot, required this.room, required this.team});

  final Bot? bot;
  final Room? room;
  final TeamState team;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Align(
      alignment: const Alignment(0, -0.35),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (bot != null) BotAvatar(bot: bot, size: 72) else if (room != null) RoomAvatar(room: room!, team: team, size: 72),
        const SizedBox(height: 12),
        Text(bot?.name ?? room?.name ?? '', style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
        if (bot?.role != null) Text(bot!.role!, style: TypeScale.small.copyWith(color: p.ink3)),
        const SizedBox(height: 10),
        Text(t('No messages yet'), style: TypeScale.caption.copyWith(color: p.ink3)),
      ]),
    );
  }
}

/// Reports its child's size after each layout, so the list can clear the dock.
class _Measure extends SingleChildRenderObjectWidget {
  const _Measure({required this.onSize, required super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasure(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasure renderObject) => renderObject.onSize = onSize;
}

class _RenderMeasure extends RenderProxyBox {
  _RenderMeasure(this.onSize);

  ValueChanged<Size> onSize;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    if (size != _last) {
      _last = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => onSize(size));
    }
  }
}
