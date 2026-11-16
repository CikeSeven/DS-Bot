import 'package:flutter/material.dart';

import '../icons.dart';
import 'expressive_menu_anchor.dart';
import 'expressive_menu_item.dart';
import 'expressive_menu_row.dart';

/// An item that opens a submenu: a › at the end of the row; on tap the
/// submenu morphs open out of this row's pill (miuix's cascade, in
/// NexioSchedule's style): the pill (radius 16) grows into a new panel
/// (radius 22) over the main menu, with a copy of this row at the top (the
/// › turned upward, tap to collapse), then a divider and [menuChildren]; the
/// main menu shrinks to 0.95 under a translucent scrim, and tapping the
/// scrim, tapping outside or going back first collapses the submenu.
///
/// Cascades are at most 2 levels deep: an [ExpressiveSubmenuItem] placed in
/// a submenu does not expand further.
///
/// [menuChildren] is fixed at tap time: rebuilds outside do not refresh it
/// while the submenu shows. Content that must change right away with a
/// selection (the check mark of a single-choice item that keeps the menu
/// open) belongs in a child widget that keeps its own selected state.
class ExpressiveSubmenuItem extends StatefulWidget {
  const ExpressiveSubmenuItem({
    super.key,
    required this.child,
    required this.menuChildren,
    this.leadingIcon,
    this.onCollapseRequest,
  });

  /// The item text; the title row at the top of the submenu uses it too.
  final Widget child;

  /// Leading icon, same as [ExpressiveMenuItem.leadingIcon].
  final Widget? leadingIcon;

  /// The submenu's content, usually a few [ExpressiveMenuItem]s.
  final List<Widget> menuChildren;

  /// Requests to collapse the submenu (tap outside, tap on the scrim, the
  /// title row, Esc, system back) ask this item first: returning true means
  /// the content stepped back one level itself (such as a calendar in the
  /// submenu going back from the month picker to the dates), so the submenu
  /// stays open this time; when null or returning false it collapses as
  /// usual.
  final bool Function()? onCollapseRequest;

  @override
  State<ExpressiveSubmenuItem> createState() => _ExpressiveSubmenuItemState();
}

class _ExpressiveSubmenuItemState extends State<ExpressiveSubmenuItem> {
  /// This row's focus: when the keyboard opens the submenu and then collapses
  /// it, focus returns to this row.
  final FocusNode _focus = FocusNode(debugLabel: 'ExpressiveSubmenuItem');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExpressiveMenuItem(
    closeOnActivate: false,
    focusNode: _focus,
    leadingIcon: widget.leadingIcon,
    trailingIcon: const ExpressiveSubmenuChevron(),
    onPressed: () => ExpressiveMenuAnchorState.maybeOf(
      context,
    )?.openSubmenu(widget, context, _focus),
    child: widget.child,
  );
}

/// The › at the end of a submenu entry row (‹ under RTL), in a 9 × 14 cell;
/// in the title row it turns upward with [turns].
class ExpressiveSubmenuChevron extends StatelessWidget {
  const ExpressiveSubmenuChevron({super.key, this.turns});

  /// Turns rotated; null means no rotation.
  final Animation<double>? turns;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    Widget icon = Ico(
      rtl ? AppIcon.back : AppIcon.forward,
      size: ExpressiveMenuRowMetrics.chevronCell.height,
    );
    final turns = this.turns;
    if (turns != null) icon = RotationTransition(turns: turns, child: icon);
    return SizedBox.fromSize(
      size: ExpressiveMenuRowMetrics.chevronCell,
      child: OverflowBox(
        maxWidth: ExpressiveMenuRowMetrics.chevronCell.height,
        child: icon,
      ),
    );
  }
}

/// The title row at the top of a submenu: a copy of the entry row (the same
/// pill, the same layout); a tap collapses the submenu, and the screen reader
/// reads it as "Back, title". When the morph starts it overlaps the trigger
/// row pixel for pixel, so it looks like that row itself grows into the
/// panel; the › at the end turns upward with [arrow] (LTR −90°, RTL +90°).
class ExpressiveSubmenuHeader extends StatelessWidget {
  const ExpressiveSubmenuHeader({
    super.key,
    required this.item,
    required this.arrow,
    required this.onCollapse,
  });

  final ExpressiveSubmenuItem item;
  final Animation<double> arrow;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return ExpressiveMenuRowInk(
      onTap: onCollapse,
      expanded: true,
      child: ExpressiveMenuRowContent(
        leadingIcon: item.leadingIcon,
        trailing: ExpressiveSubmenuChevron(
          turns: arrow.drive(Tween<double>(begin: 0, end: rtl ? 0.25 : -0.25)),
        ),
        child: Semantics(
          label: MaterialLocalizations.of(context).backButtonTooltip,
          child: item.child,
        ),
      ),
    );
  }
}

/// The divider between groups in a menu: `outlineVariant` 1dp, inset 18 on
/// the left and right (lined up with the start of the row text: row inset 6
/// plus pill padding 12), with 4 above and below (NexioSchedule / miuix's
/// HorizontalDivider is 1.5dp, which looks too thick on a real device;
/// changed to 1dp after user feedback).
class ExpressiveMenuDivider extends StatelessWidget {
  const ExpressiveMenuDivider({super.key});

  static const double inset = 18;
  static const double spacing = 4;
  static const double thickness = 1;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: inset, vertical: spacing),
    child: Divider(
      height: thickness,
      thickness: thickness,
      color: Theme.of(context).colorScheme.outlineVariant,
    ),
  );
}
