// The team at a glance: what needs you, the Main Bots, then every Bot and group
// chat by section. Rows slide for quick actions and long-press for more.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../data/chat_items.dart';
import '../../data/json.dart';
import '../../data/pending.dart';
import '../../data/team_session.dart';
import '../../data/team_state.dart';
import '../../ui/avatar.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/swipe_row.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../home/home_shell.dart';
import '../inbox/needs_sheet.dart';
import '../manage/bot_pages.dart';
import '../manage/group_pages.dart';
import '../search/search_page.dart';
import '../settings/computers_page.dart';

class TeamTab extends StatefulWidget {
  const TeamTab({super.key});

  @override
  State<TeamTab> createState() => _TeamTabState();
}

class _TeamTabState extends State<TeamTab> {
  bool _showHidden = false;
  final Set<String> _collapsed = {};

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final session = TeamScope.of(context);
    final app = AppScope.of(context);
    final team = session.team;
    final pending = pendingItemsOf(team);
    return GlassPage(
      bar: GlassBar(
        center: false,
        title: _ComputerTitle(session: session, onTap: () => push(context, const ComputersPage())),
        actions: [
          IconBtn(AppIcon.search, onTap: () => push(context, const SearchPage())),
          IconBtn(AppIcon.plus, onTap: () => _create(context)),
          const SizedBox(width: 4),
        ],
      ),
      body: team == null
          ? _Loading(session: session)
          : RefreshIndicator(
              edgeOffset: GlassBar.heightOf(context),
              color: p.accent,
              onRefresh: () async {
                session.refresh();
                await Future<void>.delayed(const Duration(milliseconds: 600));
              },
              child: ListenableBuilder(
                listenable: app.seen,
                builder: (context, _) => CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                  slivers: [
                    SliverPadding(padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 4)),
                    if (!session.online) SliverToBoxAdapter(child: _OfflineLine(session: session)),
                    if (team.readOnly != null) SliverToBoxAdapter(child: _ReadOnlyLine(reason: team.readOnly!)),
                    if (pending.isNotEmpty) SliverToBoxAdapter(child: _NeedsStrip(items: pending, team: team)),
                    SliverToBoxAdapter(child: _MainTiles(team: team, pending: pending)),
                    ..._lists(context, team, pending, session),
                    SliverPadding(padding: EdgeInsets.only(bottom: tabBarClearance(context) + 12)),
                  ],
                ),
              ),
            ),
    );
  }

  List<Widget> _lists(BuildContext context, TeamState team, List<PendingItem> pending, TeamSession session) {
    final app = AppScope.read(context);
    final hostId = session.computer.hostDeviceId;
    final mains = team.mainBotIds.toSet();
    final entries = <_Entry>[
      for (final bot in team.bots)
        if (!mains.contains(bot.id)) _Entry.bot(bot),
      for (final room in team.rooms) _Entry.room(room),
    ];
    int when(_Entry entry) => entry.lastAt ?? entry.createdAt ?? 0;
    entries.sort((a, b) => when(b).compareTo(when(a)));
    final visible = entries.where((entry) => !entry.hidden).toList();
    final hidden = entries.where((entry) => entry.hidden).toList();
    final pinned = visible.where((entry) => entry.pinned).toList();
    final sections = team.sections;
    final sectionIds = sections.map((section) => jStr(section, 'id')).toSet();
    final loose = visible.where((entry) => !entry.pinned && (entry.sectionId == null || !sectionIds.contains(entry.sectionId))).toList();

    Widget rows(List<_Entry> list) => SliverList.builder(
          itemCount: list.length,
          itemBuilder: (context, index) => _TeamRow(
            key: ValueKey(list[index].id),
            entry: list[index],
            team: team,
            pending: pending,
            unread: app.seen.isUnread(hostId, list[index].id, list[index].lastAt),
          ),
        );

    final slivers = <Widget>[];
    if (pinned.isNotEmpty) {
      slivers
        ..add(SliverToBoxAdapter(child: _Header(title: t('Pinned'), icon: AppIcon.pin)))
        ..add(rows(pinned));
    }
    for (final section in sections) {
      final id = jStr(section, 'id') ?? '';
      final members = visible.where((entry) => !entry.pinned && entry.sectionId == id).toList();
      final collapsed = _collapsed.contains(id) || (jBool(section, 'collapsed') == true && !_collapsed.contains('open:$id'));
      slivers.add(SliverToBoxAdapter(
        child: _Header(
          title: jStr(section, 'name') ?? '',
          count: members.length,
          collapsed: collapsed,
          color: jStr(section, 'color'),
          onTap: () => setState(() {
            if (collapsed) {
              _collapsed.remove(id);
              _collapsed.add('open:$id');
            } else {
              _collapsed.add(id);
              _collapsed.remove('open:$id');
            }
          }),
        ),
      ));
      if (!collapsed) slivers.add(rows(members));
    }
    if (loose.isNotEmpty) {
      if (slivers.isNotEmpty) slivers.add(SliverToBoxAdapter(child: _Header(title: t('Chats'))));
      slivers.add(rows(loose));
    }
    if (hidden.isNotEmpty) {
      slivers.add(SliverToBoxAdapter(
        child: _Header(
          title: t('Hidden'),
          icon: AppIcon.eyeOff,
          count: hidden.length,
          collapsed: !_showHidden,
          onTap: () => setState(() => _showHidden = !_showHidden),
        ),
      ));
      if (_showHidden) slivers.add(rows(hidden));
    }
    if (entries.isEmpty && team.mainBotIds.isEmpty) {
      slivers.add(SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(icon: AppIcon.people, title: t('No Bots yet'), action: Btn(t('Create new Bot'), icon: AppIcon.plus, onTap: () => showNewBot(context))),
      ));
    }
    return slivers;
  }

  void _create(BuildContext context) {
    showActions(context, [
      MenuAction(t('Create new Bot'), AppIcon.sparkle, () => showNewBot(context)),
      MenuAction(t('Create group chat'), AppIcon.people, () => showNewGroup(context)),
      MenuAction(t('New section'), AppIcon.section, () => editSection(context)),
    ]);
  }
}

