import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../core/auth/native.dart';
import '../../core/desktop/attention.dart';
import '../../core/desktop/presence.dart';
import '../../core/share_links.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/adaptive.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../agents/agents_screen.dart';
import '../home/home_screen.dart';
import '../infra/infra_screen.dart';
import '../nav.dart';
import '../sessions/sessions_screen.dart';
import 'desktop_nav.dart';

/// Narrower than this the sidebar shows icons only and the lists narrow.
const desktopCompactBelow = 1000.0;

/// The Mac's shell, in place of the phone's tab bar: a sidebar with Home,
/// Agents, Sessions and Infra; Agents and Sessions as a list with the chosen
/// item beside it. Also where the menu bar item's rows, notifications and
/// links land.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});
  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  final nav = DesktopNav();
  StreamSubscription<String>? _links;
  StreamSubscription<OpenTarget>? _opens;
  String? _account;
  AppState? _app;

  @override
  void initState() {
    super.initState();
    nav.context = context;
    DesktopNav.current = nav;
    nav.addListener(_onNav);
    _links = Native.links.listen(_onLink);
    Native.initialLink().then((l) {
      if (l != null) _onLink(l);
    });
    _opens = Native.opens.listen(_onOpen);
    Native.initialOpen().then((t) {
      if (t != null) _onOpen(t);
    });
    // Debug builds only: start on a destination (launch argument `-acDebugTab 2`).
    if (kDebugMode) {
      Native.debugTab().then((t) {
        if (mounted && t != null) nav.go(t);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = _app = AppScope.of(context);
    final id = app.current?.id;
    // Each organization starts fresh.
    if (_account != null && id != _account) nav.reset();
    _account = id;
  }

  @override
  void dispose() {
    _links?.cancel();
    _opens?.cancel();
    nav.removeListener(_onNav);
    if (DesktopNav.current == nav) DesktopNav.current = null;
    _app?.desktop?.reading = const {};
    nav.dispose();
    super.dispose();
  }

  /// Notifications leave out the conversation being read.
  void _onNav() {
    if (mounted) AppScope.read(context).desktop?.reading = nav.reading;
  }

  /// A console session link, or (debug builds) a `…://debug?…` command.
  void _onLink(String raw) {
    if (!mounted) return;
    final app = AppScope.read(context);
    if (kDebugMode && _debugCommand(raw, app)) return;
    final link = parseConsoleLink(raw, app.currentEnv);
    if (link != null) nav.showLink(link);
  }

  /// A row of the menu bar item's menu, or a notification.
  void _onOpen(OpenTarget t) {
    if (!mounted) return;
    final data = AppScope.read(context).orgData;
    switch (t.kind) {
      case 'conversation':
        for (final c in data?.recent ?? const <Conversation>[]) {
          if (c.sessions.any((s) => s.sessionId == t.id)) return nav.showConversation(c);
        }
        // Not among the recent ones: read it by its id.
        nav.showLink(ConsoleLink(slug: '-', sessionId: t.id));
      case 'agent':
        final a = data?.agent(t.id);
        a == null ? nav.go(DesktopNav.agents) : nav.showAgent(a);
      case 'agents':
        nav.go(DesktopNav.agents);
      default:
        nav.go(DesktopNav.home);
    }
  }

  /// Debug builds, for screenshots without a pointer:
  /// `open "<scheme>://debug?tab=2&open=1&theme=dark&size=760x520&menu=1"`
  /// (also `agent=N`, `settings=1`, `close=1`, `status=running|waiting|live`,
  /// `alerts=on|off`, `notify=1`, `to=<agent>&say=<text>`).
  bool _debugCommand(String raw, AppState app) {
    final u = Uri.tryParse(raw);
    if (u == null || u.host != 'debug') return false;
    final q = u.queryParameters;
    final size = q['size']?.split('x').map(double.tryParse).toList();
    if (size != null && size.length == 2 && size[0] != null && size[1] != null) {
      Native.debugWindow(size[0]!, size[1]!);
    }
    final theme = q['theme'];
    if (theme != null && (theme == 'dark') != (app.themeMode == ThemeMode.dark)) {
      app.toggleTheme(theme == 'dark' ? Brightness.light : Brightness.dark);
    }
    final tab = int.tryParse(q['tab'] ?? '');
    if (tab != null) nav.go(tab);
    final n = int.tryParse(q['open'] ?? '');
    final recent = app.orgData?.recent;
    if (n != null && recent != null && n >= 1 && n <= recent.length) nav.showConversation(recent[n - 1]);
    final agent = int.tryParse(q['agent'] ?? '');
    final agents = app.orgData?.agents;
    if (agent != null && agents != null && agent >= 1 && agent <= agents.length) nav.showAgent(agents[agent - 1]);
    if (q['settings'] != null) openSettings(context);
    if (q['menu'] != null) Native.debugStatusMenu();
    if (q['close'] != null) Native.closeWindow();
    // A new chat with the agent named `to`, sending `say` as its first message.
    final to = q['to'], say = q['say'];
    if (to != null && say != null && say.trim().isNotEmpty) {
      final a = agents?.where((a) => a.label == to && a.active && a.webchat).firstOrNull;
      if (a != null) nav.showNewChat(a, firstMessage: say);
    }
    if (q['nstate'] != null) Native.debugNotifications();
    if (q['alerts'] != null) setDesktopAlerts(context, q['alerts'] == 'on');
    // A notification about the newest conversation, posted the way a real one is.
    if (q['notify'] != null && recent != null && recent.isNotEmpty) {
      final c = recent.first;
      final (title, body) = noticeText(
          AppLocalizations.of(context),
          Notice(
              kind: NoticeKind.finished,
              agentName: c.primary.agentName,
              title: c.title,
              sessionId: c.primary.sessionId));
      Native.notify(
          id: 'conv:${c.primary.sessionId}',
          title: title,
          body: body,
          target: OpenTarget('conversation', c.primary.sessionId));
    }
    if (q['status'] != null) app.desktop?.debugShow(_sampleStatus(q['status']!));
    return true;
  }

  /// Debug builds: made-up states for the menu bar item (`status=running`,
  /// `status=waiting`; anything else shows the live state again).
  static AttentionState? _sampleStatus(String name) {
    if (name != 'running' && name != 'waiting') return null;
    final waiting = name == 'waiting';
    return AttentionState(
      conversations: [
        const WatchedConversation(
            sessionId: 'sample-1',
            sessionIds: {'sample-1'},
            state: ActivityState.working,
            agentName: 'deploy-bot',
            title: 'Roll out the billing service'),
        if (waiting)
          const WatchedConversation(
              sessionId: 'sample-2',
              sessionIds: {'sample-2'},
              state: ActivityState.awaiting,
              agentName: 'review-bot',
              title: 'Which region should this go to?'),
        if (waiting)
          const WatchedConversation(
              sessionId: 'sample-3',
              sessionIds: {'sample-3'},
              state: ActivityState.awaiting,
              agentName: 'deploy-bot',
              title: 'Database migration'),
      ],
      approvals: [
        if (waiting)
          const WatchedApproval(
              id: 'sample-a', sessionId: 'sample-3', agentName: 'deploy-bot', title: 'Database migration'),
      ],
      agents: const [
        WatchedAgent(id: 'a', name: 'deploy-bot', health: AgentHealth.online, working: true),
        WatchedAgent(id: 'b', name: 'review-bot', health: AgentHealth.online),
        WatchedAgent(id: 'c', name: 'docs-writer', health: AgentHealth.paused),
        WatchedAgent(id: 'd', name: 'nightly-sweeper', health: AgentHealth.offline),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final account = AppScope.of(context).current?.id;
    return Material(
      color: p.canvas,
      child: LayoutBuilder(builder: (context, box) {
        final compact = box.maxWidth < desktopCompactBelow;
        final listWidth = compact ? 300.0 : 340.0;
        return ListenableBuilder(
          listenable: nav,
          builder: (context, _) => Row(children: [
            DesktopSidebar(nav: nav, compact: compact),
            VerticalDivider(width: 1, thickness: 1, color: p.hairline),
            Expanded(
              child: IndexedStack(index: nav.tab, children: [
                // Keyed by account so each organization starts fresh.
                _Pane(navKey: nav.rootKeys[0], child: HomeScreen(key: ValueKey('h$account'), onTab: nav.go)),
                _Split(
                  listWidth: listWidth,
                  list: _Pane(navKey: nav.rootKeys[1], child: AgentsScreen(key: ValueKey('a$account'))),
                  detail: nav.agentsDetail,
                  empty: _Empty(
                      icon: AppIcons.smartToyOutlined, title: l.desktopSelectAgent, body: l.desktopSelectAgentBody),
                ),
                _Split(
                  listWidth: listWidth,
                  list: _Pane(navKey: nav.rootKeys[2], child: SessionsScreen(key: ValueKey('s$account'))),
                  detail: nav.sessionsDetail,
                  empty: _Empty(
                      icon: AppIcons.forumOutlined,
                      title: l.desktopSelectConversation,
                      body: l.desktopSelectConversationBody),
                ),
                _Pane(navKey: nav.rootKeys[3], child: InfraScreen(key: ValueKey('i$account'))),
              ]),
            ),
          ]),
        );
      }),
    );
  }
}

/// One column of the window with a navigator of its own: what a screen in it
/// pushes stays in the column. Screens measure themselves against the column
/// (not the window), and their short notices show in it alone.
class _Pane extends StatelessWidget {
  const _Pane({super.key, required this.navKey, required this.child});
  final GlobalKey<NavigatorState> navKey;
  final Widget child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: box.biggest),
          child: ScaffoldMessenger(
            child: Navigator(
              key: navKey,
              onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => child),
            ),
          ),
        ),
      );
}

