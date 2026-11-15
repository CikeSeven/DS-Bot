// A Bot's browser: a live screenshot while the page is open, and the controls to
// take over, give it back, finish a handoff, or stop.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/json.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'common.dart';

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.botId});

  final String botId;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  Timer? _timer;
  Uint8List? _frame;
  String? _title;
  String? _url;
  String? _error;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _load());
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    try {
      final value = asJson(await TeamScope.read(context).call('browser-frame', {'botId': widget.botId}));
      if (!mounted) return;
      setState(() {
        _frame = base64Decode(jStr(value, 'data') ?? '');
        _title = jStr(value, 'title');
        _url = jStr(value, 'url');
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final bot = team?.bot(widget.botId);
    final hold = jMap(team?.browserHolds, widget.botId);
    final enabled = team?.browserEnabled ?? false;
    final handoff = hold != null && jStr(hold, 'callId') != null;
    final mine = hold != null && jStr(hold, 'by') == 'user' && !handoff;
    return ManagePage(
      title: bot == null ? t('Browser') : t("{name}'s browser", {'name': bot.name}),
      children: [
        if (_title != null || _url != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_title != null) Text(_title!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
              if (_url != null) Text(_url!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.caption.copyWith(color: p.ink3)),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.dialog),
            child: Container(
              color: p.bubble,
              constraints: const BoxConstraints(minHeight: 220),
              alignment: Alignment.center,
              child: _frame != null && _frame!.isNotEmpty
                  ? InteractiveViewer(maxScale: 4, child: Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.contain))
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error ?? t('Loading…'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3)),
                    ),
            ),
          ),
        ),
        if (hold != null && jStr(hold, 'note') != null)
          Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 0), child: Text(jStr(hold, 'note')!, style: TypeScale.small.copyWith(color: p.ink2))),
        if (enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              if (handoff) ...[
                Btn(t('Done'), small: true, onTap: () => run(context, 'browser-give-back', {'botId': widget.botId, 'outcome': 'done', 'callId': hold['callId']})),
                Btn(t('Skip'), kind: BtnKind.secondary, small: true, onTap: () => run(context, 'browser-give-back', {'botId': widget.botId, 'outcome': 'skip', 'callId': hold['callId']})),
              ] else if (mine)
                Btn(t('Give back'), small: true, icon: AppIcon.play, onTap: () => run(context, 'browser-give-back', {'botId': widget.botId}))
              else
                Btn(t('Take over'), kind: BtnKind.secondary, small: true, icon: AppIcon.pause, onTap: () => run(context, 'browser-takeover', {'botId': widget.botId})),
              Btn(t('Stop'), kind: BtnKind.danger, small: true, icon: AppIcon.stop, onTap: () => run(context, 'browser-stop', {'botId': widget.botId})),
            ]),
          ),
      ],
    );
  }
}
