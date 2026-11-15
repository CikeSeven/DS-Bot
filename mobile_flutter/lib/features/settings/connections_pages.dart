// What the team connects to on the computer: connectors and mail, capabilities
// (MCP servers, skills, packs), secrets, chat apps, local agent CLIs and
// computer use.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../data/json.dart';
import '../../data/team_state.dart';
import '../../shared/shared_data.dart';
import '../../ui/avatar.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../manage/common.dart';

Color _stateColor(String? state, Palette p) => switch (state) {
      'ready' => Palette.green,
      'error' || 'needs-sign-in' || 'needs-client' || 'needs-approval' => Palette.danger,
      'connecting' || 'retrying' => Palette.star,
      _ => p.ink3,
    };

String _stateText(String? state) => switch (state) {
      'ready' => t('Connected'),
      'connecting' => t('Connecting…'),
      'retrying' => t('Retrying…'),
      'error' => t('Error'),
      'needs-client' => t('Needs a client id'),
      'needs-sign-in' => t('Needs sign-in'),
      'needs-approval' => t('Needs approval'),
      _ => t('Off'),
    };

Widget _dot(String? state, Palette p) => Container(width: 9, height: 9, decoration: BoxDecoration(color: _stateColor(state, p), shape: BoxShape.circle));

// ---------------------------------------------------------------- Connectors

class ConnectorsPage extends StatelessWidget {
  const ConnectorsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final view = team?.connectors;
    final rows = view is List ? view.whereType<Map>().map(asJson).toList() : jMaps(view, 'connectors');
    final byCategory = <String, List<Json>>{};
    for (final row in rows) {
      byCategory.putIfAbsent(jStr(row, 'category') ?? t('Other'), () => []).add(row);
    }
    return ManagePage(
      title: t('Connectors'),
      actions: [
        IconBtn(AppIcon.download, tooltip: t('Import'), onTap: () => _import(context)),
        IconBtn(AppIcon.plus, onTap: () => _add(context)),
      ],
      children: [
        if (rows.isEmpty) Padding(padding: const EdgeInsets.all(32), child: Text(t('No connectors'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3))),
        for (final entry in byCategory.entries)
          Group(title: entry.key, children: [
            for (final row in entry.value)
              Row2(
                title: jStr(row, 'name') ?? jStr(row, 'id') ?? '',
                subtitle: [_stateText(jStr(row, 'state')), if (jStr(row, 'account') != null) jStr(row, 'account')!, if (jStr(row, 'error') != null) jStr(row, 'error')!].join(' · '),
                leading: _dot(jStr(row, 'state'), p),
                onTap: () => showGlassSheet<void>(context, builder: (sheet) => _ConnectorSheet(id: jStr(row, 'id') ?? '')),
              ),
          ]),
      ],
    );
  }

  void _add(BuildContext context) {
    final name = TextEditingController();
    final url = TextEditingController();
    final command = TextEditingController();
    final args = TextEditingController();
    var remote = true;
    showGlassSheet<void>(
      context,
      builder: (sheet) => StatefulBuilder(builder: (context, setState) {
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
          SheetTitle(t('Add a connector')),
          Field(controller: name, label: t('Name')),
          const SizedBox(height: 12),
          Segmented<bool>(values: const [true, false], labels: [t('Remote (URL)'), t('Local command')], value: remote, onChanged: (value) => setState(() => remote = value)),
          const SizedBox(height: 12),
          if (remote)
            Field(controller: url, label: 'URL', hint: 'https://…', keyboardType: TextInputType.url)
          else ...[
            Field(controller: command, label: t('Command'), mono: true),
            const SizedBox(height: 10),
            Field(controller: args, label: t('Arguments'), hint: t('One per line'), maxLines: 4, mono: true),
          ],
          const SizedBox(height: 16),
          Btn(t('Add'), expand: true, onTap: () async {
            if (name.text.trim().isEmpty) return;
            final done = await run(context, 'connector-add', {
              'name': name.text.trim(),
              if (remote) 'url': url.text.trim() else ...{
                'command': command.text.trim(),
                'args': args.text.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList(),
              },
            });
            if (done != null && sheet.mounted) Navigator.pop(sheet);
          }),
        ]);
      }),
    );
  }

  void _import(BuildContext context) {
    showGlassSheet<void>(
      context,
      builder: (sheet) => Loader(
        endpoint: 'connector-import-scan',
        follow: false,
        builder: (context, value, _) {
          final items = value is List ? value.whereType<Map>().map(asJson).toList() : const <Json>[];
          final picked = <int>{};
          return StatefulBuilder(builder: (context, setState) {
            final p = context.p;
            return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 20), children: [
              SheetTitle(t('Import connectors')),
              if (items.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(t('No MCP servers found in Claude Desktop, Cursor or VS Code on the computer.'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3))),
              for (final (i, item) in items.indexed)
                CheckboxListTile(
                  value: picked.contains(i),
                  onChanged: (on) => setState(() => on == true ? picked.add(i) : picked.remove(i)),
                  title: Text(jStr(item, 'name') ?? ''),
                  subtitle: Text('${jStr(item, 'source') ?? ''} · ${jStr(item, 'url') ?? jStr(item, 'command') ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              if (items.isNotEmpty)
                Btn(t('Import'), expand: true, onTap: picked.isEmpty
                    ? null
                    : () async {
                        final done = await run(context, 'connector-import', {
                          'items': [for (final i in picked) {'source': items[i]['source'], 'name': items[i]['name']}],
                        });
                        if (done != null && sheet.mounted) Navigator.pop(sheet);
                      }),
            ]);
          });
        },
      ),
    );
  }
}

class _ConnectorSheet extends StatefulWidget {
  const _ConnectorSheet({required this.id});

  final String id;

  @override
  State<_ConnectorSheet> createState() => _ConnectorSheetState();
}

class _ConnectorSheetState extends State<_ConnectorSheet> {
  final _key = TextEditingController();
  final _code = TextEditingController();
  final _client = TextEditingController();
  final _secret = TextEditingController();

