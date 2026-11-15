// "Keep connected in the background": an Android foreground service keeps the
// app's process alive, so the live link goes on delivering notices. If the app's
// own isolate is gone (swiped away), the service holds a link of its own until
// the app comes back; one device id has one link at the Relay, so the service
// steps aside whenever the app's isolate is alive.
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../api/link_client.dart';
import '../app/platform.dart';
import '../data/store.dart';
import '../data/team_session.dart';
import '../shared/shared_data.dart';
import '../ui/i18n.dart';
import 'notifier.dart';

class LinkService {
  static bool get supported => Platform.isAndroid;

  static void _init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: serviceChannelId,
        channelName: t('Connection'),
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: false,
        allowWakeLock: true,
      ),
    );
  }

  /// Starts the service while the app is on screen (Android refuses a start
  /// from the background).
  static Future<void> start(String computerName) async {
    if (!supported) return;
    _init();
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.remoteMessaging],
      notificationTitle: 'DS Bot',
      notificationText: t('Connected to {name}', {'name': computerName}),
      callback: startLinkTask,
    );
  }

  static Future<void> stop() async {
    if (!supported) return;
    if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
  }

  static Future<bool> needsBatteryException() async =>
      supported && !(await FlutterForegroundTask.isIgnoringBatteryOptimizations);

  static Future<void> askBatteryException() async {
    if (supported) await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }
}

@pragma('vm:entry-point')
void startLinkTask() => FlutterForegroundTask.setTaskHandler(_LinkTaskHandler());

class _LinkTaskHandler extends TaskHandler {
  TeamSession? _session;
  bool _starting = false;

  bool get _appAlive => IsolateNameServer.lookupPortByName(mainPortName) != null;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    try {
      await SharedData.load();
      await I18n.load();
    } on Object {
      // Copy falls back to English.
    }
    await Notifier.instance.init(background: true);
    Notifier.instance.foreground = false;
    await _check();
  }

  @override
  void onRepeatEvent(DateTime timestamp) => unawaited(_check());

  Future<void> _check() async {
    if (_appAlive) {
      final session = _session;
      _session = null;
      if (session != null) {
        Notifier.instance.attach(null);
        await session.stop();
        session.dispose();
      }
      return;
    }
    if (_session != null || _starting) return;
    _starting = true;
    try {
      final store = PhoneStore(SecureKeyValueStore());
      final computer = (await store.listComputers()).active;
      if (computer == null) return;
      final identity = await store.loadIdentity();
      final name = await phoneName();
      final session = TeamSession(
        computer: computer,
        identity: identity,
        pollEvery: const Duration(minutes: 5),
        open: (computer, identity, {pairingCode}) => RelayLinkClient.open(computer, identity, phoneName: name),
      );
      _session = session;
      Notifier.instance.attach(session);
      session.start();
    } finally {
      _starting = false;
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    final session = _session;
    _session = null;
    Notifier.instance.attach(null);
    await session?.stop();
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}
