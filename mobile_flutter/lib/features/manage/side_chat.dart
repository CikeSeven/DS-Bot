// Side chat: questions about a Bot's work so far, answered from its progress
// without running anything and without joining its conversation.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/json.dart';
import '../../ui/avatar.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/markdown.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class SideChatPage extends StatefulWidget {
  const SideChatPage({super.key, required this.botId});

  final String botId;

  @override
  State<SideChatPage> createState() => _SideChatPageState();
}

class _SideChatPageState extends State<SideChatPage> {
  String? _chatId;
  final _text = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _ask(String sessionId) async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    var chatId = _chatId;
    if (chatId == null) {
      final created = await run(context, 'side-new', {'sessionId': sessionId});
      chatId = jStr(created, 'chatId');
      if (chatId == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      setState(() => _chatId = chatId);
    }
    _text.clear();
    if (!mounted) return;
    await run(context, 'side-ask', {'sessionId': sessionId, 'chatId': chatId, 'recent': true, 'text': text});
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final bot = team?.bot(widget.botId);
    if (team == null || bot == null) return const Scaffold();
    final chats = jList(team.sideChats, bot.id).whereType<Map>().map(asJson).toList();
    final open = chats.where((chat) => chat['chatId'] == _chatId).firstOrNull;
    final entries = jMaps(open, 'entries');
    return Scaffold(
      backgroundColor: p.main,
      body: GlassPage(
        solid: true,
        bar: GlassBar(
          leading: IconBtn(AppIcon.back, onTap: () => _chatId == null ? Navigator.pop(context) : setState(() => _chatId = null)),
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            BotAvatar(bot: bot, size: 26),
            const SizedBox(width: 8),
            Text(t('Side chat')),
          ]),
          actions: [
            if (_chatId != null)
              IconBtn(AppIcon.close, onTap: () async {
                await run(context, 'side-close', {'chatId': _chatId});
                if (mounted) setState(() => _chatId = null);
              }),
          ],
        ),
        bodyBuilder: (context) => _chatId == null
            ? ListView(
                padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 12, 16, 140),
                children: [
                  Text(t('Ask about the work so far'), style: TypeScale.sectionTitle.copyWith(color: p.ink)),
                  const SizedBox(height: 6),
                  Text(t('Answered from progress so far; nothing was run'), style: TypeScale.small.copyWith(color: p.ink2)),
                  const SizedBox(height: 16),
                  for (final chat in chats.reversed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Pressable(
                        onTap: () => setState(() => _chatId = jStr(chat, 'chatId')),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.dialog), border: Border.all(color: p.line)),
                          child: Row(children: [
                            Ico(AppIcon.sparkle, size: 18, color: p.accent),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(jStr(jMaps(chat, 'entries').firstOrNull, 'question') ?? t('Side chat'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
                                Text(t('{count} questions', {'count': jMaps(chat, 'entries').length}), style: TypeScale.caption.copyWith(color: p.ink3)),
                              ]),
                            ),
                            Ico(AppIcon.forward, size: 16, color: p.ink3),
                          ]),
                        ),
                      ),
                    ),
                ],
              )
            : ListView(
                reverse: true,
                padding: EdgeInsets.fromLTRB(12, MediaQuery.paddingOf(context).top + 8, 12, 140),
                children: [
                  for (final entry in entries.reversed) ...[
                    _Answer(entry: entry, chatId: _chatId!),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        margin: const EdgeInsets.only(top: 10, bottom: 6, left: 48),
                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                        decoration: BoxDecoration(color: p.user, borderRadius: BorderRadius.circular(Radii.bubble)),
                        child: Text(jStr(entry, 'question') ?? '', style: TypeScale.bubble.copyWith(color: p.userInk)),
                      ),
                    ),
                  ],
                ],
              ),
        dock: GlassSurface(
          edge: GlassEdge.top,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, MediaQuery.viewInsetsOf(context).bottom > 0 ? 10 : MediaQuery.paddingOf(context).bottom + 10),
            child: Row(children: [
              Expanded(child: Field(controller: _text, hint: t('Ask about the work so far'), onSubmitted: (_) => _ask(bot.chatSession))),
              const SizedBox(width: 8),
              Btn(t('Ask'), small: true, busy: _busy, onTap: () => _ask(bot.chatSession)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Answer extends StatelessWidget {
  const _Answer({required this.entry, required this.chatId});

  final Json entry;
  final String chatId;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final status = jStr(entry, 'status');
    if (status == 'cancelled') return Text(t('Cancelled'), style: TypeScale.caption.copyWith(color: p.ink3));
    if (jStr(entry, 'failure') != null) return Text(jStr(entry, 'failure')!, style: TypeScale.small.copyWith(color: Palette.danger));
    final answer = jStr(entry, 'answer');
    if (answer == null || answer.isEmpty) {
      return Row(children: [
        SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.ink3)),
        const SizedBox(width: 8),
        Text(t('Answering…'), style: TypeScale.small.copyWith(color: p.ink2)),
        const Spacer(),
        TextButton(onPressed: () => run(context, 'side-cancel', {'chatId': chatId, 'entryId': entry['id']}), child: Text(t('Cancel'))),
      ]);
    }
    return Container(
      margin: const EdgeInsets.only(right: 32),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(Radii.bubble)),
      child: MarkdownText(answer, background: p.bubble),
    );
  }
}
