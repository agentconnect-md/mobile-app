import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../core/console_links.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';

/// Daemons that run this org's agents: the managed cloud pool and self-hosted
/// machines, with status, version, running sessions and CPU. Read-only.
class InfraScreen extends StatelessWidget {
  const InfraScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final data = AppScope.of(context).orgData;
    return ListenableBuilder(
      listenable: data ?? ValueNotifier(0),
      builder: (context, _) {
        final machines = data?.fleet;
        final cloud = (machines ?? const <Machine>[]).where((m) => m.cloud).toList();
        final own = (machines ?? const <Machine>[]).where((m) => !m.cloud).toList();
        Widget body;
        if (machines == null) {
          body = data?.machinesError == null
              ? const Padding(padding: EdgeInsets.all(40), child: Center(child: Spinner()))
              : StateView(
                  icon: data!.machinesForbidden ? AppIcons.lockOutline : AppIcons.cloudOff,
                  title: data.machinesForbidden ? l.infraForbidden : l.infraErrorTitle,
                  body: data.machinesForbidden ? null : errorText(l, data.machinesError!),
                  actionLabel: data.machinesForbidden ? null : l.tryAgain,
                  onAction: data.machinesForbidden ? null : () => data.refresh());
        } else if (machines.isEmpty) {
          body = StateView(icon: AppIcons.dnsOutlined, title: l.infraEmptyTitle, body: l.infraEmptyBody);
        } else {
          body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (cloud.isNotEmpty) ...[
              SectionHeader(l.cloud, trailing: l.managed),
              GroupCard(children: [for (final m in cloud) _MachineRow(machine: m, poolName: l.cloudPool)]),
            ],
            if (own.isNotEmpty) ...[
              SectionHeader(l.selfHosted, trailing: l.daemonsCount(own.length)),
              GroupCard(children: [
                for (final m in own)
                  InkWell(onTap: () => showDaemonDetail(context, m), child: _MachineRow(machine: m)),
              ]),
            ],
          ]);
        }
        return Scaffold(
          appBar: AppBar(
            centerTitle: false,
            toolbarHeight: rootAppBarHeight,
            title: rootTitle(l.infraTitle),
            actions: [
              if (machines != null && machines.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Center(
                    child: Text(l.onlineOf(data!.machinesUp, machines.length), style: mono(context, size: 13)),
                  ),
                ),
            ],
          ),
          body: RefreshIndicator.adaptive(
            onRefresh: () async => data?.refresh(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: readablePadding(context, const EdgeInsets.fromLTRB(16, 0, 16, 24)),
              children: [body],
            ),
          ),
        );
      },
    );
  }
}

class _MachineRow extends StatelessWidget {
  const _MachineRow({required this.machine, this.poolName});
  final Machine machine;
  final String? poolName;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final m = machine;
    final state = m.state;
    final label = switch (state) {
      AgentHealth.online => l.online,
      AgentHealth.paused => l.paused,
      AgentHealth.offline => l.offline,
    };
    final icon = m.cloud ? AppIcons.cloudOutlined : AppIcons.dnsOutlined;
    final meta = [
      if (m.cloud) l.nodesCount(m.nodes),
      if (!m.cloud && m.host != null && m.host!.isNotEmpty && m.host != m.name) m.host!,
      if (m.version != null && m.version!.isNotEmpty) 'v${m.version}',
      l.runningCount(m.activeSessions),
    ].join(' · ');
    final cpu = state == AgentHealth.offline ? null : m.cpu;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 39,
          height: 39,
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 20, color: p.secondary),
            ),
            Positioned(right: 0, bottom: 0, child: StatusDot(color: healthColor(p, state), size: 10)),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(m.cloud ? (poolName ?? m.name) : m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              if (m.notApproved) ApprovalPill(m.approval!.status) else HealthPill(state, label),
            ]),
            const SizedBox(height: 3),
            Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: UsageBar(value: cpu)),
              const SizedBox(width: 12),
              Text(cpu == null ? l.noSignal : l.cpu(cpu.round()), style: mono(context, size: 12)),
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// Pending / Revoked badge of a daemon an owner hasn't approved.
class ApprovalPill extends StatelessWidget {
  const ApprovalPill(this.status, {super.key});
  final DaemonApprovalStatus status;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return switch (status) {
      DaemonApprovalStatus.pending => Pill(l.approvalPending, fg: p.paused, bg: p.pausedSoft),
      DaemonApprovalStatus.revoked => Pill(l.approvalRevoked, fg: p.error, bg: p.errorSoft),
      DaemonApprovalStatus.approved => Pill(l.approvalApproved, fg: p.online, bg: p.onlineSoft),
    };
  }
}

