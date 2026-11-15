// Group chats: details, settings, a new group, sections, and the group's goal.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../data/json.dart';
import '../../data/team_state.dart';
import '../../ui/avatar.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../chat/chat_page.dart';
import 'bot_pages.dart';
import 'common.dart';
import 'memory_page.dart';
import 'work_pages.dart';

void openGroupDetails(BuildContext context, String roomId) => push(context, GroupDetailsPage(roomId: roomId));

class GroupDetailsPage extends StatelessWidget {
  const GroupDetailsPage({super.key, required this.roomId});

  final String roomId;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final room = team?.room(roomId);
    if (team == null || room == null) return ManagePage(title: '', children: const []);
    final members = room.members.map(team.bot).whereType<Bot>().toList();
    final working = {for (final entry in team.roomWork(room.id)) jStr(entry, 'botId')};
    final openTasks = jMap(room.raw, 'tasks')?.values.whereType<Map>().where((task) => const {'active', 'review', 'blocked'}.contains(task['status'])).length ?? 0;
    final todos = jMaps(room.raw, 'todos');
    return ManagePage(
      title: room.name,
      actions: [IconBtn(AppIcon.gear, onTap: () => push(context, GroupSettingsPage(roomId: room.id)))],
      children: [
        const SizedBox(height: 8),
        Center(child: RoomAvatar(room: room, team: team, size: 76)),
        const SizedBox(height: 10),
        Center(child: Text(room.name, style: TypeScale.sectionTitle.copyWith(color: p.ink))),
        Center(child: Text(t('{count} members', {'count': members.length}), style: TypeScale.small.copyWith(color: p.ink3))),
        if ((room.notice ?? '').isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Radii.dialog)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('Notice'), style: TypeScale.smallStrong.copyWith(color: p.accent)),
              const SizedBox(height: 4),
              Text(room.notice!, style: TypeScale.small.copyWith(color: p.ink)),
            ]),
          ),
        Group(title: t('Members'), children: [
          for (final bot in members)
            Row2(
              title: bot.name,
              subtitle: working.contains(bot.id) ? workPhrase(team.roomWork(room.id).firstWhere((entry) => entry['botId'] == bot.id)) : bot.role,
              leading: BotAvatar(bot: bot, size: 34, working: working.contains(bot.id), main: team.isMain(bot.id), ring: p.card),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (room.admin == bot.id) Tag(t('Admin')),
                if (working.contains(bot.id))
                  TextButton(onPressed: () => run(context, 'stop-member-work', {'roomId': room.id, 'botId': bot.id}), child: Text(t('Stop'), style: const TextStyle(color: Palette.danger))),
              ]),
              onTap: () => openBotDetails(context, bot.id),
            ),
        ]),
        Group(children: [
          Row2(title: t('Who answers'), value: room.mode == 'everyone' || room.admin == null ? t('Everyone') : t('Admin leads'), leading: RowIcon(AppIcon.people), onTap: () => push(context, GroupSettingsPage(roomId: room.id))),
          Row2(title: t('Task board'), value: openTasks > 0 ? '$openTasks' : null, leading: RowIcon(AppIcon.board), onTap: () => push(context, TaskBoardPage(roomId: room.id))),
          Row2(title: t('To-dos'), value: todos.isEmpty ? null : '${todos.where((todo) => todo['done'] != true).length}', leading: RowIcon(AppIcon.check), onTap: () => push(context, TaskBoardPage(roomId: room.id, todos: true))),
          Row2(title: room.goal == null ? t('Set a goal') : t('Group goal'), value: jStr(room.goal, 'title'), leading: RowIcon(AppIcon.target), onTap: () => showGoalDraft(context, room)),
          if (team.memoryEnabled) Row2(title: t('Memory'), leading: RowIcon(AppIcon.memory), onTap: () => push(context, MemoryPage(roomId: room.id))),
          Row2(
            title: t('Working folder'),
            value: room.workDir == null ? t('Team workspace') : room.workDir!.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).last,
            leading: RowIcon(AppIcon.folder),
            onTap: () async {
              final picked = await pickFolder(context, current: room.workDir);
              if (picked != null && context.mounted) await run(context, 'update-room', {'id': room.id, 'workDir': picked});
            },
          ),
        ]),
      ],
    );
  }
}

class GroupSettingsPage extends StatefulWidget {
  const GroupSettingsPage({super.key, required this.roomId});

  final String roomId;

  @override
  State<GroupSettingsPage> createState() => _GroupSettingsPageState();
}

class _GroupSettingsPageState extends State<GroupSettingsPage> {
  final _name = TextEditingController();
  final _notice = TextEditingController();
  bool _seeded = false;

  @override
  void dispose() {
    _name.dispose();
    _notice.dispose();
    super.dispose();
  }

