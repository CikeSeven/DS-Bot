import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../icons.dart';
import '../widgets.dart';
import 'expressive_menu.dart';
import 'expressive_menu_row.dart';

/// A glass pop-up menu of [MenuAction]s that grows out of the icon button
/// [builder] draws; the button calls the given toggle to open and close it.
class ActionMenu extends StatelessWidget {
  const ActionMenu({super.key, required this.actions, required this.builder, this.placement = ExpressiveMenuPlacement.end});

  final List<MenuAction> actions;
  final Widget Function(BuildContext context, VoidCallback toggle) builder;
  final ExpressiveMenuPlacement placement;

  @override
  Widget build(BuildContext context) {
    return ExpressiveMenuAnchor(
      iconTrigger: true,
      placement: placement,
      menuChildren: [
        for (final action in actions)
          ExpressiveMenuItem(
            onPressed: action.run,
            destructive: action.danger,
            // The line icons sit inside their box with a margin, so they fill the
            // whole icon box to match the menu's text.
            leadingIcon: Ico(action.icon, size: ExpressiveMenuRowMetrics.iconBox),
            child: Text(action.label),
          ),
      ],
      builder: (context, menu, _) => Semantics(
        expanded: menu.isExpanded,
        child: builder(context, () {
          if (!menu.isExpanded && defaultTargetPlatform == TargetPlatform.android) HapticFeedback.heavyImpact();
          menu.toggle();
        }),
      ),
    );
  }
}
