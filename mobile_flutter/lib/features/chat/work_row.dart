// What a Bot is doing right now, at the foot of the message list: its avatar and
// a bubble with the step it is on, where its reply will land. The steps done
// earlier in the turn stay above, dimmed, so a long run reads as progress. No
// tool details show: a step is the call's own description, or what the tool's
// name says it does.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/json.dart';
import '../../data/team_state.dart';
import '../../ui/avatar.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Earlier steps the bubble lists; older ones fold into a count.
const _shownSteps = 3;

/// The leading column: the width of the three dots, so checks line up under them.
const _lead = 21.0;

/// How long a step stays up before the bubble goes back to thinking, so a call
/// that ends at once can still be read. A next call replaces it right away.
const _minStep = Duration(milliseconds: 1500);

class WorkRow extends StatefulWidget {
  const WorkRow({super.key, required this.bot, required this.doing, this.name, this.onStop});

  final Bot? bot;

  /// The computer's work entry for this Bot (`work.bots`, `work.rooms`), or
  /// just its activity word.
  final Object? doing;

  /// The member's name, in a group.
  final String? name;

  /// Stops this member's work, in a group (a Bot's own chat stops from the box).
  final VoidCallback? onStop;

  @override
  State<WorkRow> createState() => _WorkRowState();
}

class _WorkRowState extends State<WorkRow> with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));

  /// The steps done earlier in this turn, oldest first. Kept here: the computer
  /// sends only the step in hand.
  final List<String> _done = [];

  /// The work entry on screen: the newest one, except while a step that just
  /// ended is held for [_minStep].
  late Object? _shown = widget.doing;
  DateTime _shownAt = DateTime.now();
  Timer? _hold;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _beat.value = 0.5;
      _beat.stop();
    } else if (!_beat.isAnimating) {
      _beat.repeat();
    }
  }

  @override
  void didUpdateWidget(WorkRow old) {
    super.didUpdateWidget(old);
    final next = widget.doing;
    final since = _sinceOf(next);
    final before = _sinceOf(_shown);
    if (since != null && before != null && since != before) {
      _cancelHold();
      _done.clear();
      _shown = next;
      _shownAt = DateTime.now();
      return;
    }
    if (_thinking(next) && workStep(_shown) != null) {
      final left = _minStep - DateTime.now().difference(_shownAt);
      if (left > Duration.zero) {
        _hold ??= Timer(left, () {
          _hold = null;
          if (mounted) setState(() => _show(widget.doing));
        });
        return;
      }
    }
    _cancelHold();
    _show(next);
  }

  /// Puts [next] on screen; the step it replaces joins the steps done. A call
  /// that gains its description or path as it streams stays the same step.
  void _show(Object? next) {
    final call = _callOf(_shown);
    final sameCall = call != null && call == _callOf(next);
    final was = workStep(_shown);
    final step = workStep(next);
    if (!sameCall && (call != _callOf(next) || was != step)) {
      if (was != null && was != step && _done.lastOrNull != was) {
        _done.add(was);
        if (_done.length > 40) _done.removeAt(0);
      }
      _shownAt = DateTime.now();
    }
    _shown = next;
  }

  void _cancelHold() {
    _hold?.cancel();
    _hold = null;
  }

  @override
  void dispose() {
    _cancelHold();
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final phrase = workPhrase(_shown);
    final since = _sinceOf(widget.doing);
    final hidden = math.max(0, _done.length - _shownSteps);
    final current = Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(width: _lead, child: Center(child: _Pulse(beat: _beat, color: p.ink2))),
      const SizedBox(width: 8),
      Flexible(child: _Shimmer(beat: _beat, child: _Phrase(phrase))),
      if (widget.onStop != null) ...[
        const SizedBox(width: 10),
        Tooltip(
          message: t('Stop'),
          child: Pressable(
            onTap: widget.onStop,
            haptic: true,
            scale: 0.85,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(color: p.ink.withValues(alpha: 0.08), shape: BoxShape.circle),
              child: Center(child: Ico(AppIcon.stop, size: 12, color: p.ink2)),
            ),
          ),
        ),
      ],
    ]);
    final bubble = Container(
      padding: EdgeInsets.fromLTRB(12, 10, widget.onStop == null ? 14 : 8, 10),
      decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(Radii.bubble).copyWith(bottomLeft: const Radius.circular(6))),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 280),
        curve: SpringCurve.shape,
        alignment: Alignment.bottomLeft,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (hidden > 0) _Earlier(key: const ValueKey('earlier'), count: hidden),
          for (var i = hidden; i < _done.length; i++) _DoneStep(key: ValueKey(i), text: _done[i]),
          current,
        ]),
      ),
    );
    final row = Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      BotAvatar(bot: widget.bot, size: 28, working: true),
      const SizedBox(width: 8),
      Flexible(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (widget.name != null)
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 3),
              child: Text(widget.name!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.caption.copyWith(color: p.ink3, fontWeight: FontWeight.w600)),
            ),
          bubble,
        ]),
      ),
    ]);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: SpringCurve.shape,
      builder: (context, value, child) => Opacity(
        opacity: value.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, (1 - value) * 10), child: child),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 8, right: 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          row,
          if (since != null) Padding(padding: const EdgeInsets.only(top: 3, left: 42), child: WorkElapsed(since: since)),
        ]),
      ),
    );
  }
}

