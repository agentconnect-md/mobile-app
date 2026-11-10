import 'package:flutter/foundation.dart' show kDebugMode;
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/auth/native.dart';
import '../core/auth/app_state.dart';
import '../core/share_links.dart';
import '../l10n/app_localizations.dart';
import 'agents/agents_screen.dart';
import 'home/home_screen.dart';
import 'infra/infra_screen.dart';
import 'sessions/open_link.dart';
import 'sessions/sessions_screen.dart';

/// Home · Agents · Sessions · Infra, as in the design.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  StreamSubscription<String>? _links;

  /// A console session link (universal link): open that session.
  void _onLink(String raw) {
    if (!mounted) return;
    final link = parseConsoleLink(raw, AppScope.read(context).env);
    if (link != null) openConsoleLink(context, link);
  }

  @override
  void dispose() {
    _links?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _links = Native.links.listen(_onLink);
    Native.initialLink().then((l) {
      if (l != null) _onLink(l);
    });
    // Debug builds only: start on a tab (launch argument `-acDebugTab 2`)
    // for simulator screenshots.
    if (kDebugMode) {
      Native.debugTab().then((t) {
        if (mounted && t != null && t >= 0 && t < 4) setState(() => _tab = t);
      });
    }
  }

  void _go(int i) => setState(() => _tab = i);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = AppScope.of(context);
    final approvals = app.approvals;
    final account = app.current?.id;
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        // Keyed by account so each organization starts fresh.
        HomeScreen(key: ValueKey('h$account'), onTab: _go),
        AgentsScreen(key: ValueKey('a$account')),
        SessionsScreen(key: ValueKey('s$account')),
        InfraScreen(key: ValueKey('i$account')),
      ]),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
        child: ListenableBuilder(
          listenable: approvals ?? ValueNotifier(0),
          builder: (context, _) {
            final n = approvals?.pendingCount ?? 0;
            return NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: _go,
              destinations: [
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: n > 0,
                    label: Text('$n'),
                    child: const Icon(Icons.home_outlined),
                  ),
                  selectedIcon: Badge(
                    isLabelVisible: n > 0,
                    label: Text('$n'),
                    child: const Icon(Icons.home_outlined),
                  ),
                  label: l.tabHome,
                ),
                NavigationDestination(
                    icon: const Icon(Icons.smart_toy_outlined), label: l.tabAgents),
                NavigationDestination(
                    icon: const Icon(Icons.forum_outlined), label: l.tabSessions),
                NavigationDestination(
                    icon: const Icon(Icons.dns_outlined), label: l.tabInfra),
              ],
            );
          },
        ),
      ),
    );
  }
}
