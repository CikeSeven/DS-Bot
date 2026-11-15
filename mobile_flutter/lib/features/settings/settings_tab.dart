// Settings: this phone first (computers, look, language, notifications), then
// the team on the computer (models, connectors, capabilities, secrets, chat
// apps, local agents, computer use, its look, usage, updates).
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../home/home_shell.dart';
import 'computers_page.dart';
import 'connections_pages.dart';
import 'providers_page.dart';
import 'team_pages.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final app = AppScope.of(context);
    final session = TeamScope.of(context);
    final prefs = app.prefs;
    final team = session.team;
    return GlassPage(
      bar: GlassBar(title: Text(t('Settings'))),
      bodyBuilder: (context) => ListView(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 4, bottom: tabBarClearance(context) + 12),
        children: [
          Group(title: t('This phone'), children: [
            Row2(
              title: t('Computers'),
              value: session.hostName ?? session.computer.name,
              leading: RowIcon(AppIcon.monitor),
              onTap: () => push(context, const ComputersPage()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [RowIcon(AppIcon.sun), const SizedBox(width: 12), Text(t('Appearance'), style: TypeScale.settingsRow.copyWith(color: p.ink))]),
                const SizedBox(height: 10),
                Segmented<ThemeMode>(
                  values: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark],
                  labels: [t('System'), t('Light'), t('Dark')],
                  value: prefs.themeMode,
                  onChanged: (mode) => app.setPrefs({'theme': switch (mode) { ThemeMode.light => 'light', ThemeMode.dark => 'dark', _ => 'system' }}),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [RowIcon(AppIcon.language), const SizedBox(width: 12), Text(t('Language'), style: TypeScale.settingsRow.copyWith(color: p.ink))]),
                const SizedBox(height: 10),
                Segmented<LangPref>(
                  values: const [LangPref.system, LangPref.zh, LangPref.en],
                  labels: [t('Follow system'), '简体中文', 'English'],
                  value: prefs.lang,
                  onChanged: (lang) => app.setPrefs({'lang': lang.name}),
                ),
              ]),
            ),
            SwitchRow(
              title: t('Glass effects on bars and sheets'),
              leading: RowIcon(AppIcon.layers),
              value: prefs.glass,
              onChanged: (on) => app.setPrefs({'glass': on ? 'on' : 'off'}),
            ),
            SwitchRow(title: t('In-app banners'), leading: RowIcon(AppIcon.bell), value: prefs.banners, onChanged: (on) => app.setPrefs({'banners': on ? 'on' : 'off'})),
            SwitchRow(title: t('Enter to send'), leading: RowIcon(AppIcon.send), value: prefs.enterToSend, onChanged: (on) => app.setPrefs({'enterToSend': on ? 'on' : 'off'})),
            Row2(title: t('Notifications'), leading: RowIcon(AppIcon.inbox), onTap: () => push(context, const NotificationsPage())),
          ]),
          if (team != null) ...[
            Group(title: t('Team on the computer'), children: [
              Row2(title: t('Models'), leading: RowIcon(AppIcon.model), onTap: () => push(context, const ProvidersPage())),
              Row2(title: t('Default model for new Bots'), leading: RowIcon(AppIcon.sparkle), onTap: () => push(context, const ComputerAppearancePage())),
              Row2(title: t('Connectors'), leading: RowIcon(AppIcon.plug), onTap: () => push(context, const ConnectorsPage())),
              Row2(title: t('Mail'), leading: RowIcon(AppIcon.mail), onTap: () => push(context, const MailPage())),
              Row2(title: t('Capabilities'), leading: RowIcon(AppIcon.puzzle), onTap: () => push(context, const CapabilitiesPage())),
              Row2(title: t('Secrets'), leading: RowIcon(AppIcon.key), onTap: () => push(context, const SecretsPage())),
              Row2(title: t('Chat apps'), leading: RowIcon(AppIcon.chat), onTap: () => push(context, const ImPage())),
              Row2(title: t('Local agents'), leading: RowIcon(AppIcon.bolt), onTap: () => push(context, const LocalAgentsPage())),
              Row2(title: t('Computer use'), leading: RowIcon(AppIcon.monitor), onTap: () => push(context, const ComputerUsePage())),
            ]),
            Group(children: [
              Row2(title: t('Appearance on the computer'), leading: RowIcon(AppIcon.sun), onTap: () => push(context, const ComputerAppearancePage())),
              Row2(title: t('Usage'), leading: RowIcon(AppIcon.chart), onTap: () => push(context, const TeamUsagePage())),
              Row2(title: t('Location'), leading: RowIcon(AppIcon.folder), onTap: () => push(context, const LocationPage())),
              Row2(title: t('Updates and diagnostics'), leading: RowIcon(AppIcon.refresh), onTap: () => push(context, const UpdatesPage())),
              Row2(title: t('About'), leading: RowIcon(AppIcon.question), onTap: () => push(context, const AboutPage())),
            ]),
          ],
        ],
      ),
    );
  }
}
