// The app's home: three tabs (Team, Inbox, Settings) under a floating frosted
// tab bar, with question and approval notices sliding in from the top.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/link_client.dart';
import '../../app/app_state.dart';
import '../../app/nav.dart';
import '../../background/notifier.dart';
import '../../background/wiring.dart';
import '../../data/json.dart';
import '../../data/pending.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../inbox/inbox_tab.dart';
import '../settings/settings_tab.dart';
import '../team/team_tab.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  static void selectTab(BuildContext context, int index) => context.findAncestorStateOfType<_HomeShellState>()?._select(index);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  final _visited = <int>{0};

  @override
  void initState() {
    super.initState();
    Notifier.instance.onOpen = (botId, roomId) {
      final context = navigatorKey.currentContext;
      if (context == null || !mounted) return;
      if (botId == null && roomId == null) {
        _select(1);
        return;
      }
      openChat(context, botId: botId, roomId: roomId, replace: true);
    };
  }

  void _select(int index) {
    if (index == _tab) return;
    HapticFeedback.selectionClick();
    setState(() {
      _tab = index;
      _visited.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final team = TeamScope.of(context);
    final pending = pendingItemsOf(team.team).length;
    final tabs = [const TeamTab(), const InboxTab(), const SettingsTab()];
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: BackdropGroup(
        child: Stack(children: [
          Positioned.fill(
            child: IndexedStack(
              index: _tab,
              children: [for (final (i, tab) in tabs.indexed) _visited.contains(i) ? tab : const SizedBox.shrink()],
            ),
          ),
          Positioned(left: 0, right: 0, bottom: 0, child: _TabBar(index: _tab, onSelect: _select, inboxBadge: pending)),
          const Positioned(left: 0, right: 0, top: 0, child: NoticeBanner()),
        ]),
      ),
    );
  }
}

/// Height the content leaves free above the floating tab bar.
double tabBarClearance(BuildContext context) => 64 + 12 + MediaQuery.paddingOf(context).bottom;

class _TabBar extends StatelessWidget {
  const _TabBar({required this.index, required this.onSelect, required this.inboxBadge});

  final int index;
  final ValueChanged<int> onSelect;
  final int inboxBadge;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final items = [(AppIcon.people, t('Team')), (AppIcon.inbox, t('Inbox')), (AppIcon.gear, t('Settings'))];
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Center(
        heightFactor: 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: GlassSurface(
              radius: BorderRadius.circular(32),
              edge: GlassEdge.all,
              elevated: true,
              child: SizedBox(
                height: 64,
                child: LayoutBuilder(builder: (context, constraints) {
                  final width = constraints.maxWidth / items.length;
                  return Stack(children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 380),
                      curve: SpringCurve.shape,
                      left: width * index + 6,
                      top: 6,
                      bottom: 6,
                      width: width - 12,
                      child: Container(decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(26))),
                    ),
                    Row(children: [
                      for (final (i, (icon, label)) in items.indexed)
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => onSelect(i),
                            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Stack(clipBehavior: Clip.none, children: [
                                Ico(icon, size: 22, color: i == index ? p.accent : p.ink2),
                                if (i == 1 && inboxBadge > 0)
                                  Positioned(
                                    right: -10,
                                    top: -6,
                                    child: Container(
                                      constraints: const BoxConstraints(minWidth: 17),
                                      height: 17,
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(color: Palette.danger, borderRadius: BorderRadius.circular(9)),
                                      child: Text(inboxBadge > 99 ? '99+' : '$inboxBadge', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600, height: 1)),
                                    ),
                                  ),
                              ]),
                              const SizedBox(height: 3),
                              Text(label, style: TypeScale.caption.copyWith(color: i == index ? p.accent : p.ink2, fontWeight: i == index ? FontWeight.w600 : FontWeight.w400)),
                            ]),
                          ),
                        ),
                    ]),
                  ]);
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A frosted banner for notices that need the user (questions and approvals),
/// unless banners are off or the notice belongs to the chat on screen.
class NoticeBanner extends StatefulWidget {
  const NoticeBanner({super.key});

  /// The chat on screen, so its own notices do not pop up over it.
  static String? get openChatId => Notifier.instance.openChat;
  static set openChatId(String? id) => Notifier.instance.openChat = id;

  @override
  State<NoticeBanner> createState() => _NoticeBannerState();
}

class _NoticeBannerState extends State<NoticeBanner> {
  StreamSubscription<RpcEvent>? _feed;
  Json? _notice;
  Timer? _hide;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_feed?.cancel());
    _feed = TeamScope.read(context).feed.listen(_onEvent);
  }

  void _onEvent(RpcEvent event) {
    if (event.event != 'notice' || !AppScope.read(context).prefs.banners) return;
    final notice = asJson(event.data);
    final kind = jStr(notice, 'kind');
    if (kind != 'question' && kind != 'approval') return;
    final target = jStr(notice, 'roomId') ?? jStr(notice, 'botId');
    if (target != null && target == NoticeBanner.openChatId) return;
    HapticFeedback.mediumImpact();
    setState(() => _notice = notice);
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  @override
  void dispose() {
    unawaited(_feed?.cancel());
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final notice = _notice;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: SpringCurve.pop,
      transitionBuilder: (child, animation) => SlideTransition(
        position: Tween(begin: const Offset(0, -1.2), end: Offset.zero).animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: notice == null
          ? const SizedBox.shrink(key: ValueKey('none'))
          : SafeArea(
              key: ValueKey(notice['seq'] ?? notice['time']),
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: GestureDetector(
                  onTap: () {
                    setState(() => _notice = null);
                    final roomId = jStr(notice, 'roomId');
                    openChat(context, roomId: roomId, botId: roomId == null ? jStr(notice, 'botId') : null);
                  },
                  onVerticalDragEnd: (_) => setState(() => _notice = null),
                  child: GlassSurface(
                    radius: BorderRadius.circular(20),
                    edge: GlassEdge.all,
                    elevated: true,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(children: [
                      Ico(jStr(notice, 'kind') == 'approval' ? AppIcon.shield : AppIcon.question, size: 22, color: p.accent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(jStr(notice, 'title') ?? jStr(notice, 'name') ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.smallStrong.copyWith(color: p.ink)),
                          Text(jStr(notice, 'text') ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: TypeScale.small.copyWith(color: p.ink2)),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
    );
  }
}
