// Team settings that are about the computer's look, usage and upkeep, and the
// phone's own notification settings.
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../data/json.dart';
import '../../data/team_state.dart';
import '../../shared/shared_data.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../manage/common.dart';
import '../manage/model_picker.dart';
import '../manage/work_pages.dart';

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ManagePage(
      title: t('Notifications'),
      children: [
        Group(
          footer: t('Shows a quiet notification so questions and approvals reach you'),
          children: [
            SwitchRow(
              title: t('Keep connected in the background'),
              leading: RowIcon(AppIcon.bell),
              value: app.prefs.keepConnected,
              onChanged: (on) => app.setKeepConnected(on),
            ),
          ],
        ),
        Group(children: [
          SwitchRow(title: t('In-app banners'), leading: RowIcon(AppIcon.inbox), value: app.prefs.banners, onChanged: (on) => app.setPrefs({'banners': on ? 'on' : 'off'})),
        ]),
      ],
    );
  }
}

/// The team's look and defaults on the computer (`set-prefs`).
class ComputerAppearancePage extends StatelessWidget {
  const ComputerAppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    if (team == null) return ManagePage(title: '', children: const []);
    final prefs = team.prefs;
    final data = SharedData.instance;
    final themeId = jStr(prefs, 'theme') ?? 'deepseek';
    final accent = jStr(prefs, 'accent');
    final layout = jStr(prefs, 'layout') == 'flat' ? 'flat' : 'bubble';
    final width = (jInt(prefs, 'width') ?? 80).clamp(50, 100);
    final effects = jStr(prefs, 'effects') ?? 'full';
    final defaultModel = jStr(prefs, 'defaultBotModel');
    void save(Map<String, dynamic> patch) => run(context, 'set-prefs', patch);
    return ManagePage(
      title: t('Appearance on the computer'),
      children: [
        Group(title: t('Theme'), children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(spacing: 10, runSpacing: 10, children: [
              for (final theme in data.themes.values)
                Pressable(
                  onTap: () => save({'theme': theme.id}),
                  child: Container(
                    width: 96,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: (p.dark ? theme.dark : theme.light).bg,
                      borderRadius: BorderRadius.circular(Radii.card),
                      border: Border.all(color: theme.id == themeId ? p.accent : p.line, width: theme.id == themeId ? 2 : 1),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        for (final color in [(p.dark ? theme.dark : theme.light).accent, (p.dark ? theme.dark : theme.light).bubble, (p.dark ? theme.dark : theme.light).user])
                          Container(margin: const EdgeInsets.only(right: 4), width: 14, height: 14, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                      ]),
                      const SizedBox(height: 8),
                      Text(theme.label, style: TypeScale.caption.copyWith(color: (p.dark ? theme.dark : theme.light).text)),
                    ]),
                  ),
                ),
            ]),
          ),
        ]),
        Group(title: t('Accent'), children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(spacing: 10, runSpacing: 10, children: [
              GestureDetector(
                onTap: () => save({'accent': null}),
                child: Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: p.bubble, border: Border.all(color: accent == null ? p.ink : Colors.transparent, width: 2.5)),
                  child: Ico(AppIcon.refresh, size: 14, color: p.ink2),
                ),
              ),
              for (final id in data.accentInks)
                GestureDetector(
                  onTap: () => save({'accent': '#${(data.inks[id]![0].toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}'}),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: data.inks[id]![p.dark ? 1 : 0],
                      border: Border.all(color: accent != null && parseHex(accent) == data.inks[id]![0] ? p.ink : Colors.transparent, width: 2.5),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
        Group(title: t('Messages'), children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Segmented<String>(values: const ['bubble', 'flat'], labels: [t('Bubbles'), t('Flat')], value: layout, onChanged: (value) => save({'layout': value})),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(children: [
              Text(t('Width'), style: TypeScale.settingsRow.copyWith(color: p.ink)),
              Expanded(
                child: Slider(value: width.toDouble(), min: 50, max: 100, divisions: 10, label: '$width%', onChanged: (_) {}, onChangeEnd: (value) => save({'width': value.round()})),
              ),
              Text('$width%', style: TypeScale.small.copyWith(color: p.ink2)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Segmented<String>(values: const ['full', 'reduced', 'off'], labels: [t('Full motion'), t('Less motion'), t('No motion')], value: effects, onChanged: (value) => save({'effects': value})),
          ),
          SwitchRow(title: t('Show thinking'), value: jBool(prefs, 'thinking') == true, onChanged: (on) => save({'thinking': on})),
          SwitchRow(title: t('Enter to send'), value: jBool(prefs, 'enterToSend') != false, onChanged: (on) => save({'enterToSend': on})),
        ]),
        Group(title: t('New Bots'), children: [
          Row2(
            title: t('Default model for new Bots'),
            value: defaultModel == null ? t('Default') : (team.models.where((model) => model.ref == defaultModel).firstOrNull?.name ?? defaultModel),
            onTap: () async {
              final picked = await pickModel(context, current: defaultModel);
              if (picked != null && context.mounted) await run(context, 'set-prefs', {'defaultBotModel': picked.isEmpty ? null : picked});
            },
          ),
        ]),
      ],
    );
  }
}

