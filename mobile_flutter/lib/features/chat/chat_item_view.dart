// One row of a chat, per display item kind (parts.js displayItems, mobile.js
// roomItems): bubbles, group posts with the member's name and color, round
// events, team actions, settled cards and answers. Tool steps are not shown.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/nav.dart';
import '../../data/chat_items.dart';
import '../../data/chat_session.dart';
import '../../data/json.dart';
import '../../data/team_state.dart';
import '../../shared/deep_view.dart';
import '../../shared/shared_data.dart';
import '../../ui/avatar.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/markdown.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../manage/work_pages.dart';
import 'act_row.dart';
import 'exchange_page.dart';
import 'media.dart';
import 'view_card.dart';

class ChatItemView extends StatelessWidget {
  const ChatItemView({
    super.key,
    required this.row,
    required this.team,
    required this.sessionId,
    required this.inRoom,
    required this.flat,
    required this.botMax,
    required this.userMax,
    required this.onLongPress,
    this.onRetry,
    this.onDiscard,
    this.admin,
    this.botId,
  });

  final ChatRow row;
  final TeamState team;
  final String sessionId;
  final bool inRoom;
  final bool flat;
  final double botMax;
  final double userMax;
  final void Function(ChatRow row) onLongPress;
  final void Function(String localId)? onRetry;
  final void Function(String localId)? onDiscard;
  final String? admin;

  /// The Bot whose own chat this is; a line about another Bot opens their exchange.
  final String? botId;

