// Pages about the work: earlier conversations, a group's task board and to-dos,
// usage, scheduled tasks, the folder picker, file changes and tool details.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../data/chat_session.dart';
import '../../data/json.dart';
import '../../ui/avatar.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../chat/chat_item_view.dart';
import 'common.dart';

Future<String?> localTimeZone() async {
  try {
    return (await FlutterTimezone.getLocalTimezone()).identifier;
  } on Object {
    return null;
  }
}

/// A Bot's earlier conversations: read one, or carry on in it.
class EarlierPage extends StatelessWidget {
  const EarlierPage({super.key, required this.botId});

  final String botId;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final bot = team?.bot(botId);
    if (bot == null) return ManagePage(title: '', children: const []);
    final parts = bot.parts;
    return ManagePage(
      title: t('Earlier conversations'),
      children: [
        if (parts.isEmpty) Padding(padding: const EdgeInsets.all(40), child: Text(t('No earlier conversations yet'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3))),
        Group(children: [
          for (final (i, part) in parts.indexed.toList().reversed)
            Row2(
              title: t('Conversation {number}', {'number': i + 1}),
              leading: RowIcon(AppIcon.history),
              onTap: () => push(context, _PartPage(botId: botId, currentSession: bot.chatSession, part: i, sessionId: part)),
            ),
        ]),
      ],
    );
  }
}

class _PartPage extends StatelessWidget {
  const _PartPage({required this.botId, required this.currentSession, required this.part, required this.sessionId});

  final String botId;
  final String currentSession;
  final int part;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final team = TeamScope.of(context).team;
    return ManagePage(
      title: t('Conversation {number}', {'number': part + 1}),
      actions: [
        TextButton(
          onPressed: () async {
            final done = await run(context, 'bot-open-part', {'botId': botId, 'sessionId': sessionId});
            if (done != null && context.mounted) unawaited(openChat(context, botId: botId, replace: true));
          },
          child: Text(t('Continue here')),
        ),
      ],
      children: [
        Loader(
          endpoint: 'earlier',
          payload: {
            'sessionId': currentSession,
            'cursor': {'part': part},
          },
          follow: false,
          builder: (context, value, _) {
            final items = jMaps(value, 'items');
            if (team == null) return const SizedBox.shrink();
            final width = MediaQuery.sizeOf(context).width - 24;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(children: [
                for (final (i, item) in items.indexed)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: ChatItemView(
                      row: ChatRow(item, 'p$i', null),
                      team: team,
                      sessionId: sessionId,
                      inRoom: false,
                      flat: false,
                      botMax: width * 0.93,
                      userMax: width * 0.86,
                      onLongPress: (_) {},
                    ),
                  ),
              ]),
            );
          },
        ),
      ],
    );
  }
}

/// A group's task board (what each member registered) and its shared to-dos.
class TaskBoardPage extends StatefulWidget {
  const TaskBoardPage({super.key, required this.roomId, this.todos = false});

  final String roomId;
  final bool todos;

  @override
  State<TaskBoardPage> createState() => _TaskBoardPageState();
}

