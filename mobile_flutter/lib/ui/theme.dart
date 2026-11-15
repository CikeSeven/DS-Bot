// The phone palette derives from the same eight theme colors as the desktop team
// UI (ds-bot/src/client/themes.js); type, radius, spacing and springs follow
// docs/design/ui-standard.md and the RN app's tokens.
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../shared/shared_data.dart';

const _darkInk = Color(0xFF141414);

/// Text on the accent: near-black or white, whichever has the higher contrast.
Color accentInkFor(Color accent) =>
    (luminance(accent) + 0.05) * (luminance(accent) + 0.05) > 1.05 * (luminance(_darkInk) + 0.05) ? _darkInk : Colors.white;

@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.dark,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.bubble,
    required this.sidebar,
    required this.main,
    required this.card,
    required this.line,
    required this.line2,
    required this.hover,
    required this.active,
    required this.accent,
    required this.accentInk,
    required this.user,
    required this.userInk,
    required this.tagBg,
    required this.tagInk,
  });

  factory Palette.of({required bool dark, String? themeId, String? accent, SharedData? data}) {
    final shared = data ?? SharedData.instance;
    final theme = shared.theme(themeId);
    final mode = dark ? theme.dark : theme.light;
    var use = mode.accent;
    if (accent != null && isHex(accent)) {
      // A preset accent is saved as its light value; in dark mode it takes the
      // preset's dark value, like Bot names. A custom accent is the same in both.
      use = parseHex(accent);
      if (dark) {
        for (final id in shared.accentInks) {
          final ink = shared.inks[id];
          if (ink != null && ink[0] == use) use = ink[1];
        }
      }
    }
    final text = mode.text;
    return Palette(
      dark: dark,
      ink: text,
      ink2: text.withValues(alpha: 0.6),
      ink3: text.withValues(alpha: 0.36),
      bubble: mode.bubble,
      sidebar: mode.sidebar,
      main: mode.bg,
      card: mode.card,
      line: text.withValues(alpha: 0.08),
      line2: text.withValues(alpha: 0.15),
      hover: dark ? const Color(0x1FA0A0A0) : const Color(0x17777777),
      active: dark ? const Color(0x33A0A0A0) : const Color(0x2B777777),
      accent: use,
      accentInk: accentInkFor(use),
      user: mode.user,
      userInk: mode.userText,
      tagBg: text.withValues(alpha: dark ? 0.09 : 0.06),
      tagInk: text.withValues(alpha: 0.58),
    );
  }

  final bool dark;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color bubble;
  final Color sidebar;
  final Color main;
  final Color card;
  final Color line;
  final Color line2;
  final Color hover;
  final Color active;
  final Color accent;
  final Color accentInk;
  final Color user;
  final Color userInk;
  final Color tagBg;
  final Color tagInk;

  static const danger = Color(0xFFE02135);
  static const green = Color(0xFF00C972);
  static const star = Color(0xFFFF9800);
  static const waiting = Color(0xFF4D6BFE);

  /// The tint under frosted glass: the page color, mostly opaque so text on
  /// glass stays readable over anything that scrolls beneath.
  Color get glass => main.withValues(alpha: dark ? 0.72 : 0.68);
  Color get glassEdge => dark ? Colors.white.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.7);
  Color get glassShadow => Colors.black.withValues(alpha: dark ? 0.35 : 0.08);

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(Palette? other, double t) => t < 0.5 || other == null ? this : other;
}

extension PaletteContext on BuildContext {
  Palette get p => Theme.of(this).extension<Palette>()!;
}

/// The phone type scale: settled sizes for touch, weights only 400/500/600.
abstract final class TypeScale {
  static const rowName = TextStyle(fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w400);
  static const rowNameStrong = TextStyle(fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w500);
  static const rowPreview = TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w400);
  static const bubble = TextStyle(fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w400);
  static const headerTitle = TextStyle(fontSize: 17, height: 24 / 17, fontWeight: FontWeight.w600);
  static const largeTitle = TextStyle(fontSize: 28, height: 34 / 28, fontWeight: FontWeight.w600);
  static const sectionTitle = TextStyle(fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w600);
  static const settingsRow = TextStyle(fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w400);
  static const small = TextStyle(fontSize: 13, height: 18 / 13, fontWeight: FontWeight.w400);
  static const smallStrong = TextStyle(fontSize: 13, height: 18 / 13, fontWeight: FontWeight.w500);
  static const caption = TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w400);
  static const mono = TextStyle(fontSize: 13, height: 19 / 13, fontFamily: 'monospace');
}

abstract final class Radii {
  static const tag = 4.0;
  static const item = 6.0;
  static const input = 8.0;
  static const row = 10.0;
  static const card = 12.0;
  static const option = 12.0;
  static const dialog = 16.0;
  static const bubble = 18.0;
  static const sheet = 24.0;
  static const composer = 22.0;
  static const pill = 999.0;
}

abstract final class Space {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
}

/// The standard's springs as (angular frequency, damping ratio), mass 1.
abstract final class Springs {
  static SpringDescription of(double w, double z) => SpringDescription(mass: 1, stiffness: w * w, damping: 2 * z * w);
  static final shape = of(20, 0.78);
  static final tap = of(30, 0.8);
  static final list = of(22, 0.8);
  static final stretch = of(18, 0.56);
  static final pop = of(22, 0.49);
}

/// A curve that follows a spring from 0 to 1, for implicit animations.
class SpringCurve extends Curve {
  const SpringCurve(this.w, this.z);

  final double w;
  final double z;

  static const shape = SpringCurve(20, 0.78);
  static const pop = SpringCurve(22, 0.49);
  static const tap = SpringCurve(30, 0.8);

  @override
  double transformInternal(double t) {
    final simulation = SpringSimulation(Springs.of(w, z), 0, 1, 0);
    // The curve's unit time maps onto the spring's settle time.
    return simulation.x(t * _settle);
  }

  double get _settle => 4.6 / (z * w);
}

ThemeData buildTheme(Palette p) {
  final base = p.dark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
  final scheme = ColorScheme.fromSeed(
    seedColor: p.accent,
    brightness: p.dark ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: p.accent,
    onPrimary: p.accentInk,
    surface: p.main,
    onSurface: p.ink,
    error: Palette.danger,
    outline: p.line2,
    outlineVariant: p.line,
  );
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: p.main,
    canvasColor: p.main,
    dividerColor: p.line,
    splashFactory: InkSparkle.splashFactory,
    highlightColor: p.hover,
    splashColor: p.active,
    textTheme: base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink),
    iconTheme: IconThemeData(color: p.ink2, size: 20),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withValues(alpha: 0.25),
      selectionHandleColor: p.accent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.bubble.withValues(alpha: 0.6),
      hintStyle: TypeScale.settingsRow.copyWith(color: p.ink3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.card), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        borderSide: BorderSide(color: p.accent.withValues(alpha: 0.6)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? Palette.green : p.line2),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.user,
      contentTextStyle: TypeScale.small.copyWith(color: p.userInk),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.card)),
    ),
    extensions: [p],
  );
}
