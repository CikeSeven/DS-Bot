import 'package:flutter/material.dart';

import '../icons.dart';
import '../theme.dart';
import 'expressive_menu_anchor.dart';
import 'expressive_menu_row.dart';

/// One item in an [ExpressiveMenuAnchor] (ported from NexioSchedule's menu
/// item).
///
/// Look (sizes in [ExpressiveMenuRowMetrics]): each row is a pill inset 6 on
/// the left and right (the highlight pill has a 16 corner radius and is
/// painted by the panel for all rows, see [ExpressiveMenuRowInk]); inside
/// the pill, 12 left and right and 9 top and bottom. The leading icon sits
/// in a 22 × 22 cell (icon 16px, the same color as the text), 10 from the
/// text; the text is 14.5 at weight 500 (`onSurface`), with an optional line
/// of description [summary] (`bodyMedium`, `onSurfaceVariant`); the icon +
/// text part is at most 216 wide. Action items ([selected] is null) leave no
/// space at the end; selection items always keep a 10 + 18 check cell at the
/// end, and the current item paints a check mark in the primary color and
/// switches its text and description to the primary color too (the text does
/// not shift sideways when selected); a given [trailingIcon] takes that
/// cell. [destructive] makes the text and icon `error`; when disabled they
/// are `onSurface` at 38%.
///
/// Tap: RawMenuAnchor does not close the menu for its items, so this first
/// closes it through the anchor (taps while closing are ignored, so the
/// action never runs twice) and then runs [onPressed]. When
/// [closeOnActivate] is false it only runs the action and the menu stays
/// open (for single-choice items adjusted several times in a row). Outside
/// an anchor (such as the desktop text context menu) it runs directly.
class ExpressiveMenuItem extends StatelessWidget {
  const ExpressiveMenuItem({
    super.key,
    required this.onPressed,
    required this.child,
    this.leadingIcon,
    this.trailingIcon,
    this.summary,
    this.destructive = false,
    this.selected,
    this.closeOnActivate = true,
    this.highlighted = false,
    this.focusNode,
  });

  /// When null the item is disabled.
  final VoidCallback? onPressed;

  /// The item text, usually a `Text`.
  final Widget child;

  /// Leading icon, usually a `FaIcon` without size or color; the item sets
  /// its size and color.
  final Widget? leadingIcon;

  /// Trailing widget (such as the › of a submenu entry, or a shortcut hint);
  /// in selection items it takes the check cell.
  final Widget? trailingIcon;

  /// A line of description under the text, usually a `Text`.
  final Widget? summary;

  /// Destructive action (such as delete): text and icon use
  /// `colorScheme.error`.
  final bool destructive;

  /// Whether this item is the current value in a single-choice / check menu;
  /// null means a plain action item.
  ///
  /// When non-null it also goes into semantics (the screen reader reads
  /// "selected"); when true a check mark shows at the end of the row.
  final bool? selected;

  /// Whether a tap closes the menu.
  final bool closeOnActivate;

  /// Highlight set from outside (the arrow-key highlight in the desktop text
  /// context menu).
  final bool highlighted;

  /// The row's focus (a submenu entry uses it to take focus back when the
  /// submenu collapses).
  final FocusNode? focusNode;

  void _activate(BuildContext context) {
    if (!context.mounted) return;
    final anchor = ExpressiveMenuAnchorState.maybeOf(context);
    if (anchor != null) {
      if (!anchor.interactive) return;
      if (closeOnActivate) anchor.close();
    }
    if (closeOnActivate) {
      // Return focus to the trigger control first, then run the action: if
      // the action opens a dialog or a new page, focus lands back on the
      // entry correctly once that closes.
      FocusManager.instance.applyFocusChangesIfNeeded();
    }
    onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final isSelected = selected ?? false;
    final Widget? trailing =
        trailingIcon ??
        (selected == null
            ? null
            : SizedBox.square(
                dimension: ExpressiveMenuRowMetrics.checkCell,
                child: isSelected
                    ? const Center(
                        child: Ico(
                          AppIcon.check,
                          size: ExpressiveMenuRowMetrics.checkSize,
                        ),
                      )
                    : null,
              ));
    return ExpressiveMenuRowInk(
      onTap: enabled ? () => _activate(context) : null,
      focusNode: focusNode,
      highlighted: highlighted,
      selected: selected,
      child: ExpressiveMenuRowContent(
        enabled: enabled,
        selected: isSelected,
        destructive: destructive,
        leadingIcon: leadingIcon,
        summary: summary,
        trailing: trailing,
        child: child,
      ),
    );
  }
}

/// Layout inside a menu row's pill: padding, leading icon cell, text and
/// description, trailing cell; colors follow the state. Shared by menu items
/// and the submenu's title row, so both ends of the morph match pixel for
/// pixel.
class ExpressiveMenuRowContent extends StatelessWidget {
  const ExpressiveMenuRowContent({
    super.key,
    required this.child,
    this.trailing,
    this.enabled = true,
    this.selected = false,
    this.destructive = false,
    this.leadingIcon,
    this.summary,
  });

  final Widget child;
  final Widget? trailing;
  final bool enabled;
  final bool selected;
  final bool destructive;
  final Widget? leadingIcon;
  final Widget? summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final disabled = colors.onSurface.withValues(alpha: 0.38);
    final titleColor = !enabled
        ? disabled
        : destructive
        ? colors.error
        : selected
        ? colors.primary
        : colors.onSurface;
    final summaryColor = !enabled
        ? disabled
        : selected
        ? colors.primary
        : context.p.ink2;
    final leading = leadingIcon;
    final summary = this.summary;
    final trailing = this.trailing;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        DefaultTextStyle.merge(
          style: theme.textTheme.bodyLarge?.copyWith(
            fontSize: ExpressiveMenuRowMetrics.titleSize,
            height: ExpressiveMenuRowMetrics.titleHeight,
            fontWeight: FontWeight.w500,
            color: titleColor,
          ),
          child: child,
        ),
        if (summary != null)
          DefaultTextStyle.merge(
            style: theme.textTheme.bodyMedium?.copyWith(color: summaryColor),
            child: summary,
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ExpressiveMenuRowMetrics.horizontalPadding,
        vertical: ExpressiveMenuRowMetrics.verticalPadding,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: ExpressiveMenuRowMetrics.maxTextWidth,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (leading != null)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          end: ExpressiveMenuRowMetrics.iconGap,
                        ),
                        child: SizedBox.square(
                          dimension: ExpressiveMenuRowMetrics.iconBox,
                          child: Center(
                            child: IconTheme.merge(
                              data: IconThemeData(
                                size: ExpressiveMenuRowMetrics.iconSize,
                                color: titleColor,
                              ),
                              child: ExcludeSemantics(child: leading),
                            ),
                          ),
                        ),
                      ),
                    Flexible(child: text),
                  ],
                ),
              ),
            ),
          ),
          if (trailing != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(
                start: ExpressiveMenuRowMetrics.trailingGap,
              ),
              child: IconTheme.merge(
                data: IconThemeData(
                  size: ExpressiveMenuRowMetrics.checkSize,
                  color: enabled
                      ? (selected ? colors.primary : context.p.ink2)
                      : disabled,
                ),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: summaryColor),
                  child: trailing,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