class _TaskBoardPageState extends State<TaskBoardPage> {
  late bool _todos = widget.todos;
  bool _history = false;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final room = team?.room(widget.roomId);
    if (team == null || room == null) return ManagePage(title: '', children: const []);
    final tasks = (jMap(room.raw, 'tasks') ?? const {}).values.whereType<Map>().map(asJson).toList()
      ..sort((a, b) => (jInt(b, 'updatedAt') ?? 0).compareTo(jInt(a, 'updatedAt') ?? 0));
    final open = tasks.where((task) => const {'active', 'review', 'blocked'}.contains(task['status'])).toList();
    final done = tasks.where((task) => !open.contains(task)).toList();
    final todos = jMaps(room.raw, 'todos')..sort((a, b) => (a['done'] == true ? 1 : 0) - (b['done'] == true ? 1 : 0));
    return ManagePage(
      title: room.name,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Segmented<bool>(values: const [false, true], labels: [t('Task board'), t('To-dos')], value: _todos, onChanged: (value) => setState(() => _todos = value)),
        ),
        if (!_todos) ...[
          if (open.isEmpty)
            Padding(padding: const EdgeInsets.all(32), child: Text(t('No tasks running. Bots register their work here.'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3))),
          for (final task in open) _TaskCard(task: task, roomId: room.id),
          if (done.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextButton.icon(
                onPressed: () => setState(() => _history = !_history),
                icon: Ico(_history ? AppIcon.up : AppIcon.down, size: 16),
                label: Text(t('History · {count}', {'count': done.length})),
              ),
            ),
          if (_history) for (final task in done) _TaskCard(task: task, roomId: room.id),
        ] else ...[
          if (todos.isEmpty)
            Padding(padding: const EdgeInsets.all(32), child: Text(t('No to-dos. Bots add them with group_todo.'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3))),
          Group(children: [
            for (final todo in todos)
              Row2(
                title: jStr(todo, 'text') ?? '',
                leading: Checkbox(
                  value: todo['done'] == true,
                  onChanged: (value) => run(context, 'room-todo', {'roomId': room.id, 'id': todo['id'], 'done': value == true}),
                ),
                trailing: IconBtn(AppIcon.trash, size: 18, color: p.ink3, onTap: () => run(context, 'room-todo', {'roomId': room.id, 'id': todo['id'], 'action': 'remove'})),
              ),
          ]),
          if (todos.any((todo) => todo['done'] == true))
            Center(child: TextButton(onPressed: () => run(context, 'room-todo', {'roomId': room.id, 'action': 'clear'}), child: Text(t('Clear done')))),
        ],
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.roomId});

  final Json task;
  final String roomId;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final team = TeamScope.of(context).team;
    final bot = team?.bot(jStr(task, 'botId'));
    final status = jStr(task, 'status') ?? 'active';
    final (label, color) = switch (status) {
      'review' => (t('Waiting for review'), Palette.star),
      'blocked' => (t('Blocked'), Palette.danger),
      'done' => (t('Done'), Palette.green),
      'cancelled' => (t('Cancelled'), p.ink3),
      _ => (t('Working'), p.accent),
    };
    final running = const {'active', 'review', 'blocked'}.contains(status);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.dialog), border: Border.all(color: p.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          BotAvatar(bot: bot, size: 24, working: status == 'active'),
          const SizedBox(width: 8),
          Expanded(child: Text(bot?.name ?? '', style: TypeScale.smallStrong.copyWith(color: p.ink))),
          Tag(label, color: color, background: color.withValues(alpha: 0.12)),
        ]),
        const SizedBox(height: 8),
        Text(jStr(task, 'goal') ?? '', style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
        if ((jStr(task, 'progress') ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(jStr(task, 'progress')!, style: TypeScale.small.copyWith(color: p.ink2))),
        if ((jStr(task, 'result') ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(jStr(task, 'result')!, style: TypeScale.small.copyWith(color: p.ink))),
        if ((jStr(task, 'reason') ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(jStr(task, 'reason')!, style: TypeScale.small.copyWith(color: p.ink3))),
        if (jInt(task, 'startedAt') != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(timeLabel(jInt(task, 'startedAt')!), style: TypeScale.caption.copyWith(color: p.ink3))),
        if (running) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: Btn(t('Add a note'), kind: BtnKind.secondary, small: true, icon: AppIcon.edit, onTap: () => _note(context))),
            const SizedBox(width: 8),
            Expanded(child: Btn(t('Cancel task'), kind: BtnKind.danger, small: true, onTap: () async {
              final ok = await confirmDanger(context, title: t('Cancel this task?'), action: t('Cancel task'));
              if (ok && context.mounted) await run(context, 'task-cancel', {'roomId': roomId, 'id': task['id']});
            })),
          ]),
        ],
      ]),
    );
  }

  void _note(BuildContext context) {
    final text = TextEditingController();
    showGlassSheet<void>(
      context,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SheetTitle(t('Add a note')),
          Text(t('The note goes into the group as your message to the task owner.'), style: TypeScale.small.copyWith(color: context.p.ink2)),
          const SizedBox(height: 12),
          Field(controller: text, maxLines: 6, minLines: 3, autofocus: true),
          const SizedBox(height: 14),
          Btn(t('Send'), expand: true, onTap: () async {
            if (text.text.trim().isEmpty) return;
            final done = await run(context, 'task-note', {'roomId': roomId, 'id': task['id'], 'text': text.text.trim()});
            if (done != null && sheet.mounted) Navigator.pop(sheet);
          }),
        ]),
      ),
    );
  }
}

