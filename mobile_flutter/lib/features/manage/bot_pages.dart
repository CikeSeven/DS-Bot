// A Bot's details, its settings, and a new Bot: what the desktop's details
// drawer and Bot settings hold, laid out for one hand.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../data/json.dart';
import '../../data/team_state.dart';
import '../../shared/characters.dart';
import '../../shared/shared_data.dart';
import '../../ui/avatar.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../chat/chat_page.dart';
import 'browser_page.dart';
import 'common.dart';
import 'group_pages.dart';
import 'memory_page.dart';
import 'model_picker.dart';
import 'work_pages.dart';

void openBotDetails(BuildContext context, String botId) => push(context, BotDetailsPage(botId: botId));

class BotDetailsPage extends StatelessWidget {
  const BotDetailsPage({super.key, required this.botId});

  final String botId;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final session = TeamScope.of(context);
    final team = session.team;
    final bot = team?.bot(botId);
    if (team == null || bot == null) return ManagePage(title: '', children: const []);
    final main = team.isMain(bot.id);
    return ManagePage(
      title: bot.name,
      actions: [IconBtn(AppIcon.gear, onTap: () => push(context, BotEditPage(botId: bot.id)))],
      children: [
        const SizedBox(height: 8),
        Center(child: BotAvatar(bot: bot, size: 76, main: main, working: team.botWorking(bot.id))),
        const SizedBox(height: 10),
        Center(child: Text(bot.name, style: TypeScale.sectionTitle.copyWith(color: p.ink))),
        if (bot.role != null) Center(child: Text(bot.role!, style: TypeScale.small.copyWith(color: p.ink3))),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(child: _QuickAction(icon: AppIcon.chat, label: t('Chat'), onTap: () => openChat(context, botId: bot.id, replace: true))),
            const SizedBox(width: 8),
            Expanded(child: _QuickAction(icon: AppIcon.memory, label: t('Memory'), onTap: () => push(context, MemoryPage(botId: bot.id)))),
            const SizedBox(width: 8),
            Expanded(child: _QuickAction(icon: AppIcon.clock, label: t('Scheduled tasks'), onTap: () => push(context, SchedulesPage(botId: bot.id)))),
            if (team.browserEnabled) ...[
              const SizedBox(width: 8),
              Expanded(child: _QuickAction(icon: AppIcon.globe, label: t('Browser'), onTap: () => push(context, BrowserPage(botId: bot.id)))),
            ],
          ]),
        ),
        BlockTitle(t('Model')),
        ModelButton(bot: bot),
        if (team.permissions.isNotEmpty || jList(team.raw['permissions'], 'options').isNotEmpty) ...[
          BlockTitle(t('Permissions')),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: PermissionPicker(team: team, current: bot.permission, onPick: (value) => run(context, 'update-bot', {'id': bot.id, 'permission': value}))),
        ],
        BlockTitle(t('Working folder')),
        Group(margin: const EdgeInsets.symmetric(horizontal: 16), children: [
          Row2(
            title: bot.workDir == null ? t('Team workspace') : bot.workDir!.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).last,
            subtitle: bot.workDir,
            leading: RowIcon(AppIcon.folder),
            onTap: () async {
              final picked = await pickFolder(context, current: bot.workDir);
              if (picked != null && context.mounted) await run(context, 'update-bot', {'id': bot.id, 'workDir': picked});
            },
          ),
        ]),
        BlockTitle(t('Instructions'), trailing: TextButton(onPressed: () => push(context, BotEditPage(botId: bot.id)), child: Text(t('Edit')))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            (bot.instructions ?? '').isEmpty ? t('Add instructions in Bot settings') : bot.instructions!,
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: TypeScale.small.copyWith(color: (bot.instructions ?? '').isEmpty ? p.ink3 : p.ink2),
          ),
        ),
        Loader(
          endpoint: 'run-stats',
          payload: {'botId': bot.id},
          builder: (context, value, _) {
            final usage = jMap(value, 'tokenUsage');
            if (usage == null) return const SizedBox.shrink();
            final input = (jNum(usage, 'uncachedInputTokens') ?? 0) + (jNum(usage, 'cacheReadTokens') ?? 0) + (jNum(usage, 'cacheWriteTokens') ?? 0);
            final output = jNum(usage, 'outputTokens') ?? 0;
            final pressure = jMap(value, 'contextPressure');
            final used = jNum(pressure, 'pressureTokens');
            final window = jNum(pressure, 'contextWindow');
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              BlockTitle(t('Usage')),
              Group(margin: const EdgeInsets.symmetric(horizontal: 16), children: [
                Row2(
                  title: t('{tokens} tok · Cache hit {hit}%', {'tokens': formatTokens(input + output), 'hit': input > 0 ? ((jNum(usage, 'cacheReadTokens') ?? 0) / input * 100).round() : 0}),
                  leading: RowIcon(AppIcon.chart),
                  onTap: () => push(context, UsagePage(botId: bot.id)),
                ),
                if (used != null && window != null && window > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t('Context used · {percent}%', {'percent': (used / window * 100).round()}), style: TypeScale.caption.copyWith(color: p.ink2)),
                      const SizedBox(height: 6),
                      ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: (used / window).clamp(0, 1).toDouble(), minHeight: 6, color: p.accent, backgroundColor: p.hover)),
                    ]),
                  ),
              ]),
            ]);
          },
        ),
      ],
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onTap});

  final AppIcon icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 64,
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.dialog), border: Border.all(color: p.line)),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Ico(icon, size: 20, color: p.accent),
          const SizedBox(height: 4),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.caption.copyWith(color: p.ink)),
        ]),
      ),
    );
  }
}

