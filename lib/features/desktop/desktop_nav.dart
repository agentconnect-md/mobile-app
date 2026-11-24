import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../core/share_links.dart';
import '../../ui/platform.dart';
import '../agents/agent_detail_screen.dart';
import '../chat/new_chat_screen.dart';
import '../sessions/open_link.dart';
import '../sessions/session_screen.dart';
import 'session_panel.dart';

/// What the detail side of a split shows: one page, with a navigator of its
/// own for what that page pushes (a thread, a file).
class DetailPage {
  DetailPage(this.page, {this.sessionIds = const {}, this.agentId});
  final Widget page;

  /// The sessions of the conversation shown, to mark its row in the list.
  final Set<String> sessionIds;

  /// The agent shown, to mark its row in the list.
  final String? agentId;
  final navKey = GlobalKey<NavigatorState>();
}

/// Where the Mac shell is: the sidebar destination and what each detail side
/// shows. The phone pushes a screen over the list; here the same calls
/// (`openConversation`, `openAgent`, `openNewChat` in nav.dart) put an agent
/// beside the Agents list, and a conversation in place of the Sessions list,
/// which moves into the side panel beside it (as the web console does).
class DesktopNav extends ChangeNotifier {
  /// The shell on screen, when there is one (the Mac, signed in).
  static DesktopNav? current;

  /// The shell's own context: for dialogs opened from the menu bar.
  BuildContext? context;

  static const home = 0, agents = 1, sessions = 2, infra = 3;

  int get tab => _tab;
  int _tab = home;

  DetailPage? get sessionsDetail => _sessionsDetail;
  DetailPage? _sessionsDetail;
  DetailPage? get agentsDetail => _agentsDetail;
  DetailPage? _agentsDetail;

  /// One navigator per destination (for a split: its list side).
  List<GlobalKey<NavigatorState>> get rootKeys => _rootKeys;
  List<GlobalKey<NavigatorState>> _rootKeys = _keys();
  static List<GlobalKey<NavigatorState>> _keys() => List.generate(4, (_) => GlobalKey<NavigatorState>());

  /// The side panel beside a conversation (Sessions).
  final panel = SessionPanel();

  /// Shows a destination. Choosing the one already shown goes back to its
  /// first screen, as clicking a sidebar item does on the Mac; for Sessions
  /// with a conversation open, back to the whole list.
  void go(int i) {
    if (i < 0 || i > 3) return;
    if (i == _tab) {
      if (i == sessions && _sessionsDetail != null) return closeConversation();
      _rootKeys[i].currentState?.popUntil((r) => r.isFirst);
      return;
    }
    _tab = i;
    notifyListeners();
  }

  void showConversation(Conversation c,
          {int? focusSeq, String? fillRequestId, String? threadRoot, String? firstMessage}) =>
      _showSession(
        SessionScreen(
            conversation: c,
            focusSeq: focusSeq,
            fillRequestId: fillRequestId,
            threadRoot: threadRoot,
            firstMessage: firstMessage),
        sessionIds: {for (final s in c.sessions) s.sessionId},
      );

  void showNewChat(Agent a, {String? firstMessage, String? conversationId}) =>
      _showSession(NewChatScreen(agent: a, firstMessage: firstMessage, conversationId: conversationId));

  /// A console session link: loads the session, then shows it.
  void showLink(ConsoleLink link) => _showSession(linkedSession(link), sessionIds: {link.sessionId});

  void _showSession(Widget page, {Set<String> sessionIds = const {}}) {
    final d = _sessionsDetail = DetailPage(page, sessionIds: sessionIds);
    panel.attach(d.navKey);
    _tab = sessions;
    notifyListeners();
  }

  /// Sessions as the whole list again, no conversation beside it.
  void closeConversation() {
    if (_sessionsDetail == null) return;
    _sessionsDetail = null;
    panel.attach(null);
    notifyListeners();
  }

  void showAgent(Agent a) {
    _agentsDetail = DetailPage(AgentDetailScreen(agent: a), agentId: a.id);
    _tab = agents;
    notifyListeners();
  }

  bool showsConversation(Conversation c) {
    final ids = _sessionsDetail?.sessionIds;
    return ids != null && c.sessions.any((s) => ids.contains(s.sessionId));
  }

  bool showsAgent(Agent a) => _agentsDetail?.agentId == a.id;

  /// The sessions being read: the conversation shown, while Sessions is the
  /// destination on screen.
  Set<String> get reading => _tab == sessions ? (_sessionsDetail?.sessionIds ?? const {}) : const {};

  /// Back (⌘[): pops what the shown destination last pushed (for a
  /// conversation: its column, then the side panel's tab), then from a
  /// conversation back to the whole list.
  void back() {
    final detail = switch (_tab) { agents => _agentsDetail, sessions => _sessionsDetail, _ => null };
    final nav = detail?.navKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return;
    }
    if (_tab == sessions && _sessionsDetail != null) {
      if (!(panel.shown && panel.back())) closeConversation();
      return;
    }
    _rootKeys[_tab].currentState?.maybePop();
  }

  /// Another organization: start over.
  void reset() {
    _rootKeys = _keys();
    _sessionsDetail = null;
    _agentsDetail = null;
    panel.attach(null);
    notifyListeners();
  }

  @override
  void dispose() {
    panel.dispose();
    super.dispose();
  }
}

/// The shell to route through on the Mac; null on phones (and while signed out).
DesktopNav? get desktopNav => isMacOS ? DesktopNav.current : null;
