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
import 'file_kind.dart';
import 'file_view_screen.dart';

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
Future<T> withSession<T>(Future<T> Function(String? sessionId) call, String sessionId) async {
  try {
    return await call(sessionId);
  } on ApiException catch (e) {
    if (e.status == 400 || e.status == 404) return call(null);
    rethrow;
  }
}

/// Uncommitted changes by path (`M`, `A`, `D`, `R`), from `gitstatus`.
class Changes {
  const Changes([this._byPath = const {}]);
  factory Changes.of(GitStatus? g) => Changes({for (final f in g?.files ?? const <GitFile>[]) f.path: f.code});
  final Map<String, String> _byPath;

  String? of(String path) => _byPath[path];

  /// Something under the folder [dir] changed.
  bool inside(String dir) {
    final prefix = '$dir/';
    return _byPath.keys.any((p) => p.startsWith(prefix));
  }

  int get length => _byPath.length;
}

/// The git status letter as a small tinted square (the design's M / A tags).
class ChangeTag extends StatelessWidget {
  const ChangeTag(this.code, {super.key});
  final String code;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final l = AppLocalizations.of(context);
    final (fg, bg, label) = switch (code) {
      'A' => (p.online, p.onlineSoft, l.gitAdded),
      'D' => (p.error, p.errorSoft, l.gitDeleted),
      'R' => (p.info, p.infoSoft, l.gitRenamed),
      _ => (p.paused, p.pausedSoft, l.gitModified),
    };
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
        child: Text(
          code,
          style: mono(context, size: 11, color: fg, weight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// One file or folder: kind icon, mono name, size · age, change tag.
class FileRow extends StatelessWidget {
  const FileRow({
    super.key,
    required this.ws,
    required this.parent,
    required this.entry,
    required this.changes,
    this.depth = 0,
  });
  final WorkspaceRef ws;
  final String parent;
  final FileEntry entry;
  final Changes changes;

  /// How many folder screens sit above the sheet (for the breadcrumb).
  final int depth;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final l = AppLocalizations.of(context);
    final e = entry;
    final path = parent.isEmpty ? e.name : '$parent/${e.name}';
    final kind = e.isDir ? null : FileKind.of(e.name);
    final code = e.isDir ? null : changes.of(path);
    final meta = [
      if (!e.isDir && e.size != null) formatBytes(e.size),
      if (e.mtime != null) relativeTime(e.mtime),
    ].join(' · ');
    return InkWell(
      onTap: () => push(
        context,
        e.isDir
            ? FileBrowserScreen(ws: ws, path: path, changes: changes, depth: depth + 1)
            : FileViewScreen(ws: ws, path: path, size: e.size?.toInt(), changes: changes, depth: depth),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
          child: Row(
            children: [
              Icon(e.isDir ? Icons.folder_outlined : kind!.icon, size: 20, color: e.isDir ? p.secondary : p.tertiary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      e.isDir ? '${e.name}/' : e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(context, size: 14, color: p.ink),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(meta, maxLines: 1, style: mono(context, size: 11.5)),
                    ],
                  ],
                ),
              ),
              if (code != null) ...[const SizedBox(width: 8), ChangeTag(code)],
              if (e.isDir && changes.inside(path))
                Semantics(
                  label: l.folderHasChanges,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: StatusDot(color: p.paused, size: 7),
                  ),
                ),
              if (e.isDir) Icon(Icons.chevron_right, size: 20, color: p.tertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// A folder's listing, all pages (200 entries each) loaded on demand.
class FolderList extends StatefulWidget {
  const FolderList({
    super.key,
    required this.ws,
    required this.path,
    required this.changes,
    this.depth = 0,
    this.header,
  });
  final WorkspaceRef ws;
  final String path;
  final Changes changes;
  final int depth;

  /// Above the list (the Files tab's workspace card).
  final Widget? header;

  @override
  State<FolderList> createState() => _FolderListState();
}

class _FolderListState extends State<FolderList> {
  DirPage? _page;
  Object? _error;
  bool _more = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<DirPage> _fetch({String? cursor}) {
    final app = AppScope.read(context);
    return withSession(
      (sid) =>
          app.client.files(app.current!.orgId, widget.ws.agentId, sessionId: sid, path: widget.path, cursor: cursor),
      widget.ws.sessionId,
    );
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final page = await _fetch();
      if (mounted) setState(() => _page = page);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadMore() async {
    final page = _page;
    if (page?.nextCursor == null || _more) return;
    setState(() => _more = true);
    try {
      final next = await _fetch(cursor: page!.nextCursor);
      if (mounted) setState(() => _page = page.followedBy(next));
    } catch (_) {
    } finally {
      if (mounted) setState(() => _more = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    if (_error != null) {
      return StateView(
        icon: Icons.cloud_off,
        title: workspaceError(l, _error!),
        actionLabel: l.tryAgain,
        onAction: _load,
      );
    }
    final page = _page;
    if (page == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          ?widget.header,
          if (!page.exists || page.entries.isEmpty)
            AppCard(
              child: Text(l.folderEmpty, style: TextStyle(color: p.secondary)),
            )
          else
            GroupCard(
              children: [
                for (final e in page.entries)
                  FileRow(ws: widget.ws, parent: widget.path, entry: e, changes: widget.changes, depth: widget.depth),
              ],
            ),
          if (page.nextCursor != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: _more
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : TextButton(onPressed: _loadMore, child: Text(l.loadMore)),
              ),
            ),
        ],
      ),
    );
  }
}

/// One folder of the workspace, read-only, under a breadcrumb back to the root.
class FileBrowserScreen extends StatelessWidget {
  const FileBrowserScreen({super.key, required this.ws, required this.path, required this.changes, this.depth = 1});
  final WorkspaceRef ws;
  final String path;
  final Changes changes;

  /// Folder screens pushed above the sheet, this one included.
  final int depth;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final segs = path.split('/');
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${segs.last}/',
          style: mono(context, size: 17, color: p.ink, weight: FontWeight.w600),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: Breadcrumb(segments: segs, depth: depth),
        ),
      ),
      body: FolderList(ws: ws, path: path, changes: changes, depth: depth),
    );
  }
}

/// `Workspace › src › lib` — each ancestor whose screen is on the stack pops
/// back to it (the root is the workspace sheet).
class Breadcrumb extends StatelessWidget {
  const Breadcrumb({super.key, required this.segments, required this.depth, this.isFile = false});
  final List<String> segments;

