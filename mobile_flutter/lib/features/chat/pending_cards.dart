// The cards that wait for the user: questions, approvals, secret requests,
// browser handoffs and aside answers. The chat dock, the Needs you sheet and the
// home strip all use these, so everything can be answered where it shows up.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../data/gate.dart';
import '../../data/json.dart';
import '../../ui/i18n.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Runs an answer and reports whether it went through; errors show as toasts.
mixin _Answering<T extends StatefulWidget> on State<T> {
  bool busy = false;
  String? failure;

  Future<bool> answer(String endpoint, Json payload, {String? stale}) async {
    if (busy) return false;
    setState(() {
      busy = true;
      failure = null;
    });
    try {
      await TeamScope.read(context).call(endpoint, payload);
      HapticFeedback.lightImpact();
      return true;
    } on Object catch (error) {
      if (!isUnlockCancel(error) && mounted) setState(() => failure = stale ?? errorText(error));
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget failureLine(Palette p) => failure == null
      ? const SizedBox.shrink()
      : Padding(padding: const EdgeInsets.only(top: 8), child: Text(failure!, style: TypeScale.small.copyWith(color: Palette.danger)));
}

class QuestionBody extends StatefulWidget {
  const QuestionBody({super.key, required this.question, required this.sessionId, this.showTitle = false});

  final Json question;
  final String sessionId;
  final bool showTitle;

  @override
  State<QuestionBody> createState() => _QuestionBodyState();
}

class _QuestionBodyState extends State<QuestionBody> with _Answering {
  final Set<String> _picked = {};
  final _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _send(List<String> selected) => answer(
        'answer-question',
        {
          'sessionId': widget.sessionId,
          'questionId': widget.question['id'],
          'answer': {'selected': selected, 'custom': _custom.text.trim()},
        },
        stale: t('This question is no longer open.'),
      );

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final q = widget.question;
    final options = jList(q, 'options').map((option) => option is String ? option : jStr(option, 'label') ?? '').toList();
    final multi = jBool(q, 'multiSelect') == true;
    final detail = jStr(q, 'detail');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.showTitle) Text(jStr(q, 'question') ?? '', style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
      if (detail != null && detail.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 4), child: Text(detail, style: TypeScale.small.copyWith(color: p.ink2))),
      if (options.isNotEmpty) ...[
        const SizedBox(height: 10),
        for (final (index, option) in options.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Pressable(
              onTap: busy
                  ? null
                  : () {
                      if (!multi) {
                        _send([option]);
                        return;
                      }
                      HapticFeedback.selectionClick();
                      setState(() => _picked.contains(option) ? _picked.remove(option) : _picked.add(option));
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  color: _picked.contains(option) ? p.accent.withValues(alpha: 0.12) : p.bubble.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(Radii.option),
                  border: Border.all(color: _picked.contains(option) ? p.accent : Colors.transparent),
                ),
                child: Row(children: [
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: _picked.contains(option) ? p.accent : p.card, shape: BoxShape.circle),
                    child: Text(String.fromCharCode(65 + index),
                        style: TypeScale.caption.copyWith(fontWeight: FontWeight.w600, color: _picked.contains(option) ? p.accentInk : p.ink2)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(option, style: TypeScale.settingsRow.copyWith(color: p.ink))),
                ]),
              ),
            ),
          ),
      ],
      if (multi || options.isEmpty) ...[
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Field(controller: _custom, hint: t('Your answer'), onChanged: (_) => setState(() {}))),
          const SizedBox(width: 8),
          Btn(t('Submit'), small: true, busy: busy, onTap: _picked.isEmpty && _custom.text.trim().isEmpty ? null : () => _send([..._picked])),
        ]),
      ],
      failureLine(p),
    ]);
  }
}

class ApprovalBody extends StatefulWidget {
  const ApprovalBody({super.key, required this.approval, this.showTitle = false, this.compact = false});

  final Json approval;
  final bool showTitle;
  final bool compact;

  @override
  State<ApprovalBody> createState() => _ApprovalBodyState();
}

class _ApprovalBodyState extends State<ApprovalBody> with _Answering {
  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final a = widget.approval;
    final detail = jMap(a, 'detail');
    final text = jStr(detail, 'text');
    final code = jStr(detail, 'code');
    final reason = jStr(a, 'reason') ?? '';
    final answerable = jBool(a, 'answerable') != false;
    Future<void> go(String choice) => answer('approval-answer', {'id': a['id'], 'choice': choice}, stale: t('This approval is no longer open.'));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.showTitle) Text(jStr(a, 'tool') ?? t('Approval'), style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
      if (text != null && text.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: SelectableText(text, style: TypeScale.small.copyWith(color: p.ink))),
      if (reason.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(reason, maxLines: widget.compact ? 2 : 6, overflow: TextOverflow.ellipsis, style: TypeScale.small.copyWith(color: p.ink2)),
        ),
      if (code != null && code.isNotEmpty && !widget.compact)
        Container(
          margin: const EdgeInsets.only(top: 8),
          constraints: const BoxConstraints(maxHeight: 140),
          decoration: BoxDecoration(color: p.bubble.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(Radii.input)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: SelectableText(code, style: TypeScale.mono.copyWith(color: p.ink2)),
          ),
        ),
      const SizedBox(height: 10),
      if (answerable)
        Row(children: [
          Expanded(child: Btn(t('Reject'), kind: BtnKind.secondary, small: true, onTap: busy ? null : () => go('reject'))),
          const SizedBox(width: 8),
          Expanded(child: Btn(t('Allow once'), small: true, busy: busy, onTap: () => go('allow'))),
        ])
      else
        Text(t('Answer on the computer.'), style: TypeScale.small.copyWith(color: p.ink2)),
      failureLine(p),
    ]);
  }
}

