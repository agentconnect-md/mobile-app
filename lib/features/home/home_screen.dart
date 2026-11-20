import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../core/auth/native.dart';
import '../../core/org_data.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../approvals/approval_card.dart';
import '../chat/agent_picker.dart';
import '../nav.dart';
import '../schedules/schedule_detail_screen.dart';
import '../schedules/schedule_row.dart';
import '../schedules/schedules_screen.dart';
import '../sessions/session_tile.dart';
import '../../ui/icons.dart';
import '../../ui/platform.dart';
import '../../ui/adaptive.dart';
import '../../ui/desktop_keys.dart';

/// Header · greeting · approvals waiting · ask box · stats · recent sessions ·
/// offline daemons.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onTab});

  /// Switches the shell tab (1 Agents, 2 Sessions, 3 Infra).
  final ValueChanged<int> onTab;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _ask = TextEditingController();
  String? _agentId;

  @override
  void initState() {
    super.initState();
    _ask.addListener(() => setState(() {}));
    if (kDebugMode) _debugOpen();
  }

  /// Debug builds only (`-acDebugOpen 1`): open a recent conversation for screenshots.
  Future<void> _debugOpen() async {
    final n = await Native.debugOpen();
    if (n == null || n < 1) return;
    for (var i = 0; i < 40; i++) {
      if (!mounted) return;
      final recent = AppScope.read(context).orgData?.recent;
      if (recent != null && recent.length >= n) {
        openConversation(context, recent[n - 1]);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  @override
  void dispose() {
    _ask.dispose();
    super.dispose();
  }

  Agent? _agent(List<Agent> agents) {
    for (final a in agents) {
      if (a.id == _agentId) return a;
    }
    // Default: the built-in general agent, else the first online one.
    for (final a in agents) {
      if (a.builtin && a.health == AgentHealth.online) return a;
    }
    for (final a in agents) {
      if (a.health == AgentHealth.online) return a;
    }
    return agents.isEmpty ? null : agents.first;
  }

  Future<void> _refresh() async {
    final app = AppScope.read(context);
    await Future.wait([
      if (app.orgData != null) app.orgData!.refresh(),
      if (app.approvals != null) app.approvals!.refresh(silent: true),
    ]);
  }

  void _send(Agent? agent) {
    final t = _ask.text.trim();
    if (agent == null || t.isEmpty) return;
    _ask.clear();
    FocusScope.of(context).unfocus();
    openNewChat(context, agent, firstMessage: t);
  }

  String _greeting(AppLocalizations l, String name) {
    final first = name.trim().split(RegExp(r'\s+')).first;
    final part = greetingPart(DateTime.now());
    if (first.isEmpty) {
      return switch (part) {
        'morning' => l.greetMorningPlain,
        'afternoon' => l.greetAfternoonPlain,
        _ => l.greetEveningPlain,
      };
    }
    return switch (part) {
      'morning' => l.greetMorning(first),
      'afternoon' => l.greetAfternoon(first),
      _ => l.greetEvening(first),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final app = AppScope.of(context);
    final data = app.orgData;
    final approvals = app.approvals;
    final acc = app.current!;
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 16,
        // The Mac's sidebar already names the organization (and holds
        // appearance and Settings): the bar is the destination's title.
        title: isMacOS
            ? rootTitle(l.tabHome)
            : Row(children: [
                const BrandMark(size: 22),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(acc.orgName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
              ]),
        actions: [
          ListenableBuilder(
            listenable: approvals ?? ValueNotifier(0),
            builder: (context, _) {
              final n = approvals?.pendingCount ?? 0;
              return IconButton(
                tooltip: l.approvalsTooltip,
                onPressed: () => openApprovals(context),
                icon: Badge(
                  isLabelVisible: n > 0,
                  label: Text('$n'),
                  child: Icon(AppIcons.shieldOutlined),
                ),
              );
            },
          ),
          if (!isMacOS)
            IconButton(
              tooltip: l.switchAppearance,
              onPressed: () => app.toggleTheme(Theme.of(context).brightness),
              icon: Icon(Theme.of(context).brightness == Brightness.dark
                  ? AppIcons.lightModeOutlined
                  : AppIcons.darkModeOutlined),
            ),
          if (isMacOS)
            const SizedBox(width: 8)
          else
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 2),
            child: Semantics(
              button: true,
              label: l.accountMenu,
              child: InkResponse(
                onTap: () => openSettings(context),
                radius: 22,
                child: CircleAvatar(
                  radius: 17,
                  backgroundColor: p.brandSoft,
                  child: Text(initials(acc.userName),
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600, color: p.brandText)),
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([data, approvals]),
        builder: (context, _) {
          final agents = chatAgents(data?.agents);
          final agent = _agent(agents);
          final pending = (approvals?.pending ?? const [])
              .where((a) => !(approvals?.dismissedOnHome.contains(a.id) ?? false))
              .toList();
          final recent = (data?.recent ?? const <Conversation>[]).take(3).toList();
          final offline = data?.offlineMachines ?? const <Machine>[];
          return RefreshIndicator.adaptive(
            onRefresh: _refresh,
            child: ListView(
              padding: readablePadding(context, const EdgeInsets.fromLTRB(16, 18, 16, 24)),
              children: [
                Text(_greeting(l, acc.userName),
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w600, letterSpacing: -0.3)),
                if (pending.isNotEmpty) ...[
                  SectionHeader(
                    l.needsApproval,
                    leading: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(AppIcons.shieldOutlined, size: 16, color: p.paused),
                    ]),
                    action: l.all,
                    onAction: () => openApprovals(context),
                  ),
                  ApprovalCard(
                    key: ValueKey(pending.first.id),
                    approval: pending.first,
                    controller: approvals!,
                    onOpenSession: () => openSession(context, sessionOfApproval(pending.first)),
                    onDismiss: () => setState(() => approvals.dismissedOnHome.add(pending.first.id)),
                  ),
                  if (pending.length > 1)
                    Center(
                      child: TextButton(
                        onPressed: () => openApprovals(context),
                        child: Text(l.moreWaiting(pending.length - 1)),
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                _AskBox(
                  controller: _ask,
                  agent: agent,
                  onPick: () async {
                    final a = await pickAgent(context, selectedId: agent?.id);
                    if (a != null) setState(() => _agentId = a.id);
                  },
                  onSend: () => _send(agent),
                ),
                const SizedBox(height: 12),
                _Stats(data: data),
                SectionHeader(l.recentSessions, action: l.all, onAction: () => widget.onTab(2)),
                if (data?.recent == null && data?.recentError == null)
                  const Padding(
                      padding: EdgeInsets.all(24), child: Center(child: Spinner()))
                else if (recent.isEmpty)
                  AppCard(
                    child: Text(
                        data?.recentError != null ? l.convErrorTitle : l.noRecentSessions,
                        style: TextStyle(color: p.secondary)),
                  )
                else
                  GroupCard(children: [
                    for (final c in recent)
                      SessionTile(conversation: c, onTap: () => openConversation(context, c)),
                  ]),
                if (data?.degraded == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(l.degradedBanner, style: TextStyle(color: p.paused, fontSize: 13)),
                  ),
                if (data?.schedules != null) ...[
                  SectionHeader(l.schedulesTitle,
                      action: l.all, onAction: () => push(context, const SchedulesScreen())),
                  _UpcomingSchedules(data: data!),
                ],
                if (offline.isNotEmpty) ...[
                  SectionHeader(l.infraSection, action: l.details, onAction: () => widget.onTab(3)),
                  AppCard(
                    onTap: () => widget.onTab(3),
                    child: Row(children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                            color: p.errorSoft, borderRadius: BorderRadius.circular(8)),
                        child: Icon(AppIcons.warningAmberRounded, color: p.error, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l.daemonsOffline(offline.length),
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                          Text(
                              l.daemonsOfflineBody(
                                  offline.length, offline.map((m) => m.name).join(', ')),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: p.secondary)),
                        ]),
                      ),
                      Icon(AppIcons.chevronRight, color: p.tertiary),
                    ]),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  final a = parts.first.characters.first;
  final b = parts.length > 1 ? parts.last.characters.first : '';
  return (a + b).toUpperCase();
}

class _AskBox extends StatelessWidget {
  const _AskBox({required this.controller, required this.agent, required this.onPick, required this.onSend});
  final TextEditingController controller;
  final Agent? agent;
  final VoidCallback onPick;
  final VoidCallback onSend;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final canSend = agent != null && controller.text.trim().isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
        boxShadow: [BoxShadow(color: p.shadow, blurRadius: 3, offset: const Offset(0, 1))],
      ),
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // The Mac: Return sends, Shift-Return is a new line.
        sendOnReturn(
          text: controller,
          onSend: onSend,
          child: TextField(
            controller: controller,
            minLines: 2,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: agent == null ? l.askAnyAgent : l.askAgent(agent!.label),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              contentPadding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            ),
          ),
        ),
        Row(children: [
          const SizedBox(width: 6),
          InkWell(
            onTap: onPick,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              constraints: const BoxConstraints(minHeight: 34),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: p.border),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (agent != null)
                  AgentAvatar(
                      iconUrl: agent!.iconUrl,
                      runtime: agent!.runtime,
                      name: agent!.label,
                      size: 16,
                      showDot: false),
                const SizedBox(width: 6),
                Text(agent?.label ?? l.chooseAgent,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(width: 4),
                Icon(AppIcons.unfoldMore, size: 16, color: p.tertiary),
              ]),
            ),
          ),
          const Spacer(),
          SendButton(enabled: canSend, onPressed: onSend),
        ]),
      ]),
    );
  }
}

