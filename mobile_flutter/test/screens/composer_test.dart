import 'dart:io';

import 'package:dsbot_mobile/features/chat/composer.dart';
import 'package:dsbot_mobile/shared/shared_data.dart';
import 'package:dsbot_mobile/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() => SharedData.fromJsonText(File('assets/shared/shared.json').readAsStringSync()));

  Future<void> pumpComposer(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Palette.of(dark: false)),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 360,
            child: Composer(name: 'Chief', running: false, canStop: false, canPhotos: true, canFiles: false, onSend: (_, _, _) {}, onStop: () {}),
          ),
        ),
      ),
    ));
  }

  Rect field(WidgetTester tester) => tester.getRect(find.byType(TextField));
  Rect send(WidgetTester tester) => tester.getRect(find.descendant(of: find.byType(Composer), matching: find.byType(AnimatedSwitcher)));
  Rect box(WidgetTester tester) => tester.getRect(find.byType(Composer));

  /// The text shares the row with + and send.
  bool oneRow(WidgetTester tester) => send(tester).top < field(tester).bottom - 4 && field(tester).left - box(tester).left > 40;

  testWidgets('the text takes its own row once it needs two lines, until the box is empty', (tester) async {
    await pumpComposer(tester);
    expect(oneRow(tester), isTrue);

    await tester.enterText(find.byType(TextField), 'short');
    await tester.pumpAndSettle();
    expect(oneRow(tester), isTrue);

    await tester.enterText(find.byType(TextField), 'word ' * 8);
    await tester.pumpAndSettle();
    expect(oneRow(tester), isFalse);
    expect(field(tester).left - box(tester).left, closeTo(14, 0.5));
    expect(send(tester).top, greaterThanOrEqualTo(field(tester).bottom - 0.5));

    // Back to text that would fit in one row: the layout stays.
    await tester.enterText(find.byType(TextField), 'word');
    await tester.pumpAndSettle();
    expect(oneRow(tester), isFalse);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(oneRow(tester), isTrue);
  });

  testWidgets('a new line opens the text row too', (tester) async {
    await pumpComposer(tester);
    await tester.enterText(find.byType(TextField), 'a\nb');
    await tester.pumpAndSettle();
    expect(oneRow(tester), isFalse);
  });

  testWidgets('the box moves between the layouts without jumping, both ways', (tester) async {
    Future<List<double>> frames() async {
      final heights = <double>[];
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        heights.add(box(tester).height);
      }
      await tester.pumpAndSettle();
      return heights;
    }

    void smooth(double from, List<double> heights, double to) {
      var last = from;
      for (final height in [...heights, to]) {
        expect((height - last).abs(), lessThan(8), reason: '$from → $heights → $to');
        last = height;
      }
    }

    await pumpComposer(tester);
    await tester.enterText(find.byType(TextField), 'short');
    await tester.pumpAndSettle();
    final closed = box(tester).height;
    await tester.enterText(find.byType(TextField), 'word ' * 8);
    final opening = await frames();
    final open = box(tester).height;
    expect(open, greaterThan(closed));
    smooth(closed, opening, open);

    await tester.enterText(find.byType(TextField), '');
    final closing = await frames();
    expect(box(tester).height, closed);
    smooth(open, closing, closed);
  });
}
