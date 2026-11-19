import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../files/agent_workspace_screen.dart';
import '../nav.dart';
import '../../ui/icons.dart';

/// Agent detail: description, "Chat with", status/model/runtime/daemon, its
/// workspace, channels and recent sessions (read-only; configuration stays in
/// the console).
class AgentDetailScreen extends StatefulWidget {
  const AgentDetailScreen({super.key, required this.agent});
  final Agent agent;

  @override
  State<AgentDetailScreen> createState() => _AgentDetailScreenState();
}

class _AgentDetailScreenState extends State<AgentDetailScreen> {
  /// This agent's sessions with their own worktree, shared with its workspace page.
  WorktreeList? _worktrees;

  Agent get agent => widget.agent;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_worktrees != null) return;
    final app = AppScope.read(context);
    _worktrees = WorktreeList(app.client, app.current!.orgId, agent.id)..addListener(_changed);
    _worktrees!.more();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _worktrees?.removeListener(_changed);
    _worktrees?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final data = AppScope.of(context).orgData;
    return ListenableBuilder(
      listenable: data ?? ValueNotifier(0),
      builder: (context, _) {
        final a = data?.agent(agent.id) ?? agent;
        final sessions = (data?.recent ?? const <Conversation>[])
            .where((c) => c.sessions.any((s) => s.agentId == a.id))
            .toList();
        final status = switch (a.health) {
          AgentHealth.online => l.online,
          AgentHealth.paused => l.paused,
          AgentHealth.offline => l.offline,
        };
        final canChat = a.active && a.webchat;
        final wt = _worktrees?.worktrees ?? const <SessionRow>[];
        Widget field(String k, String? v) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Text(k, style: mono(context, size: 13, color: p.ink)),
                const Spacer(),
                Flexible(
                  child: Text(v == null || v.isEmpty ? '—' : v,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(context, size: 13, color: p.ink)),
                ),
              ]),
            );
        return Scaffold(
          appBar: AppBar(title: Text(a.label)),
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AgentAvatar(
                  iconUrl: a.iconUrl, runtime: a.runtime, name: a.label, size: 52, dot: healthColor(p, a.health)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  if ((a.description ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(a.description!, style: TextStyle(fontSize: 14, color: p.secondary, height: 1.4)),
                  ],
                ]),
              ),
            ]),
            if (canChat) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => openNewChat(context, a),
                icon: Icon(AppIcons.addCommentOutlined, size: 20),
                label: Text(l.chatWith(a.label)),
              ),
            ],
            const SizedBox(height: 14),
            GroupCard(children: [
              field(l.fieldStatus, status),
              field(l.fieldModel, a.model),
              field(l.fieldRuntime, a.runtime),
              field(l.fieldDaemon, a.daemonName),
            ]),
            const SizedBox(height: 14),
            AppCard(
              padding: EdgeInsets.zero,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => push(context, AgentWorkspaceScreen(agent: a, worktrees: _worktrees!)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                  child: Row(children: [
                    Icon(AppIcons.accountTreeOutlined, size: 20, color: p.secondary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l.workspaceTitle, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                        if (a.workspace != null || wt.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            [
                              ?a.workspace?.label,
                              // Only the sessions read so far: "2+ worktrees" while older ones remain.
                              if (wt.isNotEmpty)
                                (_worktrees!.hasMore ? l.worktreeCountMore(wt.length) : l.worktreeCount(wt.length)),
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: mono(context, size: 12),
                          ),
                        ],
                      ]),
                    ),
                    Icon(AppIcons.chevronRight, color: p.tertiary),
                  ]),
                ),
              ),
            ),
            if (a.webchat) ...[
              SectionHeader(l.channels),
              GroupCard(children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(children: [
                    const BrandMark(size: 14),
                    const SizedBox(width: 10),
                    Text(l.webChat, style: mono(context, size: 13, color: p.ink)),
                    const SizedBox(width: 6),
                    Text(l.always, style: mono(context, size: 13, color: p.ink)),
                  ]),
                ),
              ]),
            ],
            SectionHeader(l.recentSessions, trailing: '${sessions.length}'),
            if (sessions.isEmpty)
              AppCard(child: Text(l.noRecentSessions, style: TextStyle(color: p.secondary)))
            else
              GroupCard(children: [
                for (final c in sessions.take(10))
                  InkWell(
                    onTap: () => openConversation(context, c),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      child: Row(children: [
                        StatusDot(color: c.state == ActivityState.idle ? null : p.online, size: 8),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(c.title ?? l.untitled,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                            Text(c.place ?? sourceName(l, c.source),
                                style: mono(context, size: 12)),
                          ]),
                        ),
                        Text(listTime(c.lastActivity), style: mono(context, size: 12)),
                      ]),
                    ),
                  ),
              ]),
          ]),
        );
      },
    );
  }
}
