// Restrained glass: only layers that float over content (bars, the composer
// dock, sheets, menus, banners) are frosted. Message lists stay on solid color.
// Glass falls back to a solid tint when the user asks for less transparency or
// the system asks for less motion.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'theme.dart';

class GlassScope extends InheritedWidget {
  const GlassScope({super.key, required this.enabled, required super.child});

  final bool enabled;

  static bool of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<GlassScope>();
    final media = MediaQuery.maybeOf(context);
    final systemReduce = (media?.highContrast ?? false) || (media?.disableAnimations ?? false);
    return (scope?.enabled ?? true) && !systemReduce;
  }

  @override
  bool updateShouldNotify(GlassScope old) => old.enabled != enabled;
}

/// One frosted pane. Panes inside the same [BackdropGroup] share one backdrop
/// read, which keeps several bars and a dock cheap on Android.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = BorderRadius.zero,
    this.padding,
    this.edge = GlassEdge.none,
    this.elevated = false,
    this.tint,
    this.blur = 24,
  });

  final Widget child;
  final BorderRadius radius;
  final EdgeInsetsGeometry? padding;
  final GlassEdge edge;
  final bool elevated;
  final Color? tint;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final glass = GlassScope.of(context);
    final side = BorderSide(color: glass ? p.glassEdge : p.line, width: 0.5);
    final border = switch (edge) {
      GlassEdge.none => null,
      GlassEdge.top => Border(top: BorderSide(color: p.line, width: 0.5)),
      GlassEdge.bottom => Border(bottom: BorderSide(color: p.line, width: 0.5)),
      GlassEdge.all => Border.fromBorderSide(side),
    };
    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: glass ? (tint ?? p.glass) : (tint?.withValues(alpha: 1) ?? p.main),
        borderRadius: radius,
        border: border,
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
    final pane = glass
        ? ClipRRect(
            borderRadius: radius,
            child: BackdropFilter.grouped(
              filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.mirror),
              child: decorated,
            ),
          )
        : ClipRRect(borderRadius: radius, child: decorated);
    if (!elevated) return pane;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [BoxShadow(color: p.glassShadow, blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: pane,
    );
  }
}

enum GlassEdge { none, top, bottom, all }

/// The page color with two faint washes of the accent, so frosted bars have
/// some color to blur over. Content that must stay calm sits on [p.main].
class PageBackdrop extends StatelessWidget {
  const PageBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return DecoratedBox(
      decoration: BoxDecoration(color: p.main),
      child: CustomPaint(painter: _WashPainter(p.accent, p.dark), child: child),
    );
  }
}

class _WashPainter extends CustomPainter {
  _WashPainter(this.accent, this.dark);

  final Color accent;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    void wash(Offset center, double radius, Color color) {
      final rect = Rect.fromCircle(center: center, radius: radius);
      canvas.drawRect(
        Offset.zero & size,
        Paint()..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(rect),
      );
    }

    final strength = dark ? 0.16 : 0.10;
    wash(Offset(size.width * 0.15, -size.width * 0.1), size.width * 0.9, accent.withValues(alpha: strength));
    final second = HSLColor.fromColor(accent);
    wash(
      Offset(size.width * 1.0, size.height * 0.08),
      size.width * 0.7,
      second.withHue((second.hue + 40) % 360).toColor().withValues(alpha: strength * 0.7),
    );
  }

  @override
  bool shouldRepaint(_WashPainter old) => old.accent != accent || old.dark != dark;
}

/// A frosted top bar that content scrolls under. Put it in a Stack over the page
/// and pad the content by [GlassBar.heightOf].
class GlassBar extends StatelessWidget {
  const GlassBar({super.key, this.leading, this.title, this.actions = const [], this.bottom, this.center = true});

  static const height = 52.0;

  static double heightOf(BuildContext context) => MediaQuery.paddingOf(context).top + height;

  final Widget? leading;
  final Widget? title;
  final List<Widget> actions;
  final Widget? bottom;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return GlassSurface(
      edge: GlassEdge.bottom,
      child: Padding(
        padding: EdgeInsets.only(top: top),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: height,
              child: NavigationToolbar(
                leading: leading,
                middle: title == null
                    ? null
                    : DefaultTextStyle.merge(style: TypeScale.headerTitle.copyWith(color: context.p.ink), maxLines: 1, overflow: TextOverflow.ellipsis, child: title!),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
                centerMiddle: center,
                middleSpacing: 8,
              ),
            ),
            ?bottom,
          ],
        ),
      ),
    );
  }
}

/// A page with a frosted bar over scrolling content and an optional frosted
/// dock at the bottom.
class GlassPage extends StatelessWidget {
  const GlassPage({super.key, required this.bar, this.body, this.bodyBuilder, this.dock, this.backdrop = true, this.solid = false})
      : assert(body != null || bodyBuilder != null);

  final GlassBar bar;

  /// The page content. Its [MediaQuery] padding already clears the bar, so a
  /// scroll view should read padding inside [bodyBuilder]'s context.
  final Widget? body;

  /// Builds the content under the page's [MediaQuery], so `MediaQuery.paddingOf`
  /// there includes the bar.
  final WidgetBuilder? bodyBuilder;
  final Widget? dock;
  final bool backdrop;

  /// Solid page color instead of the accent washes (message lists).
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final content = Stack(
      children: [
        Positioned.fill(
          child: MediaQuery(
            data: media.copyWith(padding: media.padding.copyWith(top: GlassBar.heightOf(context))),
            child: bodyBuilder != null ? Builder(builder: bodyBuilder!) : body!,
          ),
        ),
        Positioned(left: 0, right: 0, top: 0, child: bar),
        if (dock != null) Positioned(left: 0, right: 0, bottom: 0, child: dock!),
      ],
    );
    final page = BackdropGroup(child: Material(type: MaterialType.transparency, child: content));
    if (solid || !backdrop) return ColoredBox(color: context.p.main, child: page);
    return PageBackdrop(child: page);
  }
}

/// A frosted bottom sheet with a grabber. Returns what the sheet pops with.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool scrollable = true,
  double maxHeightFactor = 0.9,
}) {
  final p = context.p;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: p.dark ? 0.45 : 0.25),
    elevation: 0,
    builder: (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * maxHeightFactor),
      child: BackdropGroup(
        child: GlassSurface(
          radius: const BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
          edge: GlassEdge.all,
          tint: p.dark ? p.card.withValues(alpha: 0.82) : p.main.withValues(alpha: 0.82),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 8, bottom: 4),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(color: p.line2, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  Flexible(child: builder(sheetContext)),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
