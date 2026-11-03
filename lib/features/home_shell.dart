import 'package:flutter/material.dart';

import '../core/auth/app_state.dart';
import '../l10n/app_localizations.dart';
import 'conversations/conversations_screen.dart';
import 'inbox/approvals_controller.dart';
import 'inbox/inbox_screen.dart';
import 'settings/settings_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  ApprovalsController? _approvals;
  String? _forAccount;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    final id = app.current?.id;
    if (id != null && id != _forAccount) {
      _approvals?.dispose();
      _forAccount = id;
      _approvals = ApprovalsController(app.client, app.current!.orgId, app.live)
        ..refresh();
    }
  }

  @override
  void dispose() {
    _approvals?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final a = _approvals!;
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        InboxScreen(controller: a),
        // Rebuilt for each account so lists reload.
        ConversationsScreen(key: ValueKey('c$_forAccount')),
        const SettingsScreen(),
      ]),
      bottomNavigationBar: ListenableBuilder(
        listenable: a,
        builder: (context, _) => NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: [
            NavigationDestination(
              icon: Badge(
                isLabelVisible: a.pendingCount > 0,
                label: Text('${a.pendingCount}'),
                child: const Icon(Icons.inbox_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: a.pendingCount > 0,
                label: Text('${a.pendingCount}'),
                child: const Icon(Icons.inbox),
              ),
              label: l.tabInbox,
            ),
            NavigationDestination(
                icon: const Icon(Icons.forum_outlined),
                selectedIcon: const Icon(Icons.forum),
                label: l.tabConversations),
            NavigationDestination(
                icon: const Icon(Icons.settings_outlined),
                selectedIcon: const Icon(Icons.settings),
                label: l.tabSettings),
          ],
        ),
      ),
    );
  }
}
