import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'expressive_motion.dart';
import 'expressive_menu_layout.dart';
import 'expressive_menu_motion.dart';
import 'expressive_menu_panel.dart';
import 'expressive_menu_row.dart';
import 'expressive_menu_surface.dart';
import 'expressive_submenu.dart';

export 'expressive_menu_layout.dart' show ExpressiveMenuPlacement;

/// Build callback for the menu's entry: it gets the menu state (whether it
/// is expanded, and the open / close methods) to draw the trigger control,
/// the same way `FormField.builder` gets a `FormFieldState`.
typedef ExpressiveMenuTriggerBuilder =
    Widget Function(
      BuildContext context,
      ExpressiveMenuAnchorState menu,
      Widget? child,
    );

/// The app's shared anchored pop-up menu, with look and motion ported from
/// NexioSchedule's ListPopup / LiquidGlassDropdownMenu (submenus follow
/// miuix's cascade), built on [RawMenuAnchor].
///
/// Why not the SDK's MenuAnchor / PopupMenuButton: MenuAnchor's open
/// duration is fixed at 500ms, and PopupMenuButton is a full-page route that
/// scales up from the center and does not align with its anchor; building on
/// the lower-level anchor lets this widget own the surface, motion and
/// placement.
///
/// - Surface: a glass panel ([ExpressiveMenuGlass], a superellipse with
///   radius 22, a ring outer shadow + thin border), 160–288 wide, its height
///   limited by the safe area and scrolling inside when it overflows; for the
///   row style see [ExpressiveMenuItem]. No dimming layer.
/// - Where it grows from (container transform, see [ExpressiveMenuMotion]):
///   - Icon button ([iconTrigger], or an anchor no larger than 56 × 56): the
///     panel covers the button and grows out of the button's circle of at
///     most 40 (aligned at the corner touching the circle), and the icon
///     fades out with it;
///   - Other entries no taller than 56 and no wider than 288 (text buttons,
///     pills): the panel covers the entry and grows out of the entry's own
///     rect, and the entry fades out with it;
///   - Larger anchors (cards, bookshelf cells) and
///     [ExpressiveMenuAnchorState.openAt]: the panel goes 8dp below the
///     anchor (flipped above when it does not fit; gap 0 at the pointer)
///     and grows out of a small 28 circle on the corner touching the anchor.
///   The panel's width and height each interpolate on a spring from the seed
///   to the final size, while it moves from the seed's corner toward its own
///   center; the content is laid out once at the final size, scaled
///   uniformly, faded in in stages and briefly blurred midway. Closing runs
///   in reverse, with one spring-back for icon buttons. With reduced motion
///   it opens and closes instantly. It takes no input while closing.
/// - Taps: the panel handles them for all rows: on press the highlight pill
///   lights up, sliding while held moves it to another row, and release runs
///   that row ([ExpressiveMenuSelection]).
/// - Submenus ([ExpressiveSubmenuItem]): the trigger row's pill grows in
///   place into a new panel over the main menu, and the main menu shrinks to
///   0.95 under a translucent scrim; the title row is a copy of the trigger
///   row, and tapping it, tapping the scrim, tapping outside, system back,
///   Esc or ← (→ under RTL) all collapse the submenu first. Cascades are at
///   most 2 levels deep. Reopening always starts from the main menu.
/// - Behavior: tapping outside closes the menu and does not pass through;
///   system back / predictive back closes the menu first (while open it
///   registers a [LocalHistoryEntry] on its route); Esc closes; ↑/↓ move
///   focus between items; on close, focus returns to [childFocusNode].
/// - Opening at a given position (right-click / long-press menus):
///   [ExpressiveMenuAnchorState.openAt] puts the menu's start corner on the
///   given global position (ignoring [placement]), and likewise flips up or
///   down and clamps into the safe area; once open, focus stays on the menu
///   (on the first item when opened from the keyboard), and on close focus
///   returns to where it was before opening.
///
/// Use [ExpressiveMenuItem] for menu items: RawMenuAnchor does not close the
/// menu for its items automatically.
class ExpressiveMenuAnchor extends StatefulWidget {
  const ExpressiveMenuAnchor({
    super.key,
    required this.menuChildren,
    required this.builder,
    this.child,
    this.controller,
    this.childFocusNode,
    this.placement = ExpressiveMenuPlacement.end,
    this.onOpen,
    this.onClose,
    this.onAnimationStatusChanged,
    this.iconTrigger = false,
  });