int? _sinceOf(Object? doing) => jInt(doing, 'since');

/// The call a work entry is about, when the computer names it.
String? _callOf(Object? doing) => jStr(doing, 'call');

/// Between calls: no tool runs and none is being written.
bool _thinking(Object? doing) {
  if (doing is String) return doing == 'thinking';
  final tool = jStr(doing, 'tool');
  return jBool(doing, 'switching') != true && (tool == null || tool.isEmpty);
}

/// The step in hand. A new one rises in as the last one rises out, into the
/// list of steps done above it.
class _Phrase extends StatelessWidget {
  const _Phrase(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
        transitionBuilder: (child, animation) {
          final incoming = child.key == ValueKey(text);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: Tween(begin: Offset(0, incoming ? 0.5 : -0.5), end: Offset.zero).animate(animation), child: child),
          );
        },
        child: Semantics(
          key: ValueKey(text),
          liveRegion: true,
          child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TypeScale.small.copyWith(color: p.ink)),
        ),
      ),
    );
  }
}

/// A light sweep across the text in hand, so the bubble reads as live.
class _Shimmer extends StatelessWidget {
  const _Shimmer({required this.beat, required this.child});

  final Animation<double> beat;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return AnimatedBuilder(
      animation: beat,
      builder: (context, child) {
        final at = beat.value * 1.6 - 0.3;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (rect) => LinearGradient(
            colors: [p.ink2, p.ink, p.ink2],
            stops: [(at - 0.25).clamp(0.0, 1.0), at.clamp(0.0, 1.0), (at + 0.25).clamp(0.0, 1.0)],
          ).createShader(rect),
          child: child,
        );
      },
      child: child,
    );
  }
}

/// A step done earlier in this turn.
class _DoneStep extends StatelessWidget {
  const _DoneStep({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return _FadeIn(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: _lead, child: Center(child: Ico(AppIcon.check, size: 13, color: p.ink3))),
          const SizedBox(width: 8),
          Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.caption.copyWith(color: p.ink3))),
        ]),
      ),
    );
  }
}

/// How many steps came before the ones listed.
class _Earlier extends StatelessWidget {
  const _Earlier({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return _FadeIn(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: _lead + 8),
          Text(t('{count} earlier', {'count': count}), style: TypeScale.caption.copyWith(color: p.ink3)),
        ]),
      ),
    );
  }
}

class _FadeIn extends StatelessWidget {
  const _FadeIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      builder: (context, value, child) => Opacity(opacity: value, child: child),
      child: child,
    );
  }
}

/// How long the Bot has been at it, counted on the computer's clock from when
/// the turn began.
class WorkElapsed extends StatefulWidget {
  const WorkElapsed({super.key, required this.since, this.style});

  final int since;
  final TextStyle? style;

  @override
  State<WorkElapsed> createState() => _WorkElapsedState();
}

class _WorkElapsedState extends State<WorkElapsed> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ms = math.max(1000, DateTime.now().millisecondsSinceEpoch - widget.since);
    return Text(t('Working for {time}', {'time': elapsedLabel(ms)}), style: widget.style ?? TypeScale.caption.copyWith(color: context.p.ink3));
  }
}

/// Three dots that rise in turn.
class _Pulse extends StatelessWidget {
  const _Pulse({required this.beat, required this.color});

  final Animation<double> beat;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: beat,
      builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          () {
            final phase = (beat.value - i * 0.14) % 1.0;
            final lift = phase < 0.36 ? math.sin(math.pi * phase / 0.36) : 0.0;
            return Transform.translate(
              offset: Offset(0, -2.5 * lift),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.35 + 0.65 * lift), shape: BoxShape.circle),
              ),
            );
          }(),
        ],
      ]),
    );
  }
}