  @override
  void dispose() {
    _key.dispose();
    _code.dispose();
    _client.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final view = team?.connectors;
    final rows = view is List ? view.whereType<Map>().map(asJson).toList() : jMaps(view, 'connectors');
    final row = rows.where((entry) => entry['id'] == widget.id).firstOrNull;
    if (row == null) return const SizedBox.shrink();
    final state = jStr(row, 'state');
    final auth = jMap(row, 'auth') ?? const {};
    final kind = jStr(auth, 'kind');
    final pending = jMap(row, 'pending');
    final id = widget.id;
    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
      SheetTitle(jStr(row, 'name') ?? id),
      Row(children: [_dot(state, p), const SizedBox(width: 8), Text(_stateText(state), style: TypeScale.small.copyWith(color: p.ink2))]),
      if (jStr(row, 'about') != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(jStr(row, 'about')!, style: TypeScale.small.copyWith(color: p.ink2))),
      if (jStr(row, 'error') != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(jStr(row, 'error')!, style: TypeScale.small.copyWith(color: Palette.danger))),
      const SizedBox(height: 14),
      if (pending != null && jStr(pending, 'kind') == 'device') ...[
        Text(t('Open this address and enter the code'), style: TypeScale.smallStrong.copyWith(color: p.ink)),
        const SizedBox(height: 6),
        SelectableText(jStr(pending, 'userCode') ?? '', style: TypeScale.largeTitle.copyWith(color: p.accent, letterSpacing: 2)),
        TextButton(onPressed: () => launchUrl(Uri.parse(jStr(pending, 'verificationUri') ?? ''), mode: LaunchMode.externalApplication), child: Text(jStr(pending, 'verificationUri') ?? '')),
      ],
      if (pending != null && jStr(pending, 'kind') == 'browser') ...[
        Text(t('Sign in on this phone, then paste the address the browser ends on.'), style: TypeScale.small.copyWith(color: p.ink2)),
        const SizedBox(height: 8),
        Btn(t('Open sign-in page'), kind: BtnKind.secondary, icon: AppIcon.globe, onTap: () => launchUrl(Uri.parse(jStr(pending, 'url') ?? ''), mode: LaunchMode.externalApplication)),
        const SizedBox(height: 10),
        Field(controller: _code, label: t('Address or code'), mono: true),
        const SizedBox(height: 8),
        Btn(t('Finish sign-in'), onTap: () => run(context, 'connector-sign-in-code', {'id': id, 'input': _code.text.trim()})),
        TextButton(onPressed: () => run(context, 'connector-cancel', {'id': id}), child: Text(t('Cancel'))),
      ],
      if (state == 'needs-client') ...[
        Field(controller: _client, label: t('Client id')),
        const SizedBox(height: 8),
        Field(controller: _secret, label: t('Client secret'), obscure: true),
        const SizedBox(height: 8),
        Btn(t('Save'), onTap: () => run(context, 'connector-client', {'id': id, 'clientId': _client.text.trim(), if (_secret.text.isNotEmpty) 'clientSecret': _secret.text})),
      ],
      if (state != 'ready' && pending == null && state != 'needs-client') ...[
        if (kind == 'key' || (kind == 'oauth' && jBool(auth, 'token') == true)) ...[
          Field(controller: _key, label: kind == 'key' ? t('Key') : t('Token'), obscure: true),
          if (jStr(auth, 'keyUrl') != null)
            TextButton(onPressed: () => launchUrl(Uri.parse(jStr(auth, 'keyUrl')!), mode: LaunchMode.externalApplication), child: Text(t('Get a key'))),
          const SizedBox(height: 8),
        ],
        Btn(t('Connect'), expand: true, onTap: () => run(context, 'connector-connect', {
              'id': id,
              if (kind == 'key') 'key': _key.text.trim(),
              if (kind == 'oauth' && _key.text.trim().isNotEmpty) 'token': _key.text.trim(),
            })),
      ],
      if (state == 'ready' || state == 'error') ...[
        if (jBool(row, 'readOnly') != null)
          SwitchRow(title: t('Read only'), value: jBool(row, 'readOnly') == true, onChanged: (on) => run(context, 'connector-set', {'id': id, 'readOnly': on})),
        Row(children: [
          Expanded(child: Btn(t('Try again'), kind: BtnKind.secondary, small: true, onTap: () => run(context, 'connector-retry', {'id': id}))),
          const SizedBox(width: 8),
          Expanded(child: Btn(t('Disconnect'), kind: BtnKind.danger, small: true, onTap: () => run(context, 'connector-disconnect', {'id': id}))),
        ]),
      ],
      if (team != null && team.bots.isNotEmpty) ...[
        const SizedBox(height: 14),
        Text(t('Bots that may use it'), style: TypeScale.smallStrong.copyWith(color: p.ink2)),
        for (final bot in team.bots)
          SwitchRow(
            title: bot.name,
            leading: BotAvatar(bot: bot, size: 26),
            value: !jStrings(row, 'offFor').contains(bot.id),
            onChanged: (on) {
              final off = {...jStrings(row, 'offFor')};
              on ? off.remove(bot.id) : off.add(bot.id);
              run(context, 'connector-set', {'id': id, 'offFor': off.toList()});
            },
          ),
      ],
      if (jBool(row, 'custom') == true) ...[
        const SizedBox(height: 10),
        Btn(t('Remove connector'), kind: BtnKind.danger, expand: true, onTap: () async {
          final ok = await confirmDanger(context, title: t('Remove {name}?', {'name': jStr(row, 'name') ?? id}), action: t('Remove'));
          if (ok && context.mounted) {
            await run(context, 'connector-remove', {'id': id});
            if (context.mounted) Navigator.pop(context);
          }
        }),
      ],
    ]);
  }
}

// ---------------------------------------------------------------- Mail

