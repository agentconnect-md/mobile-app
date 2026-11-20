import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/api/schedules.dart';
import '../../core/auth/app_state.dart';
import '../../core/console_links.dart';
import '../../core/org_data.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/adaptive.dart';
import '../../ui/icons.dart';
import '../../ui/platform.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../nav.dart';
import '../sessions/session_filters.dart';
import 'schedule_row.dart';
import 'schedule_text.dart';

/// One schedule: when it runs, what it asks, where it posts, who can see it,
/// and its recent runs. With write access (and edit rights on the schedule):
/// a switch to turn it on or off, and Run now.
class ScheduleDetailScreen extends StatelessWidget {
  const ScheduleDetailScreen({super.key, required this.schedule});
  final Schedule schedule;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final data = app.orgData;
    if (data == null) return const Scaffold(body: Center(child: Spinner()));
    return ScheduleDetailView(
      schedule: schedule,
      data: data,
      canWrite: app.canWrite,
      userId: app.current?.userId,
      onOpenAgent: (a) => openAgent(context, a),
      onOpenSession: (s) => openSession(context, s),
      onOpenConsole: consoleUri(app, '-', 'crons') == null
          ? null
          : () async {
              final slug = await currentOrgSlug(app);
              final u = consoleUri(app, slug, 'crons/${schedule.id}');
              if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
            },
    );
  }
}

class ScheduleDetailView extends StatefulWidget {
  const ScheduleDetailView({
    super.key,
    required this.schedule,
    required this.data,
    required this.canWrite,
    this.userId,
    this.onOpenAgent,
    this.onOpenSession,
    this.onOpenConsole,
  });

  /// The schedule as the list had it; replaced by [data]'s copy when it changes.
  final Schedule schedule;
  final OrgData data;

  /// The sign-in was granted write access.
  final bool canWrite;

  /// The signed-in user, to say "You" for created / modified by.
  final String? userId;
  final ValueChanged<Agent>? onOpenAgent;
  final ValueChanged<SessionRow>? onOpenSession;

  /// Opens this schedule in the web console; null when the console is unknown.
  final VoidCallback? onOpenConsole;

  @override
  State<ScheduleDetailView> createState() => _ScheduleDetailViewState();
}

class _ScheduleDetailViewState extends State<ScheduleDetailView> {
  List<ScheduleRun>? _runs;
  bool _runsFailed = false;
  bool _busy = false;
  String? _notice;
  bool _noticeIsError = false;
  String? _channelName;
  String? _opening;

  /// Runs are re-read every ten seconds while one is running, and for two
  /// minutes after Run now (the daemon reports the run on its own time).
  Timer? _poll;
  DateTime? _watchUntil;

  OrgData get _data => widget.data;
  Schedule get _schedule => _data.schedule(widget.schedule.id) ?? widget.schedule;

  @override
  void initState() {
    super.initState();
    _loadRuns();
    _loadChannelName();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      final watching = _watchUntil != null && DateTime.now().isBefore(_watchUntil!);
      if (watching || (_runs ?? const []).any((r) => r.status == ScheduleRunStatus.running)) _loadRuns();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _loadRuns() async {
    try {
      final runs = await _data.client.scheduleRuns(_data.orgId, widget.schedule.id);
      if (!mounted) return;
      setState(() {
        _runs = runs;
        _runsFailed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _runsFailed = _runs == null);
    }
  }

  Future<void> _loadChannelName() async {
    if (widget.schedule.targetChannel == null) return;
    try {
      final name = await _data.client.scheduleChannelName(_data.orgId, widget.schedule);
      if (mounted && name != null) setState(() => _channelName = name);
    } catch (_) {
      // The channel id is shown instead.
    }
  }

  Future<void> _refresh() async {
    await Future.wait([_data.refreshSchedules(), _loadRuns()]);
  }

  void _say(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _notice = text;
      _noticeIsError = error;
    });
  }