/// A list with the chosen item beside it.
class _Split extends StatelessWidget {
  const _Split({required this.listWidth, required this.list, required this.detail, required this.empty});
  final double listWidth;
  final Widget list;
  final DetailPage? detail;
  final Widget empty;
  @override
  Widget build(BuildContext context) {
    final d = detail;
    return Row(children: [
      SizedBox(width: listWidth, child: list),
      VerticalDivider(width: 1, thickness: 1, color: context.pal.hairline),
      Expanded(
        // A new choice is a new navigator: nothing of the last one is left on it.
        child: d == null ? empty : _Pane(key: ObjectKey(d), navKey: d.navKey, child: d.page),
      ),
    ]);
  }
}

/// The detail side before anything is chosen.
class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) =>
      Scaffold(appBar: AppBar(), body: StateView(icon: icon, title: title, body: body));
}

/// The sidebar: the organization, the four destinations (Home carries the
/// count of approval requests waiting), and at the bottom notifications
/// on/off, appearance and Settings. Icons only when [compact].
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({super.key, required this.nav, required this.compact});
  final DesktopNav nav;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final app = AppScope.of(context);
    final approvals = app.approvals;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: compact ? 68 : 212,
      color: p.sunken,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Tooltip(
          message: compact ? (app.current?.orgName ?? '') : '',
          child: Padding(
            padding: EdgeInsets.fromLTRB(compact ? 13 : 8, 2, 4, 12),
            child: Row(children: [
              const BrandMark(size: 22),
              if (!compact) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(app.current?.orgName ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ],
            ]),
          ),
        ),
        ListenableBuilder(
          listenable: approvals ?? ValueNotifier(0),
          builder: (context, _) => SidebarItem(
            icon: AppIcons.homeOutlined,
            selectedIcon: AppIcons.homeSelected,
            label: l.tabHome,
            selected: nav.tab == DesktopNav.home,
            badge: approvals?.pendingCount ?? 0,
            compact: compact,
            onTap: () => nav.go(DesktopNav.home),
          ),
        ),
        SidebarItem(
          icon: AppIcons.smartToyOutlined,
          label: l.tabAgents,
          selected: nav.tab == DesktopNav.agents,
          compact: compact,
          onTap: () => nav.go(DesktopNav.agents),
        ),
        SidebarItem(
          icon: AppIcons.forumOutlined,
          selectedIcon: AppIcons.forumSelected,
          label: l.tabSessions,
          selected: nav.tab == DesktopNav.sessions,
          compact: compact,
          onTap: () => nav.go(DesktopNav.sessions),
        ),
        SidebarItem(
          icon: AppIcons.dnsOutlined,
          selectedIcon: AppIcons.dnsSelected,
          label: l.tabInfra,
          selected: nav.tab == DesktopNav.infra,
          compact: compact,
          onTap: () => nav.go(DesktopNav.infra),
        ),
        const Spacer(),
        SidebarItem(
          icon: app.alerts ? AppIcons.notificationsNoneOutlined : AppIcons.notificationsOffOutlined,
          label: app.alerts ? l.notificationsOnTooltip : l.notificationsOffTooltip,
          compact: compact,
          onTap: () => setDesktopAlerts(context, !app.alerts),
        ),
        SidebarItem(
          icon: dark ? AppIcons.lightModeOutlined : AppIcons.darkModeOutlined,
          label: l.switchAppearance,
          compact: compact,
          onTap: () => app.toggleTheme(Theme.of(context).brightness),
        ),
        SidebarItem(
          icon: AppIcons.settingsOutlined,
          label: l.settingsTitle,
          compact: compact,
          onTap: () => openSettings(context),
        ),
      ]),
    );
  }
}

