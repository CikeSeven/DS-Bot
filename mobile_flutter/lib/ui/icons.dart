// DS Bot's own line icons for the phone: a 24-unit grid, 1.7 strokes, round caps.
// Drawn for this app; no icon font or third-party set.
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum AppIcon {
  back('<path d="M15 5l-7 7 7 7"/>'),
  forward('<path d="M9 5l7 7-7 7"/>'),
  down('<path d="M6 9l6 6 6-6"/>'),
  up('<path d="M6 15l6-6 6 6"/>'),
  menu('<rect x="3.5" y="5" width="17" height="14" rx="3"/><path d="M9.5 5v14"/>'),
  search('<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>'),
  plus('<path d="M12 5v14M5 12h14"/>'),
  close('<path d="M6 6l12 12M18 6L6 18"/>'),
  check('<path d="M5 12.5l4.5 4.5L19 7.5"/>'),
  send('<path d="M12 19V6M6.5 11.5L12 6l5.5 5.5"/>'),
  stop('<rect x="7" y="7" width="10" height="10" rx="2.2" fill="#000" stroke="none"/>'),
  gear('<circle cx="12" cy="12" r="3"/><path d="M12 3.5v2.2M12 18.3v2.2M20.5 12h-2.2M5.7 12H3.5M18 6l-1.6 1.6M7.6 16.4L6 18M18 18l-1.6-1.6M7.6 7.6L6 6"/>'),
  people('<circle cx="9" cy="8.5" r="3.2"/><path d="M3.5 19c.6-3.3 2.8-5.2 5.5-5.2s4.9 1.9 5.5 5.2"/><path d="M15.5 5.6a3 3 0 010 5.8M17.5 14c1.6.7 2.6 2.4 3 5"/>'),
  pin('<path d="M9 4h6l-1 5 3 3v1.5H7V12l3-3z"/><path d="M12 13.5V20"/>'),
  unpin('<path d="M9 4h6l-1 5 3 3v1.5H7V12l3-3z"/><path d="M12 13.5V20M4 4l16 16"/>'),
  eye('<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>'),
  eyeOff('<path d="M4 4l16 16M10 6c.6-.2 1.3-.5 2-.5 6 0 9.5 6.5 9.5 6.5a17 17 0 01-2.7 3.4M6.6 7.1C4 8.7 2.5 12 2.5 12S6 18.5 12 18.5c1.6 0 3-.5 4.2-1.1"/><path d="M9.9 9.9a3 3 0 004.2 4.2"/>'),
  bell('<path d="M6 16.5V11a6 6 0 0112 0v5.5l1.5 2H4.5z"/><path d="M10 20.5a2 2 0 004 0"/>'),
  inbox('<path d="M4 13.5l2.5-8h11l2.5 8v5H4z"/><path d="M4 13.5h4.5l1 2h5l1-2H20"/>'),
  memory('<path d="M7 4.5h10a1.5 1.5 0 011.5 1.5v14l-6.5-3.8L5.5 20V6A1.5 1.5 0 017 4.5z"/>'),
  clock('<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>'),
  folder('<path d="M3.5 7a2 2 0 012-2h4l2 2.2h7a2 2 0 012 2V17a2 2 0 01-2 2h-13a2 2 0 01-2-2z"/>'),
  chart('<path d="M4.5 19.5h15M7.5 16v-5M12 16V7M16.5 16v-8"/>'),
  globe('<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.4 2.3 3.5 5.3 3.5 8.5s-1.1 6.2-3.5 8.5c-2.4-2.3-3.5-5.3-3.5-8.5S9.6 5.8 12 3.5z"/>'),
  monitor('<rect x="3.5" y="4.5" width="17" height="11.5" rx="2"/><path d="M9 20h6M12 16v4"/>'),
  key('<circle cx="8.5" cy="15.5" r="4"/><path d="M11.4 12.6L19.5 4.5M16 8l2.5 2.5M14 10l2 2"/>'),
  plug('<path d="M9 3.5v4M15 3.5v4M6.5 7.5h11V11a5.5 5.5 0 01-11 0zM12 16.5v4"/>'),
  puzzle('<path d="M10 4.5a2 2 0 014 0V6h4v4h-1.5a2 2 0 000 4H18v4.5h-4V17a2 2 0 00-4 0v1.5H6V14h1.5a2 2 0 000-4H6V6h4z"/>'),
  model('<rect x="6.5" y="6.5" width="11" height="11" rx="2"/><path d="M9.5 3.5v3M14.5 3.5v3M9.5 17.5v3M14.5 17.5v3M3.5 9.5h3M3.5 14.5h3M17.5 9.5h3M17.5 14.5h3"/>'),
  image('<rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><circle cx="9" cy="10" r="1.8"/><path d="M4 17.5l5-4.5 3.5 3 3-2.5 4.5 4"/>'),
  clip('<path d="M19 11.5l-7.2 7.2a4.5 4.5 0 01-6.4-6.4l7.7-7.7a3 3 0 014.2 4.2l-7.5 7.5a1.5 1.5 0 01-2.1-2.1l6.7-6.7"/>'),
  camera('<path d="M4 8a2 2 0 012-2h2l1.5-2h5L16 6h2a2 2 0 012 2v9.5a2 2 0 01-2 2H6a2 2 0 01-2-2z"/><circle cx="12" cy="12.5" r="3.5"/>'),
  copy('<rect x="8.5" y="8.5" width="11" height="11" rx="2.2"/><path d="M15.5 8.5V6.2a1.7 1.7 0 00-1.7-1.7H6.2a1.7 1.7 0 00-1.7 1.7v7.6c0 .9.8 1.7 1.7 1.7h2.3"/>'),
  share('<path d="M12 15V4M7.5 8.5L12 4l4.5 4.5"/><path d="M5 12.5v5.5a2 2 0 002 2h10a2 2 0 002-2v-5.5"/>'),
  download('<path d="M12 4v11M7.5 10.5L12 15l4.5-4.5M5 19.5h14"/>'),
  trash('<path d="M4.5 7h15M9.5 7V5a1 1 0 011-1h3a1 1 0 011 1v2M6.5 7l1 12a1.5 1.5 0 001.5 1.4h6a1.5 1.5 0 001.5-1.4l1-12"/>'),
  edit('<path d="M4.5 19.5l1-4.2L15.8 5a2 2 0 012.8 0l.4.4a2 2 0 010 2.8L8.7 18.5z"/><path d="M13.5 7.3l3.2 3.2"/>'),
  refresh('<path d="M19.5 12a7.5 7.5 0 11-2.2-5.3M19.5 4.5v4h-4"/>'),
  more('<circle cx="6" cy="12" r="1.3" fill="#000" stroke="none"/><circle cx="12" cy="12" r="1.3" fill="#000" stroke="none"/><circle cx="18" cy="12" r="1.3" fill="#000" stroke="none"/>'),
  star('<path d="M12 4l2.4 4.9 5.4.8-3.9 3.8.9 5.4L12 16.4l-4.8 2.5.9-5.4-3.9-3.8 5.4-.8z"/>'),
  question('<circle cx="12" cy="12" r="8.5"/><path d="M9.6 9.5a2.5 2.5 0 014.8 1c0 1.7-2.4 2.2-2.4 3.7"/><circle cx="12" cy="17" r=".6" fill="#000"/>'),
  alert('<path d="M12 4l9 15.5H3z"/><path d="M12 10v4.5"/><circle cx="12" cy="17" r=".6" fill="#000"/>'),
  shield('<path d="M12 3.5l7 2.8v5.2c0 4.3-2.9 7.6-7 9-4.1-1.4-7-4.7-7-9V6.3z"/><path d="M9 12l2.2 2.2L15.5 10"/>'),
  sparkle('<path d="M12 3.5l1.8 5 5 1.8-5 1.8-1.8 5-1.8-5-5-1.8 5-1.8z"/><path d="M18.5 16l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z"/>'),
  chat('<path d="M5 5.5h14a1.5 1.5 0 011.5 1.5v8.5A1.5 1.5 0 0119 17h-7l-4.5 3.5V17H5a1.5 1.5 0 01-1.5-1.5V7A1.5 1.5 0 015 5.5z"/>'),
  board('<rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M9.5 4.5v15M15 4.5v15M5.5 8h2M11 8h2M11 11h2M16.5 8h2"/>'),
  diff('<path d="M7 4v11M3.5 7.5H10.5"/><circle cx="17" cy="16.5" r="3"/><path d="M17 4v9.5M14 20h-3.5"/>'),
  target('<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="4.5"/><circle cx="12" cy="12" r="1" fill="#000"/>'),
  bolt('<path d="M13 3.5L5.5 13.5H12l-1 7 7.5-10H12z"/>'),
  mail('<rect x="3.5" y="5.5" width="17" height="13" rx="2"/><path d="M4 7l8 6 8-6"/>'),
  phone('<rect x="7" y="3" width="10" height="18" rx="2.5"/><path d="M10.5 18h3"/>'),
  qr('<rect x="4" y="4" width="6" height="6" rx="1"/><rect x="14" y="4" width="6" height="6" rx="1"/><rect x="4" y="14" width="6" height="6" rx="1"/><path d="M14 14h2.5v2.5H14zM18 18h2v2h-2zM14 19.5h1.5M19.5 14v1.5"/>'),
  sun('<circle cx="12" cy="12" r="3.8"/><path d="M12 3.5v2M12 18.5v2M3.5 12h2M18.5 12h2M6 6l1.4 1.4M16.6 16.6L18 18M6 18l1.4-1.4M16.6 7.4L18 6"/>'),
  language('<path d="M4.5 6h9M9 4v2M6.5 6c.5 3.5 2.5 6 6 7.5M11.5 6c-.5 3.3-2.5 6-6.5 8"/><path d="M13 20l3.5-8.5L20 20M14.2 17.2h4.6"/>'),
  lock('<rect x="5" y="10.5" width="14" height="10" rx="2"/><path d="M8 10.5V8a4 4 0 018 0v2.5"/>'),
  unlink('<path d="M9.5 14.5l5-5M8 11L5.8 13.2a3.5 3.5 0 005 5L13 16M16 13l2.2-2.2a3.5 3.5 0 00-5-5L11 8M4 4l16 16"/>'),
  quote('<path d="M5 17c0-4 1.5-7 4.5-8.5M14 17c0-4 1.5-7 4.5-8.5"/><circle cx="7" cy="15.5" r="2" fill="#000"/><circle cx="16" cy="15.5" r="2" fill="#000"/>'),
  play('<path d="M8 5.5v13l10.5-6.5z"/>'),
  pause('<path d="M8.5 5.5v13M15.5 5.5v13"/>'),
  arrowDown('<path d="M12 5v14M6 13l6 6 6-6"/>'),
  layers('<path d="M12 4l8.5 4.5L12 13 3.5 8.5z"/><path d="M3.5 12.5L12 17l8.5-4.5M3.5 16.5L12 21l8.5-4.5"/>'),
  history('<path d="M4.5 12a7.5 7.5 0 102.2-5.3M4.5 4.5v4h4"/><path d="M12 8v4.5l3 1.8"/>'),
  // A message taken back: an arrow that turns round to where it came from.
  recall('<path d="M9 5.5L5.5 9 9 12.5"/><path d="M5.5 9h8.5a4.75 4.75 0 010 9.5H11"/>'),
  tools('<path d="M14.5 6.5a3.5 3.5 0 004.7 4.3L20 11.6l-8.4 8.4a2 2 0 01-2.8-2.8l8.4-8.4-.8-.8a3.5 3.5 0 01-4.3-4.7l2.4 2.4 1.8-.2.2-1.8z"/>'),
  brain('<path d="M9.5 4.5a3 3 0 00-3 3 3 3 0 00-2 5 3 3 0 002 5 3 3 0 003 2.5h1V4.5zM14.5 4.5a3 3 0 013 3 3 3 0 012 5 3 3 0 01-2 5 3 3 0 01-3 2.5h-1V4.5z"/>'),
  section('<path d="M4 6h16M4 12h10M4 18h13"/>'),
  swipe('<path d="M4.5 9h11M12 5.5L15.5 9 12 12.5M19.5 15h-11M12 11.5L8.5 15l3.5 3.5"/>'),
  at('<circle cx="12" cy="12" r="3.5"/><path d="M15.5 12v1.5a2.5 2.5 0 005 0V12a8.5 8.5 0 10-3.5 6.9"/>');

  const AppIcon(this.markup);

  final String markup;

  String get svg =>
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">$markup</svg>';
}

class Ico extends StatelessWidget {
  const Ico(this.icon, {super.key, this.size = 22, this.color});

  final AppIcon icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final paint = color ?? IconTheme.of(context).color ?? const Color(0xFF808080);
    return SizedBox.square(
      dimension: size,
      child: SvgPicture.string(icon.svg, width: size, height: size, colorFilter: ColorFilter.mode(paint, BlendMode.srcIn)),
    );
  }
}
