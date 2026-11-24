import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/api/models.dart';
import '../../core/api/workspace.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../files/workspace_tree.dart';
import '../sessions/workspace_sheet.dart';

/// The tabs of the side panel, in the web console's order.
enum PanelTab { sessions, files, git, tasks }

/// What the conversation on screen gives the side panel: its workspace and
/// the tasks it started. Null for a new chat (the panel then has Sessions only).
class PanelWorkspace {
  const PanelWorkspace({
    required this.ref,
    required this.tasks,
    this.threads = const [],
    this.onOpenThread,
    this.opensOn,
  });

  /// The tab this conversation opens on, when not Sessions.
  final PanelTab? opensOn;
  final WorkspaceRef ref;
  final List<AgentTask> tasks;

  /// The conversation's threads, listed under Tasks (opened with [onOpenThread]).
  final List<ThreadSummary> threads;
  final void Function(String rootId)? onOpenThread;
}

/// The Mac's side panel beside a conversation, as the web console's session
/// page has it: the conversation on the left, on the right the session list,
/// the workspace's files and git, and its tasks; a thread or a task opens in
/// the panel, a file in the conversation's column. One for the shell: whether
/// it is open and how wide it is stay from one conversation to the next; the
/// tab and what the tabs pushed start over with each conversation ([attach]).
class SessionPanel extends ChangeNotifier {
  static const minWidth = 300.0, maxWidth = 560.0, defaultWidth = 380.0;

  /// The narrowest conversation the panel leaves beside it. A narrower
  /// window lays the panel over the conversation instead.
  static const chatFloor = 380.0;

  bool _open = true;
  bool _overOpen = false;
  double _width = defaultWidth;

  /// Whether the panel sits beside the conversation (set by the layout) or,
  /// in a narrow window, over it.
  bool beside = true;

  /// The panel is on screen. Beside the conversation it stays as the person
  /// left it; over the conversation it starts closed with each one.
  bool get shown => beside ? _open : _overOpen;

  double get width => _width;
  set width(double w) {
    final v = w.clamp(minWidth, maxWidth);
    if (v == _width) return;
    _width = v;
    notifyListeners();
  }

  PanelTab get tab => _tab;
  PanelTab _tab = PanelTab.sessions;

  /// Tabs shown so far for this conversation: the others aren't built (and
  /// don't read the workspace) until chosen.
  final Set<PanelTab> visited = {PanelTab.sessions};

  PanelWorkspace? get workspace => _workspace;
  PanelWorkspace? _workspace;

  /// What the panel shows tabs for.
  List<PanelTab> get tabs {
    final w = _workspace;
    if (w == null) return const [PanelTab.sessions];
    // A coordinator too (unlike the console): it runs commands in its own
    // workspace, and an expanded thread of it is that session's.
    return PanelTab.values;
  }

  /// The Tasks tab's navigator: a thread or a task opens on it.
  GlobalKey<NavigatorState> get tasksKey => _tasksKey;
  GlobalKey<NavigatorState> _tasksKey = GlobalKey<NavigatorState>();

  /// The conversation's column, where a file from the panel opens.
  GlobalKey<NavigatorState>? main;

  /// Another conversation (or none): the panel goes back to its list.
  void attach(GlobalKey<NavigatorState>? mainKey) {
    main = mainKey;
    _tab = PanelTab.sessions;
    visited
      ..clear()
      ..add(PanelTab.sessions);
    _workspace = null;
    _overOpen = false;
    _opened = false;
    _picked = false;
    _gitChanges = 0;
    _tasksKey = GlobalKey<NavigatorState>();
    notifyListeners();
  }

  /// The conversation's workspace and tasks, from its screen (also while it
  /// is building, so the change is shown after the frame).
  void publish(PanelWorkspace? w) {
    _workspace = w;
    // The conversation's own first tab, once, unless the person already picked one.
    final first = w?.opensOn;
    if (first != null && !_opened && !_picked) {
      _opened = true;
      _tab = first;
      visited.add(first);
    }
    if (!tabs.contains(_tab)) _tab = PanelTab.sessions;
    _notifySoon();
  }

  /// The conversation's first tab was applied; the person picked a tab.
  bool _opened = false, _picked = false;

