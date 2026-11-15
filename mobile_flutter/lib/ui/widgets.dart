// Small building blocks every screen uses. They take their colors from the
// palette, press with a quick spring, and keep touch targets at 44 or more.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glass.dart';
import 'i18n.dart';
import 'icons.dart';
import 'theme.dart';

/// Scales down a little while pressed, then springs back.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap, this.onLongPress, this.scale = 0.97, this.haptic = false});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final bool haptic;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptic) HapticFeedback.selectionClick();
              widget.onTap!();
            },
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              _set(false);
              HapticFeedback.mediumImpact();
              widget.onLongPress!();
            },
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: Duration(milliseconds: _down ? 90 : 260),
        curve: _down ? Curves.easeOut : SpringCurve.tap,
        child: widget.child,
      ),
    );
  }
}

class IconBtn extends StatelessWidget {
  const IconBtn(this.icon, {super.key, this.onTap, this.color, this.size = 22, this.tooltip, this.badge = false, this.filled = false});

  final AppIcon icon;
  final VoidCallback? onTap;
  final Color? color;
  final double size;
  final String? tooltip;
  final bool badge;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final button = Pressable(
      onTap: onTap,
      scale: 0.9,
      child: SizedBox.square(
        dimension: 44,
        child: Center(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: filled ? 36 : size,
                height: filled ? 36 : size,
                alignment: Alignment.center,
                decoration: filled ? BoxDecoration(color: p.hover, shape: BoxShape.circle) : null,
                child: Ico(icon, size: size, color: onTap == null ? p.ink3 : (color ?? p.ink)),
              ),
              if (badge)
                Positioned(
                  right: filled ? 2 : -2,
                  top: filled ? 2 : -2,
                  child: Container(width: 9, height: 9, decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle, border: Border.all(color: p.main, width: 1.5))),
                ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

enum BtnKind { primary, secondary, ghost, danger }

class Btn extends StatelessWidget {
  const Btn(this.label, {super.key, this.onTap, this.kind = BtnKind.primary, this.icon, this.busy = false, this.expand = false, this.small = false});

  final String label;
  final VoidCallback? onTap;
  final BtnKind kind;
  final AppIcon? icon;
  final bool busy;
  final bool expand;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final (bg, fg) = switch (kind) {
      BtnKind.primary => (p.accent, p.accentInk),
      BtnKind.secondary => (p.bubble, p.ink),
      BtnKind.ghost => (Colors.transparent, p.accent),
      BtnKind.danger => (Palette.danger.withValues(alpha: 0.12), Palette.danger),
    };
    final disabled = onTap == null || busy;
    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy)
          SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
        else if (icon != null)
          Ico(icon!, size: 18, color: fg),
        if (busy || icon != null) const SizedBox(width: 8),
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: (small ? TypeScale.smallStrong : TypeScale.rowNameStrong).copyWith(color: fg))),
      ],
    );
    return Opacity(
      opacity: disabled && !busy ? 0.45 : 1,
      child: Pressable(
        onTap: disabled ? null : onTap,
        haptic: kind == BtnKind.primary,
        child: Container(
          height: small ? 34 : 46,
          padding: EdgeInsets.symmetric(horizontal: small ? 14 : 18),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
          child: content,
        ),
      ),
    );
  }
}

class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.color, this.background});

  final String label;
  final Color? color;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(color: background ?? p.tagBg, borderRadius: BorderRadius.circular(Radii.tag)),
      child: Text(label, style: TypeScale.caption.copyWith(color: color ?? p.tagInk, fontWeight: FontWeight.w500)),
    );
  }
}

class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key, this.color});

  final int count;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color ?? p.accent, borderRadius: BorderRadius.circular(10)),
      child: Text(count > 99 ? '99+' : '$count', style: TypeScale.caption.copyWith(color: p.accentInk, fontWeight: FontWeight.w600)),
    );
  }
}

/// A rounded group of rows, as in Settings.
class Group extends StatelessWidget {
  const Group({super.key, required this.children, this.title, this.footer, this.margin = const EdgeInsets.fromLTRB(16, 8, 16, 8)});

  final List<Widget> children;
  final String? title;
  final String? footer;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final rows = <Widget>[];
    for (final (index, child) in children.indexed) {
      if (index > 0) rows.add(Divider(height: 0.5, thickness: 0.5, indent: 16, color: p.line));
      rows.add(child);
    }
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
              child: Text(title!, style: TypeScale.smallStrong.copyWith(color: p.ink2)),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.dialog),
            child: ColoredBox(color: p.card.withValues(alpha: p.dark ? 0.9 : 0.85), child: Column(children: rows)),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(footer!, style: TypeScale.caption.copyWith(color: p.ink3)),
            ),
        ],
      ),
    );
  }
}

class Row2 extends StatelessWidget {
  const Row2({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.danger = false,
    this.chevron,
  });

  final String title;
  final String? subtitle;
  final String? value;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool danger;
  final bool? chevron;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final showChevron = chevron ?? (onTap != null && trailing == null);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: TypeScale.settingsRow.copyWith(color: danger ? Palette.danger : p.ink)),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle!, style: TypeScale.small.copyWith(color: p.ink2), maxLines: 3, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                ),
              ),
              if (value != null)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(value!, style: TypeScale.settingsRow.copyWith(color: p.ink2), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end),
                  ),
                ),
              ?trailing,
              if (showChevron) Padding(padding: const EdgeInsets.only(left: 4), child: Ico(AppIcon.forward, size: 18, color: p.ink3)),
            ],
          ),
        ),
      ),
    );
  }
}

