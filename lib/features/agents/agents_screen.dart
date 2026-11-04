import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../nav.dart';

String agentMeta(Agent a) =>
    [a.model, a.daemonName].whereType<String>().where((s) => s.isNotEmpty).join(' · ');

class AgentsScreen extends StatelessWidget {
  const AgentsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final data = AppScope.of(context).orgData;
    return ListenableBuilder(
      listenable: data ?? ValueNotifier(0),
      builder: (context, _) {
        final agents = data?.agents;
        return Scaffold(
          appBar: AppBar(
            title: Text(l.agentsTitle),
            actions: [
              if (agents != null)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Center(child: Text(l.agentsCount(agents.length), style: mono(context, size: 13))),
                ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () async => data?.refresh(),
            child: agents == null
                ? (data?.agentsError != null
                    ? StateView(
                        icon: Icons.error_outline,
                        title: l.agentsErrorTitle,
                        body: errorText(l, data!.agentsError!),
                        actionLabel: l.tryAgain,
                        onAction: () => data.refresh())
                    : const Center(child: CircularProgressIndicator()))
                : ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), children: [
                    if (agents.isEmpty)
                      StateView(icon: Icons.smart_toy_outlined, title: l.noAgentsTitle, body: l.noAgentsBody)
                    else
                      GroupCard(children: [for (final a in agents) _AgentRow(agent: a)]),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                      child: Text(l.agentsFooter, style: TextStyle(fontSize: 13, color: p.secondary)),
                    ),
                  ]),
          ),
        );
      },
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({required this.agent});
  final Agent agent;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final a = agent;
    final canChat = a.active && a.webchat;
    return InkWell(
      onTap: () => openAgent(context, a),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(children: [
          AgentAvatar(
              iconUrl: a.iconUrl, runtime: a.runtime, name: a.label, size: 34, dot: healthColor(p, a.health)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(a.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                if (a.builtin) ...[const SizedBox(width: 6), Pill(l.builtIn)],
              ]),
              const SizedBox(height: 2),
              Text(agentMeta(a), maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12)),
            ]),
          ),
          if (canChat)
            IconButton(
              tooltip: l.newChatWith(a.label),
              onPressed: () => openNewChat(context, a),
              icon: Icon(Icons.add_comment_outlined, color: p.secondary),
            ),
          Icon(Icons.chevron_right, color: p.tertiary),
        ]),
      ),
    );
  }
}