  Json get item => row.item;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    switch (row.kind) {
      case 'divider':
        final time = jInt(item, 'time');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            Expanded(child: Divider(color: p.line)),
            if (time != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text(clockLabel(time), style: TypeScale.caption.copyWith(color: p.ink3))),
            Expanded(child: Divider(color: p.line)),
          ]),
        );
      case 'relay':
        final line = relayReplyText(jMap(item, 'reply'));
        return line == null || line.isEmpty ? const SizedBox.shrink() : _Caption(line);
      case 'event':
        if (jStr(item, 'role') == 'paused') {
          return _Caption(t('Paused after {count} Bot relays. Waiting: {names}', {'count': jInt(item, 'ms') ?? 0, 'names': jStr(item, 'text') ?? ''}));
        }
        final name = jStr(item, 'name') ?? t('a Bot');
        final round = roundEventText(name, jStr(item, 'event'), jStr(item, 'text'), jStr(item, 'code'));
        if (round != null) return _Caption(round, tone: jStr(item, 'event') == 'failed' ? Palette.danger : null);
        return _fromBot(context, name);
      case 'closed':
        final question = jMap(item, 'question');
        return _Settled(
          title: jStr(question, 'question') ?? jStr(item, 'title') ?? '',
          badge: t(jStr(item, 'closed') == 'replied' ? 'Answered by message' : 'Dismissed'),
        );
      case 'view':
        final view = item['view'];
        if (view == null) return _Settled(title: jStr(item, 'title') ?? t('Card'));
        return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: ViewCard(sessionId: sessionId, title: jStr(item, 'title'), root: view, readOnly: true));
      case 'act':
        return ActRow(item: item, team: team, sessionId: sessionId, maxWidth: botMax);
      case 'answer':
        return _answer(context, p);
      case 'user':
        return _user(context, p);
      default:
        return _bot(context, p);
    }
  }

  /// Another Bot's message, reply or stop that reached this Bot, as the
  /// desktop's line: it opens the two Bots' exchange, a group's report the group.
  Widget _fromBot(BuildContext context, String name) {
    if (jStr(item, 'role') == 'report') {
      final room = team.room(jStr(item, 'roomId'));
      return EventLine(
        prefix: t('Replies from'),
        lead: room == null ? null : RoomAvatar(room: room, team: team, size: 18),
        name: room?.name ?? t('a group chat'),
        onTap: room == null ? null : () => openChat(context, roomId: room.id, replace: true),
      );
    }
    final other = team.bot(jStr(item, 'botId'));
    final self = botId ?? team.botOfSession(sessionId)?.id;
    return EventLine(
      prefix: switch (jStr(item, 'role')) {
        'stopped' => t('Stopped by'),
        'reply' => t('Reply from'),
        _ => t('Message from'),
      },
      lead: BotAvatar(bot: other, size: 18),
      name: other?.name ?? name,
      onTap: other == null || self == null ? null : () => push(context, ExchangePage(a: self, b: other.id)),
    );
  }

  Widget _answer(BuildContext context, Palette p) {
    var handoff = jMap(item, 'handoff');
    if (handoff == null && jList(item, 'questions').isEmpty && jList(item, 'views').isEmpty) {
      final text = jStr(item, 'text');
      if (text != null && text.startsWith('{')) {
        try {
          final parsed = asJson(_decode(text));
          if (parsed['kind'] == 'answer_to_pending_handoff' && parsed['reason'] is String) handoff = parsed;
        } on Object {
          // Plain text.
        }
      }
    }
    if (handoff != null) {
      final outcome = jStr(handoff, 'outcome');
      return _Settled(
        title: handoffTitleOf(jStr(handoff, 'reason')),
        badge: outcome == 'skipped' ? t('Skipped') : (outcome == 'returned' ? t('Returned') : null),
        check: outcome != 'skipped' && outcome != 'returned',
      );
    }
    final answers = jMaps(item, 'answers');
    final views = jMaps(item, 'views');
    if (views.isNotEmpty) {
      return GestureDetector(
        onLongPress: () => onLongPress(row),
        child: _SettledBox(children: [
          for (final (i, entry) in views.indexed) ...[
            if ((jStr(entry, 'title') ?? '').isNotEmpty) Text(jStr(entry, 'title')!, style: TypeScale.smallStrong.copyWith(color: p.ink2)),
            Text(
              () {
                final answer = answers.where((a) => a['id'] == entry['id']).firstOrNull ?? (i < answers.length ? answers[i] : null);
                final text = answer == null ? '' : viewAnswerText(entry['view'], answer);
                return text.isEmpty ? sourceTextOf(item) : text;
              }(),
              style: TypeScale.small.copyWith(color: p.ink),
            ),
          ],
        ]),
      );
    }
    final questions = jMaps(item, 'questions');
    if (questions.isNotEmpty) {
      return GestureDetector(
        onLongPress: () => onLongPress(row),
        child: _SettledBox(children: [
          for (final (i, question) in questions.indexed) ...[
            Text(jStr(question, 'question') ?? '', style: TypeScale.smallStrong.copyWith(color: p.ink2)),
            const SizedBox(height: 6),
            for (final pick in settledQuestionPicks(
              question,
              answers.where((a) => question['id'] != null && a['id'] == question['id']).firstOrNull ?? (i < answers.length ? answers[i] : null),
            ))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                    child: Text(pick.letter, style: TextStyle(color: p.accentInk, fontSize: 11, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(pick.label, style: TypeScale.small.copyWith(color: p.ink))),
                ]),
              ),
          ],
        ]),
      );
    }
    return _userBubble(context, p, MarkdownText(sourceTextOf(item), color: p.userInk, background: p.user), const []);
  }

  Widget _user(BuildContext context, Palette p) {
    final text = jStr(item, 'text') ?? '';
    final files = jMaps(item, 'files');
    final refs = jMaps(item, 'imageRefs');
    final local = jStr(item, 'local');
    final localId = jStr(item, 'localId');
    final photos = row.photos.map((photo) => photo.bytes).toList();
    final children = <Widget>[
      if (text.isNotEmpty) MarkdownText(text, color: p.userInk, background: p.user),
      for (final file in files) FileChip(file: file, sessionId: sessionId, onDark: true),
      if (photos.isNotEmpty)
        LocalImages(photos: photos)
      else if (refs.isNotEmpty)
        ImageGrid(refs: refs, sessionId: sessionId)
      else if ((jInt(item, 'images') ?? 0) > 0)
        Padding(padding: const EdgeInsets.only(top: 4), child: Text(t('{count} images', {'count': jInt(item, 'images')}), style: TypeScale.caption.copyWith(color: p.userInk.withValues(alpha: 0.8)))),
    ];
    final photosOnly = text.isEmpty && files.isEmpty && (photos.isNotEmpty || refs.isNotEmpty);
    final bubble = _userBubble(context, p, Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: children), const [], bare: photosOnly);
    final via = jStr(item, 'via');
    if (local == 'failed' && localId != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        GestureDetector(onTap: () => onRetry?.call(localId), child: bubble),
        Padding(
          padding: const EdgeInsets.only(top: 4, right: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            GestureDetector(onTap: () => onRetry?.call(localId), child: Text(t('Not sent. Tap to retry'), style: TypeScale.caption.copyWith(color: Palette.danger))),
            const SizedBox(width: 12),
            GestureDetector(onTap: () => onDiscard?.call(localId), child: Text(t('Delete'), style: TypeScale.caption.copyWith(color: p.ink3))),
          ]),
        ),
      ]);
    }
    final sending = local == 'sending';
    if (row.stamp == null && via == null && !sending) return bubble;
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      bubble,
      Padding(
        padding: const EdgeInsets.only(top: 3, right: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (sending) ...[const _Sending(), const SizedBox(width: 5)],
          if (via != null) ...[Tag(t('via {platform}', {'platform': _platformName(via)})), const SizedBox(width: 6)],
          if (row.stamp != null) Text(row.stamp!, style: TypeScale.caption.copyWith(color: p.ink3)),
        ]),
      ),
    ]);
  }

  Widget _userBubble(BuildContext context, Palette p, Widget content, List<Widget> extra, {bool bare = false}) {
    final wide = hasBlockContent(jStr(item, 'text') ?? '');
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onLongPress: () => onLongPress(row),
        child: Container(
          constraints: BoxConstraints(maxWidth: userMax, minWidth: wide ? userMax : 0),
          padding: bare ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: bare ? null : BoxDecoration(color: p.user, borderRadius: BorderRadius.circular(Radii.bubble).copyWith(bottomRight: const Radius.circular(6))),
          child: content,
        ),
      ),
    );
  }

  Widget _bot(BuildContext context, Palette p) {
    final texts = bodyTextsOf(item);
    final refs = jMaps(item, 'imageRefs');
    final files = jMaps(item, 'files');
    final whole = wholeFileOf(item);
    if (texts.isEmpty && refs.isEmpty && files.isEmpty && whole == null) return const SizedBox.shrink();
    final changes = jMap(item, 'changes');
    final extras = <Widget>[
      if (refs.isNotEmpty) ImageGrid(refs: refs, sessionId: sessionId),
      if (changes != null && jInt(changes, 'seq') != null) _ChangesChip(changes: changes),
      for (final file in files) FileChip(file: file, sessionId: sessionId),
      if (whole != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: GestureDetector(
            onTap: () => openFileText(context, whole),
            child: Text(t('Read full message'), style: TypeScale.smallStrong.copyWith(color: p.accent)),
          ),
        ),
    ];
    final author = inRoom ? team.bot(jStr(item, 'botId')) : null;
    if (inRoom && !flat) {
      final color = author != null ? SharedData.instance.ink(author.color, dark: p.dark) : p.ink2;
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 20), child: BotAvatar(bot: author, size: 26)),
          const SizedBox(width: 8),
          Flexible(
            child: GestureDetector(
              onLongPress: () => onLongPress(row),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 3),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(child: Text(jStr(item, 'name') ?? author?.name ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.caption.copyWith(color: color, fontWeight: FontWeight.w600))),
                    if (admin != null && jStr(item, 'botId') == admin) ...[const SizedBox(width: 6), Tag(t('Admin'))],
                    if (jInt(item, 'time') != null) ...[const SizedBox(width: 6), Text(messageClock(jInt(item, 'time')!), style: TypeScale.caption.copyWith(color: p.ink3))],
                  ]),
                ),
                for (final (i, text) in texts.indexed)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                    child: _botBubble(p, MarkdownText(text, background: p.bubble), maxWidth: botMax - 34, extras: i == texts.length - 1 ? extras : const [], wide: hasBlockContent(text)),
                  ),
                if (texts.isEmpty) _botBubble(p, const SizedBox.shrink(), maxWidth: botMax - 34, extras: extras),
              ]),
            ),
          ),
        ]),
      );
    }
    final joined = texts.join('\n\n');
    if (flat) {
      return GestureDetector(
        onLongPress: () => onLongPress(row),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (inRoom && jStr(item, 'name') != null) Text(jStr(item, 'name')!, style: TypeScale.caption.copyWith(color: p.ink3)),
            if (joined.isNotEmpty) MarkdownText(joined, background: p.main),
            ...extras,
            if (row.stamp != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(row.stamp!, style: TypeScale.caption.copyWith(color: p.ink3))),
          ]),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => onLongPress(row),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _botBubble(p, joined.isEmpty ? const SizedBox.shrink() : MarkdownText(joined, background: p.bubble), maxWidth: botMax, extras: extras, wide: texts.any(hasBlockContent) || refs.isNotEmpty),
          if (row.stamp != null) Padding(padding: const EdgeInsets.only(top: 3, left: 6), child: Text(row.stamp!, style: TypeScale.caption.copyWith(color: p.ink3))),
        ]),
      ),
    );
  }

  Widget _botBubble(Palette p, Widget content, {required double maxWidth, List<Widget> extras = const [], bool wide = false}) {
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth, minWidth: wide ? maxWidth : 0),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(Radii.bubble).copyWith(bottomLeft: const Radius.circular(6))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [content, ...extras]),
    );
  }
}