/// Square magenta send button (arrow up).
class SendButton extends StatelessWidget {
  const SendButton({super.key, required this.enabled, required this.onPressed});
  final bool enabled;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return Semantics(
      button: true,
      enabled: enabled,
      label: l.send,
      child: Material(
        color: enabled ? p.accent : p.accent.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled
              ? () {
                  Haptics.light();
                  onPressed();
                }
              : null,
          child: SizedBox(
              width: 40, height: 40, child: Icon(AppIcons.arrowUpward, color: Colors.white, size: 20)),
        ),
      ),
    );
  }
}

/// The next few scheduled runs, soonest first.
class _UpcomingSchedules extends StatelessWidget {
  const _UpcomingSchedules({required this.data});
  final OrgData data;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final all = data.schedules ?? const [];
    final upcoming = [
      for (final s in all)
        if (ScheduleReading(s).next case final next?) (s, next),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    if (upcoming.isEmpty) {
      return AppCard(
        child: Text(all.isEmpty ? l.schedulesEmptyTitle : l.schedulesNoUpcoming,
            style: TextStyle(color: p.secondary)),
      );
    }
    return GroupCard(children: [
      for (final (s, _) in upcoming.take(3))
        ScheduleRow(
          schedule: s,
          agent: s.agentId == null ? null : data.agent(s.agentId!),
          onTap: () => push(context, ScheduleDetailScreen(schedule: s)),
        ),
    ]);
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.data});
  final OrgData? data;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final d = data;
    final agents = d?.agents;
    final machines = d?.fleet;
    Widget tile(String label, String big, String? small) => Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 12, color: p.secondary)),
              const SizedBox(height: 4),
              Text.rich(TextSpan(children: [
                TextSpan(
                    text: big,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: p.ink)),
                if (small != null)
                  TextSpan(text: small, style: TextStyle(fontSize: 14, color: p.tertiary)),
              ])),
            ]),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: IntrinsicHeight(
        child: Row(children: [
          tile(l.agentsOnline, agents == null ? '–' : '${d!.agentsOnline}',
              agents == null ? null : '/${agents.length}'),
          VerticalDivider(width: 1, color: p.hairline),
          tile(l.runningNow, d?.recent == null ? '–' : '${d!.runningNow}', null),
          VerticalDivider(width: 1, color: p.hairline),
          tile(l.daemonsUp, machines == null ? '–' : '${d!.machinesUp}',
              machines == null ? null : '/${machines.length}'),
        ]),
      ),
    );
  }
}
