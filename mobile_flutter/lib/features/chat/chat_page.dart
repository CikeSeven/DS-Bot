// A chat with a Bot or a group: a calm solid message list under a frosted bar,
// and a frosted dock with what waits for the user, quick actions and the box.
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
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
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
    super.dispose();
  }

  void _onScroll() {
    final away = _scroll.offset > 600;
    if (away != _away) setState(() => _away = away);
    if (_scroll.position.extentAfter < 600) unawaited(_chat?.loadMore());
  }

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
        return Scaffold(
          backgroundColor: context.p.main,
          resizeToAvoidBottomInset: true,
          body: GlassPage(
            solid: true,
            bar: GlassBar(
              leading: IconBtn(AppIcon.back, onTap: () => Navigator.maybePop(context)),
              title: _TitlePill(bot: bot, room: room, team: team, session: session),
              actions: [
                if (bot != null) IconBtn(AppIcon.sparkle, tooltip: t('Side chat'), onTap: () => push(context, SideChatPage(botId: bot.id))),
                IconBtn(AppIcon.more, onTap: team == null ? null : () => _more(context, team, bot, room)),
              ],
            ),
            bodyBuilder: (context) => team == null ? const SizedBox.shrink() : _list(context, team, chat, bot, room),
            dock: team == null ? null : _Measure(onSize: (size) {
              if ((size.height - _dock).abs() > 1) setState(() => _dock = size.height);
            }, child: _dockView(context, team, chat, session, bot, room)),
          ),
        );
      },
    );
  }

  Widget _list(BuildContext context, TeamState team, ChatSession chat, Bot? bot, Room? room) {
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
    final count = rows.length + (streaming.isNotEmpty ? 1 : 0) + 1;
    final list = ListView.builder(
      controller: _scroll,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(12, media.padding.top + 8, 12, _dock + 8),
      itemCount: count,
      itemBuilder: (context, index) {
        var i = index;
        if (streaming.isNotEmpty) {
          if (i == 0) {
            return Padding(
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
            );
          }
          i -= 1;
        }
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
            onSteps: TeamScope.read(context).has('step-detail') ? (item) => showStepDetail(context, chat.sessionId, item) : null,
          ),
        );
      },
    );
    return Stack(children: [
      Positioned.fill(child: list),
      if (rows.isEmpty && streaming.isEmpty && !chat.gone) Positioned.fill(child: IgnorePointer(child: _EmptyChat(bot: bot, room: room, team: team))),
      if (chat.gone) Center(child: Text(t('No messages yet'), style: TypeScale.small.copyWith(color: p.ink3))),
      Positioned(
        right: 14,
        bottom: _dock + 12,
        child: AnimatedScale(
          scale: _away ? 1 : 0,
          duration: const Duration(milliseconds: 260),
          curve: SpringCurve.pop,
          child: GlassSurface(
            radius: BorderRadius.circular(22),
            edge: GlassEdge.all,
            elevated: true,
            child: IconBtn(AppIcon.arrowDown, size: 20, onTap: _toLatest, tooltip: t('Jump to latest')),
          ),
        ),
      ),
    ]);
  }

  Widget _dockView(BuildContext context, TeamState team, ChatSession chat, TeamSession session, Bot? bot, Room? room) {
    final p = context.p;
    final app = AppScope.of(context);
    final work = <({Bot? bot, String text, VoidCallback? stop})>[];
    if (bot != null) {
      final doing = team.workBots[bot.id] ?? team.activity[bot.id];
      if (team.botWorking(bot.id)) work.add((bot: bot, text: workPhrase(doing), stop: null));
    } else if (room != null) {
      for (final entry in team.roomWork(room.id)) {
        final member = team.bot(jStr(entry, 'botId'));
        work.add((
          bot: member,
          text: '${member?.name ?? ''} · ${workPhrase(entry)}',
          stop: member == null ? null : () => run(context, 'stop-member-work', {'roomId': room.id, 'botId': member.id}),
        ));
      }
    }
    final running = work.isNotEmpty;
    final chips = <({AppIcon icon, String label, VoidCallback onTap})>[
      if (bot != null) ...[
        (icon: AppIcon.plus, label: t('New conversation'), onTap: () => _newPart(context, bot)),
        (icon: AppIcon.history, label: t('Earlier conversations'), onTap: () => push(context, EarlierPage(botId: bot.id))),
        (icon: AppIcon.memory, label: t('Memory'), onTap: () => push(context, MemoryPage(botId: bot.id))),
      ],
      if (room != null) ...[
        (icon: AppIcon.target, label: room.goal == null ? t('Set a goal') : t('Group goal'), onTap: () => showGoalDraft(context, room)),
        (icon: AppIcon.board, label: t('Task board'), onTap: () => push(context, TaskBoardPage(roomId: room.id))),
        (icon: AppIcon.search, label: t('Search messages'), onTap: () => push(context, SearchPage(roomId: room.id))),
      ],
    ];
    final members = room == null ? const <Bot>[] : room.members.map(team.bot).whereType<Bot>().toList();
    final canPhotos = session.has('send-images') || session.has('images');
    return GlassSurface(
      edge: GlassEdge.top,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom > 0 ? 8 : MediaQuery.paddingOf(context).bottom + 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (room?.goal != null) GoalBar(goal: room!.goal!, roomId: room.id),
          if (bot?.blocked != null) BlockedCard(bot: bot!, team: team),
          if (bot != null) ComputerCards(bot: bot, team: team),
          if (running) WorkLine(entries: work, onStop: chat.stop),
          PendingDock(team: team, sessionId: chat.sessionId, bot: bot, room: room),
          if (chat.loaded && chat.loadError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(errorText(chat.loadError), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: Palette.danger)),
            ),
          QuickChips(chips: chips),
          const SizedBox(height: 6),
          Composer(
            controller: _composer,
            name: bot?.name ?? room?.name ?? '',
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
          if (!session.online)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(t('Reconnecting…'), textAlign: TextAlign.center, style: TypeScale.caption.copyWith(color: p.ink3)),
            ),
        ]),
      ),
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

  void _more(BuildContext context, TeamState team, Bot? bot, Room? room) {
    final session = TeamScope.read(context);
    showActions(context, [
      if (bot != null) ...[
        MenuAction(t('Details'), AppIcon.forward, () => openBotDetails(context, bot.id)),
        MenuAction(t('Memory'), AppIcon.memory, () => push(context, MemoryPage(botId: bot.id))),
        MenuAction(t('Side chat'), AppIcon.sparkle, () => push(context, SideChatPage(botId: bot.id))),
        MenuAction(t('New conversation'), AppIcon.plus, () => _newPart(context, bot)),
        MenuAction(t('Earlier conversations'), AppIcon.history, () => push(context, EarlierPage(botId: bot.id))),
        if (team.browserEnabled) MenuAction(t('Browser'), AppIcon.globe, () => push(context, BrowserPage(botId: bot.id))),
        if (session.has('message-search')) MenuAction(t('Search messages'), AppIcon.search, () => push(context, SearchPage(botId: bot.id))),
        MenuAction(t('Usage'), AppIcon.chart, () => push(context, UsagePage(botId: bot.id))),
      ],
      if (room != null) ...[
        MenuAction(t('Group details'), AppIcon.forward, () => openGroupDetails(context, room.id)),
        MenuAction(t('Memory'), AppIcon.memory, () => push(context, MemoryPage(roomId: room.id))),
        MenuAction(room.goal == null ? t('Set a goal') : t('Group goal'), AppIcon.target, () => showGoalDraft(context, room)),
        MenuAction(t('Task board'), AppIcon.board, () => push(context, TaskBoardPage(roomId: room.id))),
        MenuAction(t('Search messages'), AppIcon.search, () => push(context, SearchPage(roomId: room.id))),
      ],
    ]);
  }
}

