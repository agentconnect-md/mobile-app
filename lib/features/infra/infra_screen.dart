import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

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
              ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
              : StateView(
                  icon: data!.machinesForbidden ? Icons.lock_outline : Icons.cloud_off,
                  title: data.machinesForbidden ? l.infraForbidden : l.infraErrorTitle,
                  body: data.machinesForbidden ? null : errorText(l, data.machinesError!),
                  actionLabel: data.machinesForbidden ? null : l.tryAgain,
                  onAction: data.machinesForbidden ? null : () => data.refresh());
        } else if (machines.isEmpty) {
          body = StateView(icon: Icons.dns_outlined, title: l.infraEmptyTitle, body: l.infraEmptyBody);
        } else {
          body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (cloud.isNotEmpty) ...[
              SectionHeader(l.cloud, trailing: l.managed),
              GroupCard(children: [for (final m in cloud) _MachineRow(machine: m, poolName: l.cloudPool)]),
            ],
            if (own.isNotEmpty) ...[
              SectionHeader(l.selfHosted, trailing: l.daemonsCount(own.length)),
              GroupCard(children: [for (final m in own) _MachineRow(machine: m)]),
            ],
          ]);
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(l.infraTitle),
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
          body: RefreshIndicator(
            onRefresh: () async => data?.refresh(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
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
    final icon = m.cloud ? Icons.cloud_outlined : Icons.dns_outlined;
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
              HealthPill(state, label),
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