  /// Folder screens pushed above the sheet, up to this page's folder (a file
  /// opened from the Files tab: 0). Null: unknown, nothing is tappable.
  final int? depth;

  /// The last segment is a file.
  final bool isFile;

  /// Routes to pop to reach crumb [i] (0 = root), or null when it isn't on the stack.
  int? popsTo(int i) {
    final d = depth;
    final folders = isFile ? segments.length - 1 : segments.length;
    if (d == null || i > folders || (i == folders && !isFile)) return null;
    final own = isFile ? 1 : 0;
    if (i == 0) return own + d;
    if (i > folders - d) return own + folders - i;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final crumbs = [l.workspaceRoot, ...segments];
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          Row(
            children: [
              for (var i = 0; i < crumbs.length; i++) ...[
                if (i > 0) Icon(Icons.chevron_right, size: 14, color: p.tertiary),
                _crumb(
                  context,
                  crumbs[i],
                  last: i == crumbs.length - 1,
                  pops: i == crumbs.length - 1 ? null : popsTo(i),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _crumb(BuildContext context, String text, {required bool last, int? pops}) {
    final p = context.pal;
    final label = Text(
      text,
      style: mono(
        context,
        size: 12,
        color: last ? p.ink : (pops != null ? p.brandText : p.tertiary),
        weight: last ? FontWeight.w500 : null,
      ),
    );
    const pad = EdgeInsets.symmetric(horizontal: 4, vertical: 8);
    if (pops == null || pops <= 0) return Padding(padding: pad, child: label);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        final nav = Navigator.of(context);
        for (var k = 0; k < pops; k++) {
          nav.pop();
        }
      },
      child: Padding(padding: pad, child: label),
    );
  }
}