class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.title, required this.value, required this.onChanged, this.subtitle, this.leading});

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Row2(
      title: title,
      subtitle: subtitle,
      leading: leading,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

/// A leading icon in a soft tinted square, for settings rows.
class RowIcon extends StatelessWidget {
  const RowIcon(this.icon, {super.key, this.color});

  final AppIcon icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? context.p.accent;
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: tint.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
      child: Ico(icon, size: 18, color: tint),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.body, this.action});

  final AppIcon icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: p.bubble, shape: BoxShape.circle),
              child: Ico(icon, size: 28, color: p.ink3),
            ),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
            if (body != null) ...[
              const SizedBox(height: 6),
              Text(body!, textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink2)),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class SheetTitle extends StatelessWidget {
  const SheetTitle(this.title, {super.key, this.leading, this.trailing});

  final String title;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: NavigationToolbar(
        leading: leading,
        middle: Text(title, style: TypeScale.headerTitle.copyWith(color: context.p.ink)),
        trailing: trailing,
      ),
    );
  }
}

/// Text field with the app's look.
class Field extends StatelessWidget {
  const Field({
    super.key,
    this.controller,
    this.hint,
    this.label,
    this.obscure = false,
    this.maxLines = 1,
    this.minLines,
    this.autofocus = false,
    this.onSubmitted,
    this.onChanged,
    this.keyboardType,
    this.mono = false,
    this.textInputAction,
  });

  final TextEditingController? controller;
  final String? hint;
  final String? label;
  final bool obscure;
  final int? maxLines;
  final int? minLines;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;
  final bool mono;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final field = TextField(
      controller: controller,
      obscureText: obscure,
      maxLines: obscure ? 1 : maxLines,
      minLines: minLines,
      autofocus: autofocus,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      style: (mono ? TypeScale.mono.copyWith(fontSize: 14) : TypeScale.settingsRow).copyWith(color: p.ink),
      decoration: InputDecoration(hintText: hint),
    );
    if (label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(left: 4, bottom: 6), child: Text(label!, style: TypeScale.smallStrong.copyWith(color: p.ink2))),
        field,
      ],
    );
  }
}

/// A short message at the bottom of the screen.
void toast(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Row(children: [
      if (error) const Padding(padding: EdgeInsets.only(right: 8), child: Ico(AppIcon.alert, size: 18, color: Palette.danger)),
      Expanded(child: Text(message)),
    ]),
    duration: Duration(milliseconds: error ? 4000 : 2200),
  ));
}

/// Asks before something that cannot be undone. True when the user confirms.
Future<bool> confirmDanger(BuildContext context, {required String title, String? body, required String action}) async {
  final p = context.p;
  final result = await showGlassSheet<bool>(
    context,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: TypeScale.headerTitle.copyWith(color: p.ink), textAlign: TextAlign.center),
          if (body != null) ...[
            const SizedBox(height: 8),
            Text(body, style: TypeScale.small.copyWith(color: p.ink2), textAlign: TextAlign.center),
          ],
          const SizedBox(height: 20),
          Btn(action, kind: BtnKind.danger, expand: true, onTap: () => Navigator.pop(sheet, true)),
          const SizedBox(height: 8),
          Btn(t('Cancel'), kind: BtnKind.secondary, expand: true, onTap: () => Navigator.pop(sheet, false)),
        ],
      ),
    ),
  );
  return result ?? false;
}

class MenuAction {
  const MenuAction(this.label, this.icon, this.run, {this.danger = false});

  final String label;
  final AppIcon icon;
  final VoidCallback run;
  final bool danger;
}

/// A frosted action menu from the bottom, for long-press menus.
Future<void> showActions(BuildContext context, List<MenuAction> actions, {Widget? header}) {
  final p = context.p;
  return showGlassSheet<void>(
    context,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?header,
          for (final action in actions)
            InkWell(
              borderRadius: BorderRadius.circular(Radii.card),
              onTap: () {
                Navigator.pop(sheet);
                action.run();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                child: Row(children: [
                  Ico(action.icon, size: 22, color: action.danger ? Palette.danger : p.ink),
                  const SizedBox(width: 14),
                  Text(action.label, style: TypeScale.settingsRow.copyWith(color: action.danger ? Palette.danger : p.ink)),
                ]),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Segmented choice with a sliding thumb.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.values, required this.labels, required this.value, required this.onChanged});

  final List<T> values;
  final List<String> labels;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final index = values.indexOf(value).clamp(0, values.length - 1);
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth / values.length;
      return Container(
        height: 36,
        decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(10)),
        child: Stack(children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 320),
            curve: SpringCurve.shape,
            left: width * index + 2,
            top: 2,
            bottom: 2,
            width: width - 4,
            child: Container(decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(8), boxShadow: [BoxShadow(color: p.glassShadow, blurRadius: 4)])),
          ),
          Row(children: [
            for (final (i, label) in labels.indexed)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onChanged(values[i]);
                  },
                  child: Center(child: Text(label, style: TypeScale.smallStrong.copyWith(color: i == index ? p.ink : p.ink2))),
                ),
              ),
          ]),
        ]),
      );
    });
  }
}
