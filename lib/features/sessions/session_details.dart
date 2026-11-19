import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/adaptive.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'transcript.dart';

/// What the Details sheet lists about one session's run. A null value means
/// the server didn't report it, and its row is left out.
class SessionFacts {
  const SessionFacts({
    this.duration,
    this.toolCalls,
    this.usage,
    this.daemon,
    this.runsOn,
    this.runtime,
    this.model,
  });

  /// First to last message, and the tool calls between them: read from the
  /// transcript, so only known once the whole transcript is loaded.
  final Duration? duration;
  final int? toolCalls;
  final SessionUsage? usage;

  /// The machine that holds the session, by name.
  final String? daemon;

  /// Another group member that runs it, or why it stayed with its holder.
  final String? runsOn;
  final String? runtime;
  final String? model;

  /// [session] is the list row; [detail] the fresher `GET sessions/{id}` reply,
  /// which alone carries the placement verdict. [transcript] is the session's
  /// messages when all of them are loaded, else null.
  factory SessionFacts.of(
    AppLocalizations l, {
    required SessionRow session,
    SessionRow? detail,
    Agent? agent,
    List<Machine> machines = const [],
    List<TranscriptItem>? transcript,
  }) {
    String? text(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
    Machine? machine(String? id) => id == null ? null : machines.where((m) => m.id == id).firstOrNull;
    // A name, never a whole machine id.
    String short(String id) => id.length > 12 ? id.substring(0, 8) : id;

    final agentDaemon = text(agent?.daemonId);
    var daemonId = text(detail?.daemonId) ?? text(session.daemonId) ?? agentDaemon;
    // The agent's placement can be a set ("pool"), not a machine.
    if (daemonId == 'pool' || daemonId == '—') daemonId = null;
    final daemon = text(machine(daemonId)?.name) ??
        (daemonId == null || daemonId == agentDaemon ? text(agent?.daemonName) : null) ??
        (daemonId == null ? null : short(daemonId));

    final executor = text(detail?.executorDaemonId) ?? text(session.executorDaemonId);
    final stayed = stayedHomeText(l, detail?.stayedHomeReason ?? session.stayedHomeReason);
    final runsOn = executor != null && executor != daemonId
        ? text(machine(executor)?.name) ?? short(executor)
        : stayed == null
            ? null
            : daemon == null
                ? stayed
                : '$daemon · $stayed';

    final runtime = text(detail?.runtime) ?? text(session.runtime) ?? text(agent?.runtime);
    final model = text(detail?.model) ?? text(session.model) ?? text(agent?.model);
    final stats = transcript == null || transcript.isEmpty ? null : runStats(transcript);
    return SessionFacts(
      duration: stats?.$1,
      toolCalls: stats?.$2,
      usage: detail?.usage ?? session.usage,
      daemon: daemon,
      runsOn: runsOn,
      runtime: runtime == null ? null : runtimeLabel(runtime),
      // No model reported on a known runtime: the runtime's own default ran.
      model: runtime != null && (model == null || model == 'default') ? l.detailDefaultModel : model,
    );
  }

  /// The run's own rows, in the web console's order.
  List<(String, String)> rows(AppLocalizations l) {
    final u = usage;
    return [
      if (duration != null) (l.detailDuration, durationText(duration!)),
      if (u?.totalTokens != null) (l.detailTokens, compactCount(u!.totalTokens!)),
      if (u?.costAmount != null) (l.detailCost, costText(u!.costAmount!, u.costCurrency)),
      if (toolCalls != null) (l.detailToolCalls, compactCount(toolCalls!)),
      if (daemon != null) (l.fieldDaemon, daemon!),
      if (runsOn != null) (l.detailRunsOn, runsOn!),
      if (runtime != null) (l.fieldRuntime, runtime!),
      if (model != null) (l.fieldModel, model!),
    ];
  }

  /// The token breakdown: only the counts the runtime reported.
  List<(String, String)> usageRows(AppLocalizations l) {
    final u = usage;
    if (u == null) return const [];
    return [
      if (u.inputTokens != null) (l.detailInput, compactCount(u.inputTokens!)),
      if (u.outputTokens != null) (l.detailOutput, compactCount(u.outputTokens!)),
      if (u.thoughtTokens != null) (l.detailThought, compactCount(u.thoughtTokens!)),
      if (u.cachedReadTokens != null) (l.detailCacheRead, compactCount(u.cachedReadTokens!)),
      if (u.cachedWriteTokens != null) (l.detailCacheWrite, compactCount(u.cachedWriteTokens!)),
      if (u.contextUsed != null)
        (
          l.detailContext,
          u.contextSize == null
              ? compactCount(u.contextUsed!)
              : '${compactCount(u.contextUsed!)} / ${compactCount(u.contextSize!)}',
        ),
    ];
  }
}

/// The loaded messages when they are the session's whole transcript, else
/// null: not while older pages remain, and never for the threaded timeline
/// (`view=roots`), which leaves out the agent's posts inside threads, so its
/// last page being loaded doesn't mean every message is here.
List<TranscriptItem>? completeTranscript(
  List<TranscriptItem> items, {
  required bool morePages,
  required bool rootsView,
}) =>
    morePages || rootsView ? null : items;

/// Time from the first to the last message (null when none has a time) and
/// the number of tool calls: one per call id, plus rows without an id.
(Duration?, int) runStats(List<TranscriptItem> items) {
  DateTime? first, last;
  final ids = <String>{};
  var anonymous = 0;
  for (final i in items) {
    final t = i.ts;
    if (t != null) {
      if (first == null || t.isBefore(first)) first = t;
      if (last == null || t.isAfter(last)) last = t;
    }
    if (i.kind == ItemKind.tool) {
      final id = i.toolCallId;
      id == null || id.isEmpty ? anonymous++ : ids.add(id);
    }
  }
  return (first == null ? null : last!.difference(first), ids.length + anonymous);
}

/// Why a session stayed on its holder, as a short phrase; null for a reason
/// with nothing useful to say (or one this build doesn't know).
String? stayedHomeText(AppLocalizations l, String? reason) => switch (reason) {
      'not_on_group' => l.stayedNotOnGroup,
      'group_switch_off' => l.stayedGroupSwitchOff,
      'shared_session' => l.stayedSharedSession,
      'no_candidate' => l.stayedNoCandidate,
      'candidates_full' => l.stayedCandidatesFull,
      'control_plane_unreachable' => l.stayedControlPlaneUnreachable,
      'holder_least_loaded' => l.stayedHolderLeastLoaded,
      _ => null,
    };

/// Opens the Details sheet for [session]. It shows what the list row already
/// has, then the session's own record once that is read.
Future<void> showSessionDetails(
  BuildContext context, {
  required SessionRow session,
  Agent? agent,
  List<TranscriptItem>? transcript,
}) {
  final app = AppScope.read(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => AppScope(
      state: app,
      child: _DetailsLoader(session: session, agent: agent, transcript: transcript),
    ),
  );
}

class _DetailsLoader extends StatefulWidget {
  const _DetailsLoader({required this.session, this.agent, this.transcript});
  final SessionRow session;
  final Agent? agent;
  final List<TranscriptItem>? transcript;
  @override
  State<_DetailsLoader> createState() => _DetailsLoaderState();
}

class _DetailsLoaderState extends State<_DetailsLoader> {
  SessionRow? _detail;
  bool _loading = true;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _read();
  }

