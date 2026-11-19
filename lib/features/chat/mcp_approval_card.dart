import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/mcp_operations.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/icons.dart';
import '../../ui/platform.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'bubbles.dart';

/// Which operations a conversation raised itself: those whose id its own
/// recorded rows carry (a pending write's tool result names it). A
/// coordinator's tasks write under its conversation's grant, and each answers
/// its own on its thread.
bool Function(String operationId) mcpRaisedIn(List<Entry> rows) => (id) => rows.any((e) => switch (e) {
      ToolEntry(:final title, :final body) => title.contains(id) || (body?.contains(id) ?? false),
      AgentEntry(:final text) => text.contains(id),
      UserEntry(:final text) => text.contains(id),
      _ => false,
    });

/// A decided operation the owner must still be able to see. [outcome] is the
/// last answer from the server; null means the decision's response was lost
/// and the true state is unknown until it is checked.
class _Settled {
  const _Settled(this.operation, this.approved, this.outcome);
  final McpOperation operation;
  final bool approved;
  final McpOperation? outcome;

  bool get unresolved => outcome == null || outcome!.executing;
}

/// The MCP write operations an agent asked for in this webchat conversation,
/// waiting for its owner: Approve and run, or Deny. Read over REST (the
/// server lists only what is pending), so the list is asked again every few
/// seconds while the chat is open. Arguments and results are shown, never
/// logged or kept.
class McpApprovalStrip extends StatefulWidget {
  const McpApprovalStrip({
    super.key,
    required this.client,
    required this.orgId,
    required this.agentId,
    required this.conversationId,
    this.raisedHere,
    this.onDecided,
    this.turnRunning = false,
    this.pollEvery = const Duration(seconds: 3),
  });
  final ApiClient client;
  final String orgId;
  final String agentId;
  final String conversationId;

  /// Only the operations this conversation raised; null shows all.
  final bool Function(String operationId)? raisedHere;

  /// A decision whose outcome is known: the notice the agent has to hear.
  final void Function(String notice)? onDecided;

  /// The agent's turn is running; the list is asked again as soon as it ends.
  final bool turnRunning;
  final Duration pollEvery;

  @override
  State<McpApprovalStrip> createState() => _McpApprovalStripState();
}

class _McpApprovalStripState extends State<McpApprovalStrip> with AutomaticKeepAliveClientMixin {
  List<McpOperation> _listed = const [];
  final List<_Settled> _settled = [];

  /// `<operationId>:approve`, `:deny` or `:recheck` while a request runs.
  String? _busy;
  String? _error;
  Timer? _timer;
  bool _loading = false;

  /// The conversation isn't this person's (or its agent is away): ask rarely.
  bool _slow = false;