/// A Bot's usage: today, this week and this month, by model.
class UsagePage extends StatelessWidget {
  const UsagePage({super.key, required this.botId});

  final String botId;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final bot = TeamScope.of(context).team?.bot(botId);
    return ManagePage(
      title: bot == null ? t('Usage') : t("{name}'s usage", {'name': bot.name}),
      children: [
        FutureBuilder<String?>(
          future: localTimeZone(),
          builder: (context, zone) => !zone.hasData && zone.connectionState != ConnectionState.done
              ? const SizedBox.shrink()
              : Loader(
                  endpoint: 'usage-summary',
                  payload: {'botId': botId, 'timeZone': ?zone.data},
                  follow: false,
                  builder: (context, value, _) {
                    Widget period(String label, Json? totals) {
                      final input = (jNum(totals, 'input') ?? 0) + (jNum(totals, 'cacheRead') ?? 0) + (jNum(totals, 'cacheWrite') ?? 0);
                      final output = jNum(totals, 'output') ?? 0;
                      return Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.dialog), border: Border.all(color: p.line)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(label, style: TypeScale.caption.copyWith(color: p.ink3)),
                            const SizedBox(height: 4),
                            Text(formatTokens(input + output), style: TypeScale.sectionTitle.copyWith(color: p.ink)),
                            Text('↑${formatTokens(input)} ↓${formatTokens(output)}', style: TypeScale.caption.copyWith(color: p.ink2)),
                          ]),
                        ),
                      );
                    }

                    final models = jMaps(value, 'models');
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Row(children: [
                          period(t('Today'), jMap(value, 'day')),
                          const SizedBox(width: 8),
                          period(t('This week'), jMap(value, 'week')),
                          const SizedBox(width: 8),
                          period(t('This month'), jMap(value, 'month')),
                        ]),
                      ),
                      if (models.isNotEmpty)
                        Group(title: t('By model'), children: [
                          for (final model in models)
                            Row2(title: jStr(model, 'name') ?? jStr(model, 'key') ?? '', value: formatTokens((jNum(model, 'input') ?? 0) + (jNum(model, 'output') ?? 0))),
                        ]),
                    ]);
                  },
                ),
        ),
        Loader(
          endpoint: 'run-stats',
          payload: {'botId': botId},
          follow: false,
          builder: (context, value, _) {
            final stats = jMap(value, 'sessionStats');
            if (stats == null) return const SizedBox.shrink();
            return Group(title: t('This conversation'), children: [
              Row2(title: t('Turns'), value: '${jInt(stats, 'turns') ?? 0}'),
              Row2(title: t('Steps'), value: '${jInt(stats, 'steps') ?? 0}'),
            ]);
          },
        ),
      ],
    );
  }
}

/// A Bot's scheduled tasks, and a new one: once, daily, weekly or every N.
class SchedulesPage extends StatefulWidget {
  const SchedulesPage({super.key, required this.botId});

  final String botId;

  @override
  State<SchedulesPage> createState() => _SchedulesPageState();
}

class _SchedulesPageState extends State<SchedulesPage> {
  int _version = 0;

