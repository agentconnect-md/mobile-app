import '../l10n/app_localizations.dart';
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

String sourceName(AppLocalizations l, String source) => switch (source) {
      'slack' => l.sourceSlack,
      'telegram' => l.sourceTelegram,
      'discord' => l.sourceDiscord,
      'feishu' => l.sourceFeishu,
      'github' => l.sourceGitHub,
      _ => l.sourceChat,
    };

String stateName(AppLocalizations l, ActivityState s) => switch (s) {
      ActivityState.working => l.statusWorking,
      ActivityState.awaiting => l.statusWaiting,
      ActivityState.idle => l.statusIdle,
    };
