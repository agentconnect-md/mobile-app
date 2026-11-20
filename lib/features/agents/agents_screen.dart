import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../desktop/desktop_nav.dart';
import '../nav.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';

String agentMeta(Agent a) =>
    [a.model, a.daemonName].whereType<String>().where((s) => s.isNotEmpty).join(' · ');

/// "Claude Sonnet 4.5 · 10m ago" (model · last session), as in the design.
String agentListMeta(AppLocalizations l, Agent a, DateTime? lastSession) => [
      if ((a.model ?? '').isNotEmpty) a.model!,
      if (lastSession != null) agoText(l, lastSession),
    ].join(' · ');

enum AgentSort { lastSession, name, status }

/// Sorts a copy of [agents]. Last session: newest first, agents with none
/// after, by name. Status: online, paused, offline, then by last session.
List<Agent> sortAgents(List<Agent> agents, AgentSort sort, Map<String, DateTime> last) {
  int byName(Agent x, Agent y) => x.label.toLowerCase().compareTo(y.label.toLowerCase());
  int byLast(Agent x, Agent y) {
    final a = last[x.id], b = last[y.id];
    if (a == null && b == null) return byName(x, y);
    if (a == null) return 1;
    if (b == null) return -1;
    final c = b.compareTo(a);
    return c != 0 ? c : byName(x, y);
  }

  final out = [...agents];
  switch (sort) {
    case AgentSort.lastSession:
      out.sort(byLast);
    case AgentSort.name:
      out.sort(byName);
    case AgentSort.status:
      out.sort((x, y) {
        final c = x.health.index.compareTo(y.health.index);
        return c != 0 ? c : byLast(x, y);
      });
  }
  return out;
}

/// Kept while the app runs, so switching tabs doesn't reset it.
final agentSort = ValueNotifier(AgentSort.lastSession);

String _sortName(AppLocalizations l, AgentSort s) => switch (s) {
      AgentSort.lastSession => l.sortLastSession,
      AgentSort.name => l.sortName,
      AgentSort.status => l.sortStatus,
    };

class AgentsScreen extends StatelessWidget {
  const AgentsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final data = AppScope.of(context).orgData;
    return ListenableBuilder(
      // The Mac marks the agent shown beside the list.
      listenable: Listenable.merge([?data, agentSort, ?desktopNav]),
      builder: (context, _) {
        final last = data?.lastSessionAt ?? const <String, DateTime>{};
        final agents = data?.agents == null ? null : sortAgents(data!.agents!, agentSort.value, last);
        return Scaffold(
          appBar: AppBar(
            centerTitle: false,
            toolbarHeight: rootAppBarHeight,
            title: rootTitle(l.agentsTitle),
            actions: [
              if (agents != null) ...[
                Text(l.agentsCount(agents.length), style: mono(context, size: 12)),
                const SizedBox(width: 8),
                _SortButton(value: agentSort.value, onChanged: (s) => agentSort.value = s),
                const SizedBox(width: 12),
              ],
            ],
          ),
          body: RefreshIndicator.adaptive(
            onRefresh: () async => data?.refresh(),
            child: agents == null
                ? (data?.agentsError != null
                    ? StateView(
                        icon: AppIcons.errorOutline,
                        title: l.agentsErrorTitle,
                        body: errorText(l, data!.agentsError!),
                        actionLabel: l.tryAgain,
                        onAction: () => data.refresh())
                    : const Center(child: Spinner()))
                : ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), children: [
                    if (agents.isEmpty)
                      StateView(icon: AppIcons.smartToyOutlined, title: l.noAgentsTitle, body: l.noAgentsBody)
                    else
                      GroupCard(children: [for (final a in agents) _AgentRow(agent: a, lastSession: last[a.id])]),
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

class _SortButton extends StatelessWidget {
  const _SortButton({required this.value, required this.onChanged});
  final AgentSort value;
  final ValueChanged<AgentSort> onChanged;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return PopupMenuButton<AgentSort>(
      tooltip: l.sortBy,
      initialValue: value,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: p.border)),
      color: p.surface,
      itemBuilder: (context) => [
        PopupMenuItem<AgentSort>(
          enabled: false,
          height: 32,
          child: Text(l.sortBy.toUpperCase(),
              style: mono(context, size: 10.5, weight: FontWeight.w600).copyWith(letterSpacing: 0.84)),
        ),
        for (final s in AgentSort.values)
          PopupMenuItem<AgentSort>(
            value: s,
            child: SizedBox(
              width: 180,
              child: Row(children: [
                Expanded(
                  child: Text(_sortName(l, s),
                      style: TextStyle(
                          fontSize: 15, fontWeight: s == value ? FontWeight.w600 : FontWeight.w400, color: p.ink)),
                ),
                if (s == value) Icon(AppIcons.check, size: 18, color: p.accent),
              ]),
            ),
          ),
      ],
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: p.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(AppIcons.swapVert, size: 17, color: p.secondary),
          const SizedBox(width: 6),
          Text(_sortName(l, value), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: p.ink)),
        ]),
      ),
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({required this.agent, this.lastSession});
  final Agent agent;
  final DateTime? lastSession;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final a = agent;
    final canChat = a.active && a.webchat;
    final selected = desktopNav?.showsAgent(a) ?? false;
    final row = InkWell(
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
              Text(agentListMeta(l, a, lastSession),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12)),
            ]),
          ),
          if (canChat)
            IconButton(
              tooltip: l.newChatWith(a.label),
              onPressed: () => openNewChat(context, a),
              icon: Icon(AppIcons.addCommentOutlined, color: p.secondary),
            ),
          Icon(AppIcons.chevronRight, color: p.tertiary),
        ]),
      ),
    );
    if (!selected) return row;
    // Marked by a bar at the leading edge as well as the tint.
    return DecoratedBox(
      decoration: BoxDecoration(color: p.brandSoft, border: Border(left: BorderSide(color: p.accent, width: 3))),
      child: row,
    );
  }
}