  Future<void> _read() async {
    final app = AppScope.read(context);
    final org = app.current?.orgId;
    try {
      final d = org == null ? null : (await app.client.session(org, widget.session.sessionId)).$1;
      if (mounted) setState(() => _detail = d);
    } catch (_) {
      // The list row's values stay.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return SessionDetailsSheet(
      loading: _loading,
      facts: SessionFacts.of(
        AppLocalizations.of(context),
        session: widget.session,
        detail: _detail,
        agent: widget.agent,
        machines: app.orgData?.machines ?? const [],
        transcript: widget.transcript,
      ),
    );
  }
}

/// The sheet's content: label/value rows, then the token breakdown.
class SessionDetailsSheet extends StatelessWidget {
  const SessionDetailsSheet({super.key, required this.facts, this.loading = false});
  final SessionFacts facts;

  /// The session's record is still being read: shown instead of the "nothing
  /// reported" note while there is no row yet.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final rows = facts.rows(l);
    final usage = facts.usageRows(l);
    Widget row((String, String) r) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            Text(r.$1, style: TextStyle(fontSize: 15, color: p.secondary)),
            const SizedBox(width: 16),
            Expanded(
              child: Text(r.$2,
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: mono(context, size: 13, color: p.ink, weight: FontWeight.w600)),
            ),
          ]),
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.details, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (rows.isNotEmpty) GroupCard(children: [for (final r in rows) row(r)]),
        if (rows.isEmpty && usage.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: loading
                ? const Center(child: SizedBox(width: 24, height: 24, child: Spinner(strokeWidth: 2)))
                : Text(l.detailNone, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: p.secondary)),
          ),
        if (usage.isNotEmpty) ...[
          if (rows.isNotEmpty) const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 8),
            child: Text(l.detailTokenUsage,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.secondary)),
          ),
          GroupCard(children: [for (final r in usage) row(r)]),
        ],
      ]),
    );
  }
}
