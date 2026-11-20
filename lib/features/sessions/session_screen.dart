import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../core/console_links.dart';
import '../../core/last_read_store.dart';
import '../../core/share_links.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../approvals/approval_card.dart';
import '../chat/bubbles.dart';
import '../../core/api/workspace.dart';
import '../chat/chat_view.dart';
import '../chat/run_settings.dart';
import 'task_widgets.dart';
import 'thread_screen.dart';
import 'thread_widgets.dart';
import 'workspace_sheet.dart';
import 'session_details.dart';
import 'session_tile.dart';
import 'transcript.dart';
import 'transcript_pager.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';

/// One conversation: header (agent · place · state, link to the original
/// platform), transcript, approvals waiting in it, and the message box.
/// Several agents in one conversation: a switcher between their sessions.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.conversation, this.focusSeq, this.fillRequestId, this.threadRoot});
  final Conversation conversation;

  /// A message a link names (`#msg=<seq>`): older pages load until it's in.
  /// With [threadRoot], the message is in that thread.
  final int? focusSeq;

  /// A thread a link names (`?thread=<rootId>`): opened over the conversation
  /// once it has loaded, so Back lands on the conversation.
  final String? threadRoot;

  /// A Fill card a link names (`?fill=<requestId>`), opened in the chat.
  final String? fillRequestId;
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> with WidgetsBindingObserver {
  late SessionRow _session = widget.conversation.primary;
  late TranscriptPager _pager = _newPager();
  bool _loading = true;
  bool _offline = false;
  Object? _error;
  bool _loadingOlder = false;
  StreamSubscription<dynamic>? _sub;
  Timer? _debounce;
  bool _started = false;
  bool _threadOpened = false;
  List<AgentTask> _tasks = [];

  /// The loaded transcript: the newest page, and older pages asked for.
  List<TranscriptItem> get _items => _pager.items;

  /// Thread footers by root id; the timeline is read with `view=roots`.
  Map<String, ThreadSummary> get _threads => _pager.threads;
  bool get _threaded => _pager.roots;

  /// The last seq read in this session on this device before this visit (or
  /// before the app last came back to the front): the "New" divider goes
  /// above the first row after it. Null when it was never read here.
  int? _readMark;

  /// The view shows the latest row.
  bool _atLatest = false;

  /// The app is in front: what is on screen is being read.
  bool _looking = true;

  /// Records the conversation as read up to its last row, while the person
  /// is looking at the latest row. Only the session id and that seq are kept.
  void _markRead() {
    if (!_atLatest || !_looking || _items.isEmpty) return;
    LastReadStore.instance.write(_session.sessionId, _items.last.seq);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _looking = false;
      return;
    }
    if (_looking) return;
    _looking = true;
    // Coming back is when the divider moves: to what was read before leaving.
    final pager = _pager;
    LastReadStore.instance.read(_session.sessionId).then((mark) {
      if (!mounted || pager != _pager) return;
      setState(() => _readMark = mark);
      _markRead();
    });
  }

  /// A pager for the session shown now; a switch of session starts a new one.
  TranscriptPager _newPager() {
    final session = _session;
    final app = AppScope.read(context);
    return TranscriptPager(
        ({cursor, after}) => _page(app.client, app.current!.orgId, session, cursor: cursor, after: after),
        _agentIds);
  }

  /// The daemon answered 409 to `view=roots`: the flat view and task cards.
  final Set<String> _noRoots = {};

  /// Reads the main timeline: `view=roots` where threads may exist (only
  /// webchat conversations; Slack-origin pages are out of scope), the flat
  /// view on daemons without them.
  Future<MessagePage> _page(ApiClient client, String org, SessionRow session,
      {String? cursor, String? after}) async {
    final id = session.sessionId;
    // A forward read takes the larger page, as the console does.
    final limit = after == null ? 50 : 200;
    if (session.isWebchat && !_noRoots.contains(id)) {
      try {
        return await client.messages(org, id, cursor: cursor, after: after, limit: limit, roots: true);
      } on ApiException catch (e) {
        if (e.status != 409) rethrow;
        _noRoots.add(id);
      }
    }
    return client.messages(org, id, cursor: cursor, after: after, limit: limit);
  }

  void _openThread(String rootId, Agent? agent) => openThread(
        context,
        session: _session,
        rootId: rootId,
        agentIds: _agentIds,
        summary: _threads[rootId],
        agent: agent,
      );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final app = AppScope.read(context);
    WidgetsBinding.instance.addObserver(this);
    _sub = app.live?.events.listen((e) {
      final ids = widget.conversation.sessions.map((s) => s.sessionId);
      if (e.kind != 'connected' && e.sessionId != null && !ids.contains(e.sessionId)) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 700), () {
        if (mounted) {
          _load(silent: true);
          _loadTasks();
        }
      });
    });
    _load();
    _loadTasks();
  }

  /// Tasks this session started; none when the daemon can't say (409) or on errors.
  Future<void> _loadTasks() async {
    final app = AppScope.read(context);
    try {
      final t = await app.client.tasks(app.current!.orgId, _session.agentId, _session.sessionId);
      if (mounted) setState(() => _tasks = t.where((x) => x.visible).toList());
    } catch (_) {
      if (mounted && _tasks.isNotEmpty) setState(() => _tasks = []);
    }
  }

  void _openTask(AgentTask t, Agent? agent) =>
      openTaskThread(context, t, agent: agent, agentId: _session.agentId, agentName: _session.agentName);

  /// Transcript entries with each task card under the message that started it;
  /// tasks whose message isn't loaded go at the end.
  /// [placed] collects the tasks drawn so far; [rest] false leaves the others
  /// for a later part of the transcript.
  List<Entry> _withTasks(List<Entry> entries, Agent? agent, {Set<AgentTask>? placed, bool rest = true}) {
    final drawn = placed ?? <AgentTask>{};
    final out = <Entry>[];
    for (final e in entries) {
      out.add(e);
      if (e is AgentEntry && e.postId != null) {
        for (final t in _tasks.where((t) => t.openedForMessageId == e.postId)) {
          drawn.add(t);
          out.add(TaskEntry(t, t.sessionId == null ? null : () => _openTask(t, agent)));
        }
      }
    }
    if (!rest) return out;
    for (final t in _tasks.where((t) => !drawn.contains(t))) {
      out.add(TaskEntry(t, t.sessionId == null ? null : () => _openTask(t, agent)));
    }
    return out;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  Set<String> get _agentIds => widget.conversation.sessions.map((s) => s.agentId).toSet();

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      // A full load starts over, also after a switch to another agent's session.
      setState(() {
        _loading = true;
        _pager = _newPager();
        _atLatest = false;
      });
    }
    final pager = _pager;
    // What was read before this visit, taken before the visit marks it read.
    final readBefore = silent ? null : LastReadStore.instance.read(_session.sessionId);
    try {
      // A refresh keeps the older pages loaded so far.
      await (silent && pager.items.isNotEmpty ? pager.refresh() : pager.loadNewest());
      final mark = await readBefore;
      if (!mounted || pager != _pager) return;
      setState(() {
        if (!silent) _readMark = mark;
        _offline = false;
        _error = null;
        _loading = false;
      });
      _markRead();
      if (!silent) _seekFocus();
      _openLinkedThread();
    } catch (e) {
      if (!mounted || pager != _pager) return;
      if (silent && _items.isNotEmpty) return;
      setState(() {
        _loading = false;
        if (e is ApiException && e.status == 503) {
          _offline = true;
        } else {
          _error = e;
        }
      });
    }
  }

  /// The linked message when it's on the main timeline (not in a thread).
  int? get _mainFocus => widget.threadRoot == null ? widget.focusSeq : null;

  /// Opens the thread a link names, once.
  void _openLinkedThread() {
    final root = widget.threadRoot;
    if (root == null || _threadOpened) return;
    _threadOpened = true;
    final agent = AppScope.read(context).orgData?.agent(_session.agentId);
    openThread(
      context,
      session: _session,
      rootId: root,
      agentIds: _agentIds,
      summary: _threads[root],
      agent: agent,
      focusSeq: widget.focusSeq,
    );
  }

  /// Pages back through history until the linked message is loaded.
  Future<void> _seekFocus() async {
    final seq = _mainFocus;
    if (seq == null) return;
    final pager = _pager;
    var guard = 0;
    while (mounted && pager == _pager && pager.hasOlder && !_items.any((i) => i.seq <= seq) && guard++ < 100) {
      if (!await _loadOlder()) break; // that page failed
    }
  }

  Future<void> _share() async {
    final l = AppLocalizations.of(context);
    final app = AppScope.read(context);
    final s = _session;
    final org = app.current!.orgId;
    final results = await Future.wait([
      currentOrgSlug(app),
      app.client.session(org, s.sessionId).then((r) => r.$2).catchError((_) => null),
    ]);
    final link = sessionLink(app, results[0]!, s.sessionId);
    if (!mounted || link == null) return;
    final audience = switch (results[1]) {
      'private' => l.audiencePrivate,
      'org' => l.audienceOrg(app.current?.orgName ?? ''),
      'external' => l.audienceExternal,
      _ => null,
    };
    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) {
        final p = ctx.pal;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.shareSession, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            if (audience != null) ...[
              Row(children: [
                Icon(results[1] == 'private' ? AppIcons.lockOutline : AppIcons.groupOutlined, size: 18, color: p.secondary),
                const SizedBox(width: 8),
                Expanded(child: Text(audience, style: TextStyle(fontSize: 14, color: p.secondary))),
              ]),
              const SizedBox(height: 10),
            ],
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(8)),
              child: SelectableText(link.toString(), style: mono(ctx, size: 12, color: p.ink)),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              icon: Icon(AppIcons.link, size: 18),
              label: Text(l.copyLink),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link.toString()));
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.copied)));
              },
            ),
            const SizedBox(height: 6),
            Builder(
              builder: (btn) => OutlinedButton.icon(
                icon: Icon(AppIcons.iosShare, size: 18),
                label: Text(l.shareVia),
                onPressed: () {
                  // iPad shows the share sheet as a popover: anchor it on this button,
                  // measured before the sheet closes.
                  final box = btn.findRenderObject() as RenderBox?;
                  final origin = box != null && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
                  Navigator.pop(ctx);
                  SharePlus.instance.share(ShareParams(uri: link, sharePositionOrigin: origin));
                },
              ),
            ),
          ]),
        );
      },
    );
  }

  /// Run details. Duration and tool calls are read from the transcript, so
  /// they are given only when it is complete (see [completeTranscript]).
  void _details() => showSessionDetails(
        context,
        session: _session,
        agent: AppScope.read(context).orgData?.agent(_session.agentId),
        transcript: _loading ? null : completeTranscript(_items, morePages: _pager.hasOlder, rootsView: _threaded),
      );

  /// The header's less-used actions, behind its "more" button.
  Future<void> _more({required String? url, required bool canShare}) async {
    final l = AppLocalizations.of(context);
    final pick = await showActionMenu<String>(context, cancel: l.cancel, actions: [
      MenuAction('details', AppIcons.infoOutline, l.details),
      if (canShare) MenuAction('share', AppIcons.iosShare, l.shareSession),
      if (url != null) MenuAction('open', AppIcons.openInNew, l.openIn(sourceName(l, widget.conversation.source))),
    ]);
    if (!mounted) return;
    switch (pick) {
      case 'details':
        _details();
      case 'share':
        await _share();
      case 'open':
        await launchUrl(Uri.parse(url!), mode: LaunchMode.externalApplication);
    }
  }

  /// Adds the next older page; every tap goes one page further back, until
  /// the start of the conversation. False when the page failed (the button
  /// stays available).
  Future<bool> _loadOlder() async {
    final pager = _pager;
    if (!pager.hasOlder || _loadingOlder) return false;
    setState(() => _loadingOlder = true);
    final ok = await pager.loadOlder();
    if (mounted) setState(() => _loadingOlder = false);
    return ok;
  }

  List<Entry> _entries(List<TranscriptItem> items, Agent? agent) =>
      _threaded ? threadedEntries(items, _threads, (root) => _openThread(root, agent)) : entriesFromTranscript(items);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final app = AppScope.of(context);
    final conv = widget.conversation;
    final s = _session;
    final agent = app.orgData?.agent(s.agentId);
    final title = s.title?.trim().isNotEmpty == true ? s.title!.trim() : (conv.title ?? l.untitled);
    final url = s.threadUrl ?? conv.threadUrl;
    final state = s.state;
    final stateText = switch (state) {
      ActivityState.working => l.stateRunning,
      ActivityState.awaiting => l.stateWaiting,
      ActivityState.idle => l.stateIdle,
    };
    final place = conv.place ?? sourceName(l, conv.source);
    final approvals = app.approvals;
    final canShare = consoleUri(app, '-', 'sessions') != null;

    Widget body;
    if (_loading) {
      body = const Center(child: Spinner());
    } else if (_offline) {
      body = StateView(
          icon: AppIcons.cloudOff,
          title: l.offlineTitle(s.agentName),
          body: l.offlineBody,
          actionLabel: l.tryAgain,
          onAction: _load);
    } else if (_error != null && _items.isEmpty) {
      body = StateView(
          icon: AppIcons.errorOutline, title: errorText(l, _error!), actionLabel: l.tryAgain, onAction: _load);
    } else {
      // Older pages are a list of their own, so adding one leaves the rest in place.
      final earlier = _pager.earlier;
      final recent = _pager.recent;
      DateTime? startOf(List<TranscriptItem> part) => part.isEmpty ? null : part.first.ts ?? s.lastActivityAt;
      final placed = <AgentTask>{};
      // "New" goes above the first row that arrived since this was last read here.
      final newSeq = newDividerSeq(_items, _readMark);
      List<Entry> part(List<TranscriptItem> items, {required bool rest}) {
        final first = startOf(items);
        final cut = newSeq == null ? -1 : items.indexWhere((i) => i.seq == newSeq);
        final entries = cut < 0
            ? _entries(items, agent)
            : [
                ..._entries(items.sublist(0, cut), agent),
                const NewDividerEntry(),
                ..._entries(items.sublist(cut), agent),
              ];
        return [
          // The divider leads when the part starts with the new rows.
          if (cut == 0) entries.removeAt(0),
          if (first != null) TimeEntry(listTime(first)),
          ...(_threaded ? entries : _withTasks(entries, agent, placed: placed, rest: rest)),
        ];
      }

      final older = part(earlier, rest: false);
      final header = part(recent, rest: true);
      body = ListenableBuilder(
        listenable: approvals ?? ValueNotifier(0),
        builder: (context, _) => ChatView(
          key: ValueKey(s.sessionId),
          agent: agent,
          agentId: s.agentId,
          agentName: s.agentName,
          sessionId: s.sessionId,
          focusSeq: _mainFocus,
          // Only the session the link names: not another agent's in the switcher.
          fillRequestId: s.sessionId == widget.conversation.primary.sessionId ? widget.fillRequestId : null,
          conversationId: s.webchatConversationId,
          usage: s.usage,
          model: agent?.model ?? s.model,
          onTurnDone: () {
            _load(silent: true);
            _loadTasks();
          },
          runDefaults: RunDefaults(
              model: agent?.model ?? s.model, effort: s.effort, permissionMode: s.permissionMode, agent: agent),
          header: header,
          older: older,
          onAtLatest: (at) {
            _atLatest = at;
            _markRead();
          },
          earlier: _pager.hasOlder
              ? Center(
                  child: TextButton(
                      onPressed: _loadingOlder ? null : _loadOlder,
                      child: Text(_loadingOlder ? l.loadingShort : l.loadEarlier)))
              : null,
          trailing: [
            for (final a in approvals?.forSession(s.sessionId) ?? const [])
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
        titleSpacing: navTitleSpacing(context),
        toolbarHeight: 60,
        title: Column(crossAxisAlignment: navTitleAlign, children: [
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
            StatusDot(color: sessionDot(p, state), size: 8),
            const SizedBox(width: 6),
            Flexible(
              child: Text([s.agentName, place, stateText].where((x) => x.isNotEmpty).join(' · '),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12)),
            ),
          ]),
        ]),
        actions: [
          IconButton(
            tooltip: l.workspaceTooltip,
            onPressed: () => openWorkspace(
              context,
              WorkspaceRef(
                  agentId: s.agentId, agentName: s.agentName, sessionId: s.sessionId, agent: agent, title: title),
              tasks: _tasks,
            ),
            icon: Badge(
              isLabelVisible: _tasks.any((t) => t.running),
              label: Text('${_tasks.where((t) => t.running).length}'),
              backgroundColor: p.online,
              child: Icon(AppIcons.inventory2Outlined),
            ),
          ),
          // Details, Share and "Open in …" share one button; Details alone gets its own.
          if (url == null && !canShare)
            IconButton(tooltip: l.details, onPressed: _details, icon: Icon(AppIcons.infoOutline))
          else
            IconButton(
              tooltip: l.moreActions,
              onPressed: () => _more(url: url, canShare: canShare),
              icon: Icon(AppIcons.moreVert),
            ),
          const SizedBox(width: 4),
        ],
        bottom: conv.sessions.length > 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(52),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Segmented<String>(
                    items: [for (final x in conv.sessions) (x.sessionId, x.agentName)],
                    value: s.sessionId,
                    onChanged: (id) {
                      setState(() => _session = conv.sessions.firstWhere((x) => x.sessionId == id));
                      _load();
                    },
                  ),
                ),
              )
            : null,
      ),
      body: body,
    );
  }
}
