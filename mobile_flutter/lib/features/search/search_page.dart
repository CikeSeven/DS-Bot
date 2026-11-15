// Search: Bots and groups by name, group messages (`group-search`), and Bot
// messages when the computer offers `message-search`.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../data/json.dart';
import '../../data/team_state.dart';
import '../../ui/avatar.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.botId, this.roomId});

  final String? botId;
  final String? roomId;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _Hit {
  const _Hit({required this.text, this.time, this.botId, this.name, this.roomId, this.chatBotId});

  final String text;
  final int? time;
  final String? botId;
  final String? name;
  final String? roomId;
  final String? chatBotId;
}

class _SearchPageState extends State<SearchPage> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<_Hit> _hits = const [];
  bool _searching = false;
  int _generation = 0;

  @override
  void dispose() {
    _query.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _changed(String _) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    final generation = ++_generation;
    if (query.length < 2) {
      setState(() => _hits = const []);
      return;
    }
    final session = TeamScope.read(context);
    final team = session.team;
    if (team == null) return;
    setState(() => _searching = true);
    final hits = <_Hit>[];
    Future<void> group(Room room) async {
      try {
        final value = await session.call('group-search', {'roomId': room.id, 'query': query});
        for (final result in jMaps(value, 'results')) {
          hits.add(_Hit(text: jStr(result, 'text') ?? '', time: jInt(result, 'time'), botId: jStr(result, 'botId'), name: jStr(result, 'name'), roomId: room.id));
        }
      } on Object {
        // One group failing does not hide the others.
      }
    }

    Future<void> bot(Bot bot) async {
      try {
        final value = await session.call('message-search', {'botId': bot.id, 'query': query});
        for (final result in jMaps(value, 'results')) {
          hits.add(_Hit(text: jStr(result, 'text') ?? '', time: jInt(result, 'time'), botId: jStr(result, 'role') == 'user' ? null : bot.id, name: jStr(result, 'role') == 'user' ? t('You') : bot.name, chatBotId: bot.id));
        }
      } on Object {
        // Older computers have no message search.
      }
    }

    final canBots = session.has('message-search');
    final rooms = widget.roomId != null ? [team.room(widget.roomId)].whereType<Room>() : (widget.botId != null ? const <Room>[] : team.rooms);
    final bots = widget.botId != null ? [team.bot(widget.botId)].whereType<Bot>() : (widget.roomId != null || !canBots ? const <Bot>[] : team.bots);
    await Future.wait([...rooms.map(group), if (canBots || widget.botId != null) ...bots.map(bot)]);
    if (!mounted || generation != _generation) return;
    hits.sort((a, b) => (b.time ?? 0).compareTo(a.time ?? 0));
    setState(() {
      _hits = hits;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final query = _query.text.trim().toLowerCase();
    final scoped = widget.botId != null || widget.roomId != null;
    final names = scoped || team == null || query.isEmpty
        ? const <Object>[]
        : <Object>[
            ...team.bots.where((bot) => bot.name.toLowerCase().contains(query) || (bot.role ?? '').toLowerCase().contains(query)),
            ...team.rooms.where((room) => room.name.toLowerCase().contains(query)),
          ];
    return Scaffold(
      backgroundColor: p.main,
      body: GlassPage(
        bar: GlassBar(
          leading: IconBtn(AppIcon.back, onTap: () => Navigator.pop(context)),
          center: false,
          title: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextField(
              controller: _query,
              autofocus: true,
              onChanged: _changed,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              style: TypeScale.settingsRow.copyWith(color: p.ink),
              decoration: InputDecoration(
                hintText: scoped ? t('Search messages') : t('Search Bots, groups and messages'),
                prefixIcon: Padding(padding: const EdgeInsets.all(10), child: Ico(AppIcon.search, size: 18, color: p.ink3)),
                prefixIconConstraints: const BoxConstraints(minWidth: 38),
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
              ),
            ),
          ),
        ),
        bodyBuilder: (context) => team == null
            ? const SizedBox.shrink()
            : ListView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.fromLTRB(0, MediaQuery.paddingOf(context).top + 8, 0, 32),
                children: [
                  if (names.isNotEmpty)
                    Group(title: t('Bots and groups'), children: [
                      for (final entry in names)
                        if (entry is Bot)
                          Row2(title: entry.name, subtitle: entry.role, leading: BotAvatar(bot: entry, size: 34, ring: p.card), onTap: () => openChat(context, botId: entry.id))
                        else if (entry is Room)
                          Row2(title: entry.name, leading: RoomAvatar(room: entry, team: team, size: 34, ring: p.card), onTap: () => openChat(context, roomId: entry.id)),
                    ]),
                  if (_searching) Padding(padding: const EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(color: p.accent))),
                  if (!_searching && _hits.isNotEmpty)
                    Group(title: t('Messages'), children: [
                      for (final hit in _hits.take(80)) _HitRow(hit: hit, team: team, query: query),
                    ]),
                  if (!_searching && query.length >= 2 && _hits.isEmpty && names.isEmpty)
                    Padding(padding: const EdgeInsets.all(40), child: Text(t('No results'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3))),
                ],
              ),
      ),
    );
  }
}

class _HitRow extends StatelessWidget {
  const _HitRow({required this.hit, required this.team, required this.query});

  final _Hit hit;
  final TeamState team;
  final String query;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final room = team.room(hit.roomId);
    final bot = team.bot(hit.botId);
    final text = hit.text.replaceAll(RegExp(r'\s+'), ' ');
    final at = text.toLowerCase().indexOf(query.split(' ').first);
    final start = at > 40 ? at - 30 : 0;
    final snippet = (start > 0 ? '…' : '') + text.substring(start);
    return InkWell(
      onTap: () => hit.roomId != null ? openChat(context, roomId: hit.roomId) : openChat(context, botId: hit.chatBotId),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          BotAvatar(bot: bot, size: 30, ring: p.card),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(
                    [hit.name ?? bot?.name ?? t('You'), if (room != null) room.name].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TypeScale.smallStrong.copyWith(color: p.ink),
                  ),
                ),
                if (hit.time != null) Text(shortWhen(hit.time!), style: TypeScale.caption.copyWith(color: p.ink3)),
              ]),
              const SizedBox(height: 2),
              Text(snippet, maxLines: 3, overflow: TextOverflow.ellipsis, style: TypeScale.small.copyWith(color: p.ink2)),
            ]),
          ),
        ]),
      ),
    );
  }
}