/// DeepSeek Harness's permission presets as one choice. Full access is red and
/// asks again before it applies.
class PermissionPicker extends StatelessWidget {
  const PermissionPicker({super.key, required this.team, required this.current, required this.onPick});

  final TeamState team;
  final String? current;
  final ValueChanged<String> onPick;

  static const _labels = {'read-only': 'Read only', 'workspace-write': 'Workspace', 'danger-full-access': 'Full access'};

  @override
  Widget build(BuildContext context) {
    final raw = team.raw['permissions'];
    final options = raw is Map ? jMaps(raw, 'options') : jMaps(team.raw, 'permissions');
    final fallback = raw is Map ? jStr(raw, 'defaultPreset') : null;
    final values = [for (final option in options) jStr(option, 'value') ?? ''];
    if (values.isEmpty) return const SizedBox.shrink();
    final labels = [for (final option in options) t(_labels[jStr(option, 'value')] ?? jStr(option, 'name') ?? '')];
    final now = current ?? fallback ?? values.first;
    return Segmented<String>(
      values: values,
      labels: labels,
      value: values.contains(now) ? now : values.first,
      onChanged: (value) async {
        if (value == now) return;
        if (value == 'danger-full-access') {
          final ok = await confirmDanger(
            context,
            title: t('Full access'),
            body: t('Full access lets this Bot change anything on the computer. Turn it on?'),
            action: t('Turn on'),
          );
          if (!ok) return;
        }
        onPick(value);
      },
    );
  }
}

class BotEditPage extends StatefulWidget {
  const BotEditPage({super.key, required this.botId});

  final String botId;

  @override
  State<BotEditPage> createState() => _BotEditPageState();
}

class _BotEditPageState extends State<BotEditPage> {
  final _name = TextEditingController();
  final _role = TextEditingController();
  final _instructions = TextEditingController();
  bool _seeded = false;

