// Renders the main screens in demo mode to build/screenshots/*.png for a visual
// check. Needs a CJK font on this machine; skipped without one.
//   flutter test --tags screenshot test/screens/screenshot_test.dart
@Tags(['screenshot'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsbot_mobile/app/app.dart';
import 'package:dsbot_mobile/app/app_state.dart';
import 'package:dsbot_mobile/data/store.dart';
import 'package:dsbot_mobile/shared/shared_data.dart';
import 'package:dsbot_mobile/ui/i18n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _fontPaths = [
  '/usr/share/fonts/harmonyos-sans/HarmonyOS_Sans_SC.ttf',
  '/usr/share/fonts/noto/NotoSans-Regular.ttf',
];

Future<bool> _loadFonts() async {
  final path = _fontPaths.where((path) => File(path).existsSync()).firstOrNull;
  if (path == null) return false;
  final bytes = File(path).readAsBytesSync();
  for (final family in ['Roboto', '.SF UI Text', 'sans-serif', 'HarmonyOS']) {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }
  final mono = File('/usr/share/fonts/noto/NotoSansMono-Regular.ttf');
  if (mono.existsSync()) {
    final loader = FontLoader('monospace')..addFont(Future.value(ByteData.sublistView(mono.readAsBytesSync())));
    await loader.load();
  }
  return true;
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pump(const Duration(milliseconds: 600));
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/screenshots/$name.png')..createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void main() {
  testWidgets('demo screens', (tester) async {
    final fonts = await tester.runAsync(_loadFonts) ?? false;
    if (!fonts) {
      markTestSkipped('No CJK font found');
      return;
    }
    SharedData.fromJsonText(File('assets/shared/shared.json').readAsStringSync());
    I18n.loadText(File('assets/i18n/zh.json').readAsStringSync());
    final demo = jsonDecode(File('assets/demo/team.json').readAsStringSync()) as Map<String, dynamic>;
    final dark = Platform.environment['SHOT_DARK'] == '1';
    final kv = MemoryStore({
      'dsbot.prefs': jsonEncode({'lang': 'zh', 'theme': dark ? 'dark' : 'light'}),
    });
    final state = (await tester.runAsync(() => AppState.load(kv: kv, demoData: demo)))!;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    tester.view.padding = const FakeViewPadding(top: 63, bottom: 42);
    tester.view.viewPadding = const FakeViewPadding(top: 63, bottom: 42);
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: DsBotApp(state: state)));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final suffix = dark ? '-dark' : '';
    await _shot(tester, key, '01-team$suffix');

    await tester.tap(find.text('Writer').first);
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _shot(tester, key, '02-chat-bot$suffix');
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 600));

    final group = find.textContaining('Launch');
    if (group.evaluate().isNotEmpty) {
      await tester.tap(group.first);
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await _shot(tester, key, '03-chat-group$suffix');
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 600));
    }

    await tester.tap(find.text(t('Inbox')).last);
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _shot(tester, key, '04-inbox$suffix');

    await tester.tap(find.text(t('Settings')).last);
    await tester.pump(const Duration(milliseconds: 800));
    await _shot(tester, key, '05-settings$suffix');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async => state.dispose());
    await tester.pump(const Duration(seconds: 1));
  });
}
