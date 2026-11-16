// What a Bot is doing right now, at the foot of the message list: its avatar
// and a bubble with a pulse and a shimmering line, where its reply will land.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/team_state.dart';
import '../../ui/avatar.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class WorkRow extends StatefulWidget {
  const WorkRow({super.key, required this.bot, required this.text, this.name, this.onStop});

  final Bot? bot;
  final String text;

  /// The member's name, in a group.
  final String? name;

  /// Stops this member's work, in a group (a Bot's own chat stops from the box).
  final VoidCallback? onStop;

  @override
  State<WorkRow> createState() => _WorkRowState();
}

class _WorkRowState extends State<WorkRow> with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));

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
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final bubble = Container(
      padding: EdgeInsets.fromLTRB(12, 9, widget.onStop == null ? 14 : 8, 9),
      decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(Radii.bubble).copyWith(bottomLeft: const Radius.circular(6))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _Pulse(beat: _beat, color: p.ink2),
        const SizedBox(width: 10),
        Flexible(
          child: AnimatedBuilder(
            animation: _beat,
            builder: (context, child) {
              final at = _beat.value * 1.6 - 0.3;
              return ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (rect) => LinearGradient(
                  colors: [p.ink3, p.ink, p.ink3],
                  stops: [(at - 0.25).clamp(0.0, 1.0), at.clamp(0.0, 1.0), (at + 0.25).clamp(0.0, 1.0)],
                ).createShader(rect),
                child: child,
              );
            },
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
              child: Text(widget.text, key: ValueKey(widget.text), maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.small.copyWith(color: p.ink)),
            ),
          ),
        ),
        if (widget.onStop != null) ...[
          const SizedBox(width: 8),
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
      ]),
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
      child: Padding(padding: const EdgeInsets.only(top: 8, right: 40), child: row),
    );
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
