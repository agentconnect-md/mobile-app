import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/api/workspace.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../nav.dart';
import 'task_widgets.dart';
import '../files/file_view_screen.dart';
import '../files/workspace_files.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';
import '../../ui/platform.dart';

export '../files/workspace_files.dart' show WorkspaceRef, workspaceError;

Future<void> openWorkspace(BuildContext context, WorkspaceRef ref,
    {required List<AgentTask> tasks,
    List<ThreadSummary> threads = const [],
    void Function(String rootId)? onOpenThread,
    int tab = 0}) {
  final app = AppScope.read(context);
  return showAppSheet<void>(
    context: context,
    ownClose: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => AppScope(
      state: app,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.86,
        child: _WorkspaceSheet(
          ws: ref,
          tasks: tasks,
          threads: threads,
          // The sheet closes first: the thread opens over the conversation.
          onOpenThread: onOpenThread == null
              ? null
              : (root) {
                  Navigator.pop(context);
                  onOpenThread(root);
                },
          initialTab: tab,
        ),
      ),
    ),
  );
}

class _WorkspaceSheet extends StatefulWidget {
  const _WorkspaceSheet(
      {required this.ws, required this.tasks, this.threads = const [], this.onOpenThread, required this.initialTab});
  final WorkspaceRef ws;
  final List<AgentTask> tasks;
  final List<ThreadSummary> threads;
  final void Function(String rootId)? onOpenThread;
  final int initialTab;
  @override
  State<_WorkspaceSheet> createState() => _WorkspaceSheetState();
}

class _WorkspaceSheetState extends State<_WorkspaceSheet> {
  late int _tab = widget.initialTab;
  GitStatus? _git;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final running = widget.tasks.where((t) => t.running).length;
    final changes = _git?.files.length ?? 0;
    Widget tab(int i, IconData icon, String label, int badge) {
      final sel = i == _tab;
      return Expanded(
        child: Semantics(
          selected: sel,
          button: true,
          child: InkWell(
            onTap: () => setState(() => _tab = i),
            child: Container(
              padding: const EdgeInsets.only(top: 6, bottom: 8),
              decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: sel ? p.accent : Colors.transparent, width: 2))),
              child: Column(children: [
                Badge(
                  isLabelVisible: badge > 0,
                  label: Text('$badge'),
                  backgroundColor: i == 0 ? p.online : p.paused,
                  child: Icon(icon, size: 22, color: sel ? p.accent : p.secondary),
                ),
                const SizedBox(height: 4),
                Text(label,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: sel ? p.accent : p.secondary)),
              ]),
            ),
          ),
        ),
      );
    }

    final body = switch (_tab) {
      0 => WorkspaceTasks(
          ws: widget.ws, tasks: widget.tasks, threads: widget.threads, onOpenThread: widget.onOpenThread),
      1 => WorkspaceFiles(ws: widget.ws),
      _ => WorkspaceGit(ws: widget.ws, onStatus: (g) => setState(() => _git = g)),
    };
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
        child: Row(children: [
          Expanded(
            child: Text(widget.ws.title ?? l.untitled,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          IconButton(onPressed: () => Navigator.pop(context), icon: Icon(AppIcons.close)),
        ]),
      ),
      if (isIOS)
        // iOS: a segmented control switches views inside a sheet (counts go in the labels).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Segmented<int>(
            items: [
              (0, running > 0 ? '${l.tabTasks} · $running' : l.tabTasks),
              (1, l.tabFiles),
              (2, changes > 0 ? '${l.tabGit} · $changes' : l.tabGit),
            ],
            value: _tab,
            onChanged: (i) => setState(() => _tab = i),
          ),
        )
      else
        Row(children: [
          tab(0, AppIcons.checklist, l.tabTasks, running),
          tab(1, AppIcons.accountTreeOutlined, l.tabFiles, 0),
          tab(2, AppIcons.commit, l.tabGit, changes),
        ]),
      Divider(height: 1, color: p.hairline),
      Expanded(child: body),
    ]);
  }
}