  Future<Object?> _update(Room room, Map<String, dynamic> patch) => run(context, 'update-room', {'id': room.id, ...patch});

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final room = team?.room(widget.roomId);
    if (team == null || room == null) return ManagePage(title: '', children: const []);
    if (!_seeded) {
      _seeded = true;
      _name.text = room.named ? room.name : '';
      _notice.text = room.notice ?? '';
    }
    final mode = room.admin != null && room.members.contains(room.admin) ? (room.mode ?? 'admin') : 'everyone';
    return ManagePage(
      title: t('Group settings'),
      children: [
        Group(title: t('Name and notice'), children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Field(controller: _name, label: t('Name'), hint: t('Name it after the members')),
              const SizedBox(height: 12),
              Field(controller: _notice, label: t('Notice'), hint: t('Shared instructions every member reads before speaking…'), maxLines: 8, minLines: 3),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: Btn(t('Save'), small: true, onTap: () {
                  _update(room, {'name': _name.text.trim(), 'notice': _notice.text.trim()});
                  FocusScope.of(context).unfocus();
                }),
              ),
            ]),
          ),
        ]),
        Group(title: t('Who answers'), children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Segmented<String>(
              values: const ['admin', 'everyone'],
              labels: [t('Admin leads'), t('Everyone')],
              value: mode,
              onChanged: (value) => _update(room, {'mode': value}),
            ),
          ),
        ]),
        Group(title: t('Members'), footer: t('Tap to add or remove. Long-press a member to make it the admin.'), children: [
          for (final bot in team.bots)
            Row2(
              title: bot.name,
              leading: BotAvatar(bot: bot, size: 32, ring: p.card),
              onTap: () => room.members.contains(bot.id) ? _update(room, {'remove': [bot.id]}) : _update(room, {'add': [bot.id]}),
              onLongPress: room.members.contains(bot.id) ? () => _update(room, {'admin': room.admin == bot.id ? null : bot.id}) : null,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (room.admin == bot.id) Tag(t('Admin'), color: p.accent),
                const SizedBox(width: 8),
                Ico(room.members.contains(bot.id) ? AppIcon.check : AppIcon.plus, size: 18, color: room.members.contains(bot.id) ? p.accent : p.ink3),
              ]),
            ),
        ]),
        if (team.permissions.isNotEmpty || team.raw['permissions'] is Map)
          Group(title: t('Permissions'), children: [
            Padding(padding: const EdgeInsets.all(12), child: PermissionPicker(team: team, current: room.permission, onPick: (value) => _update(room, {'permission': value}))),
          ]),
        Group(children: [
          Row2(
            title: t('Working folder'),
            value: room.workDir == null ? t('Team workspace') : room.workDir!.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).last,
            leading: RowIcon(AppIcon.folder),
            onTap: () async {
              final picked = await pickFolder(context, current: room.workDir);
              if (picked != null && context.mounted) await _update(room, {'workDir': picked});
            },
          ),
          if (team.sections.isNotEmpty)
            Row2(
              title: t('Section'),
              value: jStr(team.sections.where((section) => section['id'] == room.sectionId).firstOrNull, 'name') ?? t('No section'),
              leading: RowIcon(AppIcon.section),
              onTap: () => moveToSection(context, room.id, room.sectionId),
            ),
        ]),
        Group(children: [
          Row2(
            title: t('Delete group'),
            danger: true,
            onTap: () async {
              final ok = await confirmDanger(context, title: t('Delete {name}?', {'name': room.name}), action: t('Delete'));
              if (!ok || !context.mounted) return;
              final done = await run(context, 'delete-room', {'id': room.id});
              if (done != null && context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
            },
          ),
        ]),
      ],
    );
  }
}

/// A new group: tick at least two Bots; the first picked leads until another is made admin.
Future<void> showNewGroup(BuildContext context) => showGlassSheet<void>(context, builder: (sheet) => const _NewGroupSheet());

class _NewGroupSheet extends StatefulWidget {
  const _NewGroupSheet();

  @override
  State<_NewGroupSheet> createState() => _NewGroupSheetState();
}

class _NewGroupSheetState extends State<_NewGroupSheet> {
  final List<String> _picked = [];
  String? _admin;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final bots = team?.bots ?? const <Bot>[];
    final lead = _admin != null && _picked.contains(_admin) ? _admin : _picked.firstOrNull;
    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 20), children: [
      SheetTitle(t('Create group chat')),
      Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 8), child: Text(t('Pick at least two Bots. The admin leads the group.'), style: TypeScale.small.copyWith(color: p.ink2))),
      for (final bot in bots)
        Row2(
          title: bot.name,
          subtitle: bot.role,
          leading: BotAvatar(bot: bot, size: 34),
          onTap: () => setState(() => _picked.contains(bot.id) ? _picked.remove(bot.id) : _picked.add(bot.id)),
          onLongPress: () => setState(() {
            if (!_picked.contains(bot.id)) _picked.add(bot.id);
            _admin = bot.id;
          }),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (lead == bot.id) Tag(t('Admin'), color: p.accent),
            const SizedBox(width: 8),
            Ico(_picked.contains(bot.id) ? AppIcon.check : AppIcon.plus, size: 18, color: _picked.contains(bot.id) ? p.accent : p.ink3),
          ]),
        ),
      const SizedBox(height: 16),
      Btn(t('Create'), expand: true, busy: _busy, onTap: _picked.length < 2
          ? null
          : () async {
              setState(() => _busy = true);
              final navigator = Navigator.of(context);
              final value = await run(context, 'create-room', {'members': _picked, 'admin': lead, 'greet': true});
              if (!mounted) return;
              setState(() => _busy = false);
              final id = jStr(value, 'id');
              if (id == null) return;
              navigator.pop();
              unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => ChatPage(roomId: id))));
            }),
    ]);
  }
}