  String _when(Json task) {
    final kind = jStr(task, 'kind');
    final time = jStr(task, 'time') ?? '';
    return switch (kind) {
      'daily' => t('Every day {time}', {'time': time}),
      'weekly' => t('Every {days} {time}', {'days': jList(task, 'weekdays').whereType<num>().map((day) => weekdayShort(day.toInt())).join(I18n.zh ? '、' : ', '), 'time': time}),
      'every' => t('Every {minutes} minutes', {'minutes': ((jNum(task, 'everySeconds') ?? 0) / 60).round()}),
      _ => jInt(task, 'scheduledAt') == null ? '' : timeLabel(jInt(task, 'scheduledAt')!),
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final bot = TeamScope.of(context).team?.bot(widget.botId);
    return ManagePage(
      title: t('Scheduled tasks'),
      actions: [IconBtn(AppIcon.plus, onTap: () => _create(context, bot?.chatSession ?? ''))],
      children: [
        Loader(
          key: ValueKey(_version),
          endpoint: 'schedules',
          builder: (context, value, reload) {
            if (jBool(value, 'available') == false) {
              return Padding(padding: const EdgeInsets.all(32), child: Text(t('Switch on Automation tasks on the Plugins page in Settings.'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink2)));
            }
            final tasks = jMaps(value, 'tasks').where((task) => task['botId'] == widget.botId).toList();
            if (tasks.isEmpty) return Padding(padding: const EdgeInsets.all(32), child: Text(t('No scheduled tasks yet. Add one'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink3)));
            return Group(children: [
              for (final task in tasks)
                Row2(
                  title: jStr(task, 'title') ?? '',
                  subtitle: [_when(task), if (jStr(task, 'status') != 'active') jStr(task, 'status') ?? ''].where((part) => part.isNotEmpty).join(' · '),
                  leading: RowIcon(AppIcon.clock),
                  trailing: IconBtn(AppIcon.trash, size: 18, color: p.ink3, onTap: () async {
                    final ok = await confirmDanger(context, title: t('Delete task'), body: jStr(task, 'title'), action: t('Delete'));
                    if (!ok || !context.mounted) return;
                    await run(context, 'schedule-delete', {'sessionId': jStr(task, 'sessionId'), 'id': task['id']});
                    reload();
                  }),
                ),
            ]);
          },
        ),
      ],
    );
  }

  void _create(BuildContext context, String sessionId) {
    final title = TextEditingController();
    final prompt = TextEditingController();
    var kind = 'daily';
    var time = const TimeOfDay(hour: 9, minute: 0);
    var date = DateTime.now().add(const Duration(hours: 1));
    final weekdays = <int>{1};
    var minutes = 60;
    var busy = false;
    String two(int n) => n.toString().padLeft(2, '0');
    showGlassSheet<void>(
      context,
      builder: (sheet) => StatefulBuilder(builder: (context, setState) {
        final p = context.p;
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
          SheetTitle(t('New task')),
          Field(controller: title, label: t('Title'), hint: t('Morning standup')),
          const SizedBox(height: 10),
          Field(controller: prompt, label: t('What to do'), hint: t('Post the team status'), maxLines: 5, minLines: 2),
          const SizedBox(height: 14),
          Segmented<String>(
            values: const ['at', 'daily', 'weekly', 'every'],
            labels: [t('Once'), t('Every day'), t('Every week'), t('Repeat')],
            value: kind,
            onChanged: (value) => setState(() => kind = value),
          ),
          const SizedBox(height: 12),
          if (kind == 'at')
            Row2(
              title: t('When'),
              value: '${date.month}/${date.day} ${two(date.hour)}:${two(date.minute)}',
              onTap: () async {
                final day = await showDatePicker(context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)), initialDate: date);
                if (day == null || !context.mounted) return;
                final at = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(date));
                if (at == null) return;
                setState(() => date = DateTime(day.year, day.month, day.day, at.hour, at.minute));
              },
            ),
          if (kind == 'weekly')
            Wrap(spacing: 6, children: [
              for (var day = 1; day <= 7; day++)
                FilterChip(label: Text(weekdayShort(day)), selected: weekdays.contains(day), onSelected: (on) => setState(() => on ? weekdays.add(day) : weekdays.remove(day))),
            ]),
          if (kind == 'daily' || kind == 'weekly')
            Row2(
              title: t('Time'),
              value: '${two(time.hour)}:${two(time.minute)}',
              onTap: () async {
                final picked = await showTimePicker(context: context, initialTime: time);
                if (picked != null) setState(() => time = picked);
              },
            ),
          if (kind == 'every')
            Row(children: [
              Text(t('Every'), style: TypeScale.settingsRow.copyWith(color: p.ink)),
              Expanded(
                child: Slider(
                  value: minutes.toDouble(),
                  min: 15,
                  max: 24 * 60,
                  divisions: (24 * 60 - 15) ~/ 15,
                  label: minutes >= 60 ? '${(minutes / 60).toStringAsFixed(minutes % 60 == 0 ? 0 : 1)} h' : '$minutes min',
                  onChanged: (value) => setState(() => minutes = (value / 15).round() * 15),
                ),
              ),
              Text(minutes >= 60 ? '${(minutes / 60).toStringAsFixed(minutes % 60 == 0 ? 0 : 1)} h' : '$minutes min', style: TypeScale.small.copyWith(color: p.ink2)),
            ]),
          const SizedBox(height: 16),
          Btn(t('Create task'), expand: true, busy: busy, onTap: () async {
            if (title.text.trim().isEmpty || busy) return;
            setState(() => busy = true);
            final zone = await localTimeZone();
            final when = switch (kind) {
              'at' => {'kind': 'at', 'at': date.toUtc().toIso8601String()},
              'every' => {'kind': 'every', 'minutes': minutes},
              _ => {'kind': kind, 'time': '${two(time.hour)}:${two(time.minute)}', 'timeZone': ?zone, if (kind == 'weekly') 'weekdays': (weekdays.toList()..sort())},
            };
            if (!context.mounted) return;
            final done = await run(context, 'schedule-create', {'target': widget.botId, 'title': title.text.trim(), 'prompt': prompt.text.trim(), 'when': when});
            setState(() => busy = false);
            if (done != null && sheet.mounted) {
              Navigator.pop(sheet);
              if (mounted) this.setState(() => _version += 1);
            }
          }),
        ]);
      }),
    );
  }
}