  /// Decided rows live here only: stay built while the list scrolls.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(McpApprovalStrip old) {
    super.didUpdateWidget(old);
    // The agent asks, then ends its turn: that is when a new one appears.
    if (old.turnRunning && !widget.turnRunning) _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _loading = true;
    _timer?.cancel();
    try {
      final list = await widget.client.mcpOperations(widget.orgId, widget.agentId, widget.conversationId);
      _slow = false;
      if (mounted) setState(() => _listed = list);
    } on ApiException catch (e) {
      if (e.status == 404 || e.status == 403) {
        _slow = true;
        if (mounted) setState(() => _listed = const []);
      }
    } catch (_) {
      // Keep what was listed; the next round asks again.
    } finally {
      _loading = false;
      if (mounted) _timer = Timer(_slow ? widget.pollEvery * 10 : widget.pollEvery, _refresh);
    }
  }

  void _upsert(_Settled entry) {
    _settled
      ..removeWhere((s) => s.operation.operationId == entry.operation.operationId)
      ..add(entry);
  }

  void _tell(McpOperation operation, bool approved, McpOperation outcome) =>
      widget.onDecided?.call(mcpApprovalNotice(operation, approved: approved, outcome: outcome));

  Future<McpOperation> _read(McpOperation op) =>
      widget.client.mcpOperation(widget.orgId, widget.agentId, widget.conversationId, op.operationId);

  Future<void> _decide(McpOperation op, bool approve) async {
    Haptics.medium();
    setState(() {
      _busy = '${op.operationId}:${approve ? 'approve' : 'deny'}';
      _error = null;
    });
    try {
      final outcome = await widget.client
          .decideMcpOperation(widget.orgId, widget.agentId, widget.conversationId, op.operationId, approve: approve);
      _upsert(_Settled(op, approve, outcome));
      if (!outcome.awaiting && !outcome.executing) _tell(op, approve, outcome);
    } catch (_) {
      // A lost response (network drop, 409 race) may still have executed: read it so the true state shows.
      try {
        final outcome = await _read(op);
        if (outcome.awaiting) {
          _error = 'notApplied';
        } else {
          _upsert(_Settled(op, approve, outcome));
          if (!outcome.executing) _tell(op, approve, outcome);
        }
      } catch (_) {
        _upsert(_Settled(op, approve, null));
        _error = 'responseLost';
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (mounted) await _refresh();
  }

  Future<void> _recheck(_Settled entry) async {
    setState(() {
      _busy = '${entry.operation.operationId}:recheck';
      _error = null;
    });
    try {
      final outcome = await _read(entry.operation);
      if (outcome.awaiting) {
        // The decision never arrived: the operation goes back to the pending list.
        _settled.remove(entry);
        if (mounted) unawaited(_refresh());
      } else {
        _upsert(_Settled(entry.operation, entry.approved, outcome));
        if (entry.outcome == null && !outcome.executing) _tell(entry.operation, entry.approved, outcome);
      }
    } catch (_) {
      _error = 'checkFailed';
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final settledIds = {for (final s in _settled) s.operation.operationId};
    final pending = [
      for (final o in _listed)
        if (!settledIds.contains(o.operationId) && (widget.raisedHere?.call(o.operationId) ?? true)) o,
    ];
    if (pending.isEmpty && _settled.isEmpty) return const SizedBox.shrink();
    final error = switch (_error) {
      'notApplied' => l.mcpErrorNotApplied,
      'responseLost' => l.mcpErrorResponseLost,
      'checkFailed' => l.mcpErrorCheckFailed,
      _ => null,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final o in pending) _pending(context, o),
      for (final s in _settled) _settledRow(context, s),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Semantics(liveRegion: true, child: Text(error, style: TextStyle(color: p.error, fontSize: 13))),
        ),
    ]);
  }

  Widget _head(BuildContext context, String crumb, String tool, {IconData? icon, Color? color}) {
    final p = context.pal;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon ?? AppIcons.shieldOutlined, size: 14, color: color ?? p.tertiary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(crumb,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color ?? p.tertiary, letterSpacing: 0.4)),
        ),
      ]),
      const SizedBox(height: 6),
      Text(tool, style: mono(context, size: 14, color: p.ink, weight: FontWeight.w600)),
    ]);
  }

  /// Arguments or a result, as indented JSON in a box that scrolls.
  Widget _json(BuildContext context, Object? value) {
    final p = context.pal;
    var text = const JsonEncoder.withIndent('  ').convert(value);
    if (text.length > 4000) text = '${text.substring(0, 4000)}…';
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 132),
      decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(6)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(text, style: mono(context, size: 12, color: p.ink)),
      ),
    );
  }

  Widget _pending(BuildContext context, McpOperation o) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final busy = _busy != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AppCard(
        leftBar: p.paused,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _head(context, l.mcpApprovalRequired, o.toolName),
          const SizedBox(height: 4),
          Text(l.mcpDescription, style: TextStyle(color: p.secondary, fontSize: 13, height: 1.4)),
          const SizedBox(height: 8),
          _json(context, o.arguments),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: busy ? null : () => _decide(o, false),
                child: Text(_busy == '${o.operationId}:deny' ? l.mcpDenying : l.deny),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                onPressed: busy ? null : () => _decide(o, true),
                child: Text(_busy == '${o.operationId}:approve' ? l.mcpApproving : l.mcpApprove,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _settledRow(BuildContext context, _Settled s) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final out = s.outcome;
    final denied = out != null && !s.approved && out.status == 'failed';
    final label = out == null
        ? l.mcpOutcomeUnknown
        : denied
            ? l.denied
            : switch (out.status) {
                'awaiting_confirmation' => l.mcpOutcomeAwaiting,
                'executing' => l.mcpOutcomeExecuting,
                'completed' => l.mcpOutcomeCompleted,
                'failed' => l.mcpOutcomeFailed,
                'ambiguous' => l.mcpOutcomeAmbiguous,
                'stale' => l.mcpOutcomeStale,
                _ => l.mcpOutcomeUnknown,
              };
    final note = out == null
        ? l.mcpNoteLost
        : switch (out.status) {
            'ambiguous' => l.mcpNoteAmbiguous,
            'executing' => l.mcpNoteExecuting,
            'stale' => l.mcpNoteStale,
            _ => null,
          };
    final done = out?.status == 'completed';
    final (icon, color) = done
        ? (AppIcons.checkCircleOutline, p.online)
        : denied
            ? (AppIcons.block, p.secondary)
            : out?.status == 'failed'
                ? (AppIcons.errorOutline, p.error)
                : (AppIcons.warningAmberRounded, p.paused);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(
            liveRegion: true,
            child: _head(context, label.toUpperCase(), s.operation.toolName, icon: icon, color: color),
          ),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(note, style: TextStyle(color: p.secondary, fontSize: 13, height: 1.4)),
          ],
          if (out != null && out.hasResult) ...[
            const SizedBox(height: 8),
            _json(context, out.result),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: s.unresolved
                ? OutlinedButton(
                    onPressed: _busy != null ? null : () => _recheck(s),
                    child: Text(_busy == '${s.operation.operationId}:recheck' ? l.mcpChecking : l.mcpCheckStatus),
                  )
                : OutlinedButton(
                    onPressed: () => setState(() => _settled.remove(s)),
                    child: Text(l.mcpDismiss),
                  ),
          ),
        ]),
      ),
    );
  }
}
