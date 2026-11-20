import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../core/webchat/attachments.dart';
import '../../core/webchat/frames.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../approvals/approval_card.dart';
import '../chat/bubbles.dart';
import '../chat/chat_view.dart';
import '../chat/run_settings.dart';
import '../nav.dart';
import 'thread_widgets.dart';
import 'transcript.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';

/// Opens one thread of a coordinator conversation full screen.
Future<void> openThread(
  BuildContext context, {
  required SessionRow session,
  required String rootId,
  required Set<String> agentIds,
  ThreadSummary? summary,
  Agent? agent,
  int? focusSeq,
}) =>
    push<void>(context, ThreadScreen(
      session: session, rootId: rootId, agentIds: agentIds, summary: summary, agent: agent, focusSeq: focusSeq,
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
    this.focusSeq,
  });

  /// The coordinator conversation's session.
  final SessionRow session;
  final String rootId;
  final Set<String> agentIds;
  final ThreadSummary? summary;
  final Agent? agent;

  /// A message a link names (`?thread=<root>#msg=<seq>`): older pages load
  /// until it's in, then it's scrolled to and highlighted.
  final int? focusSeq;

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
  int _loadGeneration = 0;
  SessionRow? _coordinatorDetail;
  SessionRow? _replyDetail;
  Listenable? _orgData;

  bool get _slack => widget.session.platform == 'slack';

  Comparator<TranscriptItem> get _threadOrder =>
      _slack ? compareSlackThreadItems : compareTranscriptSeq;

  bool _hasReached(int seq) => _slack
      ? _items.any((item) => item.seq == seq)
      : threadReaches(_items, widget.rootId, seq);

  String? get _slackTarget {
    final summary = _summary;
    if (summary == null || !summary.readable) return null;
    return summary.task == null ? widget.session.sessionId : summary.task?.sessionId;
  }

  Future<SessionRow?> _sessionDetail(AppState app, String sessionId) async {
    try {
      final (row, _) = await app.client.session(app.current!.orgId, sessionId);
      return row;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadSlackDetails(AppState app, int generation) async {
    final parentId = widget.session.sessionId;
    final targetId = _slackTarget;
    final details = await Future.wait([
      _sessionDetail(app, parentId),
      if (targetId != null && targetId != parentId) _sessionDetail(app, targetId),
    ]);
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _coordinatorDetail = details.first;
      _replyDetail = targetId == null ? null : details.last;
    });
  }

  String? get _taskSession => _summary?.task?.sessionId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final app = AppScope.read(context);
      if (_slack) {
        _orgData = app.orgData;
        _orgData?.addListener(_onOrgData);
      }
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

  void _onOrgData() => setState(() {});

  @override
  void dispose() {
    _orgData?.removeListener(_onOrgData);
    _sub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  /// The newest page, merged with older pages already loaded.
  Future<void> _load({bool silent = false}) async {
    final app = AppScope.read(context);
    final generation = ++_loadGeneration;
    if (!silent) setState(() => _loading = true);
    try {
      final page = await app.client.threadMessages(app.current!.orgId, widget.session.sessionId, widget.rootId);
      if (!mounted || generation != _loadGeneration) return;
      final fresh = buildTranscript(page.messages, widget.agentIds, slack: _slack);
      setState(() {
        final merged = mergeThreadPage(_items, fresh, widget.rootId, compare: _threadOrder);
        _items = merged.items;
        if (!merged.keptOlder) _older = page.nextCursor;
        _summary = _slack ? page.summary : page.summary ?? _summary;
        if (_summary?.readable == false) {
          _items = [];
          _older = null;
        }
        _loading = false;
        _error = null;
      });
      if (!silent) _seekFocus();
      if (_slack) await _loadSlackDetails(app, generation);
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      final denied = _slack && e is ApiException && (e.status == 403 || e.status == 404);
      if (silent && _items.isNotEmpty && !denied) {
        if (_slack && e is ApiException && (e.status == 409 || e.status == 503)) {
          setState(() => _replyDetail = null);
        }
        return;
      }
      setState(() {
        _loading = false;
        _error = e;
        if (denied) {
          _items = [];
          _older = null;
          _summary = null;
          _replyDetail = null;
          _coordinatorDetail = null;
        }
      });
    }
  }

  /// Pages back through the thread until the linked message is loaded.
  Future<void> _seekFocus() async {
    final seq = widget.focusSeq;
    if (seq == null) return;
    var guard = 0;
    while (mounted && _older != null && !_hasReached(seq) && guard++ < 100) {
      final before = _older;
      await _loadOlder();
      if (_older == before) break; // that page failed
    }
  }

  Future<void> _loadOlder() async {
    final cursor = _older;
    if (cursor == null || _loadingOlder) return;
    final app = AppScope.read(context);
    final generation = _loadGeneration;
    setState(() => _loadingOlder = true);
    try {
      final page = await app.client
          .threadMessages(app.current!.orgId, widget.session.sessionId, widget.rootId, cursor: cursor);
      if (!mounted || (_slack && generation != _loadGeneration)) return;
      if (_slack && page.summary?.readable == false) {
        setState(() {
          _summary = page.summary;
          _items = [];
          _older = null;
          _replyDetail = null;
        });
        return;
      }
      final have = _items.map((e) => e.seq).toSet();
      setState(() {
        _items = [
          ...buildTranscript(page.messages, widget.agentIds, slack: _slack).where((o) => !have.contains(o.seq)),
          ..._items,
        ]..sort(_threadOrder);
        _older = page.nextCursor == cursor ? null : page.nextCursor;
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
    final coordinator = _coordinatorDetail ?? widget.session;
    final slackUrl = _slack && readable
        ? slackThreadUrl(coordinator.tenantScope, coordinator.channelId, widget.rootId)
        : null;
    final orgData = app.orgData;
    final daemonId = coordinator.daemonId ?? orgData?.agent(widget.session.agentId)?.daemonId;
    final daemonSupportsContinuation = orgData?.machines?.any(
      (m) => m.id == daemonId && m.features.contains(continuationThreadsFeature),
    ) ?? false;
    final writable = !_slack ||
        (app.canWrite && _slackTarget != null &&
            _replyDetail?.sessionId == _slackTarget && _replyDetail?.canContinue == true &&
            (taskSession != null || daemonSupportsContinuation));
    final continuationThread = _slack && taskSession == null;
    final replyAgentId = _slack && writable ? _replyDetail!.agentId : widget.session.agentId;
    final replyAgent = _slack ? orgData?.agent(replyAgentId) ?? widget.agent : widget.agent;

    Widget body;
    if (_loading) {
      body = const Center(child: Spinner());
    } else if (!readable) {
      body = StateView(icon: AppIcons.lockOutline, title: l.threadNotReadable);
    } else if (_error != null && _items.isEmpty) {
      final e = _error;
      final offline = e is ApiException && e.status == 503;
      body = StateView(
        icon: offline ? AppIcons.cloudOff : AppIcons.errorOutline,
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
          key: ValueKey((taskSession, writable)),
          agent: replyAgent,
          agentId: replyAgentId,
          agentName: widget.session.agentName,
          sessionId: taskSession ?? widget.session.sessionId,
          linkSessionId: widget.session.sessionId,
          conversationId: taskSession == null ? widget.session.webchatConversationId : null,
          thread: _slack && taskSession != null ? null : widget.rootId,
          linkThread: widget.rootId,
          continuationThread: continuationThread,
          readOnly: !writable,
          connectOnOpen: _slack && writable,
          focusSeq: widget.focusSeq,
          anyThread: taskSession != null,
          attachPolicy: _slack
              ? _replyDetail?.continuationAttachments
              : taskSession == null ? null : AttachPolicy.imagesAndFiles,
          hint: l.replyInThreadHint,
          footnote: _slack
              ? (taskSession == null ? l.slackCoordinatorReplyNote : null)
              : taskSession == null ? l.replyInThreadNote : null,
          runDefaults: taskSession == null
              ? null
              : RunDefaults(model: replyAgent?.model, agent: replyAgent),
          header: entriesFromTranscript(_slack
              ? [
                  ..._items.where((i) => i.postId == widget.rootId),
                  ..._items.where((i) => i.postId != widget.rootId),
                ]
              : _items),
          headerSliver: _older == null
              ? null
              : Center(
                  child: TextButton(
                      onPressed: _loadingOlder ? null : _loadOlder,
                      child: Text(_loadingOlder ? l.loadingShort : _slack ? l.loadEarlier : l.loadingMore))),
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
        actions: [
          if (slackUrl != null)
            IconButton(
              tooltip: l.openIn(l.sourceSlack),
              onPressed: () => launchUrl(slackUrl, mode: LaunchMode.externalApplication),
              icon: Icon(AppIcons.openInNew),
            ),
        ],
        title: Column(crossAxisAlignment: navTitleAlign, children: [
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
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

/// The Slack web client opens the named thread alongside its channel.
Uri? slackThreadUrl(String? workspace, String? channel, String rootId) {
  if (workspace == null || workspace.isEmpty || channel == null || channel.isEmpty ||
      slackThreadId(rootId) == null) {
    return null;
  }
  return Uri(
    scheme: 'https',
    host: 'app.slack.com',
    pathSegments: ['client', workspace, channel, 'thread', '$channel-$rootId'],
  );
}