  /// Changed files in the workspace's git status, for the Git tab's count.
  int get gitChanges => _gitChanges;
  int _gitChanges = 0;
  void reportGit(int changes) {
    if (changes == _gitChanges) return;
    _gitChanges = changes;
    _notifySoon();
  }

  void select(PanelTab t) {
    _picked = true;
    if (t == _tab) return;
    _tab = t;
    visited.add(t);
    notifyListeners();
  }

  void toggle() {
    if (beside) {
      _open = !_open;
    } else {
      _overOpen = !_overOpen;
    }
    notifyListeners();
  }

  void _show() {
    if (beside) {
      _open = true;
    } else {
      _overOpen = true;
    }
  }

  /// A thread or a task, in the Tasks tab on top of the task list.
  void showThread(Widget page, AppState app) {
    _tab = PanelTab.tasks;
    visited.add(PanelTab.tasks);
    _show();
    notifyListeners();
    // The tab's navigator exists once the frame that shows it is built.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final nav = _tasksKey.currentState;
      if (nav == null) return;
      nav.popUntil((r) => r.isFirst);
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => AppScope(state: app, child: page),
        ),
      );
    });
  }

  /// A file from the panel: in the conversation's column, as the console's viewer.
  bool showBeside(Widget page, AppState app) {
    final nav = main?.currentState;
    if (nav == null) return false;
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => AppScope(state: app, child: page),
      ),
    );
    return true;
  }

  /// Back (⌘[) in the panel: pops what its tab pushed. False when there was nothing.
  bool back() {
    final nav = _tab == PanelTab.tasks ? _tasksKey.currentState : null;
    if (nav == null || !nav.canPop()) return false;
    nav.pop();
    return true;
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool _soon = false;
  void _notifySoon() {
    if (_soon) return;
    _soon = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _soon = false;
      if (!_disposed) notifyListeners();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }
}

/// Puts the side panel within reach of the conversation and of the panel's
/// own pages. [inPanel]: the page is in the panel (a file then opens beside it).
class SessionPanelScope extends InheritedWidget {
  const SessionPanelScope({super.key, required this.panel, this.inPanel = false, required super.child});
  final SessionPanel panel;
  final bool inPanel;

  static SessionPanelScope? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SessionPanelScope>();

  /// The panel beside the conversation [context] is in; null on phones and
  /// outside the Mac's Sessions destination.
  static SessionPanel? maybeOf(BuildContext context) => _of(context)?.panel;

  /// [context] is a page in the panel itself.
  static bool isInPanel(BuildContext context) => _of(context)?.inPanel ?? false;

  @override
  bool updateShouldNotify(SessionPanelScope old) => old.panel != panel || old.inPanel != inPanel;
}

/// The panel: a strip of tabs and the chosen tab. [sessions] is the shell's
/// session list, kept alive as the panel's first tab.
class SessionSidePanel extends StatelessWidget {
  const SessionSidePanel({super.key, required this.panel, required this.sessions});
  final SessionPanel panel;
  final Widget sessions;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final w = panel.workspace;
    final tabs = panel.tabs;
    final running =
        (w?.tasks.where((t) => t.running).length ?? 0) +
        (w?.threads.where((t) => t.running || (t.task?.running ?? false)).length ?? 0);
    Widget body(PanelTab t) {
      if (t == PanelTab.sessions) return sessions;
      if (w == null || !panel.visited.contains(t)) return const SizedBox.shrink();
      return switch (t) {
        // The web console's tree; a file opens beside the panel.
        PanelTab.files => Scaffold(body: FilesPanel(ws: w.ref)),
        PanelTab.git => Scaffold(
          body: WorkspaceGit(ws: w.ref, onStatus: (g) => panel.reportGit(g.files.length)),
        ),
        // The list follows the tasks the conversation publishes.
        _ => _TabNavigator(
          navKey: panel.tasksKey,
          page: ListenableBuilder(
            listenable: panel,
            builder: (_, _) {
              final now = panel.workspace ?? w;
              return Scaffold(
                body: WorkspaceTasks(
                  ws: now.ref,
                  tasks: now.tasks,
                  threads: now.threads,
                  onOpenThread: now.onOpenThread,
                ),
              );
            },
          ),
        ),
      };
    }