class _Entry {
  _Entry.bot(Bot this.bot) : room = null;
  _Entry.room(Room this.room) : bot = null;

  final Bot? bot;
  final Room? room;

  String get id => bot?.id ?? room!.id;
  String get name => bot?.name ?? room!.name;
  int? get lastAt => bot?.lastAt ?? room?.lastAt;
  int? get createdAt => bot?.createdAt ?? room?.createdAt;
  bool get pinned => bot?.pinned ?? room!.pinned;
  bool get hidden => bot?.hidden ?? room!.hidden;
  String? get sectionId => bot?.sectionId ?? room?.sectionId;
}

class _ComputerTitle extends StatelessWidget {
  const _ComputerTitle({required this.session, required this.onTap});

  final TeamSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final name = session.hostName ?? session.computer.name;
    final color = session.online ? Palette.green : (session.error != null ? Palette.danger : p.ink3);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('DS Bot', style: TypeScale.headerTitle.copyWith(color: p.ink)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(duration: const Duration(milliseconds: 300), width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                session.online ? (name.isEmpty ? t('Connected') : name) : (session.linked ? t('Connecting…') : t('Reconnecting…')),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TypeScale.caption.copyWith(color: p.ink2),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading({required this.session});

  final TeamSession session;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final error = session.error;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (error == null) CircularProgressIndicator(color: p.accent) else Ico(AppIcon.alert, size: 36, color: p.ink3),
          const SizedBox(height: 16),
          Text(error == null ? t('Connecting to your computer…') : errorText(error), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink2)),
          if (error != null) ...[
            const SizedBox(height: 16),
            Btn(t('Computers'), kind: BtnKind.secondary, icon: AppIcon.monitor, onTap: () => push(context, const ComputersPage())),
          ],
        ]),
      ),
    );
  }
}

class _OfflineLine extends StatelessWidget {
  const _OfflineLine({required this.session});

  final TeamSession session;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: p.bubble.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(Radii.card)),
      child: Row(children: [
        SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.ink3)),
        const SizedBox(width: 10),
        Expanded(child: Text(session.error == null ? t('Reconnecting…') : errorText(session.error), style: TypeScale.small.copyWith(color: p.ink2))),
      ]),
    );
  }
}

class _ReadOnlyLine extends StatelessWidget {
  const _ReadOnlyLine({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Palette.star.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(Radii.card)),
      child: Row(children: [
        const Ico(AppIcon.lock, size: 16, color: Palette.star),
        const SizedBox(width: 10),
        Expanded(child: Text(hostText(reason), style: TypeScale.small.copyWith(color: p.ink))),
      ]),
    );
  }
}

/// What waits for the user, as cards to answer in place.
class _NeedsStrip extends StatelessWidget {
  const _NeedsStrip({required this.items, required this.team});

