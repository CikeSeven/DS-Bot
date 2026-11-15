// The Bot's own mascot, drawn from the same character table as the desktop mark,
// with the status badges from ui-standard 8.2: a green dot while working, an
// accent "?" while waiting for you, and the Main Bot star at 36% of the avatar.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/team_state.dart';
import '../shared/characters.dart';
import 'icons.dart';
import 'theme.dart';

final Map<String, Uint8List?> _photoBytes = {};

Uint8List? _decodePhoto(String? image) {
  if (image == null || !image.startsWith('data:')) return null;
  return _photoBytes.putIfAbsent(image, () {
    final comma = image.indexOf(',');
    if (comma == -1) return null;
    try {
      return base64Decode(image.substring(comma + 1));
    } on FormatException {
      return null;
    }
  });
}

class CharacterMark extends StatelessWidget {
  const CharacterMark({super.key, required this.look, this.size = 36});

  final Look look;
  final double size;

  @override
  Widget build(BuildContext context) {
    final photo = _decodePhoto(look.image);
    if (photo != null) {
      return ClipOval(child: Image.memory(photo, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true));
    }
    return RepaintBoundary(
      child: CustomPaint(size: Size.square(size), painter: CharacterPainter(look: look, dark: context.p.dark)),
    );
  }
}

Look botLook(Bot? bot) => lookOf(id: bot?.id, shape: bot?.shape, color: bot?.color, image: bot?.image);

class BotAvatar extends StatelessWidget {
  const BotAvatar({
    super.key,
    required this.bot,
    this.size = 44,
    this.working = false,
    this.waiting = false,
    this.main = false,
    this.ring,
  });

  final Bot? bot;
  final double size;
  final bool working;
  final bool waiting;
  final bool main;

  /// The color behind the avatar, used to ring badges so they read on any row.
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final ringColor = ring ?? p.main;
    final dot = (size * 0.27).roundToDouble();
    final star = (size * 0.36).roundToDouble();
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CharacterMark(look: botLook(bot), size: size),
          if (waiting)
            Positioned(
              right: -2,
              bottom: -2,
              child: _Ring(
                color: ringColor,
                size: dot + 4,
                child: Container(
                  width: dot,
                  height: dot,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                  child: Text('?', style: TextStyle(color: p.accentInk, fontSize: dot * 0.66, height: 1, fontWeight: FontWeight.w600)),
                ),
              ),
            )
          else if (working)
            Positioned(
              right: 0,
              bottom: 0,
              child: _Ring(color: ringColor, size: dot * 0.67 + 4, child: const _Pulse()),
            ),
          if (main && !waiting)
            Positioned(
              right: -2,
              top: -2,
              child: SizedBox.square(dimension: star, child: const _MainStar()),
            ),
        ],
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.color, required this.size, required this.child});

  final Color color;
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: child,
    );
  }
}

/// The working dot breathes gently; quiet when the system asks for less motion.
class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest.shortestSide - 4;
      return FadeTransition(
        opacity: Tween(begin: 0.55, end: 1.0).animate(_controller),
        child: Container(width: size, height: size, decoration: const BoxDecoration(color: Palette.green, shape: BoxShape.circle)),
      );
    });
  }
}

class _MainStar extends StatelessWidget {
  const _MainStar();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: context.p.main, shape: BoxShape.circle),
      child: const Padding(
        padding: EdgeInsets.all(1.5),
        child: DecoratedBox(
          decoration: BoxDecoration(color: Palette.star, shape: BoxShape.circle),
          child: Padding(padding: EdgeInsets.all(2), child: FittedBox(child: Ico(AppIcon.star, color: Colors.white))),
        ),
      ),
    );
  }
}

/// A group avatar seats up to four members' characters, like the desktop's
/// RoomAvatar; past four the last seat shows "+N".
class RoomAvatar extends StatelessWidget {
  const RoomAvatar({super.key, required this.room, required this.team, this.size = 44, this.ring, this.waiting = false, this.working = false});

  final Room room;
  final TeamState team;
  final double size;
  final Color? ring;
  final bool waiting;
  final bool working;

  static List<(double, double, double)> _seats(int count, double frame) {
    if (count == 1) return [(0, 0, frame)];
    if (count == 2) return [(0, 0, frame * 2 / 3), (frame / 3, frame / 3, frame * 2 / 3)];
    if (count == 3) {
      final size = frame * 5 / 9;
      final rest = frame - size;
      return [(rest / 2, 0, size), (0, rest, size), (rest, rest, size)];
    }
    final half = frame / 2;
    return [(0, 0, half), (half, 0, half), (0, half, half), (half, half, half)];
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final ringColor = ring ?? p.main;
    final members = room.members.map(team.bot).whereType<Bot>().toList();
    final seats = _seats(members.isEmpty ? 1 : (members.length > 4 ? 4 : members.length), size);
    final overflow = members.length > 4 ? members.length - 3 : 0;
    final gap = size / 14;
    final dot = (size * 0.27).roundToDouble();
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (members.isEmpty)
            Container(decoration: BoxDecoration(color: p.bubble, shape: BoxShape.circle), child: Center(child: Ico(AppIcon.people, size: size * 0.5, color: p.ink3))),
          for (final (index, (x, y, s)) in seats.indexed)
            if (index < members.length)
              Positioned(
                left: x - gap / 2,
                top: y - gap / 2,
                child: Container(
                  width: s + gap,
                  height: s + gap,
                  padding: EdgeInsets.all(gap / 2),
                  decoration: BoxDecoration(color: ringColor, shape: BoxShape.circle),
                  child: overflow > 0 && index == 3
                      ? Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: p.bubble, shape: BoxShape.circle),
                          child: Text('+$overflow', style: TextStyle(fontSize: (s * 0.36).clamp(8, 16), color: p.ink2)),
                        )
                      : CharacterMark(look: botLook(members[index]), size: s),
                ),
              ),
          if (waiting)
            Positioned(
              right: -2,
              bottom: -2,
              child: _Ring(
                color: ringColor,
                size: dot + 4,
                child: Container(
                  width: dot,
                  height: dot,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                  child: Text('?', style: TextStyle(color: p.accentInk, fontSize: dot * 0.66, height: 1, fontWeight: FontWeight.w600)),
                ),
              ),
            )
          else if (working)
            Positioned(right: 0, bottom: 0, child: _Ring(color: ringColor, size: dot * 0.67 + 4, child: const _Pulse())),
        ],
      ),
    );
  }
}