const _sectionColors = ['blue', 'orange', 'green', 'violet', 'rose'];

/// A new section, or a renamed or recolored one (with Delete).
Future<void> editSection(BuildContext context, [Json? section]) {
  final name = TextEditingController(text: jStr(section, 'name') ?? '');
  var color = jStr(section, 'color');
  return showGlassSheet<void>(
    context,
    builder: (sheet) => StatefulBuilder(builder: (context, setState) {
      final p = context.p;
      return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
        SheetTitle(section == null ? t('New section') : t('Section')),
        Field(controller: name, label: t('Name'), autofocus: true),
        const SizedBox(height: 14),
        Wrap(spacing: 10, children: [
          for (final option in [null, ..._sectionColors])
            GestureDetector(
              onTap: () => setState(() => color = option),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: switch (option) {
                    'blue' => const Color(0xFF4F7DF3),
                    'orange' => const Color(0xFFF76B15),
                    'green' => const Color(0xFF30A46C),
                    'violet' => const Color(0xFF7D5AFF),
                    'rose' => const Color(0xFFE5484D),
                    _ => p.bubble,
                  },
                  border: Border.all(color: option == color ? p.ink : Colors.transparent, width: 2.5),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 18),
        Btn(t('Save'), expand: true, onTap: () async {
          await run(context, 'section-save', {if (section != null) 'id': section['id'], 'name': name.text.trim(), 'color': color ?? ''});
          if (context.mounted) Navigator.pop(context);
        }),
        if (section != null) ...[
          const SizedBox(height: 8),
          Btn(t('Delete section'), kind: BtnKind.danger, expand: true, onTap: () async {
            await run(context, 'section-delete', {'id': section['id']});
            if (context.mounted) Navigator.pop(context);
          }),
        ],
      ]);
    }),
  );
}

/// Puts a Bot or group into a section, or takes it out.
Future<void> moveToSection(BuildContext context, String id, String? current) {
  final sections = TeamScope.read(context).team?.sections ?? const [];
  return showGlassSheet<void>(
    context,
    builder: (sheet) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 20), children: [
      SheetTitle(t('Move to section')),
      ListTile(
        title: Text(t('No section')),
        trailing: current == null ? const Ico(AppIcon.check) : null,
        onTap: () {
          run(context, 'set-flags', {'id': id, 'sectionId': null});
          Navigator.pop(sheet);
        },
      ),
      for (final section in sections)
        ListTile(
          title: Text(jStr(section, 'name') ?? ''),
          trailing: section['id'] == current ? const Ico(AppIcon.check) : IconBtn(AppIcon.edit, size: 18, onTap: () => editSection(context, section)),
          onTap: () {
            run(context, 'set-flags', {'id': id, 'sectionId': section['id']});
            Navigator.pop(sheet);
          },
        ),
      ListTile(leading: const Ico(AppIcon.plus), title: Text(t('New section')), onTap: () => editSection(context)),
    ]),
  );
}

/// The group's goal: a one-line ask that the admin turns into stages, or the
/// running goal's controls.
Future<void> showGoalDraft(BuildContext context, Room room) {
  final text = TextEditingController();
  return showGlassSheet<void>(
    context,
    builder: (sheet) {
      final p = context.p;
      final goal = room.goal;
      final running = goal != null && const {'active', 'paused', 'drafting'}.contains(jStr(goal, 'status'));
      return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
        SheetTitle(t('Group goal')),
        if (running) ...[
          Text(jStr(goal, 'title') ?? '', style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
          const SizedBox(height: 4),
          Text(t('This group already has a goal. Stop it first.'), style: TypeScale.small.copyWith(color: p.ink2)),
          const SizedBox(height: 16),
          Btn(t('Stop goal'), kind: BtnKind.danger, expand: true, onTap: () async {
            await run(context, 'goal-control', {'roomId': room.id, 'goalId': goal['id'], 'action': 'stop'});
            if (sheet.mounted) Navigator.pop(sheet);
          }),
        ] else ...[
          Text(t('Write what this group should achieve. The admin turns it into stages and checks each one with you.'), style: TypeScale.small.copyWith(color: p.ink2)),
          const SizedBox(height: 12),
          Field(controller: text, hint: t('Ship the launch page by Friday…'), maxLines: 6, minLines: 3, autofocus: true),
          const SizedBox(height: 16),
          Btn(t('Set goal'), expand: true, onTap: () async {
            if (text.text.trim().isEmpty) return;
            final done = await run(context, 'goal-draft', {'roomId': room.id, 'text': text.text.trim()});
            if (done != null && sheet.mounted) Navigator.pop(sheet);
          }),
        ],
      ]);
    },
  );
}
