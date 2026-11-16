// A Bot's team actions in its chat, as the desktop draws them (cells.js
// renderCall): who it messaged or stopped, the Bots and groups it made or
// changed, a group chat it read, a memory change, and its computer steps.
// Each line opens what it names.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../data/json.dart';
import '../../data/team_state.dart';
import '../../ui/avatar.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/motion.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../manage/bot_pages.dart';
import '../manage/memory_page.dart';
import 'exchange_page.dart';
import 'media.dart';

class ActRow extends StatelessWidget {
  const ActRow({super.key, required this.item, required this.team, required this.sessionId, required this.maxWidth});

  final Json item;
  final TeamState team;
  final String sessionId;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final line = switch (jStr(item, 'act')) {
      'message' || 'stop' => _toBot(context),
      'create-bot' || 'update-bot' => _madeBot(context),
      'group' || 'read-group' => _group(context),
      'memory' => _memory(context),
      'computer-run' => ComputerRun(steps: jMaps(item, 'steps'), team: team, sessionId: sessionId, maxWidth: maxWidth),
      _ => null,
    };
    if (line == null) return const SizedBox.shrink();
    return Arrive(arrivalKey: '$sessionId:${item['seq'] ?? item['time']}:${jStr(item, 'act')}', time: jInt(item, 'time'), child: line);
  }

  Widget? _toBot(BuildContext context) {
    final message = jStr(item, 'act') == 'message';
    final named = jMap(item, 'bot');
    final name = jStr(named, 'name') ?? t('a Bot');
    if (jStr(item, 'state') == 'failed') {
      return EventLine(icon: AppIcon.alert, danger: true, prefix: message ? t("Couldn't message {name}", {'name': name}) : t("Couldn't stop {name}", {'name': name}));
    }
    final bot = team.bot(jStr(named, 'id'));
    final from = jStr(item, 'from');
    return EventLine(
      prefix: message ? t('Messaged') : t('Stopped'),
      lead: BotAvatar(bot: bot, size: 18),
      name: bot?.name ?? name,
      onTap: bot == null || from == null ? null : () => push(context, ExchangePage(a: from, b: bot.id)),
    );
  }

  Widget? _madeBot(BuildContext context) {
    final named = jMap(item, 'bot');
    final bot = team.bot(jStr(named, 'id'));
    final self = jBool(item, 'self') == true;
    return EventLine(
      prefix: jStr(item, 'act') == 'create-bot' ? t('Created') : t('Updated'),
      lead: BotAvatar(bot: bot, size: 18),
      name: bot?.name ?? jStr(named, 'name') ?? '',
      // A Bot that changed itself shows what changed; another opens its chat.
      onTap: bot == null ? null : () => self ? openBotDetails(context, bot.id) : openChat(context, botId: bot.id, replace: true),
    );
  }

  Widget? _group(BuildContext context) {
    final verb = jStr(item, 'verb');
    if (jStr(item, 'state') == 'failed') {
      final text = switch (verb) {
        'created' => t("Couldn't create the group"),
        'updated' => t("Couldn't update the group"),
        'deleted' => t("Couldn't delete the group"),
        _ => t("Couldn't post in the group"),
      };
      return EventLine(icon: AppIcon.alert, danger: true, prefix: text);
    }
    final prefix = switch (verb) {
      'created' => t('Created group'),
      'updated' => t('Updated group'),
      'deleted' => t('Deleted group'),
      'posted' => t('Posted in'),
      _ => t('Read'),
    };
    final named = jMap(item, 'room');
    final room = team.room(jStr(named, 'id'));
    return EventLine(
      prefix: prefix,
      lead: room == null ? null : RoomAvatar(room: room, team: team, size: 18),
      name: room?.name ?? jStr(named, 'name') ?? '',
      onTap: room == null ? null : () => openChat(context, roomId: room.id, replace: true),
    );
  }

  Widget? _memory(BuildContext context) {
    final open = jMap(item, 'open');
    final botId = jStr(open, 'botId');
    final roomId = jStr(open, 'roomId');
    final canOpen = team.memoryEnabled && ((botId != null && team.bot(botId) != null) || (roomId != null && team.room(roomId) != null));
    final onTap = !canOpen ? null : () => push(context, MemoryPage(botId: roomId == null ? botId : null, roomId: roomId));
    switch (jStr(item, 'outcome')) {
      case 'saved':
        final label = switch (jStr(item, 'whose')) {
          'team' => t('Team memory updated'),
          'bot' => t("Updated {name}'s memory", {'name': team.bot(jStr(jMap(item, 'bot'), 'id'))?.name ?? jStr(jMap(item, 'bot'), 'name') ?? ''}),
          _ => t('Memory updated'),
        };
        return EventLine(icon: AppIcon.memory, accentIcon: true, prefix: label, onTap: onTap);
      case 'already':
        return EventLine(icon: AppIcon.memory, prefix: t('Already saved'), onTap: onTap);
      default:
        final failed = jStr(item, 'outcome') == 'failed';
        final label = failed ? (jStr(item, 'tool') == 'forget' ? t("Couldn't remove from memory") : t("Couldn't save to memory")) : t('Memory not changed');
        final reason = _memoryReason(jStr(item, 'code'));
        return EventLine(icon: AppIcon.memory, danger: true, prefix: reason == null ? label : '$label · $reason', onTap: onTap);
    }
  }
}

