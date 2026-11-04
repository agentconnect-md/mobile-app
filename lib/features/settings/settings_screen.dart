import 'package:flutter/material.dart';

import '../../core/auth/account.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../signin/signin_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _confirmRemove(BuildContext context, Account a) async {
    final l = AppLocalizations.of(context);
    final app = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.signOutTitle(a.orgName)),
        content: Text(l.signOutBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(l.signOut, style: TextStyle(color: c.pal.error)),
          ),
        ],
      ),
    );
    if (ok == true) await app.signOut(a);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = AppScope.of(context);
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          SectionLabel(l.organizations),
          if (!app.canWrite)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(leftBar: p.error, child: Text(l.readOnlyGrant)),
            ),
          for (final a in app.accounts)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Dismissible(
                key: ValueKey(a.id),
                direction: DismissDirection.endToStart,
                confirmDismiss: (_) async {
                  await _confirmRemove(context, a);
                  return false;
                },
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  decoration: BoxDecoration(
                    color: p.error,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.delete_outline, color: Colors.white),
                ),
                child: AppCard(
                  onTap: () => app.select(a),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              a.orgName,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (a.userName.isNotEmpty)
                              Text(
                                a.userName,
                                style: TextStyle(color: p.secondary),
                              ),
                          ],
                        ),
                      ),
                      if (a.id == app.current?.id)
                        Chip8(l.current, fg: p.accent),
                      Semantics(
                        label: l.signOut,
                        child: IconButton(
                          icon: Icon(Icons.logout, color: p.secondary),
                          onPressed: () => _confirmRemove(context, a),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const SignInScreen(asRoute: true),
              ),
            ),
            icon: const Icon(Icons.add),
            label: Text(l.addOrganization),
          ),
          SectionLabel(l.notifications),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.approvalAlerts),
              value: app.alerts,
              onChanged: app.setAlerts,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              l.alertsFooter,
              style: TextStyle(color: p.secondary, fontSize: 13),
            ),
          ),
          SectionLabel(l.about),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  title: Text(l.version),
                  trailing: Text('1.0.0', style: TextStyle(color: p.secondary)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
