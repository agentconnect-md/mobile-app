import 'api/api_client.dart';
import 'api/models.dart';

/// Daemon feature for the `auto` session mode, which a coordinator needs
/// (packages/web/src/lib/session-mode.ts SESSION_MODE_AUTO_FEATURE).
const sessionModeAutoFeature = 'session-mode-auto-v1';

/// The daemon whose capabilities apply to [agent]: its own daemon, else an
/// online member of its set (or of the cloud pool), as the web console's
/// `agentCapabilitySource` picks it.
Machine? capabilitySource(Agent agent, List<Machine> machines) {
  final kind = agent.placementKind;
  final onSet = kind == 'set' || kind == 'pool';
  if (!onSet) {
    for (final m in machines) {
      if (m.id == agent.daemonId) return m;
    }
    return null;
  }
  final setId = agent.setId;
  final inSet = setId != null && machines.any((m) => m.memberSetId == setId);
  final members = machines.where((m) => inSet ? m.memberSetId == setId : m.cloud).toList();
  for (final m in members) {
    if (m.state == AgentHealth.online) return m;
  }
  return members.isEmpty ? null : members.first;
}

/// Whether opening [agent] enters the member's coordinator conversation: its
/// coordinator is on and its daemon reads Auto (the app always speaks the
/// legacy webchat protocol). Same rule as the web console's `opensCoordinator`.
bool opensCoordinator(Agent agent, List<Machine>? machines) {
  if (agent.coordinatorDisabled || machines == null) return false;
  return capabilitySource(agent, machines)?.features.contains(sessionModeAutoFeature) ?? false;
}

/// Where "chat with this agent" lands.
sealed class ChatTarget {
  const ChatTarget();
}

/// The member's coordinator conversation already has a session: open it.
class CoordinatorSession extends ChatTarget {
  const CoordinatorSession(this.sessionId, this.conversationId);
  final String sessionId;
  final String conversationId;
}

/// The coordinator conversation exists but has no session yet: chat in it.
class CoordinatorConversation extends ChatTarget {
  const CoordinatorConversation(this.conversationId);
  final String conversationId;
}

/// A fresh playground chat (no coordinator, or the coordinator was refused).
class PlainChat extends ChatTarget {
  const PlainChat();
}

/// Resolves where chatting with [agent] starts, as the web console's
/// `openAgentPlayground` does: the coordinator conversation when the agent
/// opens one (its session if it has one), else a plain chat. A refused or
/// failed coordinator mint falls back to a plain chat, like the console.
Future<ChatTarget> resolveChatTarget(ApiClient client, String org, Agent agent, List<Machine>? machines) async {
  if (!opensCoordinator(agent, machines)) return const PlainChat();
  try {
    final c = await client.coordinatorConversation(org, agent.id);
    final session = c.sessionId;
    return session != null ? CoordinatorSession(session, c.conversationId) : CoordinatorConversation(c.conversationId);
  } on ApiException catch (e) {
    // A 401 ends the sign-in; let the app show that instead of a chat.
    if (e.status == 401) rethrow;
    return const PlainChat();
  } on BadResponseException {
    return const PlainChat();
  } on NetworkException {
    return const PlainChat();
  }
}