  /// Menu content, usually a few [ExpressiveMenuItem]s.
  final List<Widget> menuChildren;

  /// The trigger control; called again when the menu's expanded state
  /// changes.
  final ExpressiveMenuTriggerBuilder builder;

  /// A subtree passed to [builder] as is, for the parts that do not rebuild
  /// with the expanded state.
  final Widget? child;

  /// Pass one to control opening and closing from outside; otherwise one is
  /// created inside.
  final MenuController? controller;

  /// Focus of the trigger control; focus goes back to it when the menu
  /// closes.
  final FocusNode? childFocusNode;
  final ExpressiveMenuPlacement placement;

  /// Called when the overlay is attached (called again when the menu is
  /// reopened while closing).
  final VoidCallback? onOpen;

  /// Called after the close animation ends and the overlay is removed.
  final VoidCallback? onClose;
  final ValueChanged<AnimationStatus>? onAnimationStatusChanged;

  /// The trigger control is an icon button: the panel grows out of the
  /// button's circle and springs back on close.
  final bool iconTrigger;

  /// Vertical gap between the panel and a large anchor it sits next to.
  static const double anchorGap = 8;

  /// Maximum diameter of the icon button's circle (the visible 40 inside the
  /// 48 touch target).
  static const double iconSeedSize = 40;

  /// Anchors no larger than this are treated as icon buttons; entries no
  /// taller than this grow out of themselves.
  static const double compactTrigger = 56;

  @override
  State<ExpressiveMenuAnchor> createState() => ExpressiveMenuAnchorState();
}

/// The submenu currently shown: the trigger item and the trigger row's pill
/// (main menu content coordinates, fixed at press time).
class _OpenSubmenu {
  _OpenSubmenu({
    required this.item,
    required this.pill,
    required this.triggerFocus,
    required this.serial,
  });

  final ExpressiveSubmenuItem item;
  final Rect pill;
  final FocusNode? triggerFocus;
  final int serial;
  LocalHistoryEntry? history;
}

/// Marks the submenu's subtree: [ExpressiveSubmenuItem]s in it do not expand
/// again (depth limit 2).
class _SecondaryScope extends InheritedWidget {
  const _SecondaryScope({required super.child});

  @override
  bool updateShouldNotify(_SecondaryScope oldWidget) => false;
}

/// Clamps opacity-type progress back into 0…1 (a spring may overshoot very
/// slightly).
class _Clamp01 extends Animatable<double> {
  const _Clamp01();

  @override
  double transform(double t) => t.clamp(0.0, 1.0);
}