// Keep in step with cells.js memoryFailure.
String? _memoryReason(String? code) => switch (code) {
      null || '' => null,
      'memory/empty' => t('Write something to save'),
      'memory/no-match' => t('No saved entry matched'),
      'memory/refused' || 'memory/denied' => t('The memory refused this change'),
      _ => t('The memory could not be changed'),
    };

/// A centered line in the chat: what happened, and the Bot or group it names,
/// which opens on a tap.
class EventLine extends StatelessWidget {
  const EventLine({super.key, required this.prefix, this.icon, this.accentIcon = false, this.lead, this.name, this.onTap, this.danger = false});

  final String prefix;
  final AppIcon? icon;
  final bool accentIcon;
  final Widget? lead;
  final String? name;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final tone = danger ? Palette.danger : p.ink3;
    final hasName = name != null && name!.isNotEmpty;
    final pill = Container(
      constraints: const BoxConstraints(minHeight: 28),
      padding: EdgeInsets.fromLTRB(icon != null ? 9 : 12, 4, onTap != null ? 8 : 12, 4),
      decoration: BoxDecoration(
        color: danger ? Color.alphaBlend(Palette.danger.withValues(alpha: p.dark ? 0.14 : 0.06), p.main) : p.bubble.withValues(alpha: p.dark ? 0.62 : 0.56),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: danger ? Palette.danger.withValues(alpha: 0.2) : p.line, width: 0.6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Ico(icon!, size: 14, color: danger ? Palette.danger : (accentIcon ? p.accent : p.ink2)), const SizedBox(width: 6)],
        Flexible(
          flex: hasName ? 0 : 1,
          child: Text(prefix, maxLines: hasName ? 1 : 2, overflow: TextOverflow.ellipsis, style: TypeScale.caption.copyWith(color: tone)),
        ),
        if (hasName) ...[
          const SizedBox(width: 6),
          if (lead != null) ...[lead!, const SizedBox(width: 5)],
          Flexible(child: Text(name!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.caption.copyWith(color: p.ink2, fontWeight: FontWeight.w600))),
        ],
        if (onTap != null) ...[const SizedBox(width: 3), Ico(AppIcon.forward, size: 12, color: p.ink3)],
      ]),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 16),
      child: Center(
        child: onTap == null
            ? Semantics(label: hasName ? '$prefix $name' : prefix, child: ExcludeSemantics(child: pill))
            : Semantics(button: true, label: hasName ? '$prefix $name' : prefix, child: ExcludeSemantics(child: Pressable(onTap: onTap, haptic: true, scale: 0.95, child: pill))),
      ),
    );
  }
}

/// A row that came in while the chat was open rises in; one that was there
/// when the chat opened, or that scrolls back into view, just shows.
class Arrive extends StatefulWidget {
  const Arrive({super.key, required this.arrivalKey, required this.time, required this.child});

  final String arrivalKey;
  final int? time;
  final Widget child;

  static final Set<String> _seen = {};
  static const _freshFor = Duration(seconds: 20);

  @override
  State<Arrive> createState() => _ArriveState();
}

class _ArriveState extends State<Arrive> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  @override
  void initState() {
    super.initState();
    final time = widget.time;
    final fresh = Arrive._seen.add(widget.arrivalKey) &&
        time != null &&
        DateTime.now().millisecondsSinceEpoch - time < Arrive._freshFor.inMilliseconds;
    if (fresh) {
      _in.forward();
    } else {
      _in.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) _in.value = 1;
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  // Always the same layers, so the child keeps its state once the entrance ends.
  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _in.drive(CurveTween(curve: const Interval(0, 0.55, curve: Curves.easeOut))),
      child: ScaleTransition(scale: _in.drive(Tween(begin: 0.9, end: 1.0).chain(CurveTween(curve: SpringCurve.tap))), child: widget.child),
    );
  }
}