class SecretBody extends StatefulWidget {
  const SecretBody({super.key, required this.request, required this.botName, this.showTitle = false});

  final Json request;
  final String botName;
  final bool showTitle;

  @override
  State<SecretBody> createState() => _SecretBodyState();
}

class _SecretBodyState extends State<SecretBody> with _Answering {
  final _value = TextEditingController();

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final r = widget.request;
    final allow = jStr(r, 'kind') == 'allow';
    final name = jStr(r, 'name') ?? '';
    final scope = r['scope'];
    final scopeText = scope is List ? scope.join(', ') : (scope is String ? scope : null);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.showTitle || allow)
        Text(
          allow ? t('Let {bot} use {name}?', {'bot': widget.botName, 'name': name}) : t('{name} needs a key', {'name': name}),
          style: TypeScale.rowNameStrong.copyWith(color: p.ink),
        ),
      if (allow && scopeText != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(scopeText, style: TypeScale.small.copyWith(color: p.ink2))),
      if (!allow) ...[
        const SizedBox(height: 8),
        Field(controller: _value, hint: t('Value of {name}', {'name': name}), obscure: true, onChanged: (_) => setState(() {})),
      ],
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: Btn(t('Cancel'), kind: BtnKind.secondary, small: true, onTap: busy ? null : () => answer('secret-cancel', {'requestId': r['id']}))),
        const SizedBox(width: 8),
        Expanded(
          child: allow
              ? Btn(t('Allow'), small: true, busy: busy, onTap: () => answer('secret-allow', {'requestId': r['id']}))
              : Btn(t('Save'), small: true, busy: busy, onTap: _value.text.trim().isEmpty
                  ? null
                  : () {
                      final value = _value.text;
                      _value.clear();
                      answer('secret-set', {'requestId': r['id'], 'value': value});
                    }),
        ),
      ]),
      failureLine(p),
    ]);
  }
}

class HandoffBody extends StatefulWidget {
  const HandoffBody({super.key, required this.hold, required this.botId, this.onView});

  final Json hold;
  final String botId;
  final VoidCallback? onView;

  @override
  State<HandoffBody> createState() => _HandoffBodyState();
}

class _HandoffBodyState extends State<HandoffBody> with _Answering {
  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final note = jStr(widget.hold, 'note') ?? jStr(widget.hold, 'reason');
    Future<void> go(String outcome) => answer('browser-give-back', {'botId': widget.botId, 'outcome': outcome, 'callId': widget.hold['callId']});
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (note != null) Text(note, style: TypeScale.small.copyWith(color: p.ink2)),
      const SizedBox(height: 10),
      Row(children: [
        if (widget.onView != null) ...[
          Expanded(child: Btn(t('View'), kind: BtnKind.secondary, small: true, onTap: widget.onView)),
          const SizedBox(width: 8),
        ],
        Expanded(child: Btn(t('Skip'), kind: BtnKind.secondary, small: true, onTap: busy ? null : () => go('skip'))),
        const SizedBox(width: 8),
        Expanded(child: Btn(t('Done'), small: true, busy: busy, onTap: () => go('done'))),
      ]),
      failureLine(p),
    ]);
  }
}

class AsideBody extends StatefulWidget {
  const AsideBody({super.key, required this.card, required this.sessionId});

  final Json card;
  final String sessionId;

  @override
  State<AsideBody> createState() => _AsideBodyState();
}

class _AsideBodyState extends State<AsideBody> with _Answering {
  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final failureText = jStr(widget.card, 'failure');
    final reply = jStr(widget.card, 'answer');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (failureText != null) Text(failureText, style: TypeScale.small.copyWith(color: Palette.danger)),
      if (reply != null) Text(reply, style: TypeScale.settingsRow.copyWith(color: p.ink2)),
      Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Btn(t('Dismiss'), kind: BtnKind.secondary, small: true, busy: busy, onTap: () => answer('btw-delete', {'sessionId': widget.sessionId, 'cardId': widget.card['id']})),
        ),
      ),
    ]);
  }
}

/// A skill or AGENTS.md change a Bot learned and proposes; the user approves or declines.
class LearningBody extends StatefulWidget {
  const LearningBody({super.key, required this.proposal});

