import 'package:flutter/material.dart';

import '../core/api/models.dart';
import '../core/auth/app_state.dart';
import 'agents/agent_detail_screen.dart';
import 'approvals/approvals_screen.dart';
import 'chat/new_chat_screen.dart';
import 'sessions/session_screen.dart';
import 'settings/settings_screen.dart';

/// Pushes [page] with the app state above it (routes are siblings of the shell).
Future<T?> push<T>(BuildContext context, Widget page) {
  final app = AppScope.read(context);
  return Navigator.of(context).push<T>(
      MaterialPageRoute(builder: (_) => AppScope(state: app, child: page)));
}

void openConversation(BuildContext context, Conversation c) =>
    push(context, SessionScreen(conversation: c));

void openSession(BuildContext context, SessionRow s) => openConversation(
    context, Conversation(key: s.sessionId, platform: s.platform, sessions: [s]));

void openAgent(BuildContext context, Agent a) => push(context, AgentDetailScreen(agent: a));

void openNewChat(BuildContext context, Agent a, {String? firstMessage}) =>
    push(context, NewChatScreen(agent: a, firstMessage: firstMessage));

void openApprovals(BuildContext context) => push(context, const ApprovalsScreen());

void openSettings(BuildContext context) => push(context, const SettingsScreen());
