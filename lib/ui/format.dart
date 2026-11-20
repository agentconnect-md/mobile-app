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

/// A count as the web console shows it: 60, 1.2K, 45K, 2.32M, 1.23B.
String compactCount(num n) {
  // Zeros go only after a decimal point ("10" stays "10"); the integer part is grouped.
  String fmt(double v, int digits) {
    var s = v.toStringAsFixed(digits);
    if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
    final dot = s.indexOf('.');
    final whole = dot < 0 ? s : s.substring(0, dot);
    return NumberFormat.decimalPattern('en_US').format(int.parse(whole)) + (dot < 0 ? '' : s.substring(dot));
  }

  if (n >= 1e9) return '${fmt(n / 1e9, n >= 1e10 ? 0 : 2)}B';
  if (n >= 1e6) return '${fmt(n / 1e6, n >= 1e7 ? 0 : 2)}M';
  if (n >= 1e3) return '${fmt(n / 1e3, n >= 1e4 ? 0 : 1)}K';
  return NumberFormat.decimalPattern('en_US').format(n);
}

/// A metered cost with its currency: "$1.25" for USD, "€0.40" for EUR. An
/// unknown code is written before the amount; with no code, the amount alone.
String costText(double amount, String? currency) {
  final code = currency?.trim().toUpperCase() ?? '';
  if (code.isEmpty) return NumberFormat('#,##0.00', 'en_US').format(amount);
  if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) return '$code ${NumberFormat('#,##0.00', 'en_US').format(amount)}';
  final f = NumberFormat.simpleCurrency(locale: 'en_US', name: code);
  // No symbol known for the code: keep the two apart ("XTS 1.00").
  return f.currencySymbol == code ? '$code ${NumberFormat('#,##0.00', 'en_US').format(amount)}' : f.format(amount);
}

/// A run's length: "42s", "3m 07s", "1h 05m".
String durationText(Duration d) {
  final total = (d.inMilliseconds / 1000).round();
  final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
  if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
  return '${s}s';
}

/// The runtime's product name for its id ("claude-acp" → "Claude Code");
/// an id the app doesn't know is shown as it is.
String runtimeLabel(String id) => switch (id.replaceFirst(RegExp(r'-acp$'), '')) {
      'claude' => 'Claude Code',
      'codex' => 'Codex',
      'opencode' => 'opencode',
      _ => id,
    };

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
