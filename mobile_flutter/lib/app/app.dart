import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../background/notifier.dart';
import '../background/wiring.dart';
import '../data/json.dart';
import '../features/home/home_shell.dart';
import '../features/onboarding/onboarding_flow.dart';
import '../features/pair/pair_page.dart';
import '../ui/glass.dart';
import '../ui/theme.dart';
import 'app_state.dart';

class DsBotApp extends StatefulWidget {
  const DsBotApp({super.key, required this.state});

  final AppState state;

  @override
  State<DsBotApp> createState() => _DsBotAppState();
}

class _DsBotAppState extends State<DsBotApp> with WidgetsBindingObserver {
  StreamSubscription<Uri>? _links;
  StreamSubscription<List<ConnectivityResult>>? _network;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.state.demo == null) {
      unawaited(_listenLinks());
      _listenNetwork();
    }
  }

  /// On a new network the old socket is bound to the old one: the link dials
  /// again at once instead of waiting for its probe to time out. The first
  /// event only names the network the app started on.
  void _listenNetwork() {
    var first = true;
    _network = Connectivity().onConnectivityChanged.listen((_) {
      if (!first) widget.state.networkChanged();
      first = false;
    }, onError: (Object _) {});
  }

  Future<void> _listenLinks() async {
    final links = AppLinks();
    void take(Uri? uri) {
      final text = uri?.toString();
      if (text != null && text.startsWith('dsbot://pair')) widget.state.openPairLink(text);
    }

    try {
      take(await links.getInitialLink());
    } on Object {
      // No launch link.
    }
    _links = links.uriLinkStream.listen(take, onError: (Object _) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    widget.state.setForeground(foreground);
    Notifier.instance.foreground = foreground;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_links?.cancel());
    unawaited(_network?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final state = widget.state;
          final session = state.session;
          return ListenableBuilder(
            listenable: session ?? state,
            builder: (context, _) {
              final prefs = jMap(session?.team?.raw, 'prefs');
              final themeId = jStr(prefs, 'theme');
              final accent = jStr(prefs, 'accent');
              final light = Palette.of(dark: false, themeId: themeId, accent: accent);
              final dark = Palette.of(dark: true, themeId: themeId, accent: accent);
              return MaterialApp(
                navigatorKey: navigatorKey,
                title: 'DS Bot',
                debugShowCheckedModeBanner: false,
                themeMode: state.prefs.themeMode,
                theme: buildTheme(light),
                darkTheme: buildTheme(dark),
                // A language change rebuilds every screen with the new copy.
                key: ValueKey(state.prefs.lang),
                // The team session sits above the Navigator, so every pushed page
                // (chats, details, settings) reads the same live session.
                builder: (context, child) {
                  final p = context.p;
                  final scoped = session == null ? child! : TeamScope(session: session, child: child!);
                  return AnnotatedRegion<SystemUiOverlayStyle>(
                    value: (p.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
                      statusBarColor: Colors.transparent,
                      systemNavigationBarColor: Colors.transparent,
                      systemNavigationBarContrastEnforced: false,
                    ),
                    child: GlassScope(enabled: state.prefs.glass, child: scoped),
                  );
                },
                home: _Root(state: state),
              );
            },
          );
        },
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final session = state.session;
    final Widget page;
    if (session == null || state.pendingPairLink != null) {
      final fresh = session == null && state.computers.computers.isEmpty;
      page = OnboardingFlow(
        key: const ValueKey('onboarding'),
        welcome: state.showWelcome,
        onEnter: state.finishWelcome,
        pair: PairPage(
          initialLink: state.pendingPairLink,
          canCancel: session != null,
          onBack: fresh ? state.reopenWelcome : null,
        ),
      );
    } else {
      page = HomeShell(key: ValueKey(session.computer.hostDeviceId));
    }
    // The team fades in over the pairing page, which stays opaque underneath:
    // its glass must not sit in a fading layer.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) =>
          child.key == const ValueKey('onboarding') ? child : FadeTransition(opacity: animation, child: child),
      child: page,
    );
  }
}