/// What the team used: in and out tokens, per Bot and per model.
class TeamUsagePage extends StatelessWidget {
  const TeamUsagePage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return ManagePage(
      title: t('Usage'),
      children: [
        FutureBuilder<String?>(
          future: localTimeZone(),
          builder: (context, zone) => zone.connectionState != ConnectionState.done
              ? const SizedBox.shrink()
              : Loader(
                  endpoint: 'usage',
                  payload: {'timeZone': ?zone.data},
                  follow: false,
                  builder: (context, value, _) {
                    final usage = summarizeUsage(value, TeamScope.read(context).team?.bots ?? const []);
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        child: Text(formatTokens(usage.input + usage.output), style: TypeScale.largeTitle.copyWith(color: p.ink)),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                        child: Text('↑${formatTokens(usage.input)}  ↓${formatTokens(usage.output)}', style: TypeScale.small.copyWith(color: p.ink2)),
                      ),
                      Group(title: t('By Bot'), children: [
                        for (final row in usage.owners) Row2(title: row.$1, value: formatTokens(row.$2)),
                      ]),
                      Group(title: t('By model'), children: [
                        for (final row in usage.models) Row2(title: row.$1, value: formatTokens(row.$2)),
                      ]),
                    ]);
                  },
                ),
        ),
      ],
    );
  }
}

/// The `usage` answer as totals: the host sends hourly rows
/// `[hour, owner, model, kind, input, cacheRead, cacheWrite, output, calls]` with
/// owner and model tables; older hosts (and the demo) send the totals directly.
({num input, num output, List<(String, num)> owners, List<(String, num)> models}) summarizeUsage(Object? value, List<Bot> bots) {
  final rows = jList(value, 'rows').whereType<List>().toList();
  if (rows.isEmpty) {
    final total = jMap(value, 'total');
    List<(String, num)> pairs(String key) => [
          for (final row in jMaps(value, key)) (jStr(row, 'name') ?? '', (jNum(row, 'input') ?? 0) + (jNum(row, 'output') ?? 0)),
        ]..sort((a, b) => b.$2.compareTo(a.$2));
    return (input: jNum(total, 'input') ?? 0, output: jNum(total, 'output') ?? 0, owners: pairs('bots'), models: pairs('models'));
  }
  final owners = jMaps(value, 'owners');
  final models = jMaps(value, 'models');
  final byOwner = <int, num>{};
  final byModel = <int, num>{};
  num input = 0;
  num output = 0;
  for (final row in rows) {
    if (row.length < 8) continue;
    final rowIn = (row[4] as num? ?? 0) + (row[5] as num? ?? 0) + (row[6] as num? ?? 0);
    final rowOut = row[7] as num? ?? 0;
    input += rowIn;
    output += rowOut;
    byOwner.update(row[1] as int? ?? -1, (sum) => sum + rowIn + rowOut, ifAbsent: () => rowIn + rowOut);
    byModel.update(row[2] as int? ?? -1, (sum) => sum + rowIn + rowOut, ifAbsent: () => rowIn + rowOut);
  }
  String ownerName(int index) {
    if (index < 0 || index >= owners.length) return t('Other');
    final owner = owners[index];
    return jStr(owner, 'name') ?? bots.where((bot) => bot.id == jStr(owner, 'id')).firstOrNull?.name ?? jStr(owner, 'kind') ?? t('Other');
  }

  String modelName(int index) => index < 0 || index >= models.length ? t('Other') : (jStr(models[index], 'name') ?? jStr(models[index], 'model') ?? '');
  return (
    input: input,
    output: output,
    owners: [for (final entry in byOwner.entries) (ownerName(entry.key), entry.value)]..sort((a, b) => b.$2.compareTo(a.$2)),
    models: [for (final entry in byModel.entries) (modelName(entry.key), entry.value)]..sort((a, b) => b.$2.compareTo(a.$2)),
  );
}

class LocationPage extends StatelessWidget {
  const LocationPage({super.key});

