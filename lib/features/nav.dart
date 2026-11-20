import 'package:flutter/material.dart';

import '../core/api/models.dart';
import '../core/auth/app_state.dart';
import 'agents/agent_detail_screen.dart';
import 'approvals/approvals_screen.dart';
import 'chat/new_chat_screen.dart';
import 'desktop/desktop_nav.dart';
import 'desktop/desktop_pane.dart';
import 'sessions/session_screen.dart';
import 'settings/settings_screen.dart';

/// Pushes [page] with the app state above it (routes are siblings of the shell).
Future<T?> push<T>(BuildContext context, Widget page) {
  final app = AppScope.read(context);
  // The Mac: a page pushed from a dialog (a file from the workspace) would go
  // on the window's own navigator and cover everything, sidebar included. It
  // opens as a panel over the dialog instead.
  if (desktopNav != null && Navigator.of(context) == Navigator.of(context, rootNavigator: true)) {
    return showDesktopPanel<T>(context, page: AppScope(state: app, child: page), wide: true);
  }
  return Navigator.of(context).push<T>(
      MaterialPageRoute(builder: (_) => AppScope(state: app, child: page)));
}

/// On the Mac the conversation shows beside the Sessions list; a phone pushes it.
void openConversation(BuildContext context, Conversation c) {
  final desktop = desktopNav;
  if (desktop != null) return desktop.showConversation(c);
  push(context, SessionScreen(conversation: c));
}

void openSession(BuildContext context, SessionRow s) => openConversation(
    context, Conversation(key: s.sessionId, platform: s.platform, sessions: [s]));

void openAgent(BuildContext context, Agent a) {
  final desktop = desktopNav;
  if (desktop != null) return desktop.showAgent(a);
  push(context, AgentDetailScreen(agent: a));
}

void openNewChat(BuildContext context, Agent a, {String? firstMessage}) {
  final desktop = desktopNav;
  if (desktop != null) return desktop.showNewChat(a, firstMessage: firstMessage);
  push(context, NewChatScreen(agent: a, firstMessage: firstMessage));
}

void openApprovals(BuildContext context) => push(context, const ApprovalsScreen());

/// On the Mac, Settings is a panel over the window (⌘,); a phone pushes it.
void openSettings(BuildContext context) {
  if (desktopNav != null) {
    showDesktopPanel(context, id: 'settings', page: const SettingsScreen());
    return;
  }
  push(context, const SettingsScreen());
}
