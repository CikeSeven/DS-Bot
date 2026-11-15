// The computers this phone is paired with: switch, forget, add another.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../manage/common.dart';

class ComputersPage extends StatelessWidget {
  const ComputersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final app = AppScope.of(context);
    final session = app.session;
    final active = app.computer?.hostDeviceId;
    return ManagePage(
      title: t('Computers'),
      children: [
        Group(
          footer: t('Check that this matches the code on the computer'),
          children: [
            for (final computer in app.computers.computers)
              Row2(
                title: computer.name.isEmpty ? t('Computer') : computer.name,
                subtitle: [
                  if (computer.hostDeviceId == active) session?.online == true ? t('Connected') : (session?.error != null ? errorText(session!.error) : t('Connecting…')),
                  '${t('Fingerprint')} ${_group(computer.fingerprint)}',
                ].join('\n'),
                leading: RowIcon(AppIcon.monitor, color: computer.hostDeviceId == active ? Palette.green : p.ink3),
                trailing: computer.hostDeviceId == active ? Ico(AppIcon.check, color: p.accent) : null,
                onTap: computer.hostDeviceId == active
                    ? null
                    : () async {
                        await app.switchTo(computer.hostDeviceId);
                        if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
                      },
                onLongPress: () async {
                  final ok = await confirmDanger(context, title: t('Forget {name}?', {'name': computer.name}), body: t('Pair again with a new QR code to use it.'), action: t('Forget'));
                  if (ok) await app.forget(computer.hostDeviceId);
                },
              ),
          ],
        ),
        Group(children: [
          Row2(title: t('Add a computer'), leading: RowIcon(AppIcon.qr), onTap: () {
            Navigator.of(context).popUntil((route) => route.isFirst);
            app.openPairLink();
          }),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Text(t('Long-press a computer to forget it.'), style: TypeScale.caption.copyWith(color: p.ink3)),
        ),
      ],
    );
  }

  static String _group(String code) => code.length < 12 ? code : '${code.substring(0, 4)} ${code.substring(4, 8)} ${code.substring(8)}';
}
