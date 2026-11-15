// The first-run flow: when the welcome page shows, how it leads to pairing, and
// the pairing page's own stages (refused link, handshake, connected check).
import 'dart:async';
import 'dart:io';

import 'package:dsbot_mobile/api/link_client.dart';
import 'package:dsbot_mobile/app/app.dart';
import 'package:dsbot_mobile/app/app_state.dart';
import 'package:dsbot_mobile/data/store.dart';
import 'package:dsbot_mobile/features/onboarding/welcome_page.dart';
import 'package:dsbot_mobile/features/pair/pair_page.dart';
import 'package:dsbot_mobile/link/link.dart';
import 'package:dsbot_mobile/shared/shared_data.dart';
import 'package:dsbot_mobile/ui/i18n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_link.dart';
import '../support/platform_mocks.dart';

String _pairLink({String name = 'Desk'}) {
  final keys = generateKeyPair();
  return pairingUri(PairingOffer(
    server: 'wss://bot.example/v1/link',
    hostDeviceId: deviceIdFor(keys.publicKey),
    hostKey: keys.publicKey,
    code: 'ABCD-1234',
    name: name,
  ));
}

Future<AppState> _load(WidgetTester tester, {Map<String, String>? kv, PairOpener? pair}) async {
  // Sessions never open, so nothing in a test reaches for the network.
  final never = Completer<LinkClient>();
  return (await tester.runAsync(() => AppState.load(
        kv: MemoryStore(kv),
        pairOpener: pair,
        sessionOpener: (computer, identity, {pairingCode}) => never.future,
      )))!;
}

Future<void> _pump(WidgetTester tester, AppState state, {bool reduce = true}) async {
  mockQuietPlatform(tester);
  tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: reduce);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(DsBotApp(state: state));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _end(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

const _welcomed = {'dsbot.prefs': '{"welcomed":"on"}'};

void main() {
  setUpAll(() {
    SharedData.fromJsonText(File('assets/shared/shared.json').readAsStringSync());
    I18n.loadText(File('assets/i18n/zh.json').readAsStringSync());
  });

  testWidgets('a fresh install opens on the welcome page, and Get started leads to pairing', (tester) async {
    final state = await _load(tester);
    expect(state.showWelcome, isTrue);
    await _pump(tester, state);
    await tester.pumpAndSettle();
    expect(find.byType(WelcomePage), findsOneWidget);
    expect(find.text('Welcome to DS Bot'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Get started'));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomePage), findsNothing);
    expect(find.byType(PairPage), findsOneWidget);
    expect(state.prefs.welcomed, isTrue);
    await _end(tester, state);
  });

  testWidgets('the welcome page shows once, and back from the first pairing opens it again', (tester) async {
    final state = await _load(tester, kv: _welcomed);
    expect(state.showWelcome, isFalse);
    await _pump(tester, state);
    await tester.pumpAndSettle();
    expect(find.byType(WelcomePage), findsNothing);
    expect(find.text('Connect your computer'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomePage), findsOneWidget);
    expect(state.prefs.welcomed, isFalse);
    await _end(tester, state);
  });

  testWidgets('the system back steps back through pairing instead of leaving the app', (tester) async {
    final state = await _load(tester, kv: _welcomed);
    await _pump(tester, state);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter link'));
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsOneWidget);

    // First back: the open field closes; the page stays.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsNothing);
    expect(find.byType(PairPage), findsOneWidget);

    // Next back: on a fresh install, back to the welcome page.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(WelcomePage), findsOneWidget);
    await _end(tester, state);
  });

  testWidgets('a pairing link skips the welcome page for good', (tester) async {
    final waiting = Completer<LinkClient>();
    final state = await _load(tester, pair: (candidate, identity, code) => waiting.future);
    state.openPairLink(_pairLink());
    await _pump(tester, state);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(WelcomePage), findsNothing);
    expect(find.text('Setting up an end-to-end encrypted link…'), findsOneWidget);
    expect(state.prefs.welcomed, isTrue);
    await _end(tester, state);
  });

  testWidgets('a link that is not a pairing code is refused with the reason', (tester) async {
    var opened = 0;
    final state = await _load(tester, kv: _welcomed, pair: (candidate, identity, code) async {
      opened++;
      return FakeLinkClient((endpoint, payload, state) => {});
    });
    await _pump(tester, state);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter link'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'https://example.com');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('This is not a DS Bot pairing code.'), findsOneWidget);
    expect(opened, 0);
    expect(state.computers.computers, isEmpty);
    await _end(tester, state);
  });

  testWidgets('pairing plays the connected check before the computer is saved', (tester) async {
    var opened = 0;
    final state = await _load(tester, kv: _welcomed, pair: (candidate, identity, code) async {
      opened++;
      expect(code, 'ABCD-1234');
      return FakeLinkClient((endpoint, payload, state) => {});
    });
    await _pump(tester, state);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter link'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), _pairLink(name: 'Studio'));
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(opened, 1);
    expect(find.text('Connected to Studio'), findsOneWidget);
    expect(state.computers.computers, isEmpty, reason: 'saved only after the check has played');

    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.computers.computers.map((computer) => computer.name), ['Studio']);
    expect(state.session, isNotNull);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(PairPage), findsNothing);
    await _end(tester, state);
  });

  testWidgets('with motion on, the welcome scene keeps animating until it leaves', (tester) async {
    final state = await _load(tester);
    await _pump(tester, state, reduce: false);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(find.text('Welcome to DS Bot'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Get started'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(WelcomePage), findsNothing);
    expect(find.byType(PairPage), findsOneWidget);
    await _end(tester, state);
  });
}