  Future<void> _setEnabled(Schedule s, bool on) async {
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      _data.putSchedule(await _data.client.setScheduleEnabled(_data.orgId, s, on));
    } catch (e) {
      _say(scheduleActionError(l, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runNow(Schedule s, String agentName) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmDialog(
      context,
      title: l.scheduleRunConfirmTitle(scheduleName(l, s)),
      body: l.scheduleRunConfirmBody(agentName),
      cancel: l.cancel,
      confirm: l.scheduleRunNow,
    );
    if (ok != true || !mounted) return;
    Haptics.medium();
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await _data.client.runSchedule(_data.orgId, s.id);
      _watchUntil = DateTime.now().add(const Duration(minutes: 2));
      _say(l.scheduleRunRequested);
      unawaited(_loadRuns());
    } catch (e) {
      _say(scheduleActionError(l, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSession(ScheduleRun run) async {
    final id = run.sessionId;
    final open = widget.onOpenSession;
    if (id == null || open == null || _opening != null) return;
    final l = AppLocalizations.of(context);
    setState(() => _opening = run.id);
    try {
      final (row, _) = await _data.client.session(_data.orgId, id);
      if (mounted) open(row);
    } on ApiException catch (e) {
      _say(e.status == 404 ? l.scheduleSessionGone : scheduleActionError(l, e), error: true);
    } catch (e) {
      _say(scheduleActionError(l, e), error: true);
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  /// The session's title when the recent list has it.
  String? _sessionTitle(String id) {
    for (final c in _data.recent ?? const <Conversation>[]) {
      for (final s in c.sessions) {
        if (s.sessionId == id) return s.title;
      }
    }
    return null;
  }

  String _who(AppLocalizations l, String? by, DateTime? at) => [
        if (by != null && by == widget.userId) l.approvalByYou,
        if (at != null) DateFormat.yMMMd().format(at),
      ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return ListenableBuilder(
      listenable: _data,
      builder: (context, _) {
        final s = _schedule;
        final r = ScheduleReading(s);
        final agent = s.agentId == null ? null : _data.agent(s.agentId!);
        final agentName = scheduleAgentName(l, s, agent);
        final canAct = widget.canWrite && s.canEdit;
        final orphan = s.agentId == null;
        final next = r.next;
        final nextText = next != null
            ? nextRunText(l, next)
            : r.invalid
                ? l.scheduleInvalid
                : s.enabled
                    ? '—'
                    : l.paused;
        final channel = s.targetChannel;
        final runs = _runs;
        return Scaffold(
          appBar: AppBar(title: Text(scheduleName(l, s))),
          bottomNavigationBar: canAct
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: FilledButton.icon(
                      onPressed: _busy || orphan ? null : () => _runNow(s, agentName),
                      icon: Icon(AppIcons.playArrow, size: 20),
                      label: Text(l.scheduleRunNow),
                    ),
                  ),
                )
              : null,
          body: RefreshIndicator.adaptive(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(10)),
                    child: Icon(AppIcons.timerOutlined,
                        size: 26, color: r.enabled && !r.invalid ? p.brandText : p.tertiary),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text.rich(scheduleSpan(context, s, size: 17),
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text([agentName, ?r.zone].join(' · '), style: TextStyle(fontSize: 14, color: p.secondary)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Padding(padding: const EdgeInsets.only(top: 2), child: SchedulePill(r)),
                ]),
                if (r.invalid) ...[
                  const SizedBox(height: 12),
                  _Notice(text: l.scheduleInvalidBody, error: true),
                ],
                if (_notice != null) ...[
                  const SizedBox(height: 12),
                  _Notice(text: _notice!, error: _noticeIsError),
                ],
                if (canAct) ...[
                  const SizedBox(height: 16),
                  GroupCard(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(l.scheduleSwitch, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                            const SizedBox(height: 2),
                            Text(
                              orphan
                                  ? l.scheduleOrphanNote
                                  : next != null
                                      ? l.scheduleNext(nextRunText(l, next))
                                      : lastRunText(l, s),
                              style: orphan ? TextStyle(fontSize: 13, color: p.secondary) : mono(context, size: 12),
                            ),
                          ]),
                        ),
                        const SizedBox(width: 8),
                        Switch.adaptive(
                          value: s.enabled,
                          onChanged: _busy || orphan ? null : (on) => _setEnabled(s, on),
                        ),
                      ]),
                    ),
                  ]),
                ],
                SectionHeader(l.scheduleTask),
                AppCard(child: Text(s.prompt, style: const TextStyle(fontSize: 14, height: 1.45))),
                SectionHeader(l.scheduleConfiguration),
                GroupCard(children: [
                  _Field(
                    l.scheduleFieldAgent,
                    agentName,
                    onTap: agent == null || widget.onOpenAgent == null ? null : () => widget.onOpenAgent!(agent),
                  ),
                  _Field(l.scheduleFieldCron, s.expression, monoValue: true),
                  _Field(l.scheduleFieldZone, s.timezone),
                  _Field(l.scheduleNextRun, nextText),
                  _Field(l.scheduleLastRun, s.lastRunAt == null ? l.scheduleNeverRan : runStartText(l, s.lastRunAt)),
                  _Field(
                    l.scheduleFieldPostTo,
                    channel == null
                        ? l.schedulePostNowhere
                        : '${integrationLabel(l, s.targetPlatform)} · ${_channelName ?? channel}',
                  ),
                  _Field(
                    l.scheduleFieldVisibility,
                    s.restricted ? l.scheduleVisibilitySelected : l.scheduleVisibilityEveryone,
                    icon: s.restricted ? AppIcons.lockOutline : null,
                  ),
                  _Field(l.scheduleFieldCreated, _who(l, s.createdBy, s.createdAt)),
                  _Field(l.scheduleFieldModified, _who(l, s.lastModifiedBy, s.lastModifiedAt)),
                ]),
                SectionHeader(l.scheduleRecentRuns,
                    trailing: runs == null || runs.isEmpty ? null : l.scheduleRunsCount(runs.length)),
                if (runs == null)
                  _runsFailed
                      ? AppCard(child: Text(l.scheduleRunsError, style: TextStyle(color: p.secondary)))
                      : const Padding(padding: EdgeInsets.all(24), child: Center(child: Spinner()))
                else if (runs.isEmpty)
                  AppCard(child: Text(l.scheduleNoRuns, style: TextStyle(color: p.secondary)))
                else
                  GroupCard(children: [
                    for (final run in runs.take(20))
                      _RunRow(
                        run: run,
                        sessionTitle: run.sessionId == null ? null : _sessionTitle(run.sessionId!),
                        opening: _opening == run.id,
                        onOpen: run.sessionId == null || widget.onOpenSession == null ? null : () => _openSession(run),
                      ),
                  ]),
                const SizedBox(height: 16),
                Text(
                  [if (!canAct) l.scheduleViewOnly, l.scheduleConsoleNote].join(' '),
                  style: TextStyle(fontSize: 13, color: p.secondary),
                ),
                if (widget.onOpenConsole != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      onPressed: widget.onOpenConsole,
                      icon: Icon(AppIcons.openInNew, size: 18),
                      label: Text(l.openInConsole),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A line the person should read: the result of an action, or why it failed.
class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.error = false});
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: error ? p.errorSoft : p.sunken,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(error ? AppIcons.errorOutline : AppIcons.checkCircleOutline,
              size: 18, color: error ? p.error : p.secondary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(fontSize: 14, color: error ? p.error : p.ink))),
        ]),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.monoValue = false, this.icon, this.onTap});
  final String label;
  final String value;
  final bool monoValue;
  final IconData? icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final v = value.isEmpty ? '—' : value;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Text(label, style: TextStyle(fontSize: 14, color: p.secondary)),
            const SizedBox(width: 16),
            Expanded(
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (icon != null) ...[Icon(icon, size: 14, color: p.tertiary), const SizedBox(width: 6)],
                Flexible(
                  child: Text(v,
                      textAlign: TextAlign.right,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: monoValue
                          ? mono(context, size: 13, color: p.ink)
                          : const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                ),
              ]),
            ),
            if (onTap != null) Icon(AppIcons.chevronRight, size: 20, color: p.tertiary),
          ]),
        ),
      ),
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({required this.run, this.sessionTitle, this.opening = false, this.onOpen});
  final ScheduleRun run;
  final String? sessionTitle;
  final bool opening;

  /// Opens the run's session; null when it made none.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final (color, word) = switch (run.status) {
      ScheduleRunStatus.running => (p.paused, l.scheduleRunRunning),
      ScheduleRunStatus.success => (p.online, l.scheduleRunSuccess),
      ScheduleRunStatus.failed => (p.error, l.scheduleRunFailed),
    };
    final title = sessionTitle?.trim();
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 5), child: StatusDot(color: color, size: 8)),
        const SizedBox(width: 11),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Row(children: [
                  Flexible(
                    child: Text(runStartText(l, run.startedAt),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12, color: p.ink)),
                  ),
                  const SizedBox(width: 8),
                  Text(word, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
                ]),
              ),
              const SizedBox(width: 8),
              Text(runDurationText(run.durationMs), style: mono(context, size: 12)),
            ]),
            const SizedBox(height: 2),
            Text.rich(
              TextSpan(children: [
                run.sessionId == null
                    ? TextSpan(text: l.scheduleNoSession)
                    : TextSpan(
                        text: title == null || title.isEmpty ? l.scheduleOpenSession : title,
                        style: TextStyle(color: onOpen == null ? null : p.brandText, fontWeight: FontWeight.w500)),
                if (run.reason != null)
                  TextSpan(
                      text: ' · ${run.reason}',
                      style: TextStyle(color: run.status == ScheduleRunStatus.failed ? p.error : null)),
              ]),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: p.secondary),
            ),
          ]),
        ),
        if (onOpen != null)
          SizedBox(
            width: 24,
            height: 24,
            child: opening
                ? const Padding(padding: EdgeInsets.all(4), child: Spinner(strokeWidth: 2))
                : Icon(AppIcons.chevronRight, size: 20, color: p.tertiary),
          ),
      ]),
    );
    if (onOpen == null) return row;
    return Semantics(
      button: true,
      label: l.scheduleOpenSession,
      child: InkWell(onTap: onOpen, child: row),
    );
  }
}