class _TitlePill extends StatelessWidget {
  const _TitlePill({required this.bot, required this.room, required this.team, required this.session});

  final Bot? bot;
  final Room? room;
  final TeamState? team;
  final TeamSession session;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = this.team;
    final working = team != null && (bot != null ? team.botWorking(bot!.id) : (room != null && team.roomWork(room!.id).isNotEmpty));
    final subtitle = !session.online
        ? t('Reconnecting…')
        : working
            ? t('Working')
            : bot != null
                ? (bot!.role ?? (team?.isMain(bot!.id) ?? false ? t('Main Bot') : ''))
                : t('{count} members', {'count': room?.members.length ?? 0});
    return Pressable(
      onTap: () {
        if (bot != null) openBotDetails(context, bot!.id);
        if (room != null) openGroupDetails(context, room!.id);
      },
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (bot != null) BotAvatar(bot: bot, size: 30, working: working, main: team?.isMain(bot!.id) ?? false, ring: p.main),
        if (room != null && team != null) RoomAvatar(room: room!, team: team, size: 30, working: working, ring: p.main),
        const SizedBox(width: 8),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(bot?.name ?? room?.name ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
            if (subtitle.isNotEmpty)
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.caption.copyWith(color: working ? Palette.green : p.ink2)),
          ]),
        ),
      ]),
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
