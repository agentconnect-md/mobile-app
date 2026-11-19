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
import 'workspace_files.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';

/// Sessions of [agentId] that work in their own worktree, newest first.
List<SessionRow> worktreeSessions(List<SessionRow> rows, String agentId) =>
    rows.where((r) => r.agentId == agentId && r.ownWorktree).toList();

/// An agent's session worktrees, read page by page from its sessions (a
/// worktree can sit behind many sessions on the shared checkout).
class WorktreeList extends ChangeNotifier {
  WorktreeList(this.client, this.orgId, this.agentId);
  final ApiClient client;
  final String orgId;
  final String agentId;

  final List<SessionRow> worktrees = [];
  String? _cursor;
  bool loaded = false;
  bool loading = false;

  /// Older sessions are still unread: there may be more worktrees.
  bool get hasMore => !loaded || _cursor != null;

  /// The first page, or the next one.
  Future<void> more() async {
    if (loading || (loaded && _cursor == null)) return;
    loading = true;
    notifyListeners();
    try {
      final page = await client.sessionRowsPage(orgId, agentId: agentId, cursor: _cursor);
      worktrees.addAll(worktreeSessions(page.rows, agentId));
      _cursor = page.cursor;
      loaded = true;
    } catch (_) {
      // Keeps what it has; "Load more" stays to try again.
    }
    loading = false;
    notifyListeners();
  }
}

/// An agent's workspace, read-only: the agent's own checkout, or one of its
/// sessions' worktrees picked from the checkout chip (as in the design).
class AgentWorkspaceScreen extends StatefulWidget {
  const AgentWorkspaceScreen({super.key, required this.agent, required this.worktrees});
  final Agent agent;

  /// Shared with the agent page, which started loading it.
  final WorktreeList worktrees;

  @override
  State<AgentWorkspaceScreen> createState() => _AgentWorkspaceScreenState();
}

class _AgentWorkspaceScreenState extends State<AgentWorkspaceScreen> {
  SessionRow? _worktree;
  GitStatus? _git;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadGit();
      if (!widget.worktrees.loaded) widget.worktrees.more();
    });
  }

  Future<void> _loadGit() async {
    final app = AppScope.read(context);
    final gen = ++_gen;
    try {
      final g = await withSession(
        (sid) => app.client.gitStatus(app.current!.orgId, widget.agent.id, sessionId: sid),
        _worktree?.sessionId,
      );
      if (mounted && gen == _gen) setState(() => _git = g);
    } catch (_) {
      // Files still list; the chip just has no branch name.
      if (mounted && gen == _gen) setState(() => _git = null);
    }
  }

  void _choose(SessionRow? w) {
    if (w?.sessionId == _worktree?.sessionId) return;
    setState(() {
      _worktree = w;
      _git = null;
    });
    _loadGit();
  }

  Future<void> _pickCheckout() async {
    final picked = await showModalBottomSheet<_Pick>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => AppScope(
        state: AppScope.read(context),
        child: _CheckoutSheet(
          agent: widget.agent,
          primaryBranch: _worktree == null ? _git?.branch : null,
          worktrees: widget.worktrees,
          selected: _worktree?.sessionId,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked.open && picked.worktree != null) {
      openSession(context, picked.worktree!);
    } else {
      _choose(picked.worktree);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final a = widget.agent;
    final ws = WorkspaceRef(
      agentId: a.id,
      agentName: a.label,
      agent: a,
      sessionId: _worktree?.sessionId,
      title: _worktree?.title,
    );
    final branch = _git?.branch ?? (_worktree == null ? a.workspace?.branch : null);
    final root = a.workspace?.label.split('/').last;
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: _pickCheckout,
            child: Container(
              height: 34,
              padding: const EdgeInsets.only(left: 10, right: 8),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: p.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _worktree == null ? AppIcons.forkRight : AppIcons.accountTreeOutlined,
                    size: 16,
                    color: p.secondary,
                  ),
                  const SizedBox(width: 6),
                  if (branch != null) ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Text(
                        branch,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono(context, size: 13, color: p.ink, weight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    _worktree == null ? l.checkoutWorkspace : l.checkoutWorktree,
                    style: TextStyle(fontSize: 13, color: p.secondary),
                  ),
                  const SizedBox(width: 2),
                  Icon(AppIcons.keyboardArrowDown, size: 18, color: p.secondary),
                ],
              ),
            ),
          ),
        ),
        if (_worktree != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              _worktree!.title ?? l.untitled,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: p.secondary),
            ),
          ),
        if (root != null && root.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 12, 6, 8),
            child: Text(
              root,
              style: mono(context, size: 13, color: p.ink, weight: FontWeight.w500),
            ),
          )
        else
          const SizedBox(height: 12),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: navTitleAlign,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.workspaceTitle, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            Text(
              [a.label, a.daemonName].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
              style: mono(context, size: 12),
            ),
          ],
        ),
      ),
      body: FolderList(
        key: ValueKey(_worktree?.sessionId ?? '-'),
        ws: ws,
        path: '',
        changes: Changes.of(_git),
        header: header,
        missingText: _worktree != null
            ? (a.workspace != null ? l.worktreeAbsentOf(a.workspace!.label) : l.worktreeAbsent)
            : (a.workspace != null ? l.repoNotCheckedOut : l.workspaceNotCreated),
        footer: Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text(l.workspaceReadOnly, style: TextStyle(fontSize: 13, color: p.secondary)),
        ),
      ),
    );
  }
}

