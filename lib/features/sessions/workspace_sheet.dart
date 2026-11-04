import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/api/workspace.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../nav.dart';
import 'task_widgets.dart';

/// Where a session's workspace lives: the agent plus the session (an isolated
/// worktree when it has one; the agent's checkout otherwise).
class WorkspaceRef {
  const WorkspaceRef({required this.agentId, required this.agentName, required this.sessionId, this.agent, this.title});
  final String agentId;
  final String agentName;
  final String sessionId;
  final Agent? agent;
  final String? title;
}

Future<void> openWorkspace(BuildContext context, WorkspaceRef ref, {required List<AgentTask> tasks, int tab = 0}) {
  final app = AppScope.read(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => AppScope(
      state: app,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.86,
        child: _WorkspaceSheet(ws: ref, tasks: tasks, initialTab: tab),
      ),
    ),
  );
}

String workspaceError(AppLocalizations l, Object e) {
  if (e is ApiException) {
    if (e.status == 503) return l.workspaceOffline;
    if (e.status == 409) return l.agentBusy;
    if (e.status == 403 || e.status == 404 || e.status == 400) return l.workspaceUnavailable;
  }
  return errorText(l, e);
}

/// Workspace reads take the session first (isolated worktree); a session
/// without one falls back to the agent's own checkout.
Future<T> _withSession<T>(Future<T> Function(String? sessionId) call, String sessionId) async {
  try {
    return await call(sessionId);
  } on ApiException catch (e) {
    if (e.status == 400 || e.status == 404) return call(null);
    rethrow;
  }
}

class _WorkspaceSheet extends StatefulWidget {
  const _WorkspaceSheet({required this.ws, required this.tasks, required this.initialTab});
  final WorkspaceRef ws;
  final List<AgentTask> tasks;
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
      0 => _TasksTab(ws: widget.ws, tasks: widget.tasks),
      1 => _FilesTab(ws: widget.ws),
      _ => _GitTab(ws: widget.ws, onStatus: (g) => setState(() => _git = g)),
    };
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
        child: Row(children: [
          Expanded(
            child: Text(widget.ws.title ?? l.untitled,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
        ]),
      ),
      Row(children: [
        tab(0, Icons.checklist, l.tabTasks, running),
        tab(1, Icons.account_tree_outlined, l.tabFiles, 0),
        tab(2, Icons.commit, l.tabGit, changes),
      ]),
      Divider(height: 1, color: p.hairline),
      Expanded(child: body),
    ]);
  }
}

class _TasksTab extends StatelessWidget {
  const _TasksTab({required this.ws, required this.tasks});
  final WorkspaceRef ws;
  final List<AgentTask> tasks;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    if (tasks.isEmpty) {
      return StateView(icon: Icons.checklist, title: l.noTasksTitle, body: l.noTasksBody);
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
      SectionHeader('${l.threadedTasks} ${tasks.length}'),
      GroupCard(children: [
        for (final t in tasks)
          InkWell(
            onTap: t.sessionId == null
                ? null
                : () => openTaskThread(context, t, agent: ws.agent, agentId: ws.agentId, agentName: ws.agentName),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: t.running
                      ? StatusDot(color: p.online, size: 9)
                      : Container(
                          width: 9,
                          height: 9,
                          decoration:
                              BoxDecoration(shape: BoxShape.circle, border: Border.all(color: p.idle, width: 1.5))),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Text(t.title.isEmpty ? l.untitled : t.title,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                      if (t.replies > 0) ...[
                        Icon(Icons.reply, size: 14, color: p.tertiary),
                        const SizedBox(width: 2),
                        Text('${t.replies}', style: mono(context, size: 12)),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(
                        [
                          taskStateLabel(l, t),
                          if (t.startedAt != null) l.startedAgo(relativeTime(t.startedAt)),
                          if (t.summaryAt != null) l.summaryAgo(relativeTime(t.summaryAt)),
                        ].join(' · '),
                        style: TextStyle(fontSize: 12, color: p.tertiary)),
                    if ((t.summary ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(t.summary!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, color: p.secondary, height: 1.35)),
                    ],
                  ]),
                ),
              ]),
            ),
          ),
      ]),
    ]);
  }
}