  @override
  void dispose() {
    _name.dispose();
    _role.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _save(Bot bot, Map<String, dynamic> patch) => run(context, 'update-bot', {'id': bot.id, ...patch});

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final bot = team?.bot(widget.botId);
    if (team == null || bot == null) return ManagePage(title: '', children: const []);
    if (!_seeded) {
      _seeded = true;
      _name.text = bot.name;
      _role.text = bot.role ?? '';
      _instructions.text = bot.instructions ?? '';
    }
    final main = team.isMain(bot.id);
    final statuses = jMap(team.capabilityStatuses, bot.id) ?? const {};
    final library = [...team.capabilities]..sort((a, b) => (jStr(b, 'kind') == 'pack' ? 1 : 0) - (jStr(a, 'kind') == 'pack' ? 1 : 0) == 0 ? (jStr(a, 'name') ?? '').compareTo(jStr(b, 'name') ?? '') : (jStr(b, 'kind') == 'pack' ? 1 : -1));
    return ManagePage(
      title: t('Bot settings'),
      children: [
        const SizedBox(height: 8),
        Center(
          child: Pressable(
            onTap: () => showCharacterSheet(context, bot),
            child: Stack(clipBehavior: Clip.none, children: [
              BotAvatar(bot: bot, size: 76),
              Positioned(
                right: -4,
                bottom: -4,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle, border: Border.all(color: p.main, width: 2)),
                  child: Ico(AppIcon.edit, size: 14, color: p.accentInk),
                ),
              ),
            ]),
          ),
        ),
        Group(title: t('Profile'), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Field(controller: _name, label: t('Name'), onSubmitted: (value) => value.trim().isEmpty ? null : _save(bot, {'name': value.trim()})),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: Field(controller: _role, label: t('Label'), hint: t('Research, admin…'), onSubmitted: (value) => _save(bot, {'role': value.trim()})),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerRight,
              child: Btn(t('Save'), small: true, onTap: () {
                final patch = <String, dynamic>{
                  if (_name.text.trim().isNotEmpty && _name.text.trim() != bot.name) 'name': _name.text.trim(),
                  if (_role.text.trim() != (bot.role ?? '')) 'role': _role.text.trim(),
                };
                if (patch.isNotEmpty) _save(bot, patch);
                FocusScope.of(context).unfocus();
              }),
            ),
          ),
        ]),
        Group(title: t('Instructions'), children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Field(controller: _instructions, hint: t('What this Bot is responsible for…'), maxLines: 12, minLines: 4),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: Btn(t('Save'), small: true, onTap: () {
                  _save(bot, {'instructions': _instructions.text.trim()});
                  FocusScope.of(context).unfocus();
                }),
              ),
            ]),
          ),
        ]),
        Group(title: t('Look'), children: [
          Row2(title: t('Character and color'), leading: RowIcon(AppIcon.sparkle), onTap: () => showCharacterSheet(context, bot)),
          Row2(title: t('Upload photo'), leading: RowIcon(AppIcon.image), onTap: () async {
            final image = await pickPhotoDataUrl();
            if (image != null && context.mounted) await _save(bot, {'avatar': {...bot.avatar, 'image': image}..remove('imageRef')});
          }),
          Row2(title: t('Avatar library'), leading: RowIcon(AppIcon.layers), onTap: () => showAvatarLibrary(context, bot)),
          if (bot.image != null || bot.imageRef != null)
            Row2(title: t('Remove photo'), danger: true, onTap: () => _save(bot, {'avatar': {'shape': ?bot.shape}})),
        ]),
        Group(title: t('Model'), children: [Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: ModelButton(bot: bot))]),
        Group(children: [
          SwitchRow(
            title: t('Private'),
            subtitle: t('Other Bots cannot read its folder, memory or chats, and you approve what it shares with them.'),
            value: bot.isPrivate,
            onChanged: (value) => _save(bot, {'private': value}),
          ),
          if (!bot.isPrivate)
            SwitchRow(
              title: t('Main Bot'),
              subtitle: t('Can create and change Bots, and runs every group chat.'),
              value: main,
              onChanged: (value) => run(context, 'set-main', {'id': bot.id, 'main': value}),
            ),
          if (main && team.mainBotIds.first != bot.id)
            Row2(title: t('Make first Main Bot'), leading: RowIcon(AppIcon.star, color: Palette.star), onTap: () => run(context, 'set-main', {'id': bot.id, 'main': true, 'primary': true})),
        ]),
        if (team.sections.isNotEmpty && !(main && team.mainBotIds.first == bot.id))
          Group(children: [
            Row2(
              title: t('Section'),
              value: jStr(team.sections.where((section) => section['id'] == bot.sectionId).firstOrNull, 'name') ?? t('No section'),
              leading: RowIcon(AppIcon.section),
              onTap: () => moveToSection(context, bot.id, bot.sectionId),
            ),
          ]),
        if (library.isNotEmpty)
          Group(title: t('Capabilities'), children: [
            for (final item in library)
              SwitchRow(
                title: jStr(item, 'name') ?? '',
                subtitle: bot.capabilities.contains(jStr(item, 'name')) ? capabilityStatusText(statuses[jStr(item, 'name')]) : (jStr(item, 'kind') == 'pack' ? t('Pack') : null),
                value: bot.capabilities.contains(jStr(item, 'name')),
                onChanged: (value) => run(context, 'bot-capability', {'botId': bot.id, 'name': jStr(item, 'name'), 'attached': value}),
              ),
          ]),
        if (team.browserEnabled)
          Group(title: t('Browser'), children: [
            Row2(title: t('What it may do in the browser'), leading: RowIcon(AppIcon.globe), onTap: () => showBrowserGrants(context, bot)),
          ]),
        Group(children: [
          if (!bot.isPrivate)
            Row2(
              title: t('Duplicate'),
              subtitle: t('A copy with the same job and model, and fresh memory.'),
              leading: RowIcon(AppIcon.copy),
              onTap: () async {
                final value = await run(context, 'duplicate-bot', {'id': bot.id});
                final id = jStr(value, 'id');
                if (id != null && context.mounted) unawaited(openChat(context, botId: id, replace: true));
              },
            ),
          if (!main)
            Row2(
              title: t('Delete Bot'),
              danger: true,
              onTap: () async {
                final ok = await confirmDanger(context, title: t('Delete {name}?', {'name': bot.name}), action: t('Delete'));
                if (!ok || !context.mounted) return;
                final done = await run(context, 'delete-bot', {'id': bot.id});
                if (done != null && context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
              },
            ),
        ]),
      ],
    );
  }
}