Object? _decode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

String _platformName(String id) {
  for (final platform in SharedData.instance.imPlatforms) {
    if (platform['id'] == id) return jStr(platform, 'name') ?? id;
  }
  return id;
}

/// "N files changed +a −d" under a reply, opening the review.
class _ChangesChip extends StatelessWidget {
  const _ChangesChip({required this.changes});

  final Json changes;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final files = jList(changes, 'files').length;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.card),
        onTap: () => openChanges(context, jStr(changes, 'sessionId') ?? '', jInt(changes, 'seq')!),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(color: p.ink.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(Radii.card), border: Border.all(color: p.line)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Ico(AppIcon.diff, size: 15, color: p.ink2),
            const SizedBox(width: 6),
            Text(t('{count} files', {'count': jInt(changes, 'total') ?? files}), style: TypeScale.smallStrong.copyWith(color: p.ink)),
            const SizedBox(width: 8),
            Text('+${jInt(changes, 'added') ?? 0}', style: TypeScale.small.copyWith(color: Palette.green)),
            const SizedBox(width: 4),
            Text('−${jInt(changes, 'deleted') ?? 0}', style: TypeScale.small.copyWith(color: Palette.danger)),
          ]),
        ),
      ),
    );
  }
}

/// A small spinner beside a message still on its way, shown only when the
/// trip is slow enough to notice.
class _Sending extends StatefulWidget {
  const _Sending();

  @override
  State<_Sending> createState() => _SendingState();
}

class _SendingState extends State<_Sending> {
  bool _shown = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _shown ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: SizedBox.square(dimension: 11, child: CircularProgressIndicator(strokeWidth: 1.4, color: context.p.ink3)),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text, {this.tone});

  final String text;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: p.bubble.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(Radii.pill)),
          child: Text(text, textAlign: TextAlign.center, style: TypeScale.caption.copyWith(color: tone ?? p.ink3)),
        ),
      ),
    );
  }
}

class _SettledBox extends StatelessWidget {
  const _SettledBox({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.card), border: Border.all(color: p.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

class _Settled extends StatelessWidget {
  const _Settled({required this.title, this.badge, this.check = false});

  final String title;
  final String? badge;
  final bool check;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return _SettledBox(children: [
      Row(children: [
        Expanded(child: Text(title, style: TypeScale.smallStrong.copyWith(color: p.ink2))),
        if (badge != null) Tag(badge!),
        if (check) Ico(AppIcon.check, size: 16, color: p.ink2),
      ]),
    ]);
  }
}

Uint8List? asBytes(Object? value) => value is Uint8List ? value : null;