/// A self-hosted daemon's detail: status and, when the server reports it, its
/// owner approval. Approving happens in the web console only (the route is
/// interactive-only: this sign-in would get 403), so owners get a link there.
Future<void> showDaemonDetail(BuildContext context, Machine m) {
  final app = AppScope.read(context);
  return showAppSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => AppScope(state: app, child: DaemonDetail(machine: m)),
  );
}

class DaemonDetail extends StatelessWidget {
  const DaemonDetail({super.key, required this.machine});
  final Machine machine;

  Future<void> _openConsole(BuildContext context) async {
    final app = AppScope.read(context);
    final slug = await currentOrgSlug(app);
    final u = consoleUri(app, slug, 'daemons/${machine.id}');
    if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final app = AppScope.of(context);
    final m = machine;
    final a = m.approval;
    final state = m.state;
    final health = switch (state) {
      AgentHealth.online => l.online,
      AgentHealth.paused => l.paused,
      AgentHealth.offline => l.offline,
    };
    String? by;
    if (a?.changedBy != null) {
      by = a!.changedBy == app.current?.userId ? l.approvalByYou : a.changedBy;
    }
    final source = switch (a?.source) {
      null => null,
      'owner' => l.approvalSourceOwner,
      'system' => l.approvalSourceSystem,
      'legacy_migration' => l.approvalSourceLegacy,
      final s => s,
    };
    final canLink = consoleUri(app, '-', 'daemons') != null;
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 110, child: Text(k, style: TextStyle(color: p.secondary, fontSize: 14))),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 14))),
          ]),
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(m.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          if (m.notApproved) ApprovalPill(a!.status) else HealthPill(state, health),
        ]),
        const SizedBox(height: 12),
        row(l.daemonStatus, health),
        if (m.host != null && m.host!.isNotEmpty) row(l.daemonHost, m.host!),
        if (m.version != null && m.version!.isNotEmpty) row(l.daemonVersion, 'v${m.version}'),
        if (a != null) ...[
          row(l.approvalLabel, switch (a.status) {
            DaemonApprovalStatus.pending => l.approvalPending,
            DaemonApprovalStatus.approved => l.approvalApproved,
            DaemonApprovalStatus.revoked => l.approvalRevoked,
          }),
          if (source != null) row(l.approvalSource, source),
          if (a.changedAt != null) row(l.approvalChanged, listTime(a.changedAt)),
          if (by != null) row(l.approvalChangedBy, by),
        ],
        if (m.notApproved) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: p.sunken, borderRadius: BorderRadius.circular(12), border: Border.all(color: p.border)),
            child: Text(
              a!.status == DaemonApprovalStatus.pending ? l.approvalPendingBody : l.approvalRevokedBody,
              style: TextStyle(color: p.secondary, fontSize: 14),
            ),
          ),
          if (m.canManageApproval) ...[
            const SizedBox(height: 12),
            Text(l.approvalOwnerHint, style: TextStyle(color: p.secondary, fontSize: 13)),
            if (canLink) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _openConsole(context),
                icon: Icon(AppIcons.openInNew, size: 18),
                label: Text(l.openInConsole),
              ),
            ],
          ],
        ],
      ]),
    );
  }
}
