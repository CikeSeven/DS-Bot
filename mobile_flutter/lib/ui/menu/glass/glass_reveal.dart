import 'package:flutter/widgets.dart';

/// Glass reveal progress scope: makes the `BackdropGlass`es in the subtree
/// fade in / out together by [progress], in place of an `Opacity` /
/// `FadeTransition` wrapped around the whole block to fade it in.
///
/// Why it is needed: the glass's backdrop blur samples the page under the
/// surface, and inside an opacity layer it can only sample the layer itself
/// (empty), so a base without blur shows first during the fade-in and the
/// blur "pops" in at the end. With this scope there is no opacity layer:
/// the glass surface scales its own base color, border, hairlines, shadow
/// and blur strength by the progress, and puts its content in an `Opacity`
/// inside the glass to fade in with it (the content's opacity layer is
/// above the blur and does not affect blur sampling).
///
/// Usage constraints (callers must follow them):
/// - Use it in place of Opacity only when the body of the subtree **is a
///   glass surface**; classic (opaque) surfaces keep using Opacity. The
///   caller decides with `AppGlass.of(context).isGlass(component)`.
/// - Content in the subtree that is not inside any glass surface does not
///   fade and cuts hard when the progress changes. So the whole faded block
///   must be inside one glass (for example, the toolbar buttons are all
///   inside the toolbar glass).
/// - When nested, progress multiplies (outer 0.5 × inner 0.5 = 0.25), the
///   same as nested Opacity.
class GlassReveal extends StatelessWidget {
  const GlassReveal({super.key, required this.progress, required this.child});

  /// This level's reveal progress (0 fully transparent, 1 fully shown),
  /// multiplied by the ancestors' progress.
  final double progress;
  final Widget child;

  /// The accumulated reveal progress at this position; 1 when there is no
  /// ancestor scope. Makes the caller depend on the nearest scope, so it
  /// rebuilds when the progress changes.
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GlassRevealScope>()?.value ??
      1;

  /// Whether there is an ancestor scope (without creating a dependency).
  /// `BackdropGlass` uses it to decide whether to wrap its content in an
  /// Opacity: without a scope, the tree is exactly as it was before this
  /// widget was added.
  static bool hasScope(BuildContext context) =>
      context.getElementForInheritedWidgetOfExactType<_GlassRevealScope>() !=
      null;

  @override
  Widget build(BuildContext context) {
    final value = (GlassReveal.of(context) * progress).clamp(0.0, 1.0);
    return _GlassRevealScope(value: value, child: child);
  }
}

/// A [GlassReveal] driven by an animation: updates the progress from
/// [progress] every frame.
class GlassRevealTransition extends StatelessWidget {
  const GlassRevealTransition({
    super.key,
    required this.progress,
    required this.child,
  });

  final Animation<double> progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (BuildContext context, Widget? child) =>
          GlassReveal(progress: progress.value, child: child!),
    );
  }
}

class _GlassRevealScope extends InheritedWidget {
  const _GlassRevealScope({required this.value, required super.child});

  /// The accumulated progress, already multiplied by the ancestors'.
  final double value;

  @override
  bool updateShouldNotify(_GlassRevealScope oldWidget) =>
      value != oldWidget.value;
}
