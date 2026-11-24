import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/workspace.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/adaptive.dart';
import '../../ui/format.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../desktop/session_panel.dart';
import '../nav.dart';
import 'file_kind.dart';
import 'file_view_screen.dart';
import 'workspace_files.dart';

/// The side panel's Files tab, as the web console has it: the session's own
/// files (what the agent made, what was sent to it) above the workspace, each
/// section folding on its own. Without a session, the workspace alone.
class FilesPanel extends StatefulWidget {
  const FilesPanel({super.key, required this.ws});
  final WorkspaceRef ws;
  @override
  State<FilesPanel> createState() => _FilesPanelState();
}

class _FilesPanelState extends State<FilesPanel> {
  bool _session = true, _workspace = true;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (widget.ws.sessionId == null) return WorkspaceTree(ws: widget.ws);
    return LayoutBuilder(
      builder: (context, box) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _SectionHeader(
          label: l.sessionFiles,
          tooltip: l.sessionFilesTitle,
          open: _session,
          onTap: () => setState(() => _session = !_session),
        ),
        // As tall as its rows, at most half the panel beside an open workspace;
        // kept while folded, so its open folders survive.
        Offstage(
          offstage: !_session,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: _workspace ? box.maxHeight / 2 : box.maxHeight - 80),
            child: SessionFilesTree(ws: widget.ws),
          ),
        ),
        _SectionHeader(
          label: l.workspaceFiles,
          tooltip: l.workspaceFilesTitle,
          open: _workspace,
          onTap: () => setState(() => _workspace = !_workspace),
        ),
        if (_workspace) Expanded(child: WorkspaceTree(ws: widget.ws)),
      ]),
    );
  }
}

