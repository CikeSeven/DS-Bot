import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// No deep links, no gyroscope and no network changes in a test; the app must cope with silence.
void mockQuietPlatform(WidgetTester tester) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/messages'), (call) async => null);
  messenger.setMockStreamHandler(const EventChannel('com.llfbandit.app_links/events'), MockStreamHandler.inline(onListen: (_, _) {}));
  messenger.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/sensors/method'), (call) async => null);
  messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/sensors/gyroscope'), MockStreamHandler.inline(onListen: (_, _) {}));
  messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'), MockStreamHandler.inline(onListen: (_, _) {}));
}