  @override
  Widget build(BuildContext context) {
    final team = TeamScope.of(context).team;
    return ManagePage(
      title: t('Location'),
      children: [
        Group(children: [
          Row2(
            title: t('Team workspace'),
            subtitle: team?.workspace,
            leading: RowIcon(AppIcon.folder),
            onTap: () async {
              final picked = await pickFolder(context, current: team?.workspace);
              if (picked != null && picked.isNotEmpty && context.mounted) await run(context, 'team-workspace', {'path': picked});
            },
          ),
          Row2(title: t('Data location'), subtitle: team?.dataPath, leading: RowIcon(AppIcon.lock)),
        ]),
      ],
    );
  }
}

class UpdatesPage extends StatefulWidget {
  const UpdatesPage({super.key});

  @override
  State<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends State<UpdatesPage> {
  int _version = 0;
  String? _log;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return ManagePage(
      title: t('Updates and diagnostics'),
      children: [
        Loader(
          key: ValueKey(_version),
          endpoint: 'update-check',
          payload: {'fresh': _version > 0},
          follow: false,
          builder: (context, value, reload) {
            // Older hosts nest the DS Bot part under `update`; newer ones answer flat.
            final update = jMap(value, 'update') ?? asJson(value);
            final dsh = jMap(value, 'dsh');
            final installing = jStr(update, 'phase') == 'installing';
            return Group(title: t('Updates'), children: [
              Row2(
                title: 'DS Bot ${jStr(update, 'current') ?? ''}',
                subtitle: installing
                    ? t('Installing…')
                    : (jStr(update, 'error') ?? (jBool(update, 'available') == true ? t('Version {version} is available', {'version': jStr(update, 'latest') ?? ''}) : t('Up to date'))),
                trailing: jBool(update, 'available') == true && !installing ? Btn(t('Install'), small: true, onTap: () => run(context, 'update-install')) : null,
              ),
              if (dsh != null)
                Row2(
                  title: 'DeepSeek Harness ${jStr(dsh, 'current') ?? jStr(dsh, 'installed') ?? ''}',
                  subtitle: jStr(dsh, 'error') ?? (jBool(dsh, 'available') == true ? t('Update available') : t('Up to date')),
                  trailing: jBool(dsh, 'available') == true && jStr(dsh, 'phase') != 'installing' ? Btn(t('Install'), small: true, onTap: () => run(context, 'dsh-update-install')) : null,
                ),
              Row2(title: t('Check for updates'), leading: RowIcon(AppIcon.refresh), onTap: () => setState(() => _version += 1)),
            ]);
          },
        ),
        Loader(
          endpoint: 'diagnostics',
          follow: false,
          builder: (context, value, reload) => Group(title: t('Diagnostics'), children: [
            Row2(title: t('Entries'), value: '${jInt(value, 'total') ?? jInt(value, 'entries') ?? jList(value, 'entries').length}'),
            // Entries come newest first.
            if (jStr(value, 'last') != null || jMaps(value, 'entries').isNotEmpty)
              Row2(title: t('Last entry'), subtitle: jStr(value, 'last') ?? jStr(jMaps(value, 'entries').first, 'text')),
            Row2(
              title: _log == null ? t('Show the log') : t('Hide the log'),
              leading: RowIcon(AppIcon.board),
              onTap: () async {
                if (_log != null) {
                  setState(() => _log = null);
                  return;
                }
                final log = await run(context, 'diagnostics-log');
                setState(() => _log = log is String ? log : jStrings(log, 'lines').join('\n'));
              },
            ),
            Row2(
              title: t('Clear'),
              danger: true,
              onTap: () async {
                final ok = await confirmDanger(context, title: t('Clear the diagnostics log?'), action: t('Clear'));
                if (ok && context.mounted) {
                  await run(context, 'diagnostics-clear');
                  reload();
                }
              },
            ),
          ]),
        ),
        if (_log != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(Radii.card)),
            child: SelectableText(_log!, style: TypeScale.mono.copyWith(color: p.ink, fontSize: 11)),
          ),
      ],
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = TeamScope.of(context);
    final hello = session.hello;
    return ManagePage(
      title: t('About'),
      children: [
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, info) => Group(children: [
            Row2(title: t('Phone app'), value: info.data == null ? '' : '${info.data!.version} (${info.data!.buildNumber})'),
            Row2(title: 'DS Bot', value: hello?.pluginVersion ?? session.team?.version ?? ''),
            Row2(title: t('Computer'), value: session.hostName ?? session.computer.name),
            Row2(title: t('Phone API'), value: '${hello?.api ?? ''}'),
          ]),
        ),
        Group(children: [
          Row2(title: t('License'), value: 'Apache-2.0'),
          Row2(
            title: t('Source code'),
            leading: RowIcon(AppIcon.globe),
            onTap: () => launchUrl(Uri.parse('https://github.com/CikeSeven/DS-Bot'), mode: LaunchMode.externalApplication),
          ),
        ]),
      ],
    );
  }
}
