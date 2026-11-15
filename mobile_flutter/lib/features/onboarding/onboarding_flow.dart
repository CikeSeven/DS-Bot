// The onboarding scene: one aurora sky that keeps drifting while the welcome
// page gives way to pairing. The parallax follows the phone only while the
// welcome page shows.
import 'package:flutter/material.dart';

import '../../ui/motion.dart';
import 'aurora.dart';
import 'parallax.dart';
import 'welcome_page.dart';

class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key, required this.welcome, required this.onEnter, required this.pair});

  final bool welcome;
  final Future<void> Function() onEnter;
  final Widget pair;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> with TickerProviderStateMixin {
  late final _parallax = ParallaxController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(OnboardingFlow old) {
    super.didUpdateWidget(old);
    if (widget.welcome != old.welcome) _syncMotion();
  }

  void _syncMotion() {
    if (widget.welcome && !reduceMotion(context)) {
      _parallax.listenToMotion();
    } else {
      _parallax.stopMotion();
    }
  }

  @override
  void dispose() {
    _parallax.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AuroraBackdrop(
      intensity: widget.welcome ? 1 : 0.72,
      parallax: _parallax,
      // One group, so the frosted panes on either page share a backdrop read.
      child: BackdropGroup(
        child: Material(
          type: MaterialType.transparency,
          // A straight cut between the pages: the one that leaves has already
          // played its own exit, and the one that comes in reveals its parts
          // itself. A fade would put glass in a fading layer, and moving or
          // scaling the whole page makes every pane costlier to filter.
          child: AnimatedSwitcher(
            duration: Duration.zero,
            layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: widget.welcome
                ? WelcomePage(key: const ValueKey('welcome'), onEnter: widget.onEnter, parallax: _parallax)
                : KeyedSubtree(key: const ValueKey('pair'), child: widget.pair),
          ),
        ),
      ),
    );
  }
}
