import 'dart:io';

import 'package:dsbot_mobile/app/app_state.dart';
import 'package:dsbot_mobile/data/chat_session.dart';
import 'package:dsbot_mobile/data/team_session.dart';
import 'package:dsbot_mobile/features/chat/chat_item_view.dart';
import 'package:dsbot_mobile/features/chat/media.dart';
import 'package:dsbot_mobile/shared/shared_data.dart';
import 'package:dsbot_mobile/ui/i18n.dart';
import 'package:dsbot_mobile/ui/markdown.dart';
import 'package:dsbot_mobile/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_link.dart';

const _teamRaw = <String, Object?>{
  'revision': 1,
  'bots': [
    {'id': 'b-chief', 'name': 'Chief', 'sessionId': 's-chief'},
  ],
  'rooms': <Object?>[],
};

// One transparent pixel.
const _pixel = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

const _reply = {
  'kind': 'bot',
  'seq': 8,
  'time': 1,
  'text': 'Sales went up.\n\n![Sales by month](<charts/sales.png>)\n\nThe report is attached.',
  'files': [
    {'name': 'trend.png', 'sessionId': 's-chief-1', 'seq': 9, 'index': 0},
    {'name': 'report.pdf', 'sessionId': 's-chief-1', 'seq': 9, 'index': 1},
  ],
};

// A reply that names a picture by a file: URL on the computer.
const _fileUrlReply = {'kind': 'bot', 'seq': 10, 'time': 2, 'text': 'Here it is:\n\n![Plot](file:///home/me/out/plot.png)'};


Widget _page(Widget body) => MaterialApp(theme: buildTheme(Palette.of(dark: false)), home: Scaffold(body: body));

Widget _host(Widget child, TeamSession session) => TeamScope(
      session: session,
      child: MaterialApp(
        theme: buildTheme(Palette.of(dark: false)),
        home: Scaffold(body: Center(child: SizedBox(width: 380, child: child))),
      ),
    );

void main() {
  setUpAll(() {
    SharedData.fromJsonText(File('assets/shared/shared.json').readAsStringSync());
    I18n.pref = LangPref.en;
  });

  testWidgets('a run of images in a paragraph goes to the caller between the text around it', (tester) async {
    final runs = <List<MarkdownImage>>[];
    Widget? draw(List<MarkdownImage> images) {
      runs.add(images);
      return Text('drawn ${images.map((image) => image.src).join(' ')}');
    }

    Widget page(Widget body) => MaterialApp(theme: buildTheme(Palette.of(dark: false)), home: Scaffold(body: body));

    await tester.pumpWidget(page(MarkdownText('Before ![a](one.png) ![b](two.png) after\n\n![c](https://example.com/c.png)', images: draw)));
    expect(runs.map((run) => run.map((image) => image.alt).join()), ['ab', 'c']);
    expect(find.text('drawn one.png two.png'), findsOneWidget);
    expect(find.text('drawn https://example.com/c.png'), findsOneWidget);
    expect(find.textContaining('Before', findRichText: true), findsOneWidget);
    expect(find.textContaining('after', findRichText: true), findsOneWidget);

    await tester.pumpWidget(page(MarkdownText('See ![the chart](chart.png) here', images: (_) => null)));
    expect(find.textContaining('See the chart here', findRichText: true), findsOneWidget);
  });

  testWidgets('an <img> tag and a bare path with spaces are images too, but not in code', (tester) async {
    final drawn = <String>[];
    Widget? draw(List<MarkdownImage> images) {
      drawn.addAll(images.map((image) => '${image.alt}|${image.src}'));
      return const SizedBox();
    }

    await tester.pumpWidget(_page(MarkdownText(
      '![My chart](/home/me/my chart.png)\n\n<img src="out/plot.png" alt="Plot" width="320">\n\n`![x](a b.png)`\n\n```\n<img src="kept.png">\n```',
      images: draw,
    )));
    expect(drawn, ['My chart|/home/me/my%20chart.png', 'Plot|out/plot.png']);
    expect(find.textContaining('![x](a b.png)', findRichText: true), findsOneWidget);
    expect(find.textContaining('<img src="kept.png">'), findsOneWidget);
  });

  Future<(TeamSession, FakeLinkClient, List<Map<String, dynamic>>)> connect(WidgetTester tester, List<String> capabilities) async {
    final asked = <Map<String, dynamic>>[];
    final link = FakeLinkClient((endpoint, payload, state) async {
      switch (endpoint) {
        case 'hello':
          return ok(hello(capabilities: capabilities));
        case 'notices':
          return ok({'boot': 'b1', 'seq': 0, 'notices': <Object?>[]});
        case 'image':
          asked.add(payload);
          return ok({'mime': 'image/png', 'data': _pixel});
        default:
          return ok(_teamRaw);
      }
    });
    final session = TeamSession(
      computer: testComputer,
      identity: testIdentity,
      open: (computer, identity, {pairingCode}) async => link,
      pollEvery: const Duration(hours: 1),
    );
    await tester.runAsync(() async {
      session.start();
      await settle();
    });
    addTearDown(session.dispose);
    return (session, link, asked);
  }

  Widget reply(TeamSession session) => ChatItemView(
        row: const ChatRow(_reply, 'r8', null),
        team: session.team!,
        sessionId: 's-chief',
        inRoom: false,
        flat: false,
        botMax: 340,
        userMax: 320,
        onLongPress: (_) {},
      );

  testWidgets('a reply shows its Markdown image and its presented image, and keeps other files as cards', (tester) async {
    final (session, _, asked) = await connect(tester, ['images', 'image-preview', 'shown-images']);
    await tester.pumpWidget(_host(reply(session), session));
    await tester.runAsync(() => settle());
    await tester.pump();

    expect(asked, containsAll([
      {'sessionId': 's-chief', 'path': 'charts/sales.png', 'preview': true},
      {'sessionId': 's-chief-1', 'seq': 9, 'index': 0, 'preview': true},
    ]));
    expect(find.byType(ImageGrid), findsNWidgets(2));
    expect(find.byType(FileChip), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('trend.png'), findsNothing);
    // The image cache lets go of its finished loads on a zero-delay timer.
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a computer without shown images keeps the alt text and the file card', (tester) async {
    final (session, _, asked) = await connect(tester, ['images', 'image-preview']);
    await tester.pumpWidget(_host(reply(session), session));
    await tester.runAsync(() => settle());
    await tester.pump();

    expect(asked, isEmpty);
    expect(find.byType(ImageGrid), findsNothing);
    expect(find.textContaining('Sales by month', findRichText: true), findsOneWidget);
    expect(find.byType(FileChip), findsNWidgets(2));
  });

  testWidgets('a picture named by a file: URL goes to the computer as written', (tester) async {
    final (session, _, asked) = await connect(tester, ['images', 'image-preview', 'shown-images']);
    await tester.pumpWidget(_host(
      ChatItemView(row: const ChatRow(_fileUrlReply, 'r10', null), team: session.team!, sessionId: 's-chief', inRoom: false, flat: false, botMax: 340, userMax: 320, onLongPress: (_) {}),
      session,
    ));
    await tester.runAsync(() => settle());
    await tester.pump();

    expect(asked, [{'sessionId': 's-chief', 'path': 'file:///home/me/out/plot.png', 'preview': true}]);
    expect(find.byType(ImageGrid), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
  });

}