/// Picks a folder on the computer: recent folders, then browse.
Future<String?> pickFolder(BuildContext context, {String? current}) {
  return showGlassSheet<String>(context, maxHeightFactor: 0.9, builder: (sheet) => _FolderSheet(current: current));
}

class _FolderSheet extends StatefulWidget {
  const _FolderSheet({this.current});

  final String? current;

  @override
  State<_FolderSheet> createState() => _FolderSheetState();
}

class _FolderSheetState extends State<_FolderSheet> {
  String? _path;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    if (_path == null) {
      return Loader(
        endpoint: 'folders',
        follow: false,
        builder: (context, value, _) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 20), children: [
          SheetTitle(t('Working folder')),
          ListTile(leading: const Ico(AppIcon.people), title: Text(t('Team workspace')), subtitle: Text(jStr(value, 'team') ?? ''), onTap: () => Navigator.pop(context, '')),
          for (final folder in jMaps(value, 'folders'))
            ListTile(
              leading: const Ico(AppIcon.folder),
              title: Text(jStr(folder, 'title') ?? ''),
              subtitle: Text(jStr(folder, 'path') ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: jStr(folder, 'path') == widget.current ? Ico(AppIcon.check, color: p.accent) : null,
              onTap: () => Navigator.pop(context, jStr(folder, 'path')),
            ),
          ListTile(leading: const Ico(AppIcon.search), title: Text(t('Browse…')), onTap: () => setState(() => _path = jStr(value, 'team') ?? '')),
        ]),
      );
    }
    return Loader(
      key: ValueKey(_path),
      endpoint: 'folder-list',
      payload: {'path': _path},
      follow: false,
      builder: (context, value, _) {
        final parent = jStr(value, 'parent');
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 20), children: [
          SheetTitle(jStr(value, 'path') ?? _path ?? '', trailing: TextButton(onPressed: () => Navigator.pop(context, jStr(value, 'path') ?? _path), child: Text(t('Use this folder')))),
          if (parent != null) ListTile(leading: const Ico(AppIcon.up), title: Text(t('Up one level')), onTap: () => setState(() => _path = parent)),
          for (final entry in jMaps(value, 'entries'))
            ListTile(leading: const Ico(AppIcon.folder), title: Text(jStr(entry, 'name') ?? ''), onTap: () => setState(() => _path = jStr(entry, 'path'))),
        ]);
      },
    );
  }
}

/// The files one turn changed, and each file's diff.
Future<void> openChanges(BuildContext context, String sessionId, int seq) async {
  final session = TeamScope.read(context);
  try {
    final available = await session.call('changes-check', {'sessionId': sessionId, 'seq': seq});
    if (!context.mounted) return;
    if (available != true) {
      toast(context, t('These changes are no longer available'));
      return;
    }
    await push(context, ChangesPage(sessionId: sessionId, seq: seq));
  } on Object catch (error) {
    if (context.mounted) toast(context, errorText(error), error: true);
  }
}

class ChangesPage extends StatelessWidget {
  const ChangesPage({super.key, required this.sessionId, required this.seq});