class MailPage extends StatelessWidget {
  const MailPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final mail = jMap(team?.connectors, 'mail') ?? const {};
    final accounts = jMaps(mail, 'accounts');
    return ManagePage(
      title: t('Mail'),
      actions: [IconBtn(AppIcon.plus, onTap: () => _add(context, jBool(mail, 'google') == true))],
      children: [
        if (accounts.isEmpty) Padding(padding: const EdgeInsets.all(32), child: Text(t('No mail accounts yet'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3))),
        Group(children: [
          for (final account in accounts)
            Row2(
              title: jStr(account, 'address') ?? '',
              subtitle: [jStr(account, 'provider') ?? '', _stateText(jStr(account, 'state')), if (jStr(account, 'error') != null) jStr(account, 'error')!].where((part) => part.isNotEmpty).join(' · '),
              leading: _dot(jStr(account, 'state'), p),
              trailing: IconBtn(AppIcon.trash, size: 18, color: p.ink3, onTap: () async {
                final ok = await confirmDanger(context, title: t('Remove {name}?', {'name': jStr(account, 'address') ?? ''}), action: t('Remove'));
                if (ok && context.mounted) await run(context, 'mail-account-remove', {'id': account['id']});
              }),
            ),
        ]),
        for (final pending in jMaps(mail, 'pending'))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Btn(t('Finish Google sign-in for {address}', {'address': jStr(pending, 'address') ?? ''}), kind: BtnKind.secondary, onTap: () => launchUrl(Uri.parse(jStr(pending, 'url') ?? ''), mode: LaunchMode.externalApplication)),
          ),
        Group(title: t('Sending rules'), children: [
          Row2(title: t('Allowed recipients'), subtitle: jStrings(mail, 'allowedRecipients').join(', '), onTap: () => _recipients(context, jStrings(mail, 'allowedRecipients'))),
        ]),
      ],
    );
  }

  void _add(BuildContext context, bool google) {
    final address = TextEditingController();
    final password = TextEditingController();
    final imap = TextEditingController();
    final smtp = TextEditingController();
    var provider = 'other';
    showGlassSheet<void>(
      context,
      builder: (sheet) => StatefulBuilder(builder: (context, setState) {
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
          SheetTitle(t('Add a mail account')),
          if (google) ...[
            Btn(t('Sign in with Google'), kind: BtnKind.secondary, expand: true, icon: AppIcon.globe, onTap: () async {
              final done = await run(context, 'mail-account-add', {'google': true});
              if (done != null && sheet.mounted) Navigator.pop(sheet);
            }),
            const SizedBox(height: 16),
          ],
          Field(controller: address, label: t('Address'), keyboardType: TextInputType.emailAddress),
          const SizedBox(height: 10),
          Field(controller: password, label: t('Password or app password'), obscure: true),
          const SizedBox(height: 10),
          Wrap(spacing: 6, children: [
            for (final option in const ['qq', '163', '126', 'gmail', 'icloud', 'other'])
              ChoiceChip(label: Text(option), selected: provider == option, onSelected: (_) => setState(() => provider = option)),
          ]),
          if (provider == 'other') ...[
            const SizedBox(height: 10),
            Field(controller: imap, label: t('IMAP server')),
            const SizedBox(height: 10),
            Field(controller: smtp, label: t('SMTP server')),
          ],
          const SizedBox(height: 16),
          Btn(t('Add'), expand: true, onTap: () async {
            final done = await run(context, 'mail-account-add', {
              'address': address.text.trim(),
              'password': password.text,
              'provider': provider,
              if (provider == 'other' && imap.text.trim().isNotEmpty) 'imapHost': imap.text.trim(),
              if (provider == 'other' && smtp.text.trim().isNotEmpty) 'smtpHost': smtp.text.trim(),
            });
            if (done != null && sheet.mounted) Navigator.pop(sheet);
          }),
        ]);
      }),
    );
  }

  void _recipients(BuildContext context, List<String> current) {
    final add = TextEditingController();
    showGlassSheet<void>(
      context,
      builder: (sheet) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
        SheetTitle(t('Allowed recipients')),
        for (final address in current)
          Row2(title: address, trailing: IconBtn(AppIcon.close, size: 18, onTap: () => run(context, 'mail-rule-set', {'mode': 'allow-recipient', 'removeRecipient': address}))),
        Row(children: [
          Expanded(child: Field(controller: add, hint: 'name@example.com', keyboardType: TextInputType.emailAddress)),
          const SizedBox(width: 8),
          Btn(t('Add'), small: true, onTap: () => run(context, 'mail-rule-set', {'mode': 'allow-recipient', 'addRecipient': add.text.trim()})),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------- Capabilities

class CapabilitiesPage extends StatelessWidget {
  const CapabilitiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final items = [...?team?.capabilities]..sort((a, b) => (jStr(a, 'name') ?? '').compareTo(jStr(b, 'name') ?? ''));
    return ManagePage(
      title: t('Capabilities'),
      actions: [IconBtn(AppIcon.plus, onTap: () => editCapability(context, null))],
      children: [
        if (items.isEmpty) Padding(padding: const EdgeInsets.all(32), child: Text(t('No capabilities yet. Add an MCP server, a skill or a pack.'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3))),
        Group(children: [
          for (final item in items)
            Row2(
              title: jStr(item, 'name') ?? '',
              subtitle: [
                switch (jStr(item, 'kind')) { 'skill' => t('Skill'), 'pack' => t('Pack'), _ => 'MCP · ${jStr(item, 'transport') == 'streamable-http' ? 'HTTP' : 'stdio'}' },
                if (jBool(item, 'approved') == false) t('Needs approval'),
                if ((jStr(item, 'description') ?? '').isNotEmpty) jStr(item, 'description')!,
              ].join(' · '),
              leading: RowIcon(switch (jStr(item, 'kind')) { 'skill' => AppIcon.sparkle, 'pack' => AppIcon.layers, _ => AppIcon.puzzle }, color: jBool(item, 'approved') == false ? Palette.star : null),
              onTap: () => editCapability(context, item),
            ),
        ]),
      ],
    );
  }
}

Future<void> editCapability(BuildContext context, Json? item) {
  final name = TextEditingController(text: jStr(item, 'name') ?? '');
  final description = TextEditingController(text: jStr(item, 'description') ?? '');
  final command = TextEditingController(text: jStr(item, 'command') ?? '');
  final args = TextEditingController(text: jStrings(item, 'args').join('\n'));
  final env = TextEditingController(text: (jMap(item, 'env') ?? const {}).entries.map((entry) => '${entry.key}=${entry.value}').join('\n'));
  final url = TextEditingController(text: jStr(item, 'url') ?? '');
  final headers = TextEditingController(text: (jMap(item, 'headers') ?? const {}).entries.map((entry) => '${entry.key}: ${entry.value}').join('\n'));
  final content = TextEditingController(text: jStr(item, 'content') ?? '');
  var kind = jStr(item, 'kind') ?? 'mcp';
  var transport = jStr(item, 'transport') == 'streamable-http' ? 'streamable-http' : 'stdio';
  final picked = {...jStrings(item, 'items')};
  final editing = item != null;
  Map<String, String> pairs(String text, String split) => {
        for (final line in text.split('\n'))
          if (line.contains(split)) line.substring(0, line.indexOf(split)).trim(): line.substring(line.indexOf(split) + split.length).trim(),
      };
  return showGlassSheet<void>(
    context,
    maxHeightFactor: 0.94,
    builder: (sheet) => StatefulBuilder(builder: (context, setState) {
      final p = context.p;
      final library = (TeamScope.of(context).team?.capabilities ?? const <Json>[]).where((entry) => jStr(entry, 'kind') != 'pack').toList();
      return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
        SheetTitle(editing ? (jStr(item, 'name') ?? '') : t('New capability')),
        if (!editing) ...[
          Segmented<String>(values: const ['mcp', 'skill', 'pack'], labels: [t('MCP server'), t('Skill'), t('Pack')], value: kind, onChanged: (value) => setState(() => kind = value)),
          const SizedBox(height: 12),
          Field(controller: name, label: t('Name'), hint: 'my-tool'),
          const SizedBox(height: 10),
        ],
        Field(controller: description, label: t('Description'), maxLines: 3),
        const SizedBox(height: 10),
        if (kind == 'mcp') ...[
          Segmented<String>(values: const ['stdio', 'streamable-http'], labels: [t('Local command'), 'HTTP'], value: transport, onChanged: (value) => setState(() => transport = value)),
          const SizedBox(height: 10),
          if (transport == 'stdio') ...[
            Field(controller: command, label: t('Command'), mono: true),
            const SizedBox(height: 10),
            Field(controller: args, label: t('Arguments'), hint: t('One per line'), maxLines: 4, mono: true),
            const SizedBox(height: 10),
            Field(controller: env, label: t('Environment'), hint: r'KEY=value or KEY=$DSH_SECRET_NAME', maxLines: 4, mono: true),
          ] else ...[
            Field(controller: url, label: 'URL', keyboardType: TextInputType.url),
            const SizedBox(height: 10),
            Field(controller: headers, label: t('Headers'), hint: r'Authorization: Bearer $DSH_SECRET_TOKEN', maxLines: 4, mono: true),
          ],
        ],
        if (kind == 'skill') Field(controller: content, label: t('Instructions'), maxLines: 12, minLines: 5),
        if (kind == 'pack')
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final entry in library)
              FilterChip(
                label: Text(jStr(entry, 'name') ?? ''),
                selected: picked.contains(jStr(entry, 'name')),
                onSelected: (on) => setState(() => on ? picked.add(jStr(entry, 'name')!) : picked.remove(jStr(entry, 'name'))),
              ),
          ]),
        const SizedBox(height: 16),
        Btn(t('Save'), expand: true, onTap: () async {
          final payload = <String, dynamic>{
            'name': editing ? jStr(item, 'name') : name.text.trim(),
            'kind': kind,
            'description': description.text.trim(),
            if (kind == 'mcp') 'transport': transport,
            if (kind == 'mcp' && transport == 'stdio') ...{
              'command': command.text.trim(),
              'args': args.text.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList(),
              'env': pairs(env.text, '='),
            },
            if (kind == 'mcp' && transport != 'stdio') ...{'url': url.text.trim(), 'headers': pairs(headers.text, ':')},
            if (kind == 'skill') 'content': content.text,
            if (kind == 'pack') 'items': picked.toList(),
          };
          final done = await run(context, 'capability-save', payload);
          if (done != null && sheet.mounted) Navigator.pop(sheet);
        }),
        if (editing && jBool(item, 'approved') == false) ...[
          const SizedBox(height: 8),
          Btn(t('Approve'), kind: BtnKind.secondary, expand: true, icon: AppIcon.shield, onTap: () => run(context, 'capability-approve', {'name': jStr(item, 'name')})),
        ],
        if (editing) ...[
          const SizedBox(height: 8),
          Btn(t('Delete'), kind: BtnKind.danger, expand: true, onTap: () async {
            final ok = await confirmDanger(context, title: t('Delete {name}?', {'name': jStr(item, 'name') ?? ''}), action: t('Delete'));
            if (!ok || !context.mounted) return;
            final done = await run(context, 'capability-delete', {'name': jStr(item, 'name')});
            if (done != null && sheet.mounted) Navigator.pop(sheet);
          }),
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(t('Created by {name}', {'name': TeamScope.read(context).team?.bot(jStr(item, 'createdBy'))?.name ?? t('You')}), style: TypeScale.caption.copyWith(color: p.ink3))),
        ],
      ]);
    }),
  );
}

