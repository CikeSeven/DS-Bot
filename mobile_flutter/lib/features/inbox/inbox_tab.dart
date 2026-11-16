// Everything that needs the user, answerable in place, and the notices the
// computer sent: replies, finished work, questions, cards and approvals.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/link_client.dart';
import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../data/json.dart';
import '../../data/pending.dart';
import '../../ui/avatar.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../home/home_shell.dart';
import 'needs_sheet.dart';

class InboxTab extends StatefulWidget {
  const InboxTab({super.key});

  @override
  State<InboxTab> createState() => _InboxTabState();
}

class _InboxTabState extends State<InboxTab> {
  final List<Json> _notices = [];
  StreamSubscription<RpcEvent>? _feed;
  bool _loaded = false;
  String? _boot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = TeamScope.read(context);
    unawaited(_feed?.cancel());
    _feed = session.feed.listen((event) {
      if (event.event != 'notice') return;
      _add([asJson(event.data)]);
    });
    if (!_loaded) unawaited(_load());
  }

  Future<void> _load() async {
    final session = TeamScope.read(context);
    try {
      final answer = asJson(await session.call('notices', {'since': 0}));
      _boot = jStr(answer, 'boot');
      _loaded = true;
      _add(jMaps(answer, 'notices'));
    } on Object {
      // Shown once the link is back.
    }
  }

  void _add(List<Json> entries) {
    if (!mounted) return;
    setState(() {
      for (final entry in entries) {
        final seq = entry['seq'];
        if (seq != null && _notices.any((known) => known['seq'] == seq)) continue;
        _notices.add(entry);
      }
      _notices.sort((a, b) => (jNum(b, 'time') ?? jNum(b, 'seq') ?? 0).compareTo(jNum(a, 'time') ?? jNum(a, 'seq') ?? 0));
      if (_notices.length > 200) _notices.removeRange(200, _notices.length);
    });
  }

  @override
  void dispose() {
    unawaited(_feed?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final session = TeamScope.of(context);
    final team = session.team;
    final pending = pendingItemsOf(team);
    return GlassPage(
      bar: GlassBar(title: Text(t('Inbox'))),
      bodyBuilder: (context) => team == null
          ? const SizedBox.shrink()
          : RefreshIndicator(
              edgeOffset: GlassBar.heightOf(context),
              color: p.accent,
              onRefresh: () async {
                session.refresh();
                await _load();
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, tabBarClearance(context) + 12),
                children: [
                  _Title(t('Needs you'), count: pending.length),
                  if (pending.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      alignment: Alignment.center,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Ico(AppIcon.check, size: 18, color: Palette.green),
                        const SizedBox(width: 8),
                        Text(t('Nothing needs you'), style: TypeScale.small.copyWith(color: p.ink2)),
                      ]),
                    )
                  else
                    for (final item in pending) Padding(padding: const EdgeInsets.only(bottom: 10), child: NeedCard(key: ValueKey(item.key), item: item, team: team)),
                  const SizedBox(height: 8),
                  _Title(t('Notifications')),
                  if (_notices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(t('No notifications yet'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3)),
                    )
                  else
                    ClipRRect(
                      borderRadius: BorderRadius.circular(Radii.dialog),
                      child: ColoredBox(
                        color: p.card.withValues(alpha: 0.9),
                        child: Column(children: [
                          for (final (index, notice) in _notices.indexed) ...[
                            if (index > 0) Divider(height: 0.5, thickness: 0.5, indent: 60, color: p.line),
                            _NoticeRow(notice: notice, boot: _boot),
                          ],
                        ]),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text, {this.count});

  final String text;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Row(children: [
        Text(text, style: TypeScale.sectionTitle.copyWith(color: p.ink)),
        if (count != null && count! > 0) ...[const SizedBox(width: 8), CountBadge(count!)],
      ]),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.notice, this.boot});

  final Json notice;
  final String? boot;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final kind = jStr(notice, 'kind');
    final bot = team?.bot(jStr(notice, 'botId'));
    final roomId = jStr(notice, 'roomId');
    final room = team?.room(roomId);
    final (icon, color) = switch (kind) {
      'question' => (AppIcon.question, p.accent),
      'approval' => (AppIcon.shield, Palette.star),
      'done' => (AppIcon.check, Palette.green),
      'view' => (AppIcon.board, p.accent),
      'group' => (AppIcon.people, p.ink2),
      _ => (AppIcon.chat, p.ink2),
    };
    final time = jInt(notice, 'time');
    return InkWell(
      onTap: () => openChat(context, roomId: roomId, botId: roomId == null ? jStr(notice, 'botId') : null),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(clipBehavior: Clip.none, children: [
            BotAvatar(bot: bot, size: 34, ring: p.card),
            Positioned(
              right: -4,
              bottom: -4,
              child: Container(
                padding: const EdgeInsets.all(2.5),
                decoration: BoxDecoration(color: p.card, shape: BoxShape.circle),
                child: Container(
                  padding: const EdgeInsets.all(2.5),
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: Ico(icon, size: 10, color: Colors.white),
                ),
              ),
            ),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(
                    room != null ? '${jStr(notice, 'name') ?? bot?.name ?? ''} · ${room.name}' : (jStr(notice, 'title') ?? jStr(notice, 'name') ?? bot?.name ?? ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TypeScale.smallStrong.copyWith(color: p.ink),
                  ),
                ),
                if (time != null) Text(shortWhen(time), style: TypeScale.caption.copyWith(color: p.ink3)),
              ]),
              const SizedBox(height: 2),
              Text(jStr(notice, 'text') ?? '', maxLines: 3, overflow: TextOverflow.ellipsis, style: TypeScale.small.copyWith(color: p.ink2)),
            ]),
          ),
        ]),
      ),
    );
  }
}