// The words for a computer step's method, as computer.js ACTION_NAMES has them,
// spelled so no word clashes with the desktop dictionary's other senses.
const _actionNames = {
  'click': 'Click',
  'doubleClick': 'Double click',
  'rightClick': 'Right click',
  'drag': 'Drag',
  'typeText': 'Type text',
  'pressKey': 'Press key',
  'hotkey': 'Hotkey',
  'scroll': 'Scroll',
  'screenshot': 'Screenshot',
  'getScreenSize': 'Screen size',
  'getCapabilities': 'Check capabilities',
  'listApps': 'List apps',
  'listWindows': 'List windows',
  'getState': 'Read state',
  'getAccessibilityTree': 'Read the screen',
  'launchApp': 'Launch app',
  'killApp': 'Quit app',
  'bringToFront': 'Bring to front',
  'invokeMenu': 'Open menu',
  'setValue': 'Set value',
  'getWindowState': 'Window state',
  'verifyState': 'Verify state',
  'getApp': 'Open app',
};

String actionName(String? method) {
  final known = _actionNames[method];
  if (known != null) return t(known);
  final words = (method ?? '').replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]!.toLowerCase()}').replaceAll('_', ' ').trim();
  return words.isEmpty ? t('Computer') : words[0].toUpperCase() + words.substring(1);
}

/// A run of computer steps: the app, the latest steps (all of them on a tap)
/// and a strip of the screenshots, each opening full screen.
class ComputerRun extends StatefulWidget {
  const ComputerRun({super.key, required this.steps, required this.team, required this.sessionId, required this.maxWidth});

  final List<Json> steps;
  final TeamState team;
  final String sessionId;
  final double maxWidth;

  @override
  State<ComputerRun> createState() => _ComputerRunState();
}

class _ComputerRunState extends State<ComputerRun> {
  static const _shownSteps = 3;
  bool _open = false;

  void _toggle() {
    HapticFeedback.selectionClick();
    setState(() => _open = !_open);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final steps = widget.steps;
    final last = steps.isEmpty ? null : steps.last;
    final bot = widget.team.botOfSession(widget.sessionId);
    final live = last != null && jStr(last, 'state') == 'running' && (bot == null || widget.team.botWorking(bot.id));
    final app = steps.reversed.map((step) => jStr(step, 'app')).firstWhere((name) => name != null && name.isNotEmpty, orElse: () => null);
    final shots = [
      for (final step in steps)
        if (jStr(jMap(step, 'shot'), 'attachmentId') case final id?) <String, Object?>{'attachmentId': id, 'mime': ?jStr(jMap(step, 'shot'), 'mime')},
    ];
    final hidden = steps.length > _shownSteps && !_open ? steps.length - _shownSteps : 0;
    final shown = steps.sublist(hidden);
    final title = live ? t('Using the computer') : t('Used the computer');
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth.clamp(220.0, 420.0)),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(Radii.bubble),
            border: Border.all(color: p.line, width: 0.7),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: AnimatedSize(
            duration: const Duration(milliseconds: 420),
            curve: SpringCurve.shape,
            alignment: Alignment.topCenter,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Semantics(
                button: steps.length > _shownSteps,
                label: '$title${app != null ? ' · $app' : ''}',
                child: InkWell(
                  onTap: steps.length > _shownSteps ? _toggle : null,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
                    child: Row(children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(color: p.accent.withValues(alpha: p.dark ? 0.16 : 0.1), borderRadius: BorderRadius.circular(8)),
                        child: Center(child: Ico(AppIcon.monitor, size: 15, color: p.accent)),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(text: title, style: TypeScale.smallStrong.copyWith(color: p.ink)),
                            if (app != null) TextSpan(text: ' · $app', style: TypeScale.small.copyWith(color: p.ink2)),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(t('{count} steps', {'count': steps.length}), style: TypeScale.caption.copyWith(color: p.ink3)),
                      if (steps.length > _shownSteps) ...[
                        const SizedBox(width: 2),
                        AnimatedRotation(
                          turns: _open ? 0.5 : 0,
                          duration: const Duration(milliseconds: 290),
                          curve: SpringCurve.tap,
                          child: Ico(AppIcon.down, size: 14, color: p.ink3),
                        ),
                      ],
                    ]),
                  ),
                ),
              ),
              if (hidden > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(47, 0, 12, 4),
                  child: Text(t('{count} earlier steps', {'count': hidden}), style: TypeScale.caption.copyWith(color: p.ink3)),
                ),
              for (final (index, step) in shown.indexed)
                _StepLine(
                  key: ValueKey(step['seq'] ?? step['callId'] ?? index),
                  step: step,
                  app: app,
                  live: live && identical(step, last),
                ),
              if (shots.isNotEmpty) _ShotStrip(shots: shots, sessionId: widget.sessionId) else const SizedBox(height: 6),
            ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepLine extends StatefulWidget {
  const _StepLine({super.key, required this.step, required this.app, required this.live});

  final Json step;
  final String? app;
  final bool live;

  @override
  State<_StepLine> createState() => _StepLineState();
}

