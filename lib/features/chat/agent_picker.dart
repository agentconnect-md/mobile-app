import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';

/// Agents you can chat with from the app (active, web chat on).
List<Agent> chatAgents(List<Agent>? all) =>
    (all ?? const <Agent>[]).where((a) => a.active && a.webchat).toList();

/// Bottom sheet to choose an agent. Returns null when dismissed.
Future<Agent?> pickAgent(BuildContext context, {String? selectedId}) {
  final app = AppScope.read(context);
  return showAppSheet<Agent>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => AppScope(state: app, child: _Picker(selectedId: selectedId)),
  );
}

class _Picker extends StatelessWidget {
  const _Picker({this.selectedId});
  final String? selectedId;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final data = AppScope.of(context).orgData;
    return ListenableBuilder(
      listenable: data ?? ValueNotifier(0),
      builder: (context, _) {
        final agents = chatAgents(data?.agents);
        final h = MediaQuery.sizeOf(context).height * 0.6;
        Widget body;
        if (data?.agents == null && data?.agentsError == null) {
          body = const Center(child: Spinner());
        } else if (data?.agentsError != null && data?.agents == null) {
          body = StateView(
              icon: AppIcons.errorOutline,
              title: l.agentsErrorTitle,
              actionLabel: l.tryAgain,
              onAction: () => data?.refresh());
        } else if (agents.isEmpty) {
          body = StateView(icon: AppIcons.smartToyOutlined, title: l.noAgentsTitle, body: l.noAgentsBody);
        } else {
          body = ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
            GroupCard(children: [
              for (final a in agents)
                ListTile(
                  minTileHeight: 56,
                  leading: AgentAvatar(
                      iconUrl: a.iconUrl,
                      runtime: a.runtime,
                      name: a.label,
                      size: 30,
                      dot: healthColor(p, a.health)),
                  title: Text(a.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      [a.model, a.daemonName].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(context, size: 12)),
                  trailing: a.id == selectedId ? Icon(AppIcons.check, color: p.accent) : null,
                  onTap: () => Navigator.pop(context, a),
                ),
            ]),
          ]);
        }
        return SizedBox(
          height: h,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(l.chooseAgent,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              ),
            ),
            Expanded(child: body),
          ]),
        );
      },
    );
  }
}
