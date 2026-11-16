// The messages two Bots sent each other, as the desktop's exchange dialog
// shows them. It reads again while open, so a reply in flight shows up.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/chat_items.dart';
import '../../data/chat_session.dart';
import '../../data/json.dart';
import '../../data/team_state.dart';
import '../../ui/avatar.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'chat_item_view.dart';
import 'media.dart';

class ExchangePage extends StatefulWidget {
  const ExchangePage({super.key, required this.a, required this.b});

  final String a;
  final String b;

  @override
  State<ExchangePage> createState() => _ExchangePageState();
}

class _ExchangePageState extends State<ExchangePage> with WidgetsBindingObserver {
  static const _again = Duration(milliseconds: 2500);
  static const _gap = 30 * 60 * 1000;

  List<Json>? _entries;
  Object? _error;
  Timer? _timer;
  bool _reading = false;
  bool _away = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _away = state != AppLifecycleState.resumed;
    if (!_away) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted || _reading) return;
    _reading = true;
    _timer?.cancel();
    try {
      final value = await TeamScope.read(context).call('exchange', {'a': widget.a, 'b': widget.b});
      if (!mounted) return;
      final next = value is List ? value.whereType<Map>().map((entry) => entry.cast<String, Object?>()).toList() : <Json>[];
      setState(() {
        _entries = _entries == null ? next : keepSame(_entries!, next);
        _error = null;
      });
    } on Object catch (failure) {
      if (mounted && _entries == null) setState(() => _error = failure);
    } finally {
      _reading = false;
      if (mounted && !_away) _timer = Timer(_again, _load);
    }
  }

  Future<void> _readWhole(Json entry) async {
    final session = TeamScope.read(context);
    try {
      final value = await session.call('exchange-text', {'id': entry['id'], 'a': entry['from'], 'b': entry['to']});
      if (!mounted) return;
      await showReader(context, stripLongNote(jStr(asJson(value), 'text') ?? ''));
    } on Object catch (failure) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(failure))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final left = team?.bot(widget.a);
    final right = team?.bot(widget.b);
    return Scaffold(
      backgroundColor: p.main,
      body: GlassPage(
        bar: GlassBar(
          leading: IconBtn(AppIcon.back, onTap: () => Navigator.maybePop(context)),
          title: Semantics(
            label: t('Bot exchange'),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _Side(bot: left),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Ico(AppIcon.swipe, size: 16, color: p.ink3)),
              _Side(bot: right),
            ]),
          ),
          actions: const [SizedBox(width: 48)],
        ),
        bodyBuilder: (context) => _body(context, team),
      ),
    );
  }

  Widget _body(BuildContext context, TeamState? team) {
    final p = context.p;
    final media = MediaQuery.of(context);
    final entries = _entries;
    if (team == null || entries == null) {
      return Center(
        child: _error != null
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                Text(errorText(_error), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3)),
                TextButton(onPressed: _load, child: Text(t('Retry'))),
              ])
            : CircularProgressIndicator(color: p.accent),
      );
    }
    if (entries.isEmpty) return Center(child: Text(t('No messages yet'), style: TypeScale.small.copyWith(color: p.ink3)));
    final width = media.size.width - 24;
    // Newest at the bottom, where the list opens and stays as replies come in.
    return ListView.builder(
      reverse: true,
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      padding: EdgeInsets.fromLTRB(12, media.padding.top + 8, 12, media.padding.bottom + 20),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final at = entries.length - 1 - index;
        final entry = entries[at];
        final time = jInt(entry, 'time');
        final before = at > 0 ? jInt(entries[at - 1], 'time') : null;
        final from = jStr(entry, 'from');
        final bot = team.bot(from);
        final long = jInt(entry, 'length') != null;
        return Column(key: ValueKey(entry['id'] ?? at), crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (time != null && (before == null || time - before >= _gap))
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 4),
              child: Center(child: Text(clockLabel(time), style: TypeScale.caption.copyWith(color: p.ink3))),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ChatItemView(
              row: ChatRow({'kind': 'bot', 'botId': ?from, 'name': bot?.name ?? t('You'), 'text': stripLongNote(jStr(entry, 'text') ?? ''), 'time': ?time}, 'x$at', null),
              team: team,
              sessionId: '',
              inRoom: true,
              flat: false,
              botMax: width * 0.93,
              userMax: width * 0.86,
              onLongPress: (_) {},
            ),
          ),
          if (long)
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 4),
              child: TextButton(onPressed: () => _readWhole(entry), child: Text(t('Read full message'))),
            ),
        ]);
      },
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({required this.bot});

  final Bot? bot;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Flexible(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        BotAvatar(bot: bot, size: 22),
        const SizedBox(width: 6),
        Flexible(child: Text(bot?.name ?? '?', maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.headerTitle.copyWith(color: p.ink, fontSize: 15))),
      ]),
    );
  }
}