String? capabilityStatusText(Object? status) {
  final state = jStr(status, 'state');
  return switch (state) {
    'ready' => t('Ready'),
    'connecting' => t('Connecting…'),
    'needs-approval' => t('Needs approval'),
    'error' => jStr(status, 'error') ?? t('Error'),
    _ => null,
  };
}

/// Pick one of the twenty characters and a color; changes show at once.
Future<void> showCharacterSheet(BuildContext context, Bot bot) {
  return showGlassSheet<void>(context, builder: (sheet) => _CharacterSheet(botId: bot.id));
}

class _CharacterSheet extends StatelessWidget {
  const _CharacterSheet({required this.botId});

  final String botId;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final bot = team?.bot(botId);
    if (bot == null) return const SizedBox.shrink();
    final data = SharedData.instance;
    final look = botLook(bot);
    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
      SheetTitle(t('Character')),
      Center(child: BotAvatar(bot: bot, size: 72)),
      const SizedBox(height: 16),
      GridView.count(
        crossAxisCount: 5,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        children: [
          for (final shape in data.characters.keys)
            Pressable(
              onTap: () => run(context, 'update-bot', {'id': bot.id, 'avatar': {'shape': shape}}),
              child: Container(
                decoration: BoxDecoration(
                  color: look.shape == shape && look.image == null ? p.accent.withValues(alpha: 0.14) : p.bubble.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(Radii.card),
                  border: Border.all(color: look.shape == shape && look.image == null ? p.accent : Colors.transparent, width: 1.5),
                ),
                padding: const EdgeInsets.all(8),
                child: CharacterMark(look: Look(shape: shape, color: look.color), size: 44),
              ),
            ),
        ],
      ),
      const SizedBox(height: 16),
      Text(t('Character color'), style: TypeScale.smallStrong.copyWith(color: p.ink2)),
      const SizedBox(height: 10),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final color in data.characterColors)
          Pressable(
            onTap: () => run(context, 'update-bot', {'id': bot.id, 'color': color}),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: data.gradients[color] == null
                    ? null
                    : LinearGradient(colors: [for (final stop in data.gradients[color]!) stop.color], stops: [for (final stop in data.gradients[color]!) stop.offset], begin: Alignment.topLeft, end: Alignment.bottomRight),
                color: data.gradients[color] == null ? data.ink(color, dark: p.dark) : null,
                border: Border.all(color: look.color == color ? p.ink : Colors.transparent, width: 2.5),
              ),
            ),
          ),
      ]),
    ]);
  }
}