// ---------------------------------------------------------------- Secrets

class SecretsPage extends StatelessWidget {
  const SecretsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final secrets = team?.secrets ?? const <Json>[];
    final store = team?.secretStore;
    final locked = jBool(store, 'locked') == true;
    return ManagePage(
      title: t('Secrets'),
      actions: [if (!locked) IconBtn(AppIcon.plus, onTap: () => _edit(context, null, team))],
      children: [
        Group(children: [
          Row2(
            title: jStr(store, 'mode') == 'encrypted' ? (locked ? t('Encrypted · locked') : t('Encrypted')) : t('Not encrypted'),
            leading: RowIcon(AppIcon.lock, color: jStr(store, 'mode') == 'encrypted' ? Palette.green : Palette.star),
            onTap: () => _store(context, store),
          ),
        ]),
        if (!locked)
          Group(footer: t('Values never leave the computer.'), children: [
            for (final secret in secrets)
              Row2(
                title: jStr(secret, 'name') ?? '',
                subtitle: [_scopeText(secret['scope'], team), if ((jStr(secret, 'purpose') ?? '').isNotEmpty) jStr(secret, 'purpose')!].join(' · '),
                leading: RowIcon(AppIcon.key),
                onTap: () => _edit(context, secret, team),
              ),
          ]),
        if (secrets.isEmpty && !locked) Padding(padding: const EdgeInsets.all(24), child: Text(t('No secrets yet'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3))),
      ],
    );
  }

  String _scopeText(Object? scope, TeamState? team) {
    if (scope == 'all') return t('Every Bot');
    final ids = scope is List ? scope.whereType<String>().toList() : const <String>[];
    if (ids.isEmpty) return t('No Bot');
    return ids.map((id) => team?.bot(id)?.name ?? id).join(', ');
  }

  void _store(BuildContext context, Json? store) {
    final pass = TextEditingController();
    final encrypted = jStr(store, 'mode') == 'encrypted';
    final locked = jBool(store, 'locked') == true;
    showGlassSheet<void>(
      context,
      builder: (sheet) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
        SheetTitle(t('Secret store')),
        Field(controller: pass, label: t('Passphrase'), obscure: true),
        const SizedBox(height: 14),
        if (locked)
          Btn(t('Unlock'), expand: true, onTap: () async {
            final done = await run(context, 'secret-unlock', {'passphrase': pass.text});
            if (done != null && sheet.mounted) Navigator.pop(sheet);
          })
        else if (!encrypted)
          Btn(t('Encrypt'), expand: true, onTap: () async {
            final done = await run(context, 'secret-encrypt', {'passphrase': pass.text});
            if (done != null && sheet.mounted) Navigator.pop(sheet);
          }),
        if (encrypted) ...[
          const SizedBox(height: 8),
          Btn(t('Decrypt'), kind: BtnKind.secondary, expand: true, onTap: () async {
            final done = await run(context, 'secret-decrypt', {'passphrase': pass.text});
            if (done != null && sheet.mounted) Navigator.pop(sheet);
          }),
        ],
      ]),
    );
  }

  void _edit(BuildContext context, Json? secret, TeamState? team) {
    final name = TextEditingController(text: jStr(secret, 'name') ?? '');
    final value = TextEditingController();
    final purpose = TextEditingController(text: jStr(secret, 'purpose') ?? '');
    final scopeRaw = secret?['scope'];
    var all = secret == null || scopeRaw == 'all';
    final bots = <String>{...(scopeRaw is List ? scopeRaw.whereType<String>() : const <String>[])};
    showGlassSheet<void>(
      context,
      maxHeightFactor: 0.94,
      builder: (sheet) => StatefulBuilder(builder: (context, setState) {
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
          SheetTitle(secret == null ? t('New secret') : (jStr(secret, 'name') ?? '')),
          if (secret == null) ...[Field(controller: name, label: t('Name'), hint: 'GITHUB_TOKEN', mono: true), const SizedBox(height: 10)],
          Field(controller: value, label: secret == null ? t('Value') : t('New value (leave empty to keep)'), obscure: true),
          const SizedBox(height: 10),
          Field(controller: purpose, label: t('What it is for')),
          const SizedBox(height: 12),
          SwitchRow(title: t('Every Bot may use it'), value: all, onChanged: (on) => setState(() => all = on)),
          if (!all)
            for (final bot in team?.bots ?? const <Bot>[])
              CheckboxListTile(
                value: bots.contains(bot.id),
                onChanged: (on) => setState(() => on == true ? bots.add(bot.id) : bots.remove(bot.id)),
                title: Text(bot.name),
                secondary: BotAvatar(bot: bot, size: 26),
              ),
          const SizedBox(height: 14),
          Btn(t('Save'), expand: true, onTap: () async {
            final scope = all ? 'all' : bots.toList();
            Object? done;
            if (secret == null || value.text.isNotEmpty) {
              done = await run(context, 'secret-set', {'name': secret == null ? name.text.trim() : jStr(secret, 'name'), 'value': value.text, 'purpose': purpose.text.trim(), 'scope': scope});
            } else {
              done = await run(context, 'secret-update', {'name': jStr(secret, 'name'), 'purpose': purpose.text.trim(), 'scope': scope});
            }
            if (done != null && sheet.mounted) Navigator.pop(sheet);
          }),
          if (secret != null) ...[
            const SizedBox(height: 8),
            Btn(t('Delete'), kind: BtnKind.danger, expand: true, onTap: () async {
              final ok = await confirmDanger(context, title: t('Delete {name}?', {'name': jStr(secret, 'name') ?? ''}), action: t('Delete'));
              if (!ok || !context.mounted) return;
              final done = await run(context, 'secret-delete', {'name': jStr(secret, 'name')});
              if (done != null && sheet.mounted) Navigator.pop(sheet);
            }),
          ],
        ]);
      }),
    );
  }
}

