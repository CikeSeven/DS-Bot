// Model providers and their keys: replace or remove a key, add a known provider
// or any OpenAI-compatible API, and see the models each one offers.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/json.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../manage/common.dart';

class ProvidersPage extends StatefulWidget {
  const ProvidersPage({super.key});

  @override
  State<ProvidersPage> createState() => _ProvidersPageState();
}

class _ProvidersPageState extends State<ProvidersPage> {
  int _version = 0;

  void _reload() => setState(() => _version += 1);

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Loader(
      key: ValueKey(_version),
      endpoint: 'providers',
      follow: false,
      builder: (context, value, reload) {
        final providers = jMaps(value, 'providers');
        final addable = jMaps(value, 'addable');
        final protocols = jStrings(value, 'protocols');
        return ManagePage(
          title: t('Model providers'),
          actions: [if (jBool(value, 'available') != false) IconBtn(AppIcon.plus, onTap: () => _add(context, addable, protocols))],
          children: [
            if (jBool(value, 'available') == false)
              Padding(padding: const EdgeInsets.all(24), child: Text(t('This DSH cannot set up model providers.'), style: TypeScale.small.copyWith(color: p.ink2))),
            Group(children: [
              for (final provider in providers)
                Row2(
                  title: jStr(provider, 'name') ?? jStr(provider, 'id') ?? '',
                  subtitle: [
                    _keyLabel(jMap(provider, 'key')),
                    if (jStr(provider, 'error') != null) jStr(provider, 'error')!,
                  ].join(' · '),
                  value: jList(provider, 'models').isEmpty ? t('No models') : t('{count} models', {'count': jList(provider, 'models').length}),
                  leading: RowIcon(AppIcon.plug, color: jBool(jMap(provider, 'key'), 'configured') == true ? Palette.green : Palette.danger),
                  onTap: () => _open(context, provider),
                ),
            ]),
          ],
        );
      },
    );
  }

  String _keyLabel(Json? key) {
    if (key == null) return t('No key needed');
    if (jBool(key, 'configured') != true) return t('No API key yet');
    return jBool(key, 'writable') == true ? t('Key saved') : t('Key set outside DS Bot');
  }

  void _open(BuildContext context, Json provider) {
    final key = TextEditingController();
    final id = jStr(provider, 'id');
    showGlassSheet<void>(
      context,
      builder: (sheet) {
        final p = sheet.p;
        final keyInfo = jMap(provider, 'key');
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
          SheetTitle(jStr(provider, 'name') ?? ''),
          if (jBool(keyInfo, 'writable') == true) ...[
            Field(controller: key, label: jBool(keyInfo, 'configured') == true ? t('Replace the API key') : t('API key'), obscure: true),
            const SizedBox(height: 10),
            Row(children: [
              if (jBool(keyInfo, 'configured') == true)
                Expanded(
                  child: Btn(t('Remove key'), kind: BtnKind.danger, small: true, onTap: () async {
                    await run(context, 'provider-key', {'provider': id, 'value': null});
                    if (sheet.mounted) Navigator.pop(sheet);
                    _reload();
                  }),
                ),
              if (jBool(keyInfo, 'configured') == true) const SizedBox(width: 8),
              Expanded(
                child: Btn(t('Save'), small: true, onTap: () async {
                  if (key.text.isEmpty) return;
                  await run(context, 'provider-key', {'provider': id, 'value': key.text});
                  if (sheet.mounted) Navigator.pop(sheet);
                  _reload();
                }),
              ),
            ]),
          ] else if (keyInfo != null)
            Text(t('This key comes from outside DS Bot, such as an environment variable, and cannot be changed here.'), style: TypeScale.small.copyWith(color: p.ink2)),
          if (jList(provider, 'models').isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(t('Models'), style: TypeScale.smallStrong.copyWith(color: p.ink2)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final model in jMaps(provider, 'models')) Tag(jStr(model, 'name') ?? '')]),
          ],
          if (jBool(provider, 'removable') == true) ...[
            const SizedBox(height: 16),
            Btn(t('Remove provider'), kind: BtnKind.danger, expand: true, onTap: () async {
              final ok = await confirmDanger(context, title: t('Remove {name}?', {'name': jStr(provider, 'name') ?? ''}), action: t('Remove'));
              if (!ok || !context.mounted) return;
              await run(context, 'provider-remove', {'provider': id});
              if (sheet.mounted) Navigator.pop(sheet);
              _reload();
            }),
          ],
        ]);
      },
    );
  }

  void _add(BuildContext context, List<Json> addable, List<String> protocols) {
    final key = TextEditingController();
    final id = TextEditingController();
    final name = TextEditingController();
    final base = TextEditingController();
    final typed = TextEditingController();
    String? known = addable.isEmpty ? null : jStr(addable.first, 'id');
    var custom = addable.isEmpty;
    var api = protocols.isEmpty ? 'openai' : protocols.first;
    var found = <String>[];
    final picked = <String>{};
    var finding = false;
    showGlassSheet<void>(
      context,
      builder: (sheet) => StatefulBuilder(builder: (context, setState) {
        final p = context.p;
        final models = {...picked, ...typed.text.split(RegExp(r'[,\n]')).map((item) => item.trim()).where((item) => item.isNotEmpty)}.toList();
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
          SheetTitle(t('Add a provider')),
          if (addable.isNotEmpty)
            Segmented<bool>(values: const [false, true], labels: [t('Known provider'), t('Custom API')], value: custom, onChanged: (value) => setState(() => custom = value)),
          const SizedBox(height: 12),
          if (!custom) ...[
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final option in addable)
                ChoiceChip(label: Text(jStr(option, 'name') ?? ''), selected: known == jStr(option, 'id'), onSelected: (_) => setState(() => known = jStr(option, 'id'))),
            ]),
            const SizedBox(height: 12),
            Field(controller: key, label: t('API key'), obscure: true),
            const SizedBox(height: 16),
            Btn(t('Add'), expand: true, onTap: known == null
                ? null
                : () async {
                    final done = await run(context, 'provider-add', {'provider': known, 'key': key.text});
                    if (done != null && sheet.mounted) Navigator.pop(sheet);
                    _reload();
                  }),
          ] else ...[
            Field(controller: id, label: t('Provider id'), hint: 'my-api'),
            const SizedBox(height: 10),
            Field(controller: name, label: t('Name')),
            const SizedBox(height: 10),
            Field(controller: base, label: t('Base URL'), hint: 'https://api.example.com/v1', keyboardType: TextInputType.url),
            if (protocols.length > 1) ...[
              const SizedBox(height: 10),
              Segmented<String>(values: protocols, labels: protocols, value: api, onChanged: (value) => setState(() => api = value)),
            ],
            const SizedBox(height: 10),
            Field(controller: key, label: t('API key'), obscure: true),
            const SizedBox(height: 10),
            Btn(t('Find models'), kind: BtnKind.secondary, small: true, busy: finding, onTap: base.text.trim().isEmpty
                ? null
                : () async {
                    setState(() => finding = true);
                    final value = await run(context, 'provider-models', {'baseURL': base.text.trim(), 'api': api, 'key': key.text});
                    setState(() {
                      finding = false;
                      found = [for (final model in value is List ? value : const []) if (model is Map) '${model['name'] ?? model['id'] ?? ''}' else '$model'].where((item) => item.isNotEmpty).toList();
                    });
                  }),
            if (found.isNotEmpty)
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final model in found)
                  FilterChip(label: Text(model), selected: picked.contains(model), onSelected: (on) => setState(() => on ? picked.add(model) : picked.remove(model))),
              ]),
            const SizedBox(height: 10),
            Field(controller: typed, label: t('Model ids'), hint: t('One per line, or comma separated'), maxLines: 4, onChanged: (_) => setState(() {})),
            const SizedBox(height: 16),
            Btn(t('Add'), expand: true, onTap: id.text.trim().isEmpty || base.text.trim().isEmpty || models.isEmpty
                ? null
                : () async {
                    final done = await run(context, 'provider-add', {
                      'custom': true,
                      'provider': id.text.trim(),
                      'name': name.text.trim(),
                      'baseURL': base.text.trim(),
                      'api': api,
                      'key': key.text,
                      'models': models,
                    });
                    if (done != null && sheet.mounted) Navigator.pop(sheet);
                    _reload();
                  }),
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(t('{count} models', {'count': models.length}), style: TypeScale.caption.copyWith(color: p.ink3))),
          ],
        ]);
      }),
    );
  }
}