/// A section's header: folds it, says what it holds on hover.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.tooltip, required this.open, required this.onTap});
  final String label;
  final String tooltip;
  final bool open;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          waitDuration: const Duration(milliseconds: 600),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.hairline))),
            child: Row(children: [
              Icon(open ? AppIcons.expandMore : AppIcons.chevronRight, size: 13, color: p.tertiary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.secondary)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The session's files directory: `/outputs` (what the agent made) and
/// `/uploads` (what was sent to it), both open, no git status. Read for the
/// session only, never the agent's own checkout.
class SessionFilesTree extends StatefulWidget {
  const SessionFilesTree({super.key, required this.ws});
  final WorkspaceRef ws;
  static const areas = ['outputs', 'uploads'];
  @override
  State<SessionFilesTree> createState() => _SessionFilesTreeState();
}

class _SessionFilesTreeState extends State<SessionFilesTree> {
  /// Folders by `area/path` (the area itself: `area/`).
  final Map<String, _Dir> _dirs = {};
  final Set<String> _open = {for (final a in SessionFilesTree.areas) '$a/'};
  String? _selected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final a in SessionFilesTree.areas) {
        _load(a, '');
      }
    });
  }

  Future<DirPage> _fetch(String area, String path, {String? cursor}) {
    final app = AppScope.read(context);
    return app.client.files(app.current!.orgId, widget.ws.agentId,
        sessionId: widget.ws.sessionId, path: path, cursor: cursor, root: area);
  }

  Future<void> _load(String area, String path) async {
    final d = _dirs.putIfAbsent('$area/$path', _Dir.new);
    setState(() {
      d.loading = true;
      d.error = null;
    });
    try {
      final page = await _fetch(area, path);
      if (mounted) setState(() => d.page = page);
    } catch (e) {
      if (mounted) setState(() => d.error = e);
    } finally {
      if (mounted) setState(() => d.loading = false);
    }
  }

  Future<void> _loadMore(String area, String path) async {
    final d = _dirs['$area/$path'];
    final page = d?.page;
    if (d == null || page?.nextCursor == null || d.more) return;
    setState(() => d.more = true);
    try {
      final next = await _fetch(area, path, cursor: page!.nextCursor);
      if (mounted) setState(() => d.page = page.followedBy(next));
    } catch (_) {
    } finally {
      if (mounted) setState(() => d.more = false);
    }
  }

  void _toggle(String area, String path) {
    final key = '$area/$path';
    setState(() {
      if (!_open.remove(key)) _open.add(key);
    });
    if (_open.contains(key) && _dirs[key]?.page == null) _load(area, path);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final rows = <Widget>[];
    Widget note(String text, int depth) =>
        _Note(depth: depth, child: Text(text, style: TextStyle(fontSize: 12, color: p.tertiary)));

    void level(String area, String dir, int depth) {
      final d = _dirs['$area/$dir'];
      final page = d?.page;
      if (page == null) {
        final e = d?.error;
        if (e == null) {
          rows.add(const _Note(
              depth: 1,
              child: Align(alignment: Alignment.centerLeft, child: SizedBox.square(dimension: 14, child: Spinner()))));
        } else if (dir.isEmpty) {
          rows.add(note(e is ApiException && e.status == 409 ? l.sessionFilesUnsupported : l.sessionFilesOffline, depth));
        } else {
          rows.add(note(workspaceError(l, e), depth));
        }
        return;
      }
      if (dir.isEmpty && (!page.exists || page.entries.isEmpty)) {
        rows.add(note(l.sessionFilesEmpty, depth));
        return;
      }
      for (final e in page.entries) {
        final path = dir.isEmpty ? e.name : '$dir/${e.name}';
        if (e.isDir) {
          final open = _open.contains('$area/$path');
          rows.add(_TreeRow(
            depth: depth,
            chevron: open ? AppIcons.expandMore : AppIcons.chevronRight,
            icon: open ? AppIcons.folderOpenOutlined : AppIcons.folderOutlined,
            name: e.name,
            onTap: () => _toggle(area, path),
          ));
          if (open) level(area, path, depth + 1);
        } else {
          rows.add(_TreeRow(
            depth: depth,
            icon: FileKind.of(e.name).icon,
            name: e.name,
            tooltip: [if (e.size != null) formatBytes(e.size), if (e.mtime != null) relativeTime(e.mtime)].join(' · '),
            selected: _selected == '$area/$path',
            onTap: e.type == 'file' || e.type == 'symlink'
                ? () {
                    setState(() => _selected = '$area/$path');
                    openWorkspaceFile(
                        context, FileViewScreen(ws: widget.ws.inArea(area), path: path, size: e.size?.toInt()));
                  }
                : null,
          ));
        }
      }
      if (page.nextCursor != null) {
        rows.add(_Note(
          depth: depth,
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: d!.more ? null : () => _loadMore(area, dir), child: Text(l.loadMore)),
          ),
        ));
      }
    }

    for (final area in SessionFilesTree.areas) {
      final open = _open.contains('$area/');
      rows.add(_TreeRow(
        depth: 0,
        chevron: open ? AppIcons.expandMore : AppIcons.chevronRight,
        icon: open ? AppIcons.folderOpenOutlined : AppIcons.folderOutlined,
        name: '/$area',
        onTap: () => _toggle(area, ''),
      ));
      if (open) level(area, '', 1);
    }
    return ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 6), children: rows);
  }
}

/// The workspace as one narrow tree, as the web console's Files panel draws
/// it (the Mac's side panel): a filter over the files already loaded, the
/// branch and folder, folders that open in place, git status tags, and the
/// file last opened marked. A file opens beside the panel.
class WorkspaceTree extends StatefulWidget {
  const WorkspaceTree({super.key, required this.ws});
  final WorkspaceRef ws;
  @override
  State<WorkspaceTree> createState() => _WorkspaceTreeState();
}

class _Dir {
  DirPage? page;
  Object? error;
  bool loading = false;
  bool more = false;
}

