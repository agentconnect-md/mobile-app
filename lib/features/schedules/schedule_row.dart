import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/api/schedules.dart';
import '../../core/cron.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'schedule_text.dart';

/// What a schedule's expression and switch add up to, worked out once per build.
class ScheduleReading {
  ScheduleReading(Schedule s, {DateTime? now})
      : expr = CronExpr.tryParse(s.expression),
        enabled = s.enabled {
    next = enabled ? expr?.next(s.timezone, after: now) : null;
    // The zone is named only when its clocks differ from this device's.
    zone = cronZoneMatchesDevice(s.timezone, at: now) ? null : s.timezone;
  }

  final CronExpr? expr;
  final bool enabled;

  /// Null when paused, unreadable, or in a zone unknown to this build.
  late final DateTime? next;
  late final String? zone;

  bool get invalid => expr == null;
}

/// enabled / paused / invalid.
class SchedulePill extends StatelessWidget {
  const SchedulePill(this.reading, {super.key});
  final ScheduleReading reading;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    if (reading.invalid) return Pill(l.scheduleInvalid, fg: p.error, bg: p.errorSoft);
    return reading.enabled
        ? Pill(l.scheduleEnabled, fg: p.online, bg: p.onlineSoft)
        : Pill(l.paused, fg: p.paused, bg: p.pausedSoft);
  }
}

/// "Weekdays at 09:00", or the expression in mono when it has no plain reading.
InlineSpan scheduleSpan(BuildContext context, Schedule s, {double size = 13, Color? color}) {
  final words = scheduleWords(AppLocalizations.of(context), s.expression);
  return words != null
      ? TextSpan(text: words)
      : TextSpan(text: s.expression, style: mono(context, size: size - 1, color: color));
}

/// One schedule in a list: name, agent, when it runs, next run, state.
class ScheduleRow extends StatelessWidget {
  const ScheduleRow({super.key, required this.schedule, this.agent, this.onTap, this.now});
  final Schedule schedule;

  /// The agent it drives, when this sign-in can see it.
  final Agent? agent;
  final VoidCallback? onTap;

  /// The time "next run" is counted from (tests); default: now.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final s = schedule;
    final r = ScheduleReading(s, now: now);
    final next = r.next;
    final named = s.name?.trim().isNotEmpty ?? false;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(8)),
            child: Icon(AppIcons.timerOutlined, size: 20, color: r.enabled && !r.invalid ? p.brandText : p.tertiary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Row(children: [
                    Flexible(
                      child: Text(scheduleName(l, s),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600, color: named ? null : p.secondary)),
                    ),
                    if (s.restricted) ...[
                      const SizedBox(width: 6),
                      Icon(AppIcons.lockOutline, size: 14, color: p.tertiary, semanticLabel: l.scheduleRestricted),
                    ],
                  ]),
                ),
                const SizedBox(width: 8),
                SchedulePill(r),
              ]),
              const SizedBox(height: 3),
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: '${scheduleAgentName(l, s, agent)} · '),
                  scheduleSpan(context, s, color: p.secondary),
                  // The zone is named when its clocks aren't this device's.
                  if (r.zone != null) TextSpan(text: ' · ${r.zone}'),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: p.secondary),
              ),
              const SizedBox(height: 3),
              Text(
                next != null ? l.scheduleNext(nextRunText(l, next, now: now)) : lastRunText(l, s),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono(context, size: 12),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