// ---------------------------------------------------------------- Chat apps (IM)

class ImPage extends StatelessWidget {
  const ImPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final connections = jMaps(team?.im, 'connections');
    final status = jMap(team?.raw, 'imStatus') ?? const {};
    final platforms = SharedData.instance.imPlatforms;
    String platformName(String? id) => jStr(platforms.where((entry) => entry['id'] == id).firstOrNull, 'name') ?? id ?? '';
    return ManagePage(
      title: t('Chat apps'),
      actions: [IconBtn(AppIcon.plus, onTap: () => _add(context, team))],
      children: [
        if (connections.isEmpty) Padding(padding: const EdgeInsets.all(32), child: Text(t('Talk to your Bots from Telegram, Feishu, DingTalk, WeChat and more.'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3))),
        Group(children: [
          for (final conn in connections)
            Row2(
              title: '${platformName(jStr(conn, 'platform'))} · ${jStr(jMap(conn, 'account'), 'name') ?? ''}',
              subtitle: [
                jBool(conn, 'enabled') == false ? t('Off') : _stateText(jStr(jMap(status, jStr(conn, 'id') ?? ''), 'state')),
                team?.bot(jStr(conn, 'botId'))?.name ?? '',
              ].where((part) => part.isNotEmpty).join(' · '),
              leading: _dot(jBool(conn, 'enabled') == false ? 'off' : jStr(jMap(status, jStr(conn, 'id') ?? ''), 'state'), p),
              onTap: () => showGlassSheet<void>(context, builder: (sheet) => _ImSheet(id: jStr(conn, 'id') ?? '')),
            ),
        ]),
      ],
    );
  }

  void _add(BuildContext context, TeamState? team) {
    final platforms = SharedData.instance.imPlatforms;
    String? platform = jStr(platforms.firstOrNull, 'id');
    String? botId = team?.mainBotId ?? team?.bots.firstOrNull?.id;
    final fields = <String, TextEditingController>{};
    showGlassSheet<void>(
      context,
      maxHeightFactor: 0.94,
      builder: (sheet) => StatefulBuilder(builder: (context, setState) {
        final p = context.p;
        final spec = platforms.where((entry) => entry['id'] == platform).firstOrNull ?? const {};
        final qr = jStr(spec, 'login') == 'qr';
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
          SheetTitle(t('Add a chat app')),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final entry in platforms) ChoiceChip(label: Text(jStr(entry, 'name') ?? ''), selected: entry['id'] == platform, onSelected: (_) => setState(() => platform = jStr(entry, 'id'))),
          ]),
          const SizedBox(height: 12),
          Text(t('Bot'), style: TypeScale.smallStrong.copyWith(color: p.ink2)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final bot in team?.bots ?? const <Bot>[])
              ChoiceChip(avatar: BotAvatar(bot: bot, size: 18), label: Text(bot.name), selected: bot.id == botId, onSelected: (_) => setState(() => botId = bot.id)),
          ]),
          const SizedBox(height: 12),
          if (qr)
            Text(t('WeChat signs in by scanning a code with another phone. Start it on the computer, or show the code here and scan it with the phone that has WeChat.'), style: TypeScale.small.copyWith(color: p.ink2))
          else
            for (final field in jMaps(spec, 'fields')) ...[
              if (jList(field, 'options').isNotEmpty)
                Wrap(spacing: 6, children: [
                  for (final option in jList(field, 'options').whereType<List>())
                    ChoiceChip(
                      label: Text('${option[1]}'),
                      selected: (fields[jStr(field, 'key')]?.text ?? '${jList(field, 'options').whereType<List>().first[0]}') == '${option[0]}',
                      onSelected: (_) => setState(() => fields.putIfAbsent(jStr(field, 'key')!, TextEditingController.new).text = '${option[0]}'),
                    ),
                ])
              else
                Field(controller: fields.putIfAbsent(jStr(field, 'key')!, TextEditingController.new), label: t(jStr(field, 'label') ?? ''), obscure: jBool(field, 'secret') == true),
              const SizedBox(height: 10),
            ],
          if (jStr(spec, 'help') != null) TextButton(onPressed: () => launchUrl(Uri.parse(jStr(spec, 'help')!), mode: LaunchMode.externalApplication), child: Text(t('How to get these'))),
          const SizedBox(height: 10),
          Btn(qr ? t('Show sign-in code') : t('Add'), expand: true, onTap: platform == null || botId == null
              ? null
              : () async {
                  if (qr) {
                    Navigator.pop(sheet);
                    await _qrLogin(context, platform!, botId!);
                    return;
                  }
                  final done = await run(context, 'im-add', {
                    'platform': platform,
                    'botId': botId,
                    'fields': {for (final entry in fields.entries) entry.key: entry.value.text.trim()},
                  });
                  if (done != null && sheet.mounted) Navigator.pop(sheet);
                }),
        ]);
      }),
    );
  }

  Future<void> _qrLogin(BuildContext context, String platform, String botId) async {
    final start = await run(context, 'im-login-start', {'platform': platform, 'botId': botId});
    if (start == null || !context.mounted) return;
    final loginId = jStr(start, 'loginId');
    final qr = jStr(start, 'qr') ?? '';
    var status = 'waiting';
    var active = true;
    await showGlassSheet<void>(
      context,
      builder: (sheet) => StatefulBuilder(builder: (context, setState) {
        if (active && status != 'done' && status != 'expired') {
          active = false;
          unawaited(() async {
            while (sheet.mounted && status != 'done' && status != 'expired') {
              try {
                final answer = await TeamScope.read(context).call('im-login-wait', {'platform': platform, 'botId': botId, 'loginId': loginId});
                status = jStr(answer, 'status') ?? status;
                if (sheet.mounted) setState(() {});
              } on Object {
                break;
              }
            }
          }());
        }
        final p = context.p;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SheetTitle(t('Scan with WeChat')),
            if (qr.startsWith('data:image') || qr.startsWith('http'))
              Text(t('Open this code on another screen and scan it with WeChat:'), style: TypeScale.small.copyWith(color: p.ink2)),
            const SizedBox(height: 8),
            SelectableText(qr, style: TypeScale.mono.copyWith(color: p.ink, fontSize: 11), maxLines: 6),
            const SizedBox(height: 12),
            Text(switch (status) { 'scanned' => t('Scanned. Confirm on the phone with WeChat.'), 'done' => t('Connected'), 'expired' => t('The code expired. Start again.'), _ => t('Waiting for the scan…') },
                style: TypeScale.rowNameStrong.copyWith(color: status == 'done' ? Palette.green : p.ink)),
          ]),
        );
      }),
    );
  }
}