class _Pick {
  const _Pick(this.worktree, {this.open = false});
  final SessionRow? worktree;

  /// Open the worktree's conversation instead of browsing it.
  final bool open;
}

/// "Workspace checkout": the agent's checkout, then each session worktree
/// with a link to its conversation.
class _CheckoutSheet extends StatelessWidget {
  const _CheckoutSheet({
    required this.agent,
    required this.primaryBranch,
    required this.worktrees,
    required this.selected,
  });
  final Agent agent;
  final String? primaryBranch;
  final WorktreeList worktrees;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final repo = agent.workspace?.label;
    Widget row({
      required IconData icon,
      required String title,
      required bool monoTitle,
      required String subtitle,
      required bool on,
      required VoidCallback onTap,
      Widget? trailing,
    }) => InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: p.secondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoTitle
                        ? mono(context, size: 14, color: p.ink, weight: FontWeight.w600)
                        : TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: p.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: p.secondary),
                  ),
                ],
              ),
            ),
            ?trailing,
            if (on)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(AppIcons.check, size: 18, color: p.accent),
              ),
          ],
        ),
      ),
    );

    return ListenableBuilder(
      listenable: worktrees,
      builder: (context, _) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.paddingOf(context).bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(l.workspaceCheckout, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
              GroupCard(
                children: [
                  row(
                    icon: AppIcons.forkRight,
                    title: primaryBranch ?? agent.workspace?.branch ?? l.checkoutWorkspace,
                    monoTitle: primaryBranch != null || agent.workspace?.branch != null,
                    subtitle: [l.agentWorkspace, ?repo].join(' · '),
                    on: selected == null,
                    onTap: () => Navigator.pop(context, const _Pick(null)),
                  ),
                  for (final w in worktrees.worktrees)
                    row(
                      icon: AppIcons.accountTreeOutlined,
                      title: w.title?.trim().isNotEmpty == true ? w.title!.trim() : l.untitled,
                      monoTitle: false,
                      subtitle: [
                        l.checkoutWorktreeLabel,
                        if (w.lastActivityAt != null) agoText(l, w.lastActivityAt!),
                      ].join(' · '),
                      on: selected == w.sessionId,
                      onTap: () => Navigator.pop(context, _Pick(w)),
                      trailing: TextButton(
                        style: TextButton.styleFrom(foregroundColor: p.brandText, visualDensity: VisualDensity.compact),
                        onPressed: () => Navigator.pop(context, _Pick(w, open: true)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(l.openSessionShort, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            const SizedBox(width: 2),
                            Icon(AppIcons.northEast, size: 13),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              if (worktrees.hasMore)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Center(
                    child: worktrees.loading
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(width: 18, height: 18, child: Spinner(strokeWidth: 2)),
                          )
                        : TextButton(onPressed: worktrees.more, child: Text(l.loadMore)),
                  ),
                )
              else if (worktrees.worktrees.isEmpty && agent.workspace?.worktrees == true)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                  child: Text(l.noWorktrees, style: TextStyle(fontSize: 13, color: p.secondary)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