/// One row of the sidebar. The selected one is filled and bold with the
/// filled glyph (not only tinted); the others show hover.
class SidebarItem extends StatelessWidget {
  const SidebarItem({
    super.key,
    required this.icon,
    this.selectedIcon,
    required this.label,
    this.selected = false,
    this.badge = 0,
    required this.compact,
    required this.onTap,
  });
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final bool selected;
  final int badge;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final color = selected ? p.brandText : p.secondary;
    final glyph = Icon(selected ? (selectedIcon ?? icon) : icon, size: 18, color: color);
    final count = badge > 0
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(color: p.paused, borderRadius: BorderRadius.circular(999)),
            child: Text('$badge',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
          )
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Tooltip(
        message: compact ? label : '',
        child: Semantics(
          button: true,
          selected: selected,
          label: badge > 0 ? '$label, $badge' : label,
          excludeSemantics: true,
          child: Material(
            color: selected ? p.brandSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(
                height: 34,
                child: compact
                    ? Center(child: count == null ? glyph : Badge(label: Text('$badge'), child: glyph))
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(children: [
                          glyph,
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                                    color: selected ? p.brandText : p.ink)),
                          ),
                          ?count,
                        ]),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Turns notifications on or off (Settings and the sidebar). Turning them on
/// asks the system for permission the first time; when the system doesn't
/// allow them, says where to change that.
Future<void> setDesktopAlerts(BuildContext context, bool on) async {
  final app = AppScope.read(context);
  if (!on) return app.setAlerts(false);
  if (await app.turnOnAlerts()) return;
  // Refused without ever asking the person (seen 2026-11-20 when the request
  // was made while the app was not in front; an unsigned build is the other
  // known cause). There is no switch in System Settings to send them to yet.
  final neverAsked = await Native.notificationStatus() == 'undetermined';
  if (!context.mounted) return;
  final l = AppLocalizations.of(context);
  if (neverAsked) {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.macAlertsUnsignedTitle),
        content: Text(l.macAlertsUnsignedBody),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(l.close))],
      ),
    );
    return;
  }
  final open = await confirmDialog(
    context,
    title: l.macAlertsDeniedTitle,
    body: l.macAlertsDeniedBody,
    cancel: l.cancel,
    confirm: l.macOpenSystemSettings,
  );
  if (open == true) {
    await launchUrl(Uri.parse('x-apple.systempreferences:com.apple.Notifications-Settings.extension'));
  }
}
