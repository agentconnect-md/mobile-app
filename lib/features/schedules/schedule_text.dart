import 'package:intl/intl.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/api/schedules.dart';
import '../../core/cron.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/format.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// "Weekdays at 09:00" for the simple shapes the console's builder writes
/// (hourly, daily, weekdays, weekly); null for anything else, which is shown
/// as the expression itself.
String? scheduleWords(AppLocalizations l, String expression) {
  final p = CronPreset.of(expression);
  if (p == null) return null;
  final time = '${_two(p.hour)}:${_two(p.minute)}';
  return switch (p.kind) {
    CronPresetKind.hourly => p.minute == 0 ? l.scheduleEveryHour : l.scheduleHourlyAt(_two(p.minute)),
    CronPresetKind.daily => l.scheduleDailyAt(time),
    CronPresetKind.weekdays => l.scheduleWeekdaysAt(time),
    // 2024-01-07 was a Sunday.
    CronPresetKind.weekly =>
      l.scheduleWeeklyAt(DateFormat.EEEE().format(DateTime(2024, 1, 7 + p.weekday)), time),
  };
}

// Dates and times use the default locale's formats, as `ui/format.dart` does.

/// When a run is due, in this device's time: "now", "in 14 min",
/// "Today 3:00 PM", "Tomorrow 9:00 AM", "Mon 9:00 AM", then "Dec 3 9:00 AM".
String nextRunText(AppLocalizations l, DateTime next, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final t = next.toLocal();
  final minutes = (t.difference(n).inSeconds / 60).round();
  if (minutes < 1) return l.scheduleWhenNow;
  if (minutes < 60) return l.scheduleWhenMinutes(minutes);
  final time = DateFormat.jm().format(t);
  final days = DateTime(t.year, t.month, t.day).difference(DateTime(n.year, n.month, n.day)).inHours / 24;
  final ahead = days.round();
  if (ahead == 0) return l.scheduleWhenToday(time);
  if (ahead == 1) return l.scheduleWhenTomorrow(time);
  if (ahead < 7) return '${DateFormat.E().format(t)} $time';
  return '${DateFormat.MMMd().format(t)} $time';
}

/// When a run started: "Today 2:14 PM", otherwise "Nov 3 2:14 PM" (with the
/// year when it isn't this one).
String runStartText(AppLocalizations l, DateTime? started, {DateTime? now}) {
  if (started == null) return '—';
  final n = now ?? DateTime.now();
  final t = started.toLocal();
  final time = DateFormat.jm().format(t);
  if (t.year == n.year && t.month == n.month && t.day == n.day) return l.scheduleWhenToday(time);
  final day = t.year == n.year ? DateFormat.MMMd() : DateFormat.yMMMd();
  return '${day.format(t)} $time';
}

/// "4m 05s", or "—" for a run that hasn't reported one.
String runDurationText(int? ms) {
  if (ms == null || ms < 0) return '—';
  final s = (ms / 1000).round();
  return s < 60 ? '${s}s' : '${s ~/ 60}m ${_two(s % 60)}s';
}

/// The agent a schedule drives: its name, the start of its id when this
/// sign-in can't see the agent, or "No agent" when it was deleted.
String scheduleAgentName(AppLocalizations l, Schedule s, Agent? agent) {
  if (agent != null) return agent.label;
  final id = s.agentId;
  if (id == null || id.isEmpty) return l.scheduleNoAgent;
  return id.length > 8 ? id.substring(0, 8) : id;
}

String scheduleName(AppLocalizations l, Schedule s) {
  final n = s.name?.trim();
  return n == null || n.isEmpty ? l.scheduleUnnamed : n;
}

/// Why turning a schedule on or off, or running it, failed. The server says
/// why it refused (no edit rights, the agent is being moved, its daemon is
/// offline); that sentence is shown as it came.
String scheduleActionError(AppLocalizations l, Object e) {
  if (e is ApiException && const {400, 403, 409, 503}.contains(e.status)) {
    final m = e.message?.trim();
    if (m != null && m.isNotEmpty) return '${m[0].toUpperCase()}${m.substring(1)}${m.endsWith('.') ? '' : '.'}';
  }
  return errorText(l, e);
}

/// When a schedule last ran, for a list row: "Last run 2h ago" / "Never run".
String lastRunText(AppLocalizations l, Schedule s) =>
    s.lastRunAt == null ? l.scheduleNeverRan : l.scheduleLastRan(agoText(l, s.lastRunAt!));
