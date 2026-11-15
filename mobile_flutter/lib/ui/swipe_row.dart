// A row that slides aside to show quick actions: swipe left for the trailing
// actions, right for the leading ones. A tap on an action runs it and closes.
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'icons.dart';
import 'theme.dart';

class SwipeAction {
  const SwipeAction({required this.icon, required this.label, required this.color, required this.run});

  final AppIcon icon;
  final String label;
  final Color color;
  final VoidCallback run;
}

class SwipeRow extends StatefulWidget {
  const SwipeRow({super.key, required this.child, this.leading = const [], this.trailing = const []});

  final Widget child;
  final List<SwipeAction> leading;
  final List<SwipeAction> trailing;

  @override
  State<SwipeRow> createState() => _SwipeRowState();
}

class _SwipeRowState extends State<SwipeRow> with SingleTickerProviderStateMixin {
  static const _actionWidth = 76.0;
  late final AnimationController _controller = AnimationController.unbounded(vsync: this);
  double _offset = 0;
  bool _crossed = false;

  double get _maxLeft => widget.trailing.length * _actionWidth;
  double get _maxRight => widget.leading.length * _actionWidth;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() => _offset = _controller.value));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _settle(double target, [double velocity = 0]) {
    _controller.value = _offset;
    _controller.animateWith(SpringSimulation(Springs.shape, _offset, target, velocity));
  }

  void close() => _settle(0);

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final showing = _offset < 0 ? widget.trailing : widget.leading;
    return GestureDetector(
      onHorizontalDragStart: (_) => _controller.stop(),
      onHorizontalDragUpdate: (details) {
        var next = _offset + details.delta.dx;
        if (next < -_maxLeft) next = -_maxLeft - (next + _maxLeft).abs() * 0.0 + (next + _maxLeft) * 0.25;
        if (next > _maxRight) next = _maxRight + (next - _maxRight) * 0.25;
        if (widget.trailing.isEmpty && next < 0) next = 0;
        if (widget.leading.isEmpty && next > 0) next = 0;
        final crossed = next.abs() > _actionWidth * 0.6;
        if (crossed != _crossed) {
          _crossed = crossed;
          if (crossed) HapticFeedback.selectionClick();
        }
        setState(() => _offset = next);
      },
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (_offset < 0) {
          _settle(_offset < -_actionWidth * 0.5 || velocity < -600 ? -_maxLeft : 0, velocity);
        } else {
          _settle(_offset > _actionWidth * 0.5 || velocity > 600 ? _maxRight : 0, velocity);
        }
      },
      child: Stack(children: [
        if (_offset != 0)
          Positioned.fill(
            child: Row(
              mainAxisAlignment: _offset < 0 ? MainAxisAlignment.end : MainAxisAlignment.start,
              children: [
                for (final action in showing)
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      close();
                      action.run();
                    },
                    child: Container(
                      width: _actionWidth,
                      color: action.color,
                      alignment: Alignment.center,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Ico(action.icon, size: 20, color: Colors.white),
                        const SizedBox(height: 4),
                        Text(action.label, style: TypeScale.caption.copyWith(color: Colors.white, fontWeight: FontWeight.w500)),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        Transform.translate(
          offset: Offset(_offset, 0),
          child: ColoredBox(color: p.main, child: widget.child),
        ),
      ]),
    );
  }
}