class _FilesTab extends StatefulWidget {
  const _FilesTab({required this.ws});
  final WorkspaceRef ws;
  @override
  State<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<_FilesTab> {
  DirPage? _page;
  String? _root;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final org = app.current!.orgId;
    setState(() => _error = null);
    try {
      final page = await _withSession(
          (sid) => app.client.files(org, widget.ws.agentId, sessionId: sid), widget.ws.sessionId);
      String? root;
      try {
        root = (await _withSession((sid) => app.client.gitStatus(org, widget.ws.agentId, sessionId: sid),
                widget.ws.sessionId))
            .dir;
      } catch (_) {}
      if (mounted) {
        setState(() {
        _page = page;
        _root = root;
      });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    if (_error != null) {
      return StateView(icon: Icons.cloud_off, title: workspaceError(l, _error!), actionLabel: l.tryAgain, onAction: _load);
    }
    final page = _page;
    if (page == null) return const Center(child: CircularProgressIndicator());
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Row(children: [
          Expanded(
            child: Text(_root ?? (page.path.isEmpty ? '/' : page.path),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 12, color: p.secondary)),
          ),
          TextButton(
            onPressed: () => push(context, FileBrowserScreen(ws: widget.ws, path: '')),
            child: Row(mainAxisSize: MainAxisSize.min, children: [Text(l.browseAll), const Icon(Icons.chevron_right, size: 18)]),
          ),
        ]),
      ),
      if (page.entries.isEmpty)
        AppCard(child: Text(l.folderEmpty, style: TextStyle(color: p.secondary)))
      else
        GroupCard(children: [
          for (final e in page.entries.take(12)) _EntryRow(ws: widget.ws, parent: '', entry: e),
        ]),
    ]);
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.ws, required this.parent, required this.entry});
  final WorkspaceRef ws;
  final String parent;
  final FileEntry entry;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = entry;
    final path = parent.isEmpty ? e.name : '$parent/${e.name}';
    return InkWell(
      onTap: () => push(context, e.isDir ? FileBrowserScreen(ws: ws, path: path) : FileViewScreen(ws: ws, path: path)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          Icon(e.isDir ? Icons.folder_outlined : Icons.description_outlined,
              size: 20, color: e.isDir ? p.link : p.secondary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(e.isDir ? '${e.name}/' : e.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 14, color: p.ink)),
          ),
          if (!e.isDir && e.mtime != null) Text(relativeTime(e.mtime), style: mono(context, size: 12)),
        ]),
      ),
    );
  }
}

/// One folder of the workspace, read-only.
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key, required this.ws, required this.path});
  final WorkspaceRef ws;
  final String path;
  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  DirPage? _page;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    setState(() => _error = null);
    try {
      final page = await _withSession(
          (sid) => app.client.files(app.current!.orgId, widget.ws.agentId, sessionId: sid, path: widget.path),
          widget.ws.sessionId);
      if (mounted) setState(() => _page = page);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final page = _page;
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.path.isEmpty ? l.tabFiles : widget.path.split('/').last,
              style: mono(context, size: 17, color: p.ink, weight: FontWeight.w600))),
      body: _error != null
          ? StateView(icon: Icons.cloud_off, title: workspaceError(l, _error!), actionLabel: l.tryAgain, onAction: _load)
          : page == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
                    if (!page.exists || page.entries.isEmpty)
                      AppCard(child: Text(l.folderEmpty, style: TextStyle(color: p.secondary)))
                    else
                      GroupCard(children: [
                        for (final e in page.entries) _EntryRow(ws: widget.ws, parent: widget.path, entry: e),
                      ]),
                  ]),
                ),
    );
  }
}

/// A file's first slice, read-only, in memory only.
class FileViewScreen extends StatefulWidget {
  const FileViewScreen({super.key, required this.ws, required this.path});
  final WorkspaceRef ws;
  final String path;
  @override
  State<FileViewScreen> createState() => _FileViewScreenState();
}

class _FileViewScreenState extends State<FileViewScreen> {
  FileSlice? _file;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    setState(() => _error = null);
    try {
      final f = await _withSession(
          (sid) => app.client.file(app.current!.orgId, widget.ws.agentId, widget.path, sessionId: sid),
          widget.ws.sessionId);
      if (mounted) setState(() => _file = f);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final f = _file;
    Widget body;
    if (_error != null) {
      body = StateView(icon: Icons.cloud_off, title: workspaceError(l, _error!), actionLabel: l.tryAgain, onAction: _load);
    } else if (f == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!f.exists) {
      body = StateView(icon: Icons.description_outlined, title: l.fileMissing);
    } else if (f.binary) {
      body = StateView(icon: Icons.description_outlined, title: l.binaryFile);
    } else {
      body = ListView(padding: const EdgeInsets.all(16), children: [
        if (f.truncated)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(l.fileTruncated, style: TextStyle(fontSize: 13, color: p.secondary)),
          ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: p.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: p.border)),
          child: SelectableText(f.text, style: mono(context, size: 12, color: p.ink)),
        ),
      ]);
    }
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.path.split('/').last,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, size: 16, color: p.ink, weight: FontWeight.w600))),
      body: body,
    );
  }
}

class _GitTab extends StatefulWidget {
  const _GitTab({required this.ws, required this.onStatus});
  final WorkspaceRef ws;
  final ValueChanged<GitStatus> onStatus;
  @override
  State<_GitTab> createState() => _GitTabState();
}

class _GitTabState extends State<_GitTab> {
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
      final g = await _withSession(
          (sid) => app.client.gitStatus(app.current!.orgId, widget.ws.agentId, sessionId: sid), widget.ws.sessionId);
      if (!mounted) return;
      setState(() => _status = g);
      widget.onStatus(g);
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
      final r = await _withSession(
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
      return StateView(icon: Icons.cloud_off, title: workspaceError(l, _error!), actionLabel: l.tryAgain, onAction: _load);
    }
    final g = _status;
    if (g == null) return const Center(child: CircularProgressIndicator());
    if (!g.isRepo) return StateView(icon: Icons.commit, title: l.notARepo);
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
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
        GroupCard(children: [kv(l.fieldBranch, g.branch), kv(l.fieldBase, g.base)]),
        SectionHeader('${l.changes} ${g.files.length}'),
        if (g.files.isEmpty)
          AppCard(child: Text(l.noChanges, style: TextStyle(color: p.secondary)))
        else ...[
          GroupCard(children: [
            for (final f in g.files)
              Padding(
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
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