    return SessionPanelScope(
      panel: panel,
      inPanel: true,
      child: Material(
        color: p.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (tabs.length > 1) ...[
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    const SizedBox(width: 6),
                    for (final t in tabs)
                      _Tab(
                        icon: switch (t) {
                          PanelTab.sessions => AppIcons.forumOutlined,
                          PanelTab.files => AppIcons.accountTreeOutlined,
                          PanelTab.git => AppIcons.commit,
                          PanelTab.tasks => AppIcons.checklist,
                        },
                        label: switch (t) {
                          PanelTab.sessions => l.tabSessions,
                          PanelTab.files => l.tabFiles,
                          PanelTab.git => l.tabGit,
                          PanelTab.tasks => l.tabTasks,
                        },
                        badge: switch (t) {
                          PanelTab.tasks => running,
                          PanelTab.git => panel.gitChanges,
                          _ => 0,
                        },
                        selected: panel.tab == t,
                        onTap: () => panel.select(t),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: p.hairline),
            ],
            Expanded(
              child: IndexedStack(
                index: tabs.indexOf(panel.tab).clamp(0, tabs.length - 1),
                children: [
                  // Another agent's session in the conversation: its own files and tasks.
                  for (final t in tabs) KeyedSubtree(key: ValueKey((t, w?.ref.sessionId)), child: body(t)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tab with a navigator of its own, measured against the panel.
class _TabNavigator extends StatelessWidget {
  const _TabNavigator({required this.navKey, required this.page});
  final GlobalKey<NavigatorState> navKey;
  final Widget page;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => MediaQuery(
      data: MediaQuery.of(context).copyWith(size: box.biggest),
      child: ScaffoldMessenger(
        child: Navigator(
          key: navKey,
          onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => page),
        ),
      ),
    ),
  );
}

/// One tab of the strip: glyph and word, the chosen one in the brand color
/// over a bar (not color alone), running tasks as a count.
class _Tab extends StatelessWidget {
  const _Tab({required this.icon, required this.label, required this.selected, required this.onTap, this.badge = 0});
  final IconData icon;
  final String label;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final color = selected ? p.brandText : p.secondary;
    return Flexible(
      child: Semantics(
        button: true,
        selected: selected,
        label: badge > 0 ? '$label, $badge' : label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: selected ? p.brandText : Colors.transparent, width: 2)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: color,
                    ),
                  ),
                ),
                if (badge > 0) ...[
                  const SizedBox(width: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: p.brandSoft, borderRadius: BorderRadius.circular(999)),
                    child: Text(
                      '$badge',
                      style: mono(context, size: 11, color: p.brandText, weight: FontWeight.w600),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The panel's left edge: drag to resize, arrow keys too.
class PanelResizeEdge extends StatefulWidget {
  const PanelResizeEdge({super.key, required this.panel, required this.maxWidth});
  final SessionPanel panel;

  /// The widest the window allows now (the conversation keeps its floor).
  final double maxWidth;
  @override
  State<PanelResizeEdge> createState() => _PanelResizeEdgeState();
}

class _PanelResizeEdgeState extends State<PanelResizeEdge> {
  bool _hover = false, _drag = false;

  void _set(double w) =>
      widget.panel.width = w.clamp(SessionPanel.minWidth, math.max(SessionPanel.minWidth, widget.maxWidth));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return Semantics(
      label: l.resizeSidePanel,
      child: Focus(
        onKeyEvent: (_, e) {
          if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
          if (e.logicalKey == LogicalKeyboardKey.arrowLeft) _set(widget.panel.width + 16);
          if (e.logicalKey == LogicalKeyboardKey.arrowRight) _set(widget.panel.width - 16);
          return e.logicalKey == LogicalKeyboardKey.arrowLeft || e.logicalKey == LogicalKeyboardKey.arrowRight
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => setState(() => _drag = true),
            onHorizontalDragUpdate: (d) => _set(widget.panel.width - d.delta.dx),
            onHorizontalDragEnd: (_) => setState(() => _drag = false),
            onDoubleTap: () => _set(SessionPanel.defaultWidth),
            child: SizedBox(
              width: 5,
              child: Center(
                child: Container(width: _drag ? 2 : 1, color: _drag ? p.brandText : (_hover ? p.border : p.hairline)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
