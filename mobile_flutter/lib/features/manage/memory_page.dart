// A Bot's or a group's memory: the summary, a box to ask or change it in plain
// words, every entry (pin, edit, move, always-on, forget), new entries with
// their scope, and the change log with restore.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/json.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'common.dart';

class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key, this.botId, this.roomId});

  final String? botId;
  final String? roomId;

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  Json? _view;
  String? _reply;
  bool _asking = false;
  final _ask = TextEditingController();

  Json get _target => widget.roomId != null ? {'roomId': widget.roomId} : {'botId': widget.botId};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_view == null) _load();
  }

  @override
  void dispose() {
    _ask.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final value = await run(context, 'memory-view', {..._target, 'summarize': true});
    if (mounted && value is Map) setState(() => _view = asJson(value));
  }

  Future<void> _call(String endpoint, Json payload) async {
    final value = await run(context, endpoint, {..._target, ...payload});
    if (!mounted || value is! Map) return;
    final view = jMap(value, 'view') ?? asJson(value);
    if (view.containsKey('entries')) setState(() => _view = view);
  }

  Future<void> _askNow() async {
    final text = _ask.text.trim();
    if (text.isEmpty) return;
    setState(() => _asking = true);
    final value = await run(context, 'memory-ask', {..._target, 'text': text});
    if (!mounted) return;
    setState(() {
      _asking = false;
      if (value is Map) {
        _reply = jStr(value, 'reply');
        final view = jMap(value, 'view');
        if (view != null) _view = view;
        _ask.clear();
      }
    });
  }

  String _scopeLabel(String? scope) => switch (scope) { 'team' => t('Team memory'), 'group' => t('Group memory'), _ => t('Own memory') };

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final name = widget.roomId != null ? team?.room(widget.roomId)?.name : team?.bot(widget.botId)?.name;
    final view = _view;
    final entries = jMaps(view, 'entries');
    final summary = jMap(view, 'summary');
    final scopes = <String>{for (final entry in entries) jStr(entry, 'scope') ?? 'own'};
    final tidy = jMap(view, 'tidy');
    return ManagePage(
      title: name == null ? t('Memory') : t("{name}'s memory", {'name': name}),
      actions: [
        IconBtn(AppIcon.history, onTap: () => _history(context)),
        IconBtn(AppIcon.plus, onTap: view == null ? null : () => _edit(context, null)),
      ],
      onRefresh: _load,
      children: view == null
          ? [Padding(padding: const EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: p.accent)))]
          : [
              if (summary != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Radii.dialog)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Ico(AppIcon.sparkle, size: 16, color: p.accent),
                      const SizedBox(width: 6),
                      Text(t('Summary'), style: TypeScale.smallStrong.copyWith(color: p.accent)),
                      const Spacer(),
                      if (jBool(view, 'summarizing') == true) SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: p.accent)),
                    ]),
                    const SizedBox(height: 6),
                    Text(jStr(summary, 'text') ?? '', style: TypeScale.small.copyWith(color: p.ink)),
                  ]),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(children: [
                  Expanded(child: Field(controller: _ask, hint: t('Ask memory, or tell it what to change'), onSubmitted: (_) => _askNow())),
                  const SizedBox(width: 8),
                  Btn(t('Ask'), small: true, busy: _asking, onTap: _askNow),
                ]),
              ),
              if (_reply != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(Radii.card)),
                  child: Text(_reply!, style: TypeScale.small.copyWith(color: p.ink)),
                ),
              if (tidy != null && jStr(tidy, 'batch') != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        t('Memory was tidied: {merged} merged, {moved} moved, {retired} retired', {
                          'merged': jInt(tidy, 'merged') ?? 0,
                          'moved': jInt(tidy, 'moved') ?? 0,
                          'retired': jInt(tidy, 'retired') ?? 0,
                        }),
                        style: TypeScale.small.copyWith(color: p.ink2),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _call('memory-tidy-undo', {'scope': jStr(tidy, 'scope'), 'batch': jStr(tidy, 'batch')}),
                      child: Text(t('Undo')),
                    ),
                  ]),
                ),
              if (entries.isEmpty)
                Padding(padding: const EdgeInsets.all(32), child: Text(t('Nothing saved yet'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3))),
              for (final scope in ['own', 'group', 'team'].where(scopes.contains))
                Group(
                  title: _scopeLabel(scope),
                  children: [
                    for (final entry in entries.where((entry) => (jStr(entry, 'scope') ?? 'own') == scope))
                      _EntryRow(entry: entry, onTap: () => _entryMenu(context, entry)),
                  ],
                ),
            ],
    );
  }

  void _entryMenu(BuildContext context, Json entry) {
    final pinned = jBool(entry, 'pinned') == true;
    final always = jStr(entry, 'topic') == null;
    final places = jMaps(_view, 'places');
    showActions(
      context,
      [
        MenuAction(t('Edit'), AppIcon.edit, () => _edit(context, entry)),
        MenuAction(pinned ? t('Unpin') : t('Pin'), pinned ? AppIcon.unpin : AppIcon.pin, () => _call('memory-pin', {..._entryKey(entry), 'pin': !pinned})),
        MenuAction(always ? t('Recall only when relevant') : t('Always remember'), AppIcon.layers, () => _call('memory-layer', {..._entryKey(entry), 'always': !always})),
        if (places.isNotEmpty) MenuAction(t('Move to…'), AppIcon.forward, () => _move(context, entry, places)),
        MenuAction(t('Forget'), AppIcon.trash, () async {
          final ok = await confirmDanger(context, title: t('Forget this?'), body: jStr(entry, 'text'), action: t('Forget'));
          if (ok) await _call('memory-forget', _entryKey(entry));
        }, danger: true),
      ],
      header: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: Text(jStr(entry, 'text') ?? '', maxLines: 4, overflow: TextOverflow.ellipsis, style: TypeScale.small.copyWith(color: context.p.ink2))),
    );
  }

  Json _entryKey(Json entry) => {'scope': jStr(entry, 'scope'), 'topic': entry['topic'], 'text': jStr(entry, 'text')};

  void _move(BuildContext context, Json entry, List<Json> places) {
    showGlassSheet<void>(
      context,
      builder: (sheet) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 20), children: [
        SheetTitle(t('Move to…')),
        for (final place in places)
          ListTile(
            leading: Ico(jStr(place, 'kind') == 'group' ? AppIcon.people : AppIcon.sparkle),
            title: Text(jStr(place, 'name') ?? ''),
            onTap: () {
              Navigator.pop(sheet);
              _call('memory-move', {..._entryKey(entry), 'to': jStr(place, 'key')});
            },
          ),
      ]),
    );
  }

  void _edit(BuildContext context, Json? entry) {
    final text = TextEditingController(text: jStr(entry, 'text') ?? '');
    final topic = TextEditingController(text: jStr(entry, 'topic') ?? '');
    var scope = jStr(entry, 'scope') ?? (widget.roomId != null ? 'group' : 'own');
    showGlassSheet<void>(
      context,
      builder: (sheet) => StatefulBuilder(builder: (context, setState) {
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
          SheetTitle(entry == null ? t('Add to memory') : t('Edit')),
          if (entry == null && widget.roomId == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Segmented<String>(values: const ['own', 'team'], labels: [t('Own memory'), t('Team memory')], value: scope, onChanged: (value) => setState(() => scope = value)),
            ),
          Field(controller: topic, label: t('Topic'), hint: t('Leave empty to always remember it')),
          const SizedBox(height: 12),
          Field(controller: text, label: t('Text'), maxLines: 6, minLines: 2, autofocus: true),
          const SizedBox(height: 16),
          Btn(t('Save'), expand: true, onTap: () async {
            if (text.text.trim().isEmpty) return;
            final topicValue = topic.text.trim().isEmpty ? null : topic.text.trim();
            if (entry == null) {
              await _call('memory-add', {'scope': scope, 'topic': topicValue, 'text': text.text.trim()});
            } else {
              await _call('memory-edit', {'scope': jStr(entry, 'scope'), 'topic': entry['topic'], 'text': jStr(entry, 'text'), 'next': text.text.trim()});
            }
            if (sheet.mounted) Navigator.pop(sheet);
          }),
        ]);
      }),
    );
  }

  void _history(BuildContext context) {
    showGlassSheet<void>(
      context,
      maxHeightFactor: 0.92,
      builder: (sheet) => Loader(
        endpoint: 'memory-history',
        payload: _target,
        follow: false,
        builder: (context, value, reload) {
          final p = context.p;
          final rows = jMaps(value, 'rows');
          return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 20), children: [
            SheetTitle(t('History')),
            if (rows.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(t('No changes yet'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3))),
            for (final row in rows)
              ListTile(
                leading: Ico(switch (jStr(row, 'op')) { 'add' => AppIcon.plus, 'remove' => AppIcon.trash, _ => AppIcon.edit }, color: p.ink2),
                title: Text(jStr(row, 'text') ?? '', maxLines: 3, overflow: TextOverflow.ellipsis, style: TypeScale.small.copyWith(color: p.ink)),
                subtitle: Text(
                  [_scopeLabel(jStr(row, 'scope')), if (jStr(row, 'by') == 'user') t('You') else jStr(row, 'by') ?? '', if (jInt(row, 'time') != null) timeLabel(jInt(row, 'time')!)].where((part) => part.isNotEmpty).join(' · '),
                  style: TypeScale.caption.copyWith(color: p.ink3),
                ),
                trailing: jBool(row, 'restored') == true
                    ? Tag(t('Restored'))
                    : TextButton(
                        onPressed: () async {
                          await _call('memory-restore', {'id': jStr(row, 'id')});
                          reload();
                        },
                        child: Text(t('Restore')),
                      ),
              ),
          ]);
        },
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.onTap});

  final Json entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final meta = [jStr(entry, 'topic'), jStr(entry, 'by'), jStr(entry, 'added')].whereType<String>().where((part) => part.isNotEmpty).join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Ico(jBool(entry, 'pinned') == true ? AppIcon.pin : (jStr(entry, 'topic') == null ? AppIcon.star : AppIcon.memory), size: 16, color: jBool(entry, 'pinned') == true ? Palette.star : p.ink3),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(jStr(entry, 'text') ?? '', style: TypeScale.small.copyWith(color: jBool(entry, 'expired') == true ? p.ink3 : p.ink, decoration: jBool(entry, 'expired') == true ? TextDecoration.lineThrough : null)),
              if (meta.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: Text(meta, style: TypeScale.caption.copyWith(color: p.ink3))),
            ]),
          ),
        ]),
      ),
    );
  }
}