/// The tasks a session started, then its threads (the sheet's Tasks tab;
/// the Mac's side panel). A coordinator's work is often in threads no task
/// holds, so they are listed too.
class WorkspaceTasks extends StatelessWidget {
  const WorkspaceTasks({super.key, required this.ws, required this.tasks, this.threads = const [], this.onOpenThread});
  final WorkspaceRef ws;
  final List<AgentTask> tasks;
  final List<ThreadSummary> threads;
  final void Function(String rootId)? onOpenThread;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final open = onOpenThread;
    final shownThreads = open == null ? const <ThreadSummary>[] : threads;
    if (tasks.isEmpty && shownThreads.isEmpty) {
      return StateView(icon: AppIcons.checklist, title: l.noTasksTitle, body: l.noTasksBody);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        if (shownThreads.isNotEmpty) ...[
          SectionHeader('${l.threadsSection} ${shownThreads.length}'),
          GroupCard(
            children: [for (final s in shownThreads) _ThreadRow(summary: s, onTap: () => open!(s.rootId))],
          ),
        ],
        if (tasks.isNotEmpty) SectionHeader('${l.threadedTasks} ${tasks.length}'),
        if (tasks.isNotEmpty)
          GroupCard(
            children: [
              for (final t in tasks)
                InkWell(
                  onTap: t.sessionId == null
                      ? null
                      : () => openTaskThread(context, t, agent: ws.agent, agentId: ws.agentId, agentName: ws.agentName),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: t.running
                              ? StatusDot(color: p.online, size: 9)
                              : Container(
                                  width: 9,
                                  height: 9,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: p.idle, width: 1.5),
                                  ),
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      t.title.isEmpty ? l.untitled : t.title,
                                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  if (t.replies > 0) ...[
                                    Icon(AppIcons.reply, size: 14, color: p.tertiary),
                                    const SizedBox(width: 2),
                                    Text('${t.replies}', style: mono(context, size: 12)),
                                  ],
                                  if (t.running && t.canStop && t.sessionId != null)
                                    _StopTask(agentId: ws.agentId, task: t),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                [
                                  taskStateLabel(l, t),
                                  if (t.startedAt != null) l.startedAgo(relativeTime(t.startedAt)),
                                  if (t.summaryAt != null) l.summaryAgo(relativeTime(t.summaryAt)),
                                ].join(' · '),
                                style: TextStyle(fontSize: 12, color: p.tertiary),
                              ),
                              if ((t.summary ?? '').isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  t.summary!,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 14, color: p.secondary, height: 1.35),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// Stops a running task's current turn, after asking (as the console does).
class _StopTask extends StatefulWidget {
  const _StopTask({required this.agentId, required this.task});
  final String agentId;
  final AgentTask task;
  @override
  State<_StopTask> createState() => _StopTaskState();
}

class _StopTaskState extends State<_StopTask> {
  bool _busy = false;

  Future<void> _stop() async {
    final l = AppLocalizations.of(context);
    final ok = await confirmDialog(
      context,
      title: l.stopTaskTitle,
      body: l.stopTaskBody,
      cancel: l.cancel,
      confirm: l.stopTask,
      destructive: true,
    );
    if (ok != true || !mounted) return;
    Haptics.medium();
    final app = AppScope.read(context);
    setState(() => _busy = true);
    try {
      await app.client.stopTask(app.current!.orgId, widget.agentId, widget.task.sessionId!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(e is ApiException && e.readOnlyGrant ? l.readOnlyGrant : l.errNetwork)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: _busy
          ? const SizedBox.square(dimension: 16, child: Spinner(strokeWidth: 1.5))
          : IconButton(
              tooltip: l.stopTask,
              visualDensity: VisualDensity.compact,
              onPressed: _stop,
              icon: Icon(AppIcons.stopCircleOutlined, size: 18),
            ),
    );
  }
}

/// One thread of the conversation: what it is about, its replies and its
/// last reply; running in words beside the dot.
class _ThreadRow extends StatelessWidget {
  const _ThreadRow({required this.summary, required this.onTap});
  final ThreadSummary summary;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final s = summary;
    final task = s.task;
    final running = s.running || (task?.running ?? false);
    final title = s.readable && (task?.title ?? '').isNotEmpty
        ? task!.title!
        : (s.readable ? s.rootExcerpt : null) ?? l.threadTitle;
    final meta = [
      if (running) l.stateRunning,
      if (s.replies > 0) l.threadReplies(s.replies),
      if (s.lastReplyAt != null) relativeTime(s.lastReplyAt),
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(AppIcons.reply, size: 15, color: running ? p.online : p.tertiary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.3),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(meta, style: TextStyle(fontSize: 12, color: p.tertiary)),
                  ],
                  if (s.readable && (s.lastReplyExcerpt ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      s.lastReplyExcerpt!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: p.secondary, height: 1.35),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The workspace folder with git change tags (the sheet's Files tab; the Mac's side panel).
class WorkspaceFiles extends StatefulWidget {
  const WorkspaceFiles({super.key, required this.ws});
  final WorkspaceRef ws;
  @override
  State<WorkspaceFiles> createState() => _WorkspaceFilesState();
}

class _WorkspaceFilesState extends State<WorkspaceFiles> {
  GitStatus? _git;
  bool _gitDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadGit());
  }

  Future<void> _loadGit() async {
    final app = AppScope.read(context);
    GitStatus? g;
    try {
      g = await withSession(
        (sid) => app.client.gitStatus(app.current!.orgId, widget.ws.agentId, sessionId: sid),
        widget.ws.sessionId,
      );
    } catch (_) {}
    if (mounted) {
      setState(() {
        _git = g;
        _gitDone = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // The list waits for git status so its change tags are there from the start.
    if (!_gitDone) return const Center(child: Spinner());
    return FolderList(
      ws: widget.ws,
      path: '',
      changes: Changes.of(_git),
      header: _git == null ? null : _RootCard(git: _git!),
    );
  }
}

/// Workspace folder, branch and how many files changed (the design's Files card head).
class _RootCard extends StatelessWidget {
  const _RootCard({required this.git});
  final GitStatus git;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final dir = git.dir;
    final n = git.files.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (dir != null && dir.isNotEmpty)
            Text(
              dir,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono(context, size: 12, color: p.secondary),
            ),
          if (git.isRepo) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(AppIcons.callSplit, size: 14, color: p.tertiary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    git.branch ?? '—',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(context, size: 12, color: p.ink),
                  ),
                ),
                const SizedBox(width: 10),
                if (n > 0) ...[
                  StatusDot(color: p.paused, size: 7),
                  const SizedBox(width: 5),
                  Text('${l.changes} $n', style: mono(context, size: 12, color: p.paused)),
                ] else
                  Text(l.noChanges, style: mono(context, size: 12)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Branch, changes and commit (the sheet's Git tab; the Mac's side panel).
class WorkspaceGit extends StatefulWidget {
  const WorkspaceGit({super.key, required this.ws, this.onStatus});
  final WorkspaceRef ws;
  final ValueChanged<GitStatus>? onStatus;
  @override
  State<WorkspaceGit> createState() => _WorkspaceGitState();
}

class _WorkspaceGitState extends State<WorkspaceGit> {
  final _message = TextEditingController();
  GitStatus? _status;
  Object? _error;
  bool _committing = false;
  String? _result;
  bool _resultOk = false;

  @override
  void initState() {
    super.initState();
    _message.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    setState(() => _error = null);
    try {
      final g = await withSession(
          (sid) => app.client.gitStatus(app.current!.orgId, widget.ws.agentId, sessionId: sid), widget.ws.sessionId);
      if (!mounted) return;
      setState(() => _status = g);
      widget.onStatus?.call(g);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _commit() async {
    final l = AppLocalizations.of(context);
    final g = _status;
    final msg = _message.text.trim();
    if (g == null || msg.isEmpty || g.files.isEmpty) return;
    final app = AppScope.read(context);
    setState(() {
      _committing = true;
      _result = null;
    });
    try {
      final r = await withSession(
          (sid) => app.client.commit(app.current!.orgId, widget.ws.agentId, g.files.map((f) => f.path).toList(), msg,
              sessionId: sid),
          widget.ws.sessionId);
      if (!mounted) return;
      setState(() {
        _resultOk = r.ok;
        _result = r.ok
            ? l.committed((r.sha ?? '').length > 7 ? r.sha!.substring(0, 7) : (r.sha ?? ''))
            : l.commitFailed(r.reason ?? 'error');
        if (r.ok) _message.clear();
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resultOk = false;
        _result = e is ApiException && e.readOnlyGrant ? l.readOnlyGrant : workspaceError(l, e);
      });
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    if (_error != null) {
      return StateView(icon: AppIcons.cloudOff, title: workspaceError(l, _error!), actionLabel: l.tryAgain, onAction: _load);
    }
    final g = _status;
    if (g == null) return const Center(child: Spinner());
    if (!g.isRepo) return StateView(icon: AppIcons.commit, title: l.notARepo);
    Widget kv(String k, String? v) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            Text(k, style: TextStyle(fontSize: 14, color: p.secondary)),
            const Spacer(),
            Text(v ?? '—', style: mono(context, size: 14, color: p.ink)),
          ]),
        );
    Color codeColor(String c) => switch (c) {
          'A' => p.online,
          'D' => p.error,
          _ => p.paused,
        };
    return RefreshIndicator.adaptive(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
        GroupCard(children: [kv(l.fieldBranch, g.branch), kv(l.fieldBase, g.base)]),
        SectionHeader('${l.changes} ${g.files.length}'),
        if (g.files.isEmpty)
          AppCard(child: Text(l.noChanges, style: TextStyle(color: p.secondary)))
        else ...[
          GroupCard(children: [
            for (final f in g.files)
              InkWell(
                onTap: () => openWorkspaceFile(
                    context, FileViewScreen(ws: widget.ws, path: f.path, changes: Changes.of(g), depth: 0)),
                child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  SizedBox(
                      width: 18,
                      child: Text(f.code, style: mono(context, size: 13, color: codeColor(f.code), weight: FontWeight.w600))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(f.path,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 13, color: p.ink)),
                  ),
                  if ((f.additions ?? 0) > 0) Text('+${f.additions}', style: mono(context, size: 12, color: p.online)),
                  if ((f.deletions ?? 0) > 0) ...[
                    const SizedBox(width: 6),
                    Text('-${f.deletions}', style: mono(context, size: 12, color: p.error)),
                  ],
                ]),
              ),
              ),
          ]),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
                color: p.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: p.border)),
            padding: const EdgeInsets.fromLTRB(4, 2, 8, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: _message,
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: l.commitMessage,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: const EdgeInsets.fromLTRB(10, 12, 10, 4),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _committing || _message.text.trim().isEmpty ? null : _commit,
                  child: _committing
                      ? const SizedBox(width: 16, height: 16, child: Spinner(strokeWidth: 2, color: Colors.white))
                      : Text(l.commitFiles(g.files.length)),
                ),
              ),
            ]),
          ),
        ],
        if (_result != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Semantics(
              liveRegion: true,
              child: Text(_result!, style: TextStyle(fontSize: 13, color: _resultOk ? p.online : p.error)),
            ),
          ),
      ]),
    );
  }
}