class _StepLineState extends State<_StepLine> with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _StepLine old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.live && !reduceMotion(context)) {
      if (!_beat.isAnimating) _beat.repeat();
    } else {
      _beat.stop();
    }
  }

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final step = widget.step;
    final failed = jStr(step, 'state') == 'failed';
    final app = jStr(step, 'app');
    final action = actionName(jStr(step, 'method'));
    final label = app != null && app != widget.app ? '$app · $action' : action;
    final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.small.copyWith(color: failed ? Palette.danger : p.ink2));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 3, 12, 3),
      child: Row(children: [
        SizedBox(
          width: 26,
          child: Center(
            child: failed
                ? Ico(AppIcon.alert, size: 13, color: Palette.danger)
                : widget.live
                    ? _LiveDot(beat: _beat)
                    : Ico(AppIcon.check, size: 13, color: p.ink3),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: widget.live
              ? AnimatedBuilder(
                  animation: _beat,
                  child: text,
                  builder: (context, child) {
                    final at = _beat.value * 1.6 - 0.3;
                    return ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (rect) => LinearGradient(
                        colors: [p.ink2, p.ink, p.ink2],
                        stops: [(at - 0.25).clamp(0.0, 1.0), at.clamp(0.0, 1.0), (at + 0.25).clamp(0.0, 1.0)],
                      ).createShader(rect),
                      child: child,
                    );
                  },
                )
              : text,
        ),
      ]),
    );
  }
}

class _LiveDot extends StatelessWidget {
  const _LiveDot({required this.beat});

  final Animation<double> beat;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return FadeTransition(
      opacity: beat.drive(TweenSequence([
        TweenSequenceItem(tween: Tween(begin: 0.45, end: 1.0), weight: 1),
        TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.45), weight: 1),
      ])),
      child: Container(width: 7, height: 7, decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle)),
    );
  }
}

/// The run's screenshots, newest last, scrolled to the end.
class _ShotStrip extends StatefulWidget {
  const _ShotStrip({required this.shots, required this.sessionId});

  final List<Json> shots;
  final String sessionId;

  @override
  State<_ShotStrip> createState() => _ShotStripState();
}

class _ShotStripState extends State<_ShotStrip> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _ShotStrip old) {
    super.didUpdateWidget(old);
    if (widget.shots.length > old.shots.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final end = _scroll.position.maxScrollExtent;
        if (reduceMotion(context)) {
          _scroll.jumpTo(end);
        } else {
          _scroll.animateTo(end, duration: const Duration(milliseconds: 420), curve: SpringCurve.shape);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shots = widget.shots;
    return SizedBox(
      height: 84,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        itemCount: shots.length,
        separatorBuilder: (context, index) => const SizedBox(width: 6),
        itemBuilder: (context, index) => Semantics(
          button: true,
          label: t('Screenshot'),
          child: Pressable(
            scale: 0.94,
            onTap: () => showPhotos(context, widget.sessionId, shots, index),
            child: _ShotThumb(sessionId: widget.sessionId, attachmentId: jStr(shots[index], 'attachmentId') ?? ''),
          ),
        ),
      ),
    );
  }
}

class _ShotThumb extends StatefulWidget {
  const _ShotThumb({required this.sessionId, required this.attachmentId});

  final String sessionId;
  final String attachmentId;

  @override
  State<_ShotThumb> createState() => _ShotThumbState();
}

class _ShotThumbState extends State<_ShotThumb> {
  Future<Uint8List>? _image;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _image ??= loadImage(TeamScope.read(context), widget.sessionId, widget.attachmentId);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.input),
      child: Container(
        width: 104,
        decoration: BoxDecoration(color: p.bubble, border: Border.all(color: p.line, width: 0.6), borderRadius: BorderRadius.circular(Radii.input)),
        child: FutureBuilder<Uint8List>(
          future: _image,
          builder: (context, snapshot) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: snapshot.hasData
                ? Image.memory(snapshot.data!, key: const ValueKey('shot'), fit: BoxFit.cover, width: 104, height: 66, gaplessPlayback: true)
                : Center(
                    key: const ValueKey('wait'),
                    child: snapshot.hasError
                        ? Ico(AppIcon.image, size: 18, color: p.ink3)
                        : SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.ink3)),
                  ),
          ),
        ),
      ),
    );
  }
}