  final List<PendingItem> items;
  final TeamState team;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
        child: Row(children: [
          Text(t('Needs you'), style: TypeScale.sectionTitle.copyWith(color: p.ink)),
          const SizedBox(width: 8),
          CountBadge(items.length),
          const Spacer(),
          TextButton(onPressed: () => HomeShell.selectTab(context, 1), child: Text(t('See all'), style: TypeScale.smallStrong.copyWith(color: p.accent))),
        ]),
      ),
      SizedBox(
        height: 188,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) => SizedBox(width: 292, child: NeedCard(item: items[index], team: team, compact: true)),
        ),
      ),
    ]);
  }
}

class _MainTiles extends StatelessWidget {
  const _MainTiles({required this.team, required this.pending});

  final TeamState team;
  final List<PendingItem> pending;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final mains = team.mainBotIds.map(team.bot).whereType<Bot>().toList();
    if (mains.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(children: [
        for (final (index, bot) in mains.take(3).indexed) ...[
          if (index > 0) const SizedBox(width: 10),
          Expanded(
            child: Pressable(
              onTap: () => openChat(context, botId: bot.id),
              onLongPress: () => openBotDetails(context, bot.id),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: p.card.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(Radii.dialog), border: Border.all(color: p.line)),
                child: Row(children: [
                  BotAvatar(
                    bot: bot,
                    size: mains.length == 1 ? 48 : 40,
                    main: true,
                    working: team.botWorking(bot.id),
                    waiting: botHasPending(pending, bot.id),
                    ring: p.card,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(bot.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
                      Text(
                        team.botWorking(bot.id) ? workPhrase(team.workBots[bot.id]) : (bot.role ?? t('Main Bot')),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TypeScale.caption.copyWith(color: team.botWorking(bot.id) ? Palette.green : p.ink2),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, this.icon, this.count, this.collapsed, this.onTap, this.color});

  final String title;
  final AppIcon? icon;
  final int? count;
  final bool? collapsed;
  final VoidCallback? onTap;
  final String? color;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 6),
        child: Row(children: [
          if (color != null) ...[
            Container(width: 8, height: 8, decoration: BoxDecoration(color: _sectionColor(color!, p), shape: BoxShape.circle)),
            const SizedBox(width: 8),
          ] else if (icon != null) ...[
            Ico(icon!, size: 14, color: p.ink3),
            const SizedBox(width: 6),
          ],
          Text(title, style: TypeScale.smallStrong.copyWith(color: p.ink2)),
          if (count != null) ...[const SizedBox(width: 6), Text('$count', style: TypeScale.caption.copyWith(color: p.ink3))],
          const Spacer(),
          if (collapsed != null)
            AnimatedRotation(turns: collapsed! ? -0.25 : 0, duration: const Duration(milliseconds: 220), child: Ico(AppIcon.down, size: 16, color: p.ink3)),
        ]),
      ),
    );
  }
}

Color _sectionColor(String color, Palette p) => switch (color) {
      'red' => const Color(0xFFE5484D),
      'orange' => const Color(0xFFF76B15),
      'yellow' => const Color(0xFFD4A017),
      'green' => const Color(0xFF30A46C),
      'blue' => const Color(0xFF4F7DF3),
      'violet' => const Color(0xFF7D5AFF),
      'pink' || 'magenta' => const Color(0xFFD3458B),
      _ => p.ink3,
    };

class _TeamRow extends StatelessWidget {
  const _TeamRow({super.key, required this.entry, required this.team, required this.pending, required this.unread});

  final _Entry entry;
  final TeamState team;
  final List<PendingItem> pending;
  final bool unread;

  String _preview() {
    final bot = entry.bot;
    final room = entry.room;
    if (bot != null) {
      if (team.questions.containsKey(bot.chatSession)) return t('Waiting for your answer');
      if (pending.any((item) => item.kind == PendingKind.approval && item.botId == bot.id && item.roomId == null)) return t('Waiting for your approval');
      final doing = team.workBots[bot.id];
      if (doing != null) return workPhrase(doing);
      return cleanPreview(bot.preview) ?? bot.role ?? '';
    }
    if (roomHasPending(pending, room!.id)) return t('Waiting for your approval');
    final work = team.roomWork(room.id);
    if (work.isNotEmpty) return '${team.bot(jStr(work.first, 'botId'))?.name ?? ''} · ${workPhrase(work.first)}';
    return cleanPreview(room.preview) ?? t('{count} members', {'count': room.members.length});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final bot = entry.bot;
    final room = entry.room;
    final working = bot != null ? team.botWorking(bot.id) : team.roomWork(room!.id).isNotEmpty;
    final waiting = bot != null ? botHasPending(pending, bot.id) : roomHasPending(pending, room!.id);
    final preview = _preview();
    final lastAt = entry.lastAt;
    final highlight = waiting || working;
    return SwipeRow(
      leading: [
        if (unread) SwipeAction(icon: AppIcon.check, label: t('Read'), color: p.accent, run: () => _markRead(context)),
      ],
      trailing: [
        SwipeAction(icon: entry.pinned ? AppIcon.unpin : AppIcon.pin, label: entry.pinned ? t('Unpin') : t('Pin'), color: Palette.star, run: () => _flag(context, pinned: !entry.pinned)),
        SwipeAction(icon: entry.hidden ? AppIcon.eye : AppIcon.eyeOff, label: entry.hidden ? t('Show') : t('Hide'), color: p.ink3, run: () => _flag(context, hidden: !entry.hidden)),
      ],
      child: InkWell(
        onTap: () => bot != null ? openChat(context, botId: bot.id) : openChat(context, roomId: room!.id),
        onLongPress: () => _menu(context, working),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(children: [
            if (bot != null)
              BotAvatar(bot: bot, size: 48, working: working, waiting: waiting)
            else
              RoomAvatar(room: room!, team: team, size: 48, working: working, waiting: waiting),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: (unread ? TypeScale.rowNameStrong : TypeScale.rowName).copyWith(color: p.ink)),
                  ),
                  if (bot?.isPrivate ?? false) ...[const SizedBox(width: 4), Ico(AppIcon.lock, size: 13, color: p.ink3)],
                  if (bot?.engine != null) ...[const SizedBox(width: 6), Tag(bot!.engine!)],
                  const Spacer(),
                  if (lastAt != null) Text(shortWhen(lastAt), style: TypeScale.caption.copyWith(color: unread ? p.accent : p.ink3)),
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  Expanded(
                    child: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TypeScale.rowPreview.copyWith(color: waiting ? p.accent : (working ? Palette.green : p.ink2)),
                    ),
                  ),
                  if (entry.pinned) Padding(padding: const EdgeInsets.only(left: 6), child: Ico(AppIcon.pin, size: 14, color: p.ink3)),
                  if (unread && !highlight)
                    Container(margin: const EdgeInsets.only(left: 8), width: 9, height: 9, decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle)),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  void _markRead(BuildContext context) {
    final app = AppScope.read(context);
    final session = TeamScope.read(context);
    unawaited(app.seen.markSeen(session.computer.hostDeviceId, entry.id, entry.lastAt ?? DateTime.now().millisecondsSinceEpoch));
  }

  void _flag(BuildContext context, {bool? pinned, bool? hidden}) {
    unawaited(run(context, 'set-flags', {'id': entry.id, 'pinned': ?pinned, 'hidden': ?hidden}));
  }

  void _menu(BuildContext context, bool working) {
    final bot = entry.bot;
    final team = TeamScope.read(context).team;
    showActions(
      context,
      [
        MenuAction(entry.pinned ? t('Unpin') : t('Pin'), entry.pinned ? AppIcon.unpin : AppIcon.pin, () => _flag(context, pinned: !entry.pinned)),
        MenuAction(entry.hidden ? t('Show') : t('Hide'), entry.hidden ? AppIcon.eye : AppIcon.eyeOff, () => _flag(context, hidden: !entry.hidden)),
        MenuAction(t('Mark as read'), AppIcon.check, () => _markRead(context)),
        if ((team?.sections ?? const []).isNotEmpty) MenuAction(t('Move to section'), AppIcon.section, () => moveToSection(context, entry.id, entry.sectionId)),
        if (working)
          MenuAction(t('Stop'), AppIcon.stop, () {
            unawaited(bot != null ? run(context, 'stop-chat', {'botId': bot.id}) : run(context, 'stop-room-work', {'roomId': entry.room!.id}));
          }, danger: true),
        if (bot != null) MenuAction(t('New conversation'), AppIcon.plus, () => run(context, 'bot-new-part', {'botId': bot.id})),
        MenuAction(t('Details'), AppIcon.forward, () => bot != null ? openBotDetails(context, bot.id) : openGroupDetails(context, entry.room!.id)),
      ],
      header: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Text(entry.name, style: TypeScale.headerTitle.copyWith(color: context.p.ink)),
      ),
    );
  }
}