/// Photos the user imported once and can reuse for any Bot.
Future<void> showAvatarLibrary(BuildContext context, Bot bot) {
  return showGlassSheet<void>(
    context,
    builder: (sheet) => Loader(
      endpoint: 'avatar-library',
      follow: false,
      builder: (context, value, reload) {
        final p = context.p;
        final entries = jMaps(value, 'items');
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
          SheetTitle(t('Avatar library'), trailing: IconBtn(AppIcon.plus, onTap: () async {
            final image = await pickPhotoDataUrl();
            if (image == null || !context.mounted) return;
            await run(context, 'avatar-import', {
              'items': [
                {'name': 'photo', 'image': image},
              ],
            });
            reload();
          })),
          if (entries.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Text(t('No photos yet. Add one with +.'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3)))
          else
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              children: [
                for (final entry in entries)
                  GestureDetector(
                    onTap: () {
                      run(context, 'update-bot', {'id': bot.id, 'avatar': {...bot.avatar, 'image': entry['image']}..remove('imageRef')});
                      Navigator.pop(context);
                    },
                    onLongPress: () async {
                      final ok = await confirmDanger(context, title: t('Delete this photo?'), action: t('Delete'));
                      if (ok && context.mounted) {
                        await run(context, 'avatar-delete', {'id': entry['id']});
                        reload();
                      }
                    },
                    child: CharacterMark(look: Look(shape: 'gumdrop', color: 'gray', image: jStr(entry, 'image')), size: 64),
                  ),
              ],
            ),
        ]);
      },
    ),
  );
}

/// What a Bot may do in its browser without asking: per site (or every site),
/// the kinds of action it may take.
Future<void> showBrowserGrants(BuildContext context, Bot bot) {
  return showGlassSheet<void>(context, builder: (sheet) => _BrowserGrants(botId: bot.id));
}

class _BrowserGrants extends StatefulWidget {
  const _BrowserGrants({required this.botId});

  final String botId;

  @override
  State<_BrowserGrants> createState() => _BrowserGrantsState();
}

class _BrowserGrantsState extends State<_BrowserGrants> {
  final _site = TextEditingController();
  final Set<String> _kinds = {'post'};

  static Map<String, String> get _kindLabels => {
        'post': t('Post and submit'),
        'upload': t('Upload files'),
        'download': t('Download files'),
        'delete': t('Delete things'),
        '*': t('Anything'),
      };

  @override
  void dispose() {
    _site.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final bot = TeamScope.of(context).team?.bot(widget.botId);
    final grants = jList(bot?.raw, 'browserGrants').whereType<Map>().map(asJson).toList();
    Future<void> save(List<Json> next) => run(context, 'update-bot', {'id': widget.botId, 'browserGrants': next});
    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
      SheetTitle(t('Browser')),
      if (grants.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(t('It asks you before it posts, uploads, downloads or deletes.'), style: TypeScale.small.copyWith(color: p.ink2))),
      for (final grant in grants)
        Row2(
          title: jStr(grant, 'site') == '*' ? t('Every site') : (jStr(grant, 'site') ?? ''),
          subtitle: jStrings(grant, 'kinds').map((kind) => _kindLabels[kind] ?? kind).join(' · '),
          trailing: IconBtn(AppIcon.trash, color: Palette.danger, onTap: () => save(grants.where((entry) => !identical(entry, grant)).toList())),
        ),
      const SizedBox(height: 12),
      Field(controller: _site, label: t('Site'), hint: 'example.com  /  *'),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final entry in _kindLabels.entries)
          FilterChip(
            label: Text(entry.value),
            selected: _kinds.contains(entry.key),
            onSelected: (on) => setState(() => on ? _kinds.add(entry.key) : _kinds.remove(entry.key)),
          ),
      ]),
      const SizedBox(height: 12),
      Btn(t('Add'), onTap: _site.text.trim().isEmpty && _kinds.isEmpty
          ? null
          : () {
              final site = _site.text.trim().isEmpty ? '*' : _site.text.trim().toLowerCase();
              if (_kinds.isEmpty) return;
              save([...grants, {'site': site, 'kinds': _kinds.toList()}]);
              _site.clear();
            }),
    ]);
  }
}

