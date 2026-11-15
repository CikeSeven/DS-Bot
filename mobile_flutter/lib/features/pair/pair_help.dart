// How to get a pairing code: three steps, worded as the desktop shows them
// (Settings → Phone, "Phone access", "Show a QR code" → "Show").
import 'package:flutter/material.dart';

import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

Future<void> showPairHelp(BuildContext context) {
  return showGlassSheet<void>(
    context,
    scrollable: false,
    builder: (context) {
      final p = context.p;
      final steps = [
        t('On the computer, open DS Bot and go to Settings → Phone.'),
        t('Turn on “Phone access”, then choose “Show” next to “Show a QR code”.'),
        t('Scan the code with the camera here. After that the phone connects by itself.'),
      ];
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitle(t('How to pair')),
              const SizedBox(height: 8),
              for (final (index, step) in steps.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color.lerp(p.accent, Colors.white, 0.25)!, Color.lerp(p.accent, Colors.black, 0.15)!],
                          ),
                        ),
                        child: SizedBox.square(
                          dimension: 28,
                          child: Center(
                            child: Text('${index + 1}', style: TypeScale.smallStrong.copyWith(color: Colors.white)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(step, style: TypeScale.rowPreview.copyWith(color: p.ink, height: 1.5)),
                        ),
                      ),
                    ],
                  ),
                ),
              Text(
                t('The system camera can scan it too; the code opens this app.'),
                style: TypeScale.caption.copyWith(color: p.ink3),
              ),
            ],
          ),
        ),
      );
    },
  );
}