/// State of [ExpressiveMenuAnchor]; [ExpressiveMenuItem] finds it through
/// [maybeOf] to close the menu.
class ExpressiveMenuAnchorState extends State<ExpressiveMenuAnchor>
    with TickerProviderStateMixin {
  late final ExpressiveMenuMotion _motion = ExpressiveMenuMotion(
    vsync: this,
    onStatusChanged: _statusChanged,
    onSecondaryCollapsed: _submenuSettled,
  );
  late final Animation<double> _maskOpacity = _motion.expand.drive(
    const _Clamp01(),
  );
  final FocusScopeNode _menuFocus = FocusScopeNode(
    debugLabel: 'ExpressiveMenu',
  );
  final ScrollController _scroll = ScrollController();
  final GlobalKey _primaryKey = GlobalKey(debugLabel: 'ExpressiveMenuPrimary');

  /// Whether the panel covered the trigger control at the last overlay
  /// build: when it does, the trigger control fades out as the panel grows.
  bool _coverTrigger = false;
  late final Animation<double> _triggerOpacity = _TriggerOpacity(this);
  MenuController? _internalController;
  VoidCallback? _hideOverlay;
  LocalHistoryEntry? _history;
  bool _reduced = false;

  /// The submenu being shown (including while it collapses).
  _OpenSubmenu? _submenu;
  int _submenuSerial = 0;

  /// Whether this opening went through [openAt] at a given position (the
  /// position relative to the anchor's top-left is kept in [_openPosition]),
  /// and whether focus should then land on the first item or on the menu
  /// itself.
  Offset? _openPosition;
  bool _focusFirstItem = false;

  /// Focus before [openAt] opened the menu: without
  /// [ExpressiveMenuAnchor.childFocusNode], focus goes back to it after
  /// closing.
  FocusNode? _focusBeforeOpen;

  /// Whether tickers in this subtree are running (see
  /// [didChangeDependencies]).
  bool _tickersEnabled = true;

  /// Finds the menu that encloses [context] (the menu overlay is still a
  /// descendant of the anchor in the element tree).
  static ExpressiveMenuAnchorState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<ExpressiveMenuAnchorState>();

  MenuController get controller =>
      widget.controller ?? (_internalController ??= MenuController());

  /// Opening or open: false as soon as the close animation starts; the
  /// trigger control shows "collapsed" based on it.
  bool get isExpanded => _motion.status.isForwardOrCompleted;

  /// Whether the overlay is still attached (from opening until the close
  /// animation ends): the icon button keeps its pressed background based on
  /// it, like miuix's holdDown, which releases only at onDismissFinished.
  bool get isShowing => controller.isOpen;

  /// Menu items respond only while opening or open; taps while closing no
  /// longer run actions.
  bool get interactive => isExpanded;

  /// Whether the submenu is expanded (false while it collapses).
  bool get submenuOpen => _submenu != null && _motion.secondaryExpanded;

  void open() => controller.open();

  void close() => controller.close();

  /// Tapping the trigger control again while closing reopens the menu
  /// instead of treating it as "open" and closing it again; while a submenu
  /// is open, it collapses the submenu first (like tapping outside).
  void toggle() {
    if (!isExpanded) {
      open();
    } else if (submenuOpen) {
      closeSubmenu();
    } else {
      close();
    }
  }

  /// Expands [item]'s submenu from the row that [itemContext] is in (called
  /// by [ExpressiveSubmenuItem]). The trigger row's pill is fixed at this
  /// point (main menu content coordinates) and no longer follows the main
  /// menu's scale while the submenu shows.
  void openSubmenu(
    ExpressiveSubmenuItem item,
    BuildContext itemContext,
    FocusNode? triggerFocus,
  ) {
    if (!interactive || submenuOpen) return;
    if (itemContext.getInheritedWidgetOfExactType<_SecondaryScope>() != null) {
      assert(false, 'ExpressiveSubmenuItem supports only two levels: one inside a submenu does not expand again.');
      return;
    }
    final row = itemContext.findRenderObject();
    final primary = _primaryKey.currentContext?.findRenderObject();
    if (row is! RenderBox ||
        primary is! RenderBox ||
        !row.hasSize ||
        !primary.hasSize) {
      return;
    }
    // The whole row's rect (including the left and right inset) in the main
    // menu content; with the inset taken off, that is the pill.
    final rowRect = MatrixUtils.transformRect(
      row.getTransformTo(primary),
      Offset.zero & row.size,
    );
    final pill = Rect.fromLTRB(
      rowRect.left + ExpressiveMenuRowMetrics.inset,
      rowRect.top,
      rowRect.right - ExpressiveMenuRowMetrics.inset,
      rowRect.bottom,
    ).intersect(Offset.zero & primary.size);
    final submenu = _OpenSubmenu(
      item: item,
      pill: pill,
      triggerFocus: triggerFocus,
      serial: ++_submenuSerial,
    );
    _registerSubmenuHistory(submenu);
    setState(() => _submenu = submenu);
    _motion.expandSecondary(reduced: _reduced);
    if (!_menuFocus.hasFocus) return;
    // Keyboard use: focus lands on the submenu's first item (the title row),
    // and ↑↓ can move on from there.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final menuContext = _menuFocus.context;
      if (!mounted || !submenuOpen || menuContext == null) return;
      FocusTraversalGroup.of(
        menuContext,
      ).findFirstFocus(_menuFocus, ignoreCurrentFocus: true)?.requestFocus();
    });
  }

  /// Registers a local history entry for the submenu, so the system back key
  /// collapses the submenu first.
  ///
  /// When system back pops it, [ExpressiveSubmenuItem.onCollapseRequest] is
  /// asked first: if the content stepped back one level itself, a new entry
  /// is registered so the next back goes to it first again; otherwise the
  /// submenu collapses.
  void _registerSubmenuHistory(_OpenSubmenu submenu) {
    final route = ModalRoute.of(context);
    if (route == null) return;
    late final LocalHistoryEntry entry;
    entry = LocalHistoryEntry(
      // Keep the AppBar from swapping its back button for a close button
      // because of this.
      impliesAppBarDismissal: false,
      onRemove: () {
        // A deliberate collapse unlinks the entry first; only a pop by system
        // back gets here.
        if (submenu.history != entry) return;
        submenu.history = null;
        if (!identical(_submenu, submenu)) return;
        if (submenu.item.onCollapseRequest?.call() ?? false) {
          _registerSubmenuHistory(submenu);
        } else {
          _collapseSubmenu();
        }
      },
    );
    submenu.history = entry;
    route.addLocalHistoryEntry(entry);
  }

  /// Collapses the submenu; does nothing when none is expanded. When the
  /// content intercepts through [ExpressiveSubmenuItem.onCollapseRequest]
  /// (returns true), it does not collapse this time and the content steps
  /// back one level itself.
  void closeSubmenu() {
    if (!interactive || !submenuOpen) return;
    if (_submenu?.item.onCollapseRequest?.call() ?? false) return;
    _collapseSubmenu();
  }

  void _collapseSubmenu() {
    final submenu = _submenu;
    if (submenu == null || !_motion.secondaryExpanded) return;
    _releaseSubmenuHistory(submenu);
    final refocus = _menuFocus.hasFocus ? submenu.triggerFocus : null;
    setState(() {});
    _motion.collapseSecondary(reduced: _reduced);
    if (refocus == null) return;
    // The main menu can take focus back only after ExcludeFocus is lifted in
    // this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && refocus.context != null && !submenuOpen) {
        refocus.requestFocus();
      }
    });
  }

  /// The submenu's collapse spring has settled: remove it.
  void _submenuSettled() {
    if (!mounted || _motion.secondaryExpanded || _submenu == null) return;
    setState(() => _submenu = null);
  }

  void _releaseSubmenuHistory(_OpenSubmenu submenu) {
    final entry = submenu.history;
    submenu.history = null;
    entry?.remove();
  }

  /// Opens the menu at the global position [globalPosition] (usually the
  /// right-click pointer position): the menu's start corner sits on this
  /// point (the top-left under LTR; flipped above when it does not fit
  /// below), clamped into the safe area.
  ///
  /// Why focus moves into the menu once it opens: on right-click, focus is
  /// usually still on the page (such as keyboard focus on a list),
  /// so Esc and the arrow keys would be handled by the page first (clearing
  /// the selection, moving cards) instead of closing the menu. When
  /// [focusFirstItem] is true (opened with the keyboard's menu key /
  /// Shift+F10), focus lands straight on the first item and Enter runs it;
  /// when opened with the mouse, focus stays on the menu itself and ↓ enters
  /// the first item. If the menu is already open, moving to a new position
  /// opens it again from there.
  void openAt(Offset globalPosition, {bool focusFirstItem = false}) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    _focusBeforeOpen = FocusManager.instance.primaryFocus;
    _focusFirstItem = focusFirstItem;
    controller.open(position: box.globalToLocal(globalPosition));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = ExpressiveMotion.reduceMotion(context);
    // Switched to reduced motion mid-animation: jump to the end next frame,
    // leaving no half-open menu.
    if (_reduced && _motion.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _reduced) _motion.settleNow();
      });
    }
    // The tickers of this page are muted (the home screen switched away from
    // this tab, such as "More → Settings"): the open / close animation no
    // longer advances and the close never finishes, so the overlay and its
    // outside-tap interception (consumeOutsideTaps) stay and swallow taps
    // elsewhere, such as on the bottom bar. In that case close the menu
    // directly with no animation. Opening and closing is not allowed during
    // build, so do it after this frame.
    _tickersEnabled = TickerMode.valuesOf(context).enabled;
    if (!_tickersEnabled && controller.isOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_tickersEnabled) _dismissImmediately();
      });
    }
  }

  /// Closes the menu without animation (if it has not started closing yet,
  /// starts the close first, then jumps to the end).
  void _dismissImmediately() {
    if (!controller.isOpen) return;
    if (_motion.status != AnimationStatus.reverse) controller.close();
    _motion.snapClosed();
    _finishClose();
  }

  @override
  void didUpdateWidget(ExpressiveMenuAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller &&
        widget.controller != null) {
      _internalController = null;
    }
  }

  void _statusChanged(AnimationStatus status) {
    if (mounted) setState(() {});
    widget.onAnimationStatusChanged?.call(status);
    if (status == AnimationStatus.dismissed) _finishClose();
  }

  void _open(Offset? position, VoidCallback showOverlay) {
    // Reopened while closing: keep the current overlay and progress, do not
    // rebuild the content, and drop the callback from the last close.
    _hideOverlay = null;
    final moved = controller.isOpen && position != _openPosition;
    _openPosition = position;
    if (!controller.isOpen || moved) {
      // Opening with a newly attached overlay always starts from the main
      // menu.
      _submenu = null;
      _motion.collapseSecondary(reduced: true);
      if (_scroll.hasClients) _scroll.jumpTo(0);
      showOverlay();
      // Moved to a new position: RawMenuAnchor attaches the overlay again,
      // and the opening plays from the start (from the new corner).
      if (moved && !_reduced) _motion.restart();
    } else if (!interactive) {
      widget.onOpen?.call();
    }
    _addHistory();
    if (!interactive) {
      _reduced ? _motion.snapOpen() : _motion.open();
    }
    if (position != null) {
      // The overlay is only built in this frame; move focus after it has
      // joined the focus tree.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !controller.isOpen || !interactive) return;
        if (_focusFirstItem) {
          _moveFocus(forward: true);
        } else {
          _menuFocus.requestScopeFocus();
        }
      });
    }
  }

  void _close(VoidCallback hideOverlay) {
    if (!controller.isOpen) return;
    _hideOverlay = hideOverlay;
    // Drop the back interception as soon as closing starts: a back gesture
    // during the animation should act on the page itself.
    final submenu = _submenu;
    if (submenu != null) _releaseSubmenuHistory(submenu);
    _removeHistory();
    if (_menuFocus.hasFocus) {
      final returnTo = widget.childFocusNode ?? _focusBeforeOpen;
      // The focus from before opening may have been unmounted with its page
      // (its context is null); then it is not given back.
      if (returnTo != null && returnTo.context != null) {
        returnTo.requestFocus();
      }
    }
    _focusBeforeOpen = null;
    if (_motion.status == AnimationStatus.reverse) return;
    if (_reduced || _motion.status == AnimationStatus.dismissed) {
      _motion.snapClosed();
      _finishClose();
    } else {
      _motion.close();
    }
  }

  void _finishClose() {
    final hide = _hideOverlay;
    _hideOverlay = null;
    hide?.call();
  }

  /// While open, registers a local history entry on the route: system back /
  /// predictive back pops it first (which closes the menu), and the page
  /// itself is not popped.
  void _addHistory() {
    if (_history != null) return;
    final route = ModalRoute.of(context);
    if (route == null) return;
    late final LocalHistoryEntry entry;
    entry = LocalHistoryEntry(
      // Keep the AppBar from swapping its back button for a close button
      // because of this.
      impliesAppBarDismissal: false,
      onRemove: () {
        // When we remove it ourselves, _history is cleared first; only a pop
        // by back needs to close the menu.
        if (_history != entry) return;
        _history = null;
        controller.close();
      },
    );
    _history = entry;
    route.addLocalHistoryEntry(entry);
  }

  void _removeHistory() {
    final entry = _history;
    _history = null;
    entry?.remove();
  }

  void _handleClosed() {
    _removeHistory();
    final submenu = _submenu;
    if (submenu != null) _releaseSubmenuHistory(submenu);
    _submenu = null;
    widget.onClose?.call();
  }

  void _handleOutsideTap() => submenuOpen ? closeSubmenu() : close();

  void _moveFocus({required bool forward}) {
    final menuContext = _menuFocus.context;
    if (!interactive || menuContext == null) return;
    // When focus is on the menu itself ([openAt] opened by mouse) there is
    // no current item yet; treat it as "first entry": ↓ lands on the first
    // item, ↑ on the last.
    if (_menuFocus.hasFocus && !_menuFocus.hasPrimaryFocus) {
      forward ? _menuFocus.nextFocus() : _menuFocus.previousFocus();
    } else {
      final policy = FocusTraversalGroup.of(menuContext);
      final node = forward
          ? policy.findFirstFocus(_menuFocus, ignoreCurrentFocus: true)
          : policy.findLastFocus(_menuFocus, ignoreCurrentFocus: true);
      node?.requestFocus();
    }
  }

  Widget _shortcuts(Widget child) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      if (controller.isOpen) ...<ShortcutActivator, VoidCallback>{
        // While a submenu is open, Esc collapses it first, same as system
        // back.
        const SingleActivator(LogicalKeyboardKey.escape): _handleOutsideTap,
        if (submenuOpen)
          SingleActivator(
            Directionality.of(context) == TextDirection.rtl
                ? LogicalKeyboardKey.arrowRight
                : LogicalKeyboardKey.arrowLeft,
          ): closeSubmenu,
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _moveFocus(forward: true),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _moveFocus(forward: false),
      },
    },
    child: child,
  );

  @override
  void dispose() {
    _hideOverlay = null;
    final submenu = _submenu;
    if (submenu != null) _releaseSubmenuHistory(submenu);
    _removeHistory();
    _motion.dispose();
    _menuFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawMenuAnchor(
    controller: controller,
    childFocusNode: widget.childFocusNode,
    consumeOutsideTaps: true,
    onOpenRequested: _open,
    onCloseRequested: _close,
    onOpen: widget.onOpen,
    onClose: _handleClosed,
    builder: (BuildContext context, MenuController _, Widget? child) =>
        _shortcuts(
          // While the panel grows over the trigger control, the trigger fades
          // out with it, and it fades back in early as the panel shrinks back
          // (the screen reader can still read its expanded state).
          FadeTransition(
            opacity: _triggerOpacity,
            alwaysIncludeSemantics: true,
            child: widget.builder(context, this, child),
          ),
        ),
    overlayBuilder: _buildOverlay,
    child: widget.child,
  );

  Widget _buildOverlay(BuildContext context, RawMenuOverlayInfo info) {
    // When opened at a given position, the anchor shrinks to that point
    // (zero size, zero gap) and aligns by its start edge: the menu's start
    // corner sits on the pointer and the menu grows out of that corner.
    final position = info.position;
    final anchor = position == null
        ? info.anchorRect
        : Rect.fromLTWH(
            info.anchorRect.left + position.dx,
            info.anchorRect.top + position.dy,
            0,
            0,
          );
    final area = ExpressiveMenuArea.of(context, info.overlaySize, anchor);
    const compact = ExpressiveMenuAnchor.compactTrigger;
    final icon =
        position == null &&
        (widget.iconTrigger ||
            (anchor.width <= compact && anchor.height <= compact));
    final textTrigger =
        position == null &&
        !icon &&
        anchor.height <= compact &&
        anchor.width <= ExpressiveMenuPanel.defaultMaxWidth;
    final Rect? seed;
    if (icon) {
      final d = ExpressiveMenuAnchor.iconSeedSize.clamp(
        0.0,
        anchor.shortestSide,
      );
      seed = Rect.fromCenter(center: anchor.center, width: d, height: d);
    } else if (textTrigger) {
      seed = anchor;
    } else {
      seed = null;
    }
    _coverTrigger = seed != null;
    _motion.style = icon
        ? ExpressiveMenuMorphStyle.button
        : ExpressiveMenuMorphStyle.dropdown;
    final colors = Theme.of(context).colorScheme;
    final submenu = _submenu;
    final maskAlpha = colors.brightness == Brightness.dark ? 0.3 : 0.15;
    final cascade = ExpressiveMenuCascade(
      anchor: anchor,
      bounds: area.bounds,
      cover: seed != null,
      seed: seed,
      gap: position == null ? ExpressiveMenuAnchor.anchorGap : 0,
      placement: position == null
          ? widget.placement
          : ExpressiveMenuPlacement.start,
      textDirection: Directionality.of(context),
      motion: _motion,
      shadowColor: ExpressiveMenuSurface.ringShadowOf(colors),
      borderColor: ExpressiveMenuSurface.borderOf(context.p),
      submenuPill: submenu?.pill,
      children: <Widget>[
        ExpressiveMenuGlass(motion: _motion),
        KeyedSubtree(
          key: _primaryKey,
          child: _primaryPanel(colors.scrim.withValues(alpha: maskAlpha)),
        ),
        if (submenu != null) ...<Widget>[
          ExpressiveMenuGlass(motion: _motion),
          _secondaryPanel(submenu),
        ],
      ],
    );
    return TapRegion(
      groupId: info.tapRegionGroupId,
      consumeOutsideTaps: true,
      onTapOutside: (_) => _handleOutsideTap(),
      child: ExcludeSemantics(
        excluding: !interactive,
        child: ExcludeFocus(
          excluding: !interactive,
          child: IgnorePointer(
            ignoring: !interactive,
            child: Semantics(
              scopesRoute: true,
              explicitChildNodes: true,
              child: FocusTraversalGroup(
                child: FocusScope(
                  node: _menuFocus,
                  skipTraversal: true,
                  child: _shortcuts(cascade),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The main menu: while a submenu is expanded it gives up focus and
  /// semantics and is covered by a scrim that collapses the submenu on tap
  /// (its opacity follows the morph progress; it does not block taps while
  /// collapsing). The tree structure never changes, so the main menu's
  /// scroll position and item state are not affected by the submenu opening
  /// and closing.
  Widget _primaryPanel(Color maskColor) {
    final active = submenuOpen;
    return Stack(
      children: <Widget>[
        ExcludeFocus(
          excluding: active,
          child: ExcludeSemantics(
            excluding: active,
            child: ExpressiveMenuPanel(
              scrollController: _scroll,
              jelly: _motion.primaryJelly,
              ready: () =>
                  interactive && !submenuOpen && _motion.dragSelectReadyNow,
              // Show the scrollbar only once opening finishes, so it does
              // not flash during the morph.
              showScrollbar: _motion.status == AnimationStatus.completed,
              children: widget.menuChildren,
            ),
          ),
        ),
        if (_submenu != null)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !active,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: closeSubmenu,
                child: FadeTransition(
                  opacity: _maskOpacity,
                  child: ColoredBox(color: maskColor),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// The submenu: title row (a copy of the trigger row) + divider + items;
  /// it stops responding while collapsing.
  Widget _secondaryPanel(_OpenSubmenu submenu) {
    final active = submenuOpen;
    return _SecondaryScope(
      child: KeyedSubtree(
        // Each expansion is a new panel: do not reuse the previous submenu's
        // item state and scroll position.
        key: ValueKey<int>(submenu.serial),
        child: ExcludeFocus(
          excluding: !active,
          child: ExcludeSemantics(
            excluding: !active,
            child: IgnorePointer(
              ignoring: !active,
              child: ExpressiveMenuPanel(
                jelly: _motion.secondaryJelly,
                ready: () =>
                    interactive &&
                    submenuOpen &&
                    _motion.expand.value >=
                        ExpressiveMenuMotion.dragSelectReady,
                showScrollbar:
                    active && _motion.status == AnimationStatus.completed,
                header: ExpressiveSubmenuHeader(
                  item: submenu.item,
                  arrow: _motion.arrow,
                  onCollapse: closeSubmenu,
                ),
                children: <Widget>[
                  const ExpressiveMenuDivider(),
                  ...submenu.item.menuChildren,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opacity of the trigger control: fades out with
/// [ExpressiveMenuMotion.triggerOpacity] when the panel covers it, otherwise
/// always 1. Whether it is covered is only known after the overlay's layout,
/// so it is read fresh on every access.
class _TriggerOpacity extends Animation<double>
    with AnimationWithParentMixin<double> {
  _TriggerOpacity(this._state);

  final ExpressiveMenuAnchorState _state;

  @override
  Animation<double> get parent => _state._motion.triggerOpacity;

  @override
  double get value =>
      _state._coverTrigger && _state.controller.isOpen ? parent.value : 1;
}