/// A new Bot: name, character, color and model in one sheet.
Future<void> showNewBot(BuildContext context) {
  return showGlassSheet<void>(context, builder: (sheet) => const _NewBotSheet());
}

class _NewBotSheet extends StatefulWidget {
  const _NewBotSheet();

  @override
  State<_NewBotSheet> createState() => _NewBotSheetState();
}

class _NewBotSheetState extends State<_NewBotSheet> {
  final _name = TextEditingController();
  late String _shape;
  late String _color;
  String? _model;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final data = SharedData.instance;
    final seed = DateTime.now().microsecondsSinceEpoch.toString();
    _shape = defaultShape(seed, data);
    _color = defaultColor(seed, data);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final value = await run(context, 'create-bot', {'name': name, 'color': _color, 'avatar': {'shape': _shape}, 'model': ?_model});
    if (!mounted) return;
    setState(() => _busy = false);
    final id = jStr(value, 'id');
    if (id == null) return;
    navigator.pop();
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => ChatPage(botId: id))));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final data = SharedData.instance;
    final team = TeamScope.of(context).team;
    final taken = team?.bots.any((bot) => bot.name.toLowerCase() == _name.text.trim().toLowerCase()) ?? false;
    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
      SheetTitle(t('Create new Bot')),
      Center(child: CharacterMark(look: Look(shape: _shape, color: _color), size: 72)),
      const SizedBox(height: 16),
      Field(controller: _name, label: t('Name'), hint: 'Bob', autofocus: true, onChanged: (_) => setState(() {}), onSubmitted: (_) => _create()),
      if (taken) Padding(padding: const EdgeInsets.only(top: 6, left: 4), child: Text(t('A Bot named {name} already exists', {'name': _name.text.trim()}), style: TypeScale.caption.copyWith(color: Palette.danger))),
      const SizedBox(height: 16),
      SizedBox(
        height: 64,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final shape in data.characters.keys)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Pressable(
                onTap: () => setState(() => _shape = shape),
                child: Container(
                  width: 60,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: shape == _shape ? p.accent.withValues(alpha: 0.14) : p.bubble.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(Radii.card),
                    border: Border.all(color: shape == _shape ? p.accent : Colors.transparent, width: 1.5),
                  ),
                  child: CharacterMark(look: Look(shape: shape, color: _color), size: 44),
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final color in data.characterColors)
          GestureDetector(
            onTap: () => setState(() => _color = color),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: data.gradients[color] == null ? data.ink(color, dark: p.dark) : null,
                gradient: data.gradients[color] == null ? null : LinearGradient(colors: [for (final stop in data.gradients[color]!) stop.color]),
                border: Border.all(color: color == _color ? p.ink : Colors.transparent, width: 2.5),
              ),
            ),
          ),
      ]),
      const SizedBox(height: 16),
      Group(margin: EdgeInsets.zero, children: [
        Row2(
          title: t('Model'),
          value: _model == null ? t('Default') : (team?.models.where((model) => model.ref == _model).firstOrNull?.name ?? _model),
          onTap: () async {
            final picked = await pickModel(context, current: _model);
            if (picked != null) setState(() => _model = picked.isEmpty ? null : picked);
          },
        ),
      ]),
      const SizedBox(height: 20),
      Btn(t('Create'), expand: true, busy: _busy, onTap: _name.text.trim().isEmpty || taken ? null : _create),
    ]);
  }
}
