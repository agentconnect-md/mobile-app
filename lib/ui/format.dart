import '../l10n/app_localizations.dart';
import 'package:intl/intl.dart';

import '../core/api/models.dart';

String relativeTime(DateTime? t) {
  if (t == null) return '';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

/// "10m ago", or "just now" under a minute.
String agoText(AppLocalizations l, DateTime t) {
  final r = relativeTime(t);
  return r == 'now' ? l.justNow : l.ago(r);
}

String sourceName(AppLocalizations l, String source) => switch (source) {
      'slack' => l.sourceSlack,
      'telegram' => l.sourceTelegram,
      'discord' => l.sourceDiscord,
      'feishu' => l.sourceFeishu,
      'github' => l.sourceGitHub,
      'chat' => l.webChat,
      _ => '',
    };

String stateName(AppLocalizations l, ActivityState s) => switch (s) {
      ActivityState.working => l.statusWorking,
      ActivityState.awaiting => l.statusWaiting,
      ActivityState.idle => l.statusIdle,
    };

/// "2:14 PM" today, "Mon" this week, otherwise "Oct 3" (the design's list times).
String listTime(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return DateFormat.jm().format(t);
  if (diff > 0 && diff < 7) return DateFormat.E().format(t);
  if (t.year == n.year) return DateFormat.MMMd().format(t);
  return DateFormat.yMMMd().format(t);
}

/// "Good morning" / "Good afternoon" / "Good evening" key for the hour.
String greetingPart(DateTime t) => t.hour < 12
    ? 'morning'
    : t.hour < 18
        ? 'afternoon'
        : 'evening';
