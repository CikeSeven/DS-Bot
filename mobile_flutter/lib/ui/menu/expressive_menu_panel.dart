import 'package:flutter/material.dart';

import '../theme.dart';
import 'expressive_motion.dart';
import 'glass/glass_surface.dart';
import 'expressive_menu_motion.dart';
import 'expressive_menu_row.dart';
import 'expressive_menu_selection.dart';
import 'expressive_menu_surface.dart';

/// The content of one menu panel (main menu or submenu): a scrollable column
/// of menu rows, with the sliding highlight pill behind them and, outermost,
/// the panel's only tap / drag-to-select gesture layer. The glass base is
/// painted separately by [ExpressiveMenuGlass] (clipped to the panel rect
/// during the morph); this widget only handles the content.
///
/// - Width: the content's intrinsic width, clamped to [minWidth]–[maxWidth]
///   (160–288; a submenu is at least as wide as the main menu, which layout
///   passes through the constraints), and narrowed further when it exceeds
///   the available width.
/// - Height: scrolls inside when it exceeds the maximum height layout gives;
///   the scrollbar shows only after opening finishes.
/// - [ExpressiveMenuRowMetrics.panelPadding] at the top and bottom; with a
///   [header] (the submenu's title row), that is the first row.
/// - For gestures see [ExpressiveMenuSelection]: when [ready] is false
///   (opened less than 98%, or covered by a submenu) it does not take over;
///   [jelly] is this panel's press deformation.
class ExpressiveMenuPanel extends StatefulWidget {
  const ExpressiveMenuPanel({
    super.key,
    required this.showScrollbar,
    required this.children,
    this.ready,
    this.jelly,
    this.scrollController,
    this.header,
    this.minWidth = defaultMinWidth,
    this.maxWidth = defaultMaxWidth,
  });

  static const double defaultMinWidth = 160;
  static const double defaultMaxWidth = 288;

  final bool showScrollbar;
  final List<Widget> children;
  final bool Function()? ready;
  final ExpressiveMenuJelly? jelly;

  /// When not given, the panel creates its own (each submenu opening is a
  /// new panel, so scrolling starts at the top).
  final ScrollController? scrollController;
  final Widget? header;
  final double minWidth;
  final double maxWidth;

  @override
  State<ExpressiveMenuPanel> createState() => _ExpressiveMenuPanelState();
}

class _ExpressiveMenuPanelState extends State<ExpressiveMenuPanel>
    with TickerProviderStateMixin {
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'ExpressiveMenuPanel');
  late final ExpressiveMenuSelection _selection = ExpressiveMenuSelection(
    vsync: this,
  );
  ScrollController? _ownScroll;

  ScrollController get _scroll =>
      widget.scrollController ?? (_ownScroll ??= ScrollController());

  @override
  void initState() {
    super.initState();
    _selection
      ..contentBox = _contentBox
      ..ready = _ready
      ..fits = _fits
      ..reduceMotion = _reduceMotion
      ..jelly = widget.jelly;
  }

  RenderBox? _contentBox() {
    final box = _contentKey.currentContext?.findRenderObject();
    return box is RenderBox ? box : null;
  }

  bool _ready() => mounted && (widget.ready?.call() ?? true);

  bool _fits() {
    final scroll = _scroll;
    return !scroll.hasClients || scroll.position.maxScrollExtent <= 1;
  }

  bool _reduceMotion() => mounted && ExpressiveMotion.reduceMotion(context);

  @override
  void didUpdateWidget(ExpressiveMenuPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selection.jelly = widget.jelly;
  }

  @override
  void dispose() {
    _selection.dispose();
    _ownScroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final header = widget.header;
    final maskColor = colors.onSurface.withValues(
      alpha: colors.brightness == Brightness.dark ? 0.10 : 0.06,
    );
    final content = Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _selection.handlePointerDown,
      onPointerMove: _selection.handlePointerMove,
      onPointerUp: _selection.handlePointerUp,
      onPointerCancel: _selection.handlePointerCancel,
      // The pill's canvas, the reference box for row positions and the
      // gesture layer must share one origin: row positions are measured
      // against [_contentKey], press positions against the Listener, and the
      // pill is painted on the CustomPaint. So the padding goes inside the
      // canvas, not the canvas inside the padding (that would shift the whole
      // pill down by panelPadding).
      child: CustomPaint(
        key: _contentKey,
        painter: ExpressiveMenuMaskPainter(
          selection: _selection,
          color: maskColor,
          inset: ExpressiveMenuRowMetrics.inset,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: ExpressiveMenuRowMetrics.panelPadding,
          ),
          child: ListBody(children: <Widget>[?header, ...widget.children]),
        ),
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: widget.minWidth,
        maxWidth: widget.maxWidth,
      ),
      // Laid out at the final size; the morph happens only at paint time, so
      // text does not reflow every frame.
      child: IntrinsicWidth(
        child: Material(
          type: MaterialType.transparency,
          child: ExpressiveMenuSelectionScope(
            selection: _selection,
            child: ScrollConfiguration(
              // Turn off the platform's default scrollbar and overscroll
              // effect; the Scrollbar below controls the scrollbar through
              // [showScrollbar].
              behavior: ScrollConfiguration.of(context).copyWith(
                scrollbars: false,
                overscroll: false,
                physics: const ClampingScrollPhysics(),
              ),
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: widget.showScrollbar,
                child: SingleChildScrollView(
                  controller: _scroll,
                  primary: false,
                  child: RepaintBoundary(child: content),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The panel's glass base ([BackdropGlass]: translucent base color and
/// backdrop blur, square corners; layout clips it to a superellipse from the
/// current panel rect). The base color and blur appear with
/// [ExpressiveMenuMotion.containerAlpha]; it takes no taps and has no
/// semantics. With reduced motion or high contrast it is an opaque base with
/// no blur.
class ExpressiveMenuGlass extends StatelessWidget {
  const ExpressiveMenuGlass({super.key, required this.motion});

  final ExpressiveMenuMotion motion;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final solid = ExpressiveMenuSurface.solidOf(context);
    final tint = ExpressiveMenuSurface.tintOf(p);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: motion,
          builder: (BuildContext context, Widget? child) => BackdropGlass(
            fill: solid ? Color.alphaBlend(tint, p.main) : tint,
            blurSigma: ExpressiveMenuSurface.blurSigma,
            blur: !solid,
            progress: motion.containerAlpha,
            child: child!,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
