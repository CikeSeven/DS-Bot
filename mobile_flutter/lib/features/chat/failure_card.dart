// A failed turn in a Bot's own chat, where the desktop draws its repair card: what
// went wrong in words, and on the newest one Retry and the fixes the phone can carry
// out. An older failure, or one the card above the message box already handles (a
// key or balance block on the Bot), is a quiet line; Technical details open on tap.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../data/json.dart';
import '../../data/team_state.dart';
import '../../data/turn_failure.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../manage/bot_pages.dart';
import '../settings/providers_page.dart';

// After a Retry the Bot's work shows within a moment; if nothing comes of it, Retry
// comes back instead of staying greyed out.
const _retryHold = Duration(seconds: 10);

class FailureCard extends StatefulWidget {
  const FailureCard({super.key, required this.item, required this.team, required this.botId, required this.latest, required this.maxWidth});

  final Json item;
  final TeamState team;
  final String? botId;

  /// Whether nothing in the chat came after this failure.
  final bool latest;
  final double maxWidth;

  @override
  State<FailureCard> createState() => _FailureCardState();
}

class _FailureCardState extends State<FailureCard> {
  bool _details = false;
  bool _retrying = false;
  Timer? _hold;

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  Future<void> _retry(String botId) async {
    setState(() => _retrying = true);
    final sent = await run(context, 'resume', {'botId': botId});
    if (!mounted) return;
    if (sent == null) {
      setState(() => _retrying = false);
      return;
    }
    _hold?.cancel();
    _hold = Timer(_retryHold, () {
      if (mounted) setState(() => _retrying = false);
    });
  }

  void _fix(FailureFix fix, Bot bot) {
    switch (fix) {
      case FailureFix.key || FailureFix.rekey:
        push(context, const ProvidersPage());
      case FailureFix.model:
        openBotDetails(context, bot.id);
      case FailureFix.topUp:
        unawaited(launchUrl(Uri.parse(topUpUrl), mode: LaunchMode.externalApplication));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final item = widget.item;
    final team = widget.team;
    final bot = team.bot(widget.botId);
    final code = jStr(item, 'code') ?? '';
    final standing = bot?.blocked;
    final blocked = standing != null && jStr(standing, 'code') == code ? standing : null;
    final provider = jStr(item, 'provider') ?? jStr(blocked, 'provider') ?? botProvider(team, bot);
    final text = failureText(
      code,
      name: bot?.name ?? t('This Bot'),
      provider: providerName(team, provider),
      status: jInt(item, 'status') ?? jInt(blocked, 'status'),
    );
    final facts = failureFacts(item, blocked);
    // A turn that answered another Bot already told that Bot; Retry would answer the
    // user's last message instead. A standing block has its own card above the message box.
    final open = widget.latest && bot != null && !team.botWorking(bot.id) && blocked == null && jBool(item, 'asked') != true;
    if (!open) return _line(p, text, facts);
    final fixes = failureFixes(code, provider: provider);
    final retry = retryShown(code, blocked);
    final buttons = <Widget>[
      if (retry)
        Btn(_retrying ? t('Retrying…') : t('Retry'),
            kind: BtnKind.secondary, small: true, icon: AppIcon.refresh, busy: _retrying, onTap: _retrying ? null : () => unawaited(_retry(bot.id))),
      for (final fix in fixes) Btn(fixLabel(fix), kind: BtnKind.secondary, small: true, onTap: () => _fix(fix, bot)),
    ];
    if (buttons.isEmpty) return _line(p, text, facts);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: Palette.danger.withValues(alpha: 0.28)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          _head(p, text, TypeScale.small.copyWith(color: p.ink)),
          Padding(
            padding: const EdgeInsets.only(left: _indent, top: 10),
            child: Wrap(spacing: 8, runSpacing: 8, children: buttons),
          ),
          if (facts.isNotEmpty) Padding(padding: const EdgeInsets.only(left: _indent, top: 8), child: _toggle(p, facts)),
        ]),
      ),
    );
  }

  static const _indent = 15.0;

  // The dot sits centred on the first line of text.
  Widget _head(Palette p, String text, TextStyle style) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: EdgeInsets.only(top: ((style.fontSize ?? 13) * (style.height ?? 1.4) - 7) / 2),
          child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: Palette.danger, shape: BoxShape.circle)),
        ),
        const SizedBox(width: 8),
        Flexible(child: Text(text, style: style)),
      ]);

  /// A failure the chat moved past, or one with nothing to do here.
  Widget _line(Palette p, String text, List<(String, String, String)> facts) {
    final head = _head(p, text, TypeScale.caption.copyWith(color: p.ink2));
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: facts.isEmpty
              ? head
              : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => setState(() => _details = !_details), child: head),
                  if (_details) Padding(padding: const EdgeInsets.only(left: _indent, top: 6), child: _Facts(facts: facts)),
                ]),
        ),
      ),
    );
  }

  Widget _toggle(Palette p, List<(String, String, String)> facts) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _details = !_details),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_details ? t('Show less') : t('Technical details'), style: TypeScale.caption.copyWith(color: p.ink3)),
              const SizedBox(width: 2),
              AnimatedRotation(turns: _details ? 0.25 : 0, duration: const Duration(milliseconds: 160), child: Ico(AppIcon.forward, size: 12, color: p.ink3)),
            ]),
          ),
        ),
        if (_details) Padding(padding: const EdgeInsets.only(top: 6), child: _Facts(facts: facts)),
      ]);
}

/// Code, status, request id and the provider's message; Copy puts them on the
/// clipboard in English, for a report.
class _Facts extends StatelessWidget {
  const _Facts({required this.facts});

  final List<(String, String, String)> facts;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final value = TypeScale.mono.copyWith(fontSize: 11.5, height: 16 / 11.5, color: p.ink2);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      for (final (_, label, text) in facts)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 92, child: Text(label, style: TypeScale.caption.copyWith(color: p.ink3))),
            Expanded(child: SelectableText(text, style: value)),
          ]),
        ),
      const SizedBox(height: 2),
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          Clipboard.setData(ClipboardData(text: facts.map((fact) => '${fact.$1}: ${fact.$3}').join('\n')));
          toast(context, t('Copied'));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Ico(AppIcon.copy, size: 13, color: p.ink3),
            const SizedBox(width: 4),
            Text(t('Copy'), style: TypeScale.caption.copyWith(color: p.ink3)),
          ]),
        ),
      ),
    ]);
  }
}