class _ImSheet extends StatelessWidget {
  const _ImSheet({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final conn = jMaps(team?.im, 'connections').where((entry) => entry['id'] == id).firstOrNull;
    if (conn == null) return const SizedBox.shrink();
    final chats = jMap(conn, 'chats') ?? const {};
    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
      SheetTitle(jStr(jMap(conn, 'account'), 'name') ?? jStr(conn, 'platform') ?? ''),
      SwitchRow(title: t('On'), value: jBool(conn, 'enabled') != false, onChanged: (on) => run(context, 'im-update', {'id': id, 'enabled': on})),
      Row2(
        title: t('Bot'),
        value: team?.bot(jStr(conn, 'botId'))?.name ?? '',
        onTap: () => showActions(context, [
          for (final bot in team?.bots ?? const <Bot>[]) MenuAction(bot.name, AppIcon.sparkle, () => run(context, 'im-update', {'id': id, 'botId': bot.id})),
        ]),
      ),
      if (jMaps(conn, 'requests').isNotEmpty) ...[
        Padding(padding: const EdgeInsets.fromLTRB(4, 12, 4, 6), child: Text(t('Waiting to talk'), style: TypeScale.smallStrong.copyWith(color: p.ink2))),
        for (final request in jMaps(conn, 'requests'))
          Row2(
            title: jStr(request, 'name') ?? '',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(onPressed: () => run(context, 'im-pair', {'id': id, 'senderId': request['id'], 'allow': false}), child: Text(t('Deny'))),
              Btn(t('Allow'), small: true, onTap: () => run(context, 'im-pair', {'id': id, 'senderId': request['id'], 'allow': true})),
            ]),
          ),
      ],
      if (jMaps(conn, 'paired').isNotEmpty) ...[
        Padding(padding: const EdgeInsets.fromLTRB(4, 12, 4, 6), child: Text(t('Allowed people'), style: TypeScale.smallStrong.copyWith(color: p.ink2))),
        for (final person in jMaps(conn, 'paired'))
          Row2(title: jStr(person, 'name') ?? '', trailing: IconBtn(AppIcon.close, size: 18, onTap: () => run(context, 'im-unpair', {'id': id, 'senderId': person['id']}))),
      ],
      if (chats.isNotEmpty) ...[
        Padding(padding: const EdgeInsets.fromLTRB(4, 12, 4, 6), child: Text(t('Chats'), style: TypeScale.smallStrong.copyWith(color: p.ink2))),
        for (final entry in chats.entries)
          Row2(
            title: jStr(entry.value, 'title') ?? entry.key,
            subtitle: () {
              final target = jMap(entry.value, 'target');
              if (target == null) return team?.bot(jStr(conn, 'botId'))?.name;
              return team?.bot(jStr(target, 'botId'))?.name ?? team?.room(jStr(target, 'roomId'))?.name;
            }(),
            onTap: () => showActions(context, [
              for (final bot in team?.bots ?? const <Bot>[]) MenuAction(bot.name, AppIcon.sparkle, () => run(context, 'im-chat', {'id': id, 'chatKey': entry.key, 'target': {'botId': bot.id}})),
              for (final room in team?.rooms ?? const <Room>[]) MenuAction(room.name, AppIcon.people, () => run(context, 'im-chat', {'id': id, 'chatKey': entry.key, 'target': {'roomId': room.id}})),
              MenuAction(t('Forget this chat'), AppIcon.trash, () => run(context, 'im-chat', {'id': id, 'chatKey': entry.key, 'remove': true}), danger: true),
            ]),
          ),
      ],
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: Btn(t('Try again'), kind: BtnKind.secondary, small: true, onTap: () => run(context, 'im-retry', {'id': id}))),
        const SizedBox(width: 8),
        Expanded(child: Btn(t('Remove'), kind: BtnKind.danger, small: true, onTap: () async {
          final ok = await confirmDanger(context, title: t('Remove this chat app?'), action: t('Remove'));
          if (ok && context.mounted) {
            await run(context, 'im-remove', {'id': id});
            if (context.mounted) Navigator.pop(context);
          }
        })),
      ]),
    ]);
  }
}