class _WorkspaceTreeState extends State<WorkspaceTree> {
  final _query = TextEditingController();
  final Map<String, _Dir> _dirs = {};
  final Set<String> _open = {};
  GitStatus? _git;
  bool _gitDone = false;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await Future.wait([_loadGit(), _loadDir(''), for (final d in _open) _loadDir(d)]);
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
    if (!mounted) return;
    setState(() {
      _git = g;
      _gitDone = true;
    });
    if (g != null) SessionPanelScope.maybeOf(context)?.reportGit(g.files.length);
  }

  Future<DirPage> _fetch(String path, {String? cursor}) {
    final app = AppScope.read(context);
    return withSession(
      (sid) => app.client.files(app.current!.orgId, widget.ws.agentId, sessionId: sid, path: path, cursor: cursor),
      widget.ws.sessionId,
    );
  }

  Future<void> _loadDir(String path) async {
    final d = _dirs.putIfAbsent(path, _Dir.new);
    setState(() {
      d.loading = true;
      d.error = null;
    });
    try {
      final page = await _fetch(path);
      if (mounted) setState(() => d.page = page);
    } catch (e) {
      if (mounted) setState(() => d.error = e);
    } finally {
      if (mounted) setState(() => d.loading = false);
    }
  }

  Future<void> _loadMore(String path) async {
    final d = _dirs[path];
    final page = d?.page;
    if (d == null || page?.nextCursor == null || d.more) return;
    setState(() => d.more = true);
    try {
      final next = await _fetch(path, cursor: page!.nextCursor);
      if (mounted) setState(() => d.page = page.followedBy(next));
    } catch (_) {
    } finally {
      if (mounted) setState(() => d.more = false);
    }
  }

  void _toggle(String path) {
    setState(() {
      if (!_open.remove(path)) _open.add(path);
    });
    if (_open.contains(path) && _dirs[path]?.page == null) _loadDir(path);
  }

  void _openFile(String path, FileEntry e, Changes changes) {
    setState(() => _selected = path);
    openWorkspaceFile(context, FileViewScreen(ws: widget.ws, path: path, size: e.size?.toInt(), changes: changes));
  }

  /// Every file in the folders loaded so far: the only ones a filter can search.
  List<(String, FileEntry)> get _loadedFiles {
    final out = <(String, FileEntry)>[];
    for (final MapEntry(key: dir, value: d) in _dirs.entries) {
      for (final e in d.page?.entries ?? const <FileEntry>[]) {
        if (!e.isDir) out.add((dir.isEmpty ? e.name : '$dir/${e.name}', e));
      }
    }
    return out..sort((a, b) => a.$1.compareTo(b.$1));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final changes = Changes.of(_git);
    final root = _dirs[''];
    final q = _query.text.trim().toLowerCase();

    final rows = <Widget>[];
    void level(String dir, int depth) {
      final d = _dirs[dir];
      if (d == null) return;
      final page = d.page;
      if (page == null) {
        rows.add(
          _Note(
            depth: depth,
            child: d.error != null
                ? Text(workspaceError(l, d.error!), style: TextStyle(fontSize: 12, color: p.tertiary))
                : const Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox.square(dimension: 14, child: Spinner()),
                  ),
          ),
        );
        return;
      }
      for (final e in page.entries) {
        final path = dir.isEmpty ? e.name : '$dir/${e.name}';
        if (e.isDir) {
          final open = _open.contains(path);
          rows.add(
            _TreeRow(
              depth: depth,
              chevron: open ? AppIcons.expandMore : AppIcons.chevronRight,
              icon: open ? AppIcons.folderOpenOutlined : AppIcons.folderOutlined,
              name: e.name,
              // Something inside changed: a dot, as the folder has no letter of its own.
              trailing: changes.inside(path) ? StatusDot(color: p.paused, size: 6) : null,
              onTap: () => _toggle(path),
            ),
          );
          if (open) level(path, depth + 1);
        } else {
          final code = changes.of(path);
          rows.add(
            _TreeRow(
              depth: depth,
              icon: FileKind.of(e.name).icon,
              name: e.name,
              tooltip: [
                if (e.size != null) formatBytes(e.size),
                if (e.mtime != null) relativeTime(e.mtime),
              ].join(' · '),
              trailing: code == null ? null : ChangeTag(code),
              selected: _selected == path,
              onTap: e.type == 'file' || e.type == 'symlink' ? () => _openFile(path, e, changes) : null,
            ),
          );
        }
      }
      if (page.nextCursor != null) {
        rows.add(
          _Note(
            depth: depth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: d.more ? null : () => _loadMore(dir), child: Text(l.loadMore)),
            ),
          ),
        );
      }
    }

    Widget body;
    if (root?.page == null && root?.error != null) {
      body = StateView(
        icon: AppIcons.cloudOff,
        title: workspaceError(l, root!.error!),
        actionLabel: l.tryAgain,
        onAction: _refresh,
      );
    } else if (root?.page == null || !_gitDone) {
      body = const Center(child: Spinner());
    } else if (!root!.page!.exists || root.page!.entries.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.all(16),
        child: Text(l.folderEmpty, style: TextStyle(fontSize: 13, color: p.secondary)),
      );
    } else if (q.isNotEmpty) {
      final matches = _loadedFiles.where((f) => f.$1.toLowerCase().contains(q)).toList();
      body = ListView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
            child: Text(l.filterMatches(matches.length), style: TextStyle(fontSize: 11.5, color: p.tertiary)),
          ),
          for (final (path, e) in matches)
            _TreeRow(
              depth: 0,
              icon: FileKind.of(e.name).icon,
              name: path,
              trailing: changes.of(path) == null ? null : ChangeTag(changes.of(path)!),
              selected: _selected == path,
              onTap: () => _openFile(path, e, changes),
            ),
        ],
      );
    } else {
      level('', 0);
      body = ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: rows);
    }

    final git = _git;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 32,
                      child: TextField(
                        controller: _query,
                        style: mono(context, size: 12, color: p.ink),
                        decoration: InputDecoration(
                          hintText: l.filterFiles,
                          isDense: true,
                          prefixIcon: Icon(AppIcons.search, size: 14, color: p.tertiary),
                          prefixIconConstraints: const BoxConstraints(minWidth: 30),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l.refreshFiles,
                    visualDensity: VisualDensity.compact,
                    onPressed: _refresh,
                    icon: Icon(AppIcons.refresh, size: 15, color: p.secondary),
                  ),
                ],
              ),
              if (git != null && (git.isRepo || (git.dir ?? '').isNotEmpty)) ...[
                const SizedBox(height: 7),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Row(
                    children: [
                      if (git.isRepo && git.branch != null) ...[
                        Icon(AppIcons.callSplit, size: 12, color: p.tertiary),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            git.branch!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: mono(context, size: 11, color: p.secondary, weight: FontWeight.w500),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if ((git.dir ?? '').isNotEmpty)
                        Expanded(
                          child: Tooltip(
                            message: git.dir!,
                            child: Text(
                              git.dir!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: mono(context, size: 11, color: p.tertiary),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        Divider(height: 1, color: p.hairline),
        Expanded(child: body),
      ],
    );
  }
}

/// One row of the tree: indent, chevron (folders), kind icon, mono name, tag.
/// The open file is marked with a bar at its right edge and a tint.
class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.depth,
    required this.icon,
    required this.name,
    this.chevron,
    this.trailing,
    this.tooltip,
    this.selected = false,
    this.onTap,
  });
  final int depth;
  final IconData icon;
  final IconData? chevron;
  final String name;
  final Widget? trailing;
  final String? tooltip;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final row = Container(
      constraints: const BoxConstraints(minHeight: 30),
      padding: EdgeInsets.only(left: 8.0 + depth * 14, right: 10),
      decoration: BoxDecoration(
        color: selected ? p.sunken : null,
        border: Border(right: BorderSide(color: selected ? p.brandText : Colors.transparent, width: 2)),
      ),
      child: Row(
        children: [
          SizedBox(width: 14, child: chevron == null ? null : Icon(chevron, size: 12, color: p.tertiary)),
          const SizedBox(width: 4),
          Icon(icon, size: 15, color: chevron != null ? p.secondary : p.tertiary),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono(context, size: 12.5, color: selected ? p.ink : p.secondary),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 6), trailing!],
        ],
      ),
    );
    final tip = tooltip ?? '';
    return Semantics(
      button: onTap != null,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: tip.isEmpty ? row : Tooltip(message: tip, waitDuration: const Duration(milliseconds: 600), child: row),
      ),
    );
  }
}

/// A line in the tree that isn't an entry: loading, an error, "Load more".
class _Note extends StatelessWidget {
  const _Note({required this.depth, required this.child});
  final int depth;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.fromLTRB(26.0 + depth * 14, 6, 12, 6), child: child);
}
