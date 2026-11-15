// Which model a Bot runs on, and how hard it thinks: models grouped by provider,
// the default marked, and the thinking level the model offers.
import 'package:flutter/material.dart';

import '../../api/link_client.dart';
import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../data/json.dart';
import '../../data/team_state.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../settings/providers_page.dart';

class ModelButton extends StatelessWidget {
  const ModelButton({super.key, required this.bot});

  final Bot bot;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final ref = bot.model ?? bot.appliedModel ?? team?.defaultModel;
    final model = team?.models.where((entry) => entry.ref == ref).firstOrNull;
    final subtitle = [
      model?.providerName ?? model?.provider ?? (ref?.split('/').first ?? ''),
      if (bot.effort != null) bot.effort!,
      if (bot.model == null) t('Default'),
    ].where((part) => part.isNotEmpty).join(' · ');
    return Pressable(
      onTap: () => showModelSheet(context, bot),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.dialog), border: Border.all(color: p.line)),
        child: Row(children: [
          RowIcon(AppIcon.model),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(model?.name ?? ref ?? t('Default model'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
              if (subtitle.isNotEmpty) Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.caption.copyWith(color: p.ink2)),
            ]),
          ),
          Ico(AppIcon.down, size: 18, color: p.ink3),
        ]),
      ),
    );
  }
}

Future<void> showModelSheet(BuildContext context, Bot bot) {
  return showGlassSheet<void>(context, builder: (sheet) => _ModelSheet(bot: bot));
}

class _ModelSheet extends StatefulWidget {
  const _ModelSheet({required this.bot});

  final Bot bot;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  Json? _efforts;
  String? _ref;

  @override
  void initState() {
    super.initState();
    _ref = widget.bot.model ?? widget.bot.appliedModel;
    _loadEfforts(_ref);
  }

  Future<void> _loadEfforts(String? ref) async {
    if (ref == null) return;
    try {
      final value = asJson(await TeamScope.read(context).call('efforts', {'ref': ref}));
      if (mounted) setState(() => _efforts = value);
    } on Object {
      if (mounted) setState(() => _efforts = null);
    }
  }

  Future<void> _pick(String? ref) async {
    setState(() {
      _ref = ref;
      _efforts = null;
    });
    final session = TeamScope.read(context);
    final payload = <String, dynamic>{'id': widget.bot.id, 'model': ref ?? '', 'effort': null};
    try {
      await session.call('update-bot', payload);
    } on BotError catch (error) {
      // Moving a Bot between a model and a local agent CLI needs the user's say-so.
      if (!(error.message.contains('needs a confirmation')) || !mounted) {
        if (mounted) toast(context, errorText(error), error: true);
        return;
      }
      final ok = await confirmDanger(context, title: t('Change what this Bot runs on?'), body: t('Its conversation moves to a new part.'), action: t('Change'));
      if (!ok || !mounted) return;
      await run(context, 'update-bot', {...payload, 'changeEngine': true});
    }
    await _loadEfforts(ref);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final bot = team?.bot(widget.bot.id) ?? widget.bot;
    final models = team?.models ?? const <ModelEntry>[];
    final groups = <String, List<ModelEntry>>{};
    for (final model in models) {
      groups.putIfAbsent(model.providerName ?? model.provider ?? model.ref.split('/').first, () => []).add(model);
    }
    final efforts = jMaps(_efforts, 'efforts');
    final current = bot.effort ?? jStr(_efforts, 'defaultEffort');
    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 16), children: [
      SheetTitle(t('Model')),
      if (efforts.isNotEmpty) ...[
        Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 8), child: Text(t('Thinking'), style: TypeScale.smallStrong.copyWith(color: p.ink2))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Segmented<String>(
            values: [for (final effort in efforts) jStr(effort, 'id') ?? ''],
            labels: [for (final effort in efforts) t(jStr(effort, 'name') ?? jStr(effort, 'id') ?? '')],
            value: current ?? jStr(efforts.first, 'id') ?? '',
            onChanged: (id) => run(context, 'update-bot', {'id': bot.id, 'effort': id}),
          ),
        ),
        const SizedBox(height: 8),
      ],
      ListTile(
        title: Text(t('Default model')),
        subtitle: Text(team?.defaultModel ?? '', style: TypeScale.caption.copyWith(color: p.ink3)),
        trailing: bot.model == null ? Ico(AppIcon.check, color: p.accent) : null,
        onTap: () => _pick(null),
      ),
      for (final entry in groups.entries) ...[
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 8, 4), child: Text(entry.key, style: TypeScale.smallStrong.copyWith(color: p.ink2))),
        for (final model in entry.value)
          ListTile(
            title: Text(model.name),
            subtitle: model.needsKey ? Text(t('Needs an API key'), style: TypeScale.caption.copyWith(color: Palette.star)) : null,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (model.ref == team?.defaultModel) Tag(t('Default')),
              if (model.ref == _ref) ...[const SizedBox(width: 8), Ico(AppIcon.check, color: p.accent)],
            ]),
            onTap: () => _pick(model.ref),
          ),
      ],
      const SizedBox(height: 8),
      Row2(title: t('Models and providers…'), leading: RowIcon(AppIcon.plug), onTap: () => push(context, const ProvidersPage())),
    ]);
  }
}

/// A plain model choice (no thinking level), for new Bots and the team default.
Future<String?> pickModel(BuildContext context, {String? current, bool allowDefault = true}) {
  final team = TeamScope.read(context).team;
  final models = team?.models ?? const <ModelEntry>[];
  return showGlassSheet<String>(
    context,
    builder: (sheet) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 16), children: [
      SheetTitle(t('Model')),
      if (allowDefault) ListTile(title: Text(t('Default model')), trailing: current == null ? const Ico(AppIcon.check) : null, onTap: () => Navigator.pop(sheet, '')),
      for (final model in models)
        ListTile(
          title: Text(model.name),
          subtitle: Text(model.providerName ?? model.provider ?? '', style: TypeScale.caption),
          trailing: model.ref == current ? const Ico(AppIcon.check) : null,
          onTap: () => Navigator.pop(sheet, model.ref),
        ),
    ]),
  );
}
