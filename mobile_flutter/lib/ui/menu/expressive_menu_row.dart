import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'expressive_menu_selection.dart';

/// Sizes of a menu row. The structure is ported from NexioSchedule's
/// DropdownImpl / LiquidGlassDropdownMenuItem; the values were scaled down
/// across the board after user feedback (the originals were "too big"): row
/// height 45 → 40, font size 15.6 → 14.5.
abstract final class ExpressiveMenuRowMetrics {
  /// Distance from a row's pill to the panel's left and right edges (the
  /// highlight pill is inset the same way).
  ///
  /// Must equal [panelPadding]: the submenu's title row grows outward from
  /// the trigger row's pill by this much on each side to reach the panel's
  /// top-left corner (see the submenu panel morph in ExpressiveMenuCascade).
  /// The panel radius minus this is the pill radius (concentric).
  static const double inset = 6;

  /// Space at the top and bottom of the panel (above the first row and below
  /// the last).
  static const double panelPadding = 6;

  /// Horizontal and vertical padding inside the pill.
  static const double horizontalPadding = 12;
  static const double verticalPadding = 9;

  /// Width of the leading icon cell, its gap to the text, and the icon size.
  static const double iconBox = 22;
  static const double iconGap = 10;
  static const double iconSize = 16;

  /// Gap before the check mark at the end of a selection row (or the ›, or a
  /// custom trailing widget), and the side length of the check cell.
  static const double trailingGap = 10;
  static const double checkCell = 18;
  static const double checkSize = 14;

  /// The cell for the › at the end of a submenu entry row (9 × 14).
  static const Size chevronCell = Size(9, 14);

  /// Maximum width of the icon + text part.
  static const double maxTextWidth = 216;

  /// Title font size and line height (14.5sp, medium weight).
  static const double titleSize = 14.5;
  static const double titleHeight = 1.3;
}

/// The interaction layer of a menu row: registers the row with its panel's
/// [ExpressiveMenuSelection] (the panel handles taps, drag-to-select and the
/// highlight pill for all rows) and provides the keyboard and screen reader
/// entry points.
///
/// - The row is inset [ExpressiveMenuRowMetrics.inset] on the left and
///   right; the pill is the inset area.
/// - Taps are not handled on the row: the panel's gesture layer lights up on
///   press and runs on release; the row keeps only the screen reader tap
///   action and Enter / Space (ActivateIntent). Hover and keyboard focus are
///   reported to the panel and highlighted with the same pill. Outside a
///   panel (used on its own) it falls back to a plain tap.
/// - Semantics: one button node (merging the text in the row), with selected
///   / expanded state.
class ExpressiveMenuRowInk extends StatefulWidget {
  const ExpressiveMenuRowInk({
    super.key,
    required this.onTap,
    required this.child,
    this.focusNode,
    this.highlighted = false,
    this.selected,
    this.expanded,
  });

  /// When null the whole row is disabled (no hit testing, not focusable).
  final VoidCallback? onTap;
  final Widget child;
  final FocusNode? focusNode;

  /// Highlight set from outside (such as the arrow-key highlight in the
  /// desktop text context menu).
  final bool highlighted;
  final bool? selected;
  final bool? expanded;

  @override
  State<ExpressiveMenuRowInk> createState() => _ExpressiveMenuRowInkState();
}

class _ExpressiveMenuRowInkState extends State<ExpressiveMenuRowInk> {
  final ExpressiveMenuRowHandle _handle = ExpressiveMenuRowHandle();
  ExpressiveMenuSelection? _selection;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final selection = ExpressiveMenuSelectionScope.maybeOf(context);
    if (identical(selection, _selection)) return;
    _selection?.unregister(_handle);
    _selection = selection;
    selection?.register(_handle);
    _syncHighlight();
  }

  @override
  void didUpdateWidget(ExpressiveMenuRowInk oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.highlighted != widget.highlighted) _syncHighlight();
  }

  void _syncHighlight() {
    final selection = _selection;
    if (selection == null) return;
    // Registering and highlighting both happen during build; the pill's
    // transition can only read positions once this frame's layout is done.
    final highlighted = widget.highlighted;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(selection, _selection)) {
        selection.setHighlighted(_handle, highlighted);
      }
    });
  }

  @override
  void dispose() {
    _selection?.unregister(_handle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    final enabled = onTap != null;
    _handle
      ..enabled = enabled
      ..activate = onTap;
    final selection = _selection;
    Widget row = _RowBox(
      handle: _handle,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ExpressiveMenuRowMetrics.inset,
        ),
        child: widget.child,
      ),
    );
    if (selection == null) {
      row = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: row,
      );
    }
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: enabled,
        selected: widget.selected,
        expanded: widget.expanded,
        onTap: selection == null ? null : onTap,
        child: FocusableActionDetector(
          focusNode: widget.focusNode,
          enabled: enabled,
          mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (ActivateIntent intent) {
                onTap?.call();
                return null;
              },
            ),
          },
          onShowHoverHighlight: (bool value) =>
              selection?.setHovered(_handle, value),
          onShowFocusHighlight: (bool value) =>
              selection?.setFocused(_handle, value),
          child: row,
        ),
      ),
    );
  }
}

/// Hands the row's render box to its registration; the panel reads the row's
/// position from it.
class _RowBox extends SingleChildRenderObjectWidget {
  const _RowBox({required this.handle, super.child});

  final ExpressiveMenuRowHandle handle;

  @override
  _RenderRowBox createRenderObject(BuildContext context) =>
      _RenderRowBox(handle);

  @override
  void updateRenderObject(BuildContext context, _RenderRowBox renderObject) {
    renderObject.handle = handle;
  }
}

class _RenderRowBox extends RenderProxyBox {
  _RenderRowBox(this._handle);

  ExpressiveMenuRowHandle _handle;
  set handle(ExpressiveMenuRowHandle value) {
    if (identical(value, _handle)) return;
    if (identical(_handle.box, this)) _handle.box = null;
    _handle = value;
    if (attached) _handle.box = this;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _handle.box = this;
  }

  @override
  void detach() {
    if (identical(_handle.box, this)) _handle.box = null;
    super.detach();
  }
}