  final String sessionId;
  final int seq;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return ManagePage(
      title: t('File changes'),
      children: [
        Loader(
          endpoint: 'changes-summary',
          payload: {'sessionId': sessionId, 'seq': seq},
          follow: false,
          builder: (context, value, _) {
            final files = jMaps(value, 'files');
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Row(children: [
                  Text(t('{count} files', {'count': jInt(value, 'total') ?? files.length}), style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
                  const Spacer(),
                  Text('+${jInt(value, 'added') ?? 0}', style: TypeScale.smallStrong.copyWith(color: Palette.green)),
                  const SizedBox(width: 8),
                  Text('−${jInt(value, 'deleted') ?? 0}', style: TypeScale.smallStrong.copyWith(color: Palette.danger)),
                ]),
              ),
              Group(children: [
                for (final (index, file) in files.indexed)
                  Row2(
                    title: jStr(file, 'display') ?? jStr(file, 'path') ?? '',
                    subtitle: jBool(file, 'binary') == true ? t('Binary file') : '+${jInt(file, 'added') ?? 0}  −${jInt(file, 'deleted') ?? 0}',
                    leading: RowIcon(AppIcon.diff),
                    onTap: jBool(file, 'binary') == true ? null : () => push(context, _DiffPage(sessionId: sessionId, seq: seq, index: index, title: jStr(file, 'display') ?? jStr(file, 'path') ?? '')),
                  ),
              ]),
            ]);
          },
        ),
      ],
    );
  }
}

class _DiffPage extends StatelessWidget {
  const _DiffPage({required this.sessionId, required this.seq, required this.index, required this.title});

  final String sessionId;
  final int seq;
  final int index;
  final String title;

  String _text(Object? value) {
    if (value is String) return value;
    for (final key in const ['patch', 'diff', 'text', 'unified']) {
      final text = jStr(value, key);
      if (text != null) return text;
    }
    final hunks = jMaps(value, 'hunks');
    if (hunks.isNotEmpty) {
      return hunks.map((hunk) => [jStr(hunk, 'header') ?? '', ...jList(hunk, 'lines').map((line) => line is String ? line : '${jStr(line, 'kind') == 'add' ? '+' : jStr(line, 'kind') == 'del' ? '-' : ' '}${jStr(line, 'text') ?? ''}')].join('\n')).join('\n');
    }
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return ManagePage(
      title: title.split('/').last,
      children: [
        Loader(
          endpoint: 'changes-diff',
          payload: {'sessionId': sessionId, 'seq': seq, 'index': index},
          follow: false,
          builder: (context, value, _) {
            final lines = _text(value).split('\n');
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final line in lines)
                  Container(
                    color: line.startsWith('+') && !line.startsWith('+++')
                        ? Palette.green.withValues(alpha: 0.12)
                        : (line.startsWith('-') && !line.startsWith('---') ? Palette.danger.withValues(alpha: 0.12) : (line.startsWith('@@') ? p.accent.withValues(alpha: 0.08) : null)),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    child: Text(line.isEmpty ? ' ' : line, style: TypeScale.mono.copyWith(color: p.ink, fontSize: 12)),
                  ),
              ]),
            );
          },
        ),
      ],
    );
  }
}

/// One tool call's arguments and output (the computer's `step-detail`).
Future<void> showStepDetail(BuildContext context, String sessionId, Json item) {
  final p = context.p;
  final tool = jMap(item, 'tool');
  return showGlassSheet<void>(
    context,
    maxHeightFactor: 0.9,
    builder: (sheet) => Loader(
      endpoint: 'step-detail',
      payload: {'sessionId': sessionId, 'turn': item['turn'], 'seq': item['seq'], 'index': item['index']},
      follow: false,
      builder: (context, value, _) {
        String text(Object? part) => part is String ? part : const JsonEncoder.withIndent('  ').convert(part);
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 20), children: [
          SheetTitle(jStr(tool, 'label') ?? jStr(tool, 'name') ?? t('Tool details')),
          Text(t('Arguments'), style: TypeScale.smallStrong.copyWith(color: p.ink2)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(Radii.input)),
            child: SelectableText(text(value is Map ? value['arguments'] : ''), style: TypeScale.mono.copyWith(color: p.ink)),
          ),
          const SizedBox(height: 14),
          Text(t('Output'), style: TypeScale.smallStrong.copyWith(color: p.ink2)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(Radii.input)),
            child: SelectableText(text(value is Map ? value['output'] : ''), style: TypeScale.mono.copyWith(color: jBool(value, 'ok') == false ? Palette.danger : p.ink)),
          ),
          if (jBool(value, 'truncated') == true) Padding(padding: const EdgeInsets.only(top: 8), child: Text(t('Cut short; the whole output is on the computer.'), style: TypeScale.caption.copyWith(color: p.ink3))),
        ]);
      },
    ),
  );
}
