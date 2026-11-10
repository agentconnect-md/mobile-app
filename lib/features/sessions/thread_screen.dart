import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../approvals/approval_card.dart';
import '../chat/bubbles.dart';
import '../chat/chat_view.dart';
import '../chat/run_settings.dart';
import 'thread_widgets.dart';
import 'transcript.dart';

/// Opens one thread of a coordinator conversation full screen.
Future<void> openThread(
  BuildContext context, {
  required SessionRow session,
  required String rootId,
  required Set<String> agentIds,
  ThreadSummary? summary,
  Agent? agent,
}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ThreadScreen(session: session, rootId: rootId, agentIds: agentIds, summary: summary, agent: agent),
    ));

/// A thread: its root, then the replies oldest first (older pages on demand),
/// refreshed on live activity, and a box that writes in the thread. A thread a
/// task holds writes through that task's continuation, which also takes the
/// task's run settings and shows its approvals; an unowned thread writes to
/// the coordinator on the conversation's own chat.
class ThreadScreen extends StatefulWidget {
  const ThreadScreen({
    super.key,
    required this.session,
    required this.rootId,
    required this.agentIds,
    this.summary,
    this.agent,
  });

  /// The coordinator conversation's session.
  final SessionRow session;
  final String rootId;
  final Set<String> agentIds;
  final ThreadSummary? summary;
  final Agent? agent;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  late ThreadSummary? _summary = widget.summary;
  List<TranscriptItem> _items = [];
  String? _older;
  bool _loading = true;
  bool _loadingOlder = false;
  Object? _error;
  StreamSubscription<dynamic>? _sub;
  Timer? _debounce;

  String? get _taskSession => _summary?.task?.sessionId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final app = AppScope.read(context);
      _sub = app.live?.events.listen((e) {
        final id = e.sessionId;
        if (e.kind != 'connected' && id != widget.session.sessionId && (id == null || id != _taskSession)) return;
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 700), () {
          if (mounted) _load(silent: true);
        });
      });
      _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  /// The newest page, merged with older pages already loaded.
  Future<void> _load({bool silent = false}) async {
    final app = AppScope.read(context);
    if (!silent) setState(() => _loading = true);
    try {
      final page = await app.client.threadMessages(app.current!.orgId, widget.session.sessionId, widget.rootId);
      if (!mounted) return;
      final fresh = buildTranscript(page.messages, widget.agentIds);
      setState(() {
        // Keep older pages loaded before; the root is always on the newest page.
        final merged = mergeThreadPage(_items, fresh, widget.rootId);
        _items = merged.items;
        if (!merged.keptOlder) _older = page.nextCursor;
        _summary = page.summary ?? _summary;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || (silent && _items.isNotEmpty)) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> _loadOlder() async {
    final cursor = _older;
    if (cursor == null || _loadingOlder) return;
    final app = AppScope.read(context);
    setState(() => _loadingOlder = true);
    try {
      final page = await app.client
          .threadMessages(app.current!.orgId, widget.session.sessionId, widget.rootId, cursor: cursor);
      if (!mounted) return;
      final have = _items.map((e) => e.seq).toSet();
      setState(() {
        _items = [
          ...buildTranscript(page.messages, widget.agentIds).where((o) => !have.contains(o.seq)),
          ..._items,
        ]..sort((a, b) => a.seq.compareTo(b.seq));
        _older = page.nextCursor;
      });
    } catch (_) {
      // the button stays available
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final app = AppScope.of(context);
    final s = _summary;
    final task = s?.task;
    final readable = s?.readable ?? true;
    final title = readable && (task?.title ?? '').isNotEmpty
        ? task!.title!
        : (readable ? s?.rootExcerpt : null) ?? l.threadTitle;
    final meta = [
      if (task != null) threadTaskStateLabel(l, task),
      if (s != null && s.replies > 0) l.repliesCount(s.replies),
    ].join(' · ');
    final taskSession = _taskSession;
    final approvals = app.approvals;

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!readable) {
      body = StateView(icon: Icons.lock_outline, title: l.threadNotReadable);
    } else if (_error != null && _items.isEmpty) {
      final e = _error;
      final offline = e is ApiException && e.status == 503;
      body = StateView(
        icon: offline ? Icons.cloud_off : Icons.error_outline,
        title: offline
            ? l.offlineTitle(widget.session.agentName)
            : e is ApiException && e.status == 404
                ? l.threadMissing
                : errorText(l, e!),
        actionLabel: l.tryAgain,
        onAction: _load,
      );
    } else {
      body = ListenableBuilder(
        listenable: approvals ?? ValueNotifier(0),
        builder: (context, _) => ChatView(
          // A thread the coordinator hands to a task starts writing to it.
          key: ValueKey(taskSession ?? 'coordinator'),
          agent: widget.agent,
          agentId: widget.session.agentId,
          agentName: widget.session.agentName,
          sessionId: taskSession ?? widget.session.sessionId,
          conversationId: taskSession == null ? widget.session.webchatConversationId : null,
          thread: widget.rootId,
          anyThread: taskSession != null,
          hint: l.replyInThreadHint,
          footnote: taskSession == null ? l.replyInThreadNote : null,
          runDefaults: taskSession == null ? null : RunDefaults(model: widget.agent?.model, agent: widget.agent),
          header: entriesFromTranscript(_items),
          headerSliver: _older == null
              ? null
              : Center(
                  child: TextButton(
                      onPressed: _loadOlder, child: Text(_loadingOlder ? l.loadingShort : l.loadingMore))),
          onTurnDone: () => _load(silent: true),
          trailing: [
            if (taskSession != null)
              for (final a in approvals?.forSession(taskSession) ?? const [])
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: ApprovalCard(key: ValueKey(a.id), approval: a, controller: approvals!),
                ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        toolbarHeight: 60,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Row(children: [
            StatusDot(color: task != null && (task.running || s!.running) ? p.online : null, size: 8),
            const SizedBox(width: 6),
            Flexible(
              child: Text(meta.isEmpty ? l.threadTitle : meta,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12)),
            ),
          ]),
        ]),
      ),
      body: body,
    );
  }
}