// ---------------------------------------------------------------- Local agents

class LocalAgentsPage extends StatefulWidget {
  const LocalAgentsPage({super.key});

  @override
  State<LocalAgentsPage> createState() => _LocalAgentsPageState();
}

class _LocalAgentsPageState extends State<LocalAgentsPage> {
  int _version = 0;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    return Loader(
      key: ValueKey(_version),
      endpoint: _version == 0 ? 'local-agents' : 'local-agent-refresh',
      follow: false,
      builder: (context, value, reload) => ManagePage(
        title: t('Local agents'),
        actions: [
          IconBtn(AppIcon.refresh, onTap: () => setState(() => _version += 1)),
          IconBtn(AppIcon.plus, onTap: () => _edit(context, null)),
        ],
        children: [
          if (jBool(value, 'available') == false)
            Padding(padding: const EdgeInsets.all(24), child: Text(t('This DSH cannot run local agent CLIs.'), style: TypeScale.small.copyWith(color: p.ink2))),
          Group(title: t('Found on the computer'), footer: t('A Bot can run on one of these instead of a model. Pick it in the Bot\'s model menu.'), children: [
            for (final agent in jMaps(value, 'detected'))
              Row2(
                title: jStr(agent, 'name') ?? '',
                subtitle: [
                  jStr(agent, 'version') ?? '',
                  switch (jBool(agent, 'signedIn')) { true => t('Signed in'), false => t('Not signed in · {command}', {'command': jStr(agent, 'signIn') ?? ''}), _ => '' },
                ].where((part) => part.isNotEmpty).join(' · '),
                leading: RowIcon(AppIcon.bolt, color: jBool(agent, 'signedIn') == false ? Palette.star : Palette.green),
              ),
          ]),
          Group(title: t('Your own agents'), children: [
            for (final agent in jMaps(value, 'custom'))
              Row2(
                title: jStr(agent, 'name') ?? '',
                subtitle: '${jStr(agent, 'command') ?? ''} ${jStrings(agent, 'args').join(' ')}',
                leading: RowIcon(AppIcon.bolt),
                onTap: () => _edit(context, agent),
              ),
          ]),
          if (team != null && team.agents.isEmpty)
            Group(children: [Row2(title: t('Add a DSH Agent to the team'), leading: RowIcon(AppIcon.plus), onTap: () => run(context, 'add-agent'))]),
          for (final agent in team?.agents ?? const <Json>[])
            Group(title: 'DSH Agent', children: [
              Row2(title: t('{count} sessions', {'count': jList(agent, 'sessions').length}), leading: RowIcon(AppIcon.chat)),
              Row2(title: t('Remove the DSH Agent'), danger: true, onTap: () async {
                final ok = await confirmDanger(context, title: t('Remove the DSH Agent?'), action: t('Remove'));
                if (ok && context.mounted) await run(context, 'remove-agent', {'agentId': agent['id']});
              }),
            ]),
        ],
      ),
    );
  }

  void _edit(BuildContext context, Json? agent) {
    final name = TextEditingController(text: jStr(agent, 'name') ?? '');
    final command = TextEditingController(text: jStr(agent, 'command') ?? '');
    final args = TextEditingController(text: jStrings(agent, 'args').join(' '));
    showGlassSheet<void>(
      context,
      builder: (sheet) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
        SheetTitle(agent == null ? t('Add an agent') : (jStr(agent, 'name') ?? '')),
        Field(controller: name, label: t('Name')),
        const SizedBox(height: 10),
        Field(controller: command, label: t('Command'), hint: 'my-agent', mono: true),
        const SizedBox(height: 10),
        Field(controller: args, label: t('Arguments'), hint: '--acp', mono: true),
        const SizedBox(height: 16),
        Btn(t('Save'), expand: true, onTap: () async {
          final done = await run(context, agent == null ? 'local-agent-add' : 'local-agent-update', {
            if (agent != null) 'id': agent['id'],
            'name': name.text.trim(),
            'command': command.text.trim(),
            'args': args.text.trim(),
          });
          if (done != null && sheet.mounted) {
            Navigator.pop(sheet);
            setState(() => _version += 1);
          }
        }),
        if (agent != null) ...[
          const SizedBox(height: 8),
          Btn(t('Remove'), kind: BtnKind.danger, expand: true, onTap: () async {
            final done = await run(context, 'local-agent-remove', {'id': agent['id']});
            if (done != null && sheet.mounted) {
              Navigator.pop(sheet);
              setState(() => _version += 1);
            }
          }),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------- Computer use

class ComputerUsePage extends StatelessWidget {
  const ComputerUsePage({super.key});

  static Map<String, String> get _levels => {'off': t('Off'), 'view': t('Look only'), 'background': t('In the background'), 'foreground': t('Take the screen')};

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final computer = team?.computer ?? const {};
    final provider = jMap(computer, 'provider') ?? const {};
    final live = team?.computerLive ?? const {};
    final enabled = jBool(computer, 'enabled') == true;
    return ManagePage(
      title: t('Computer use'),
      children: [
        Group(children: [
          SwitchRow(title: t('Let Bots use this computer'), value: enabled, onChanged: (on) => run(context, 'computer-set-enabled', {'enabled': on})),
          Row2(
            title: t('Status'),
            value: switch (jStr(provider, 'state')) { 'ready' => t('Ready'), 'loading' => t('Loading…'), 'unsupported' => t('Not supported here'), 'occupied' => t('In use by another app'), 'missing' => t('Not installed'), 'error' => t('Error'), _ => t('Off') },
            subtitle: jStr(provider, 'message') ?? jStr(jMap(provider, 'install'), 'command'),
            trailing: jStr(provider, 'state') == 'error' ? TextButton(onPressed: () => run(context, 'computer-provider-retry'), child: Text(t('Try again'))) : null,
          ),
        ]),
        if (enabled)
          for (final bot in team?.bots ?? const <Bot>[])
            () {
              final entry = jMap(jMap(computer, 'bots'), bot.id) ?? const {};
              final state = jMap(jMap(live, 'bots'), bot.id);
              final apps = jMap(entry, 'apps') ?? const {};
              final level = jStr(entry, 'level') ?? 'background';
              return Group(title: bot.name, children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Segmented<String>(values: _levels.keys.toList(), labels: _levels.values.toList(), value: level, onChanged: (value) => run(context, 'computer-set-level', {'botId': bot.id, 'level': value})),
                ),
                if (state != null && jStr(state, 'state') != 'idle')
                  Row2(
                    title: switch (jStr(state, 'state')) { 'user' => t('You have the computer'), 'waiting' => t('Waiting'), _ => t('Working on {app}', {'app': jStr(state, 'app') ?? ''}) },
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (jStr(state, 'state') == 'user') TextButton(onPressed: () => run(context, 'computer-handback', {'botId': bot.id}), child: Text(t('Give back'))),
                      if (jStr(state, 'state') == 'bot') TextButton(onPressed: () => run(context, 'computer-takeover', {'botId': bot.id}), child: Text(t('Take over'))),
                      if (jStr(state, 'waitingFor') == 'user-idle') TextButton(onPressed: () => run(context, 'computer-allow-foreground', {'botId': bot.id}), child: Text(t('Let it continue'))),
                      TextButton(onPressed: () => run(context, 'computer-stop', {'botId': bot.id}), child: Text(t('Stop'), style: const TextStyle(color: Palette.danger))),
                    ]),
                  ),
                for (final app in apps.entries)
                  Row2(
                    title: jStr(app.value, 'name') ?? app.key,
                    subtitle: t('Allowed'),
                    trailing: IconBtn(AppIcon.close, size: 18, color: p.ink3, onTap: () => run(context, 'computer-revoke-app', {'botId': bot.id, 'appKey': app.key})),
                  ),
              ]);
            }(),
        if (enabled && (jList(live, 'leases').isNotEmpty))
          Padding(
            padding: const EdgeInsets.all(16),
            child: Btn(t('Stop every Bot'), kind: BtnKind.danger, expand: true, onTap: () => run(context, 'computer-stop', {'all': true})),
          ),
      ],
    );
  }
}