  final Json proposal;

  @override
  State<LearningBody> createState() => _LearningBodyState();
}

class _LearningBodyState extends State<LearningBody> with _Answering {
  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final proposal = widget.proposal;
    final skill = jStr(proposal, 'kind') != 'agents';
    final edits = jMaps(proposal, 'edits');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(
        skill
            ? (jStr(proposal, 'action') == 'update' ? t('Update the skill {name}', {'name': jStr(proposal, 'name') ?? ''}) : t('Save a new skill {name}', {'name': jStr(proposal, 'name') ?? ''}))
            : t('Change {path}', {'path': jStr(proposal, 'path') ?? 'AGENTS.md'}),
        style: TypeScale.rowNameStrong.copyWith(color: p.ink),
      ),
      if ((jStr(proposal, 'why') ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(jStr(proposal, 'why')!, style: TypeScale.small.copyWith(color: p.ink2))),
      if (skill && (jStr(proposal, 'description') ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(jStr(proposal, 'description')!, style: TypeScale.small.copyWith(color: p.ink))),
      for (final edit in edits.take(4))
        Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: (jStr(edit, 'op') == 'remove' ? Palette.danger : Palette.green).withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Radii.input)),
          child: Text('${jStr(edit, 'op') == 'remove' ? '−' : '+'} ${jStr(edit, 'text') ?? jStr(edit, 'old') ?? ''}', maxLines: 4, overflow: TextOverflow.ellipsis, style: TypeScale.mono.copyWith(color: p.ink, fontSize: 12)),
        ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: Btn(t('Decline'), kind: BtnKind.secondary, small: true, onTap: busy ? null : () => answer('learning-answer', {'id': proposal['id'], 'approve': false}))),
        const SizedBox(width: 8),
        Expanded(child: Btn(t('Approve'), small: true, busy: busy, onTap: () => answer('learning-answer', {'id': proposal['id'], 'approve': true}))),
      ]),
      failureLine(p),
    ]);
  }
}

/// A Bot asks for a connector it needs; connect it in Settings or say no.
class ConnectorRequestBody extends StatefulWidget {
  const ConnectorRequestBody({super.key, required this.request, required this.onConnect});

  final Json request;
  final VoidCallback onConnect;

  @override
  State<ConnectorRequestBody> createState() => _ConnectorRequestBodyState();
}

class _ConnectorRequestBodyState extends State<ConnectorRequestBody> with _Answering {
  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final request = widget.request;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t('Connect {name}', {'name': jStr(request, 'name') ?? jStr(request, 'connectorId') ?? ''}), style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
      if ((jStr(request, 'purpose') ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(jStr(request, 'purpose')!, style: TypeScale.small.copyWith(color: p.ink2))),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: Btn(t('Not now'), kind: BtnKind.secondary, small: true, onTap: busy ? null : () => answer('connector-request-cancel', {'requestId': request['id']}))),
        const SizedBox(width: 8),
        Expanded(child: Btn(t('Connect'), small: true, onTap: widget.onConnect)),
      ]),
      failureLine(p),
    ]);
  }
}

/// A mail a Bot wants to send: check it, edit it, send it or cancel.
class MailRequestBody extends StatefulWidget {
  const MailRequestBody({super.key, required this.request});

  final Json request;

  @override
  State<MailRequestBody> createState() => _MailRequestBodyState();
}

class _MailRequestBodyState extends State<MailRequestBody> with _Answering {
  late final TextEditingController _to = TextEditingController(text: _list(widget.request['to']));
  late final TextEditingController _subject = TextEditingController(text: jStr(widget.request, 'subject') ?? '');
  late final TextEditingController _body = TextEditingController(text: jStr(widget.request, 'body') ?? '');

  static String _list(Object? value) => value is List ? value.join(', ') : (value is String ? value : '');

  @override
  void dispose() {
    _to.dispose();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final request = widget.request;
    final attachments = jMaps(request, 'attachmentDetails');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Field(controller: _to, label: t('To')),
      const SizedBox(height: 8),
      Field(controller: _subject, label: t('Subject')),
      const SizedBox(height: 8),
      Field(controller: _body, label: t('Message'), maxLines: 10, minLines: 4),
      if (attachments.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(attachments.map((file) => jStr(file, 'name') ?? '').join(', '), style: TypeScale.caption.copyWith(color: p.ink2))),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: Btn(t('Cancel'), kind: BtnKind.secondary, small: true, onTap: busy ? null : () => answer('mail-send-answer', {'requestId': request['id'], 'choice': 'cancel'}))),
        const SizedBox(width: 8),
        Expanded(
          child: Btn(t('Send'), small: true, busy: busy, onTap: () => answer('mail-send-answer', {
                'requestId': request['id'],
                'choice': 'send',
                'fields': {'to': _to.text.trim(), 'cc': _list(request['cc']), 'bcc': _list(request['bcc']), 'subject': _subject.text, 'body': _body.text},
              })),
        ),
      ]),
      failureLine(p),
    ]);
  }
}
