import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/schedules.dart';
import '../../core/auth/app_state.dart';
import '../../core/org_data.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/adaptive.dart';
import '../../ui/errors.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../nav.dart';
import 'schedule_detail_screen.dart';
import 'schedule_row.dart';

/// The org's scheduled runs (the console's "Schedules"): what runs, for which
/// agent, when next. Opened from Home. Adding, editing and deleting stay in
/// the desktop console; a schedule's page turns it on or off and runs it now.
class SchedulesScreen extends StatelessWidget {
  const SchedulesScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final data = AppScope.of(context).orgData;
    if (data == null) return const Scaffold(body: Center(child: Spinner()));
    return SchedulesView(
      data: data,
      onOpen: (s) => push(context, ScheduleDetailScreen(schedule: s)),
    );
  }
}

class SchedulesView extends StatelessWidget {
  const SchedulesView({super.key, required this.data, required this.onOpen});
  final OrgData data;
  final ValueChanged<Schedule> onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: data,
      builder: (context, _) {
        final schedules = data.schedules;
        final error = data.schedulesError;
        final Widget body;
        if (schedules == null) {
          final forbidden = error is ApiException && error.status == 403;
          body = error == null
              ? const Padding(padding: EdgeInsets.all(40), child: Center(child: Spinner()))
              : StateView(
                  icon: forbidden ? AppIcons.lockOutline : AppIcons.cloudOff,
                  title: forbidden ? l.schedulesForbidden : l.schedulesErrorTitle,
                  body: forbidden ? null : errorText(l, error),
                  actionLabel: forbidden ? null : l.tryAgain,
                  onAction: forbidden ? null : data.refreshSchedules);
        } else if (schedules.isEmpty) {
          body = StateView(icon: AppIcons.timerOutlined, title: l.schedulesEmptyTitle, body: l.schedulesEmptyBody);
        } else {
          body = Padding(
            padding: const EdgeInsets.only(top: 16),
            child: GroupCard(children: [
              for (final s in schedules)
                ScheduleRow(
                  key: ValueKey(s.id),
                  schedule: s,
                  agent: s.agentId == null ? null : data.agent(s.agentId!),
                  onTap: () => onOpen(s),
                ),
            ]),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(l.schedulesTitle),
            actions: [
              if (schedules != null && schedules.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Center(
                    child: Text(l.schedulesEnabledCount(schedules.where((s) => s.enabled).length),
                        style: mono(context, size: 13)),
                  ),
                ),
            ],
          ),
          body: RefreshIndicator.adaptive(
            onRefresh: data.refresh,
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
