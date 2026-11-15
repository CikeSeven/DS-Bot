// Connects the app to notifications and the background service.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app/app_state.dart';
import 'link_service.dart';
import 'notifier.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> wireBackground(AppState state) async {
  final notifier = Notifier.instance;
  try {
    await notifier.init();
  } on Object {
    // No notifications on this device; the app works without them.
    return;
  }
  void follow() => notifier.attach(state.session);
  follow();
  state.addListener(follow);
  AppState.onKeepConnectedChanged = (on) async {
    if (on) {
      await notifier.requestPermission();
      final computer = state.computer;
      if (computer != null) await LinkService.start(state.session?.hostName ?? computer.name);
      if (await LinkService.needsBatteryException()) await LinkService.askBatteryException();
    } else {
      await LinkService.stop();
    }
  };
  if (state.prefs.keepConnected && state.computer != null) {
    unawaited(LinkService.start(state.computer!.name));
  }
}
