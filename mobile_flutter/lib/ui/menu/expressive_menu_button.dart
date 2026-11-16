import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'expressive_menu_anchor.dart';

/// An [ExpressiveMenuAnchor] with an icon-button entry (ported from the
/// LiquidGlassDropdownMenu of NexioSchedule's top bar "more" button): it has
/// its own menu controller and focus, and a tap opens and closes it.
///
/// For "more actions" in top bars and at the end of list rows (the caller
/// passes its existing `FaIcon(FontAwesomeIcons.ellipsisVertical, …)`). The
/// button is marked expanded / collapsed in semantics, and counts as
/// collapsed as soon as the close animation starts.
///
/// - The button and the menu are one piece of glass: on tap the panel grows
///   out of the button's 40 circle and covers the button (aligned at the
///   corner touching the circle), and the button's icon fades out with it;
///   on close it shrinks back into the button with one spring-back.
/// - Pressing shows no state layer and no ripple: the deformation is the
///   press feedback, and the pressed circle also shows past the panel's 22
///   corner radius. Hover and keyboard focus still highlight.
/// - On Android, opening gives one CONTEXT_CLICK haptic (Flutter's
///   heavyImpact is this level on Android).
class ExpressiveMenuButton extends StatefulWidget {
  const ExpressiveMenuButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.items,
    this.placement = ExpressiveMenuPlacement.end,
    this.enabled = true,
    this.takesFocus = true,
  });

  final String tooltip;
  final Widget icon;

  /// Menu content, usually a few [ExpressiveMenuItem]s.
  final List<Widget> items;
  final ExpressiveMenuPlacement placement;
  final bool enabled;

  /// Whether focus moves to the button when the menu opens (and comes back
  /// to the button on close). Buttons inside the body editor (the ⋮ on video
  /// cards) pass false: the button is in the editor's focus subtree, and as
  /// soon as focus moves there the editor thinks it has focus, attaches the
  /// input method and shows the keyboard.
  final bool takesFocus;

  @override
  State<ExpressiveMenuButton> createState() => _ExpressiveMenuButtonState();
}

class _ExpressiveMenuButtonState extends State<ExpressiveMenuButton> {
  static final ButtonStyle _noPressFeedback = ButtonStyle(
    overlayColor: WidgetStateProperty.resolveWith(
      (Set<WidgetState> states) =>
          states.contains(WidgetState.pressed) ? Colors.transparent : null,
    ),
    splashFactory: NoSplash.splashFactory,
  );

  final FocusNode _focus = FocusNode(debugLabel: 'ExpressiveMenuButton');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _toggle(ExpressiveMenuAnchorState menu) {
    if (!menu.isExpanded && defaultTargetPlatform == TargetPlatform.android) {
      HapticFeedback.heavyImpact();
    }
    menu.toggle();
  }

  @override
  Widget build(BuildContext context) {
    return ExpressiveMenuAnchor(
      childFocusNode: widget.takesFocus ? _focus : null,
      placement: widget.placement,
      iconTrigger: true,
      menuChildren: widget.items,
      builder:
          (BuildContext context, ExpressiveMenuAnchorState menu, Widget? _) =>
              // Merged into the button's own semantics node: the screen
              // reader reads "button, expanded" on one focus.
              MergeSemantics(
                child: Semantics(
                  expanded: menu.isExpanded,
                  child: IconButton(
                    focusNode: _focus,
                    tooltip: widget.tooltip,
                    onPressed: widget.enabled ? () => _toggle(menu) : null,
                    style: _noPressFeedback,
                    icon: widget.icon,
                  ),
                ),
              ),
    );
  }
}
