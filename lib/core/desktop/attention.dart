import '../api/approvals.dart';
import '../api/models.dart';
import '../approvals_controller.dart';
import '../org_data.dart';

/// What the Mac's menu bar item and notifications watch of one organization
/// at one moment. A list is null until it was read for the first time, so
/// "not loaded yet" is never mistaken for "nothing there".
///
/// Plain data, compared by [AttentionWatcher] and drawn by the menu bar
/// snapshot: no I/O here, so both are unit tested.
class AttentionState {
  const AttentionState({this.conversations, this.approvals, this.agents});
  final List<WatchedConversation>? conversations;
  final List<WatchedApproval>? approvals;
  final List<WatchedAgent>? agents;

  /// The current state of the shared org lists.
  factory AttentionState.of(OrgData? org, ApprovalsController? approvals) {
    final recent = org?.recent;
    final agents = org?.agents;
    final working = <String>{
      for (final c in recent ?? const <Conversation>[])
        for (final s in c.sessions)
          if (s.state == ActivityState.working) s.agentId,
    };
    return AttentionState(
      conversations: recent == null
          ? null
          : [
              for (final c in recent)
                WatchedConversation(
                  sessionId: c.primary.sessionId,
                  sessionIds: {for (final s in c.sessions) s.sessionId},
                  title: c.title,
                  agentName: c.primary.agentName,
                  state: c.state,
                ),
            ],
      // Before the first answer the controller's list is empty, not known.
      approvals: approvals == null || (approvals.loading && approvals.approvals.isEmpty)
          ? null
          : [
              for (final Approval a in approvals.pending)
                WatchedApproval(
                  id: a.id,
                  sessionId: a.sessionId,
                  agentName: a.agentName.isNotEmpty ? a.agentName : a.requester,
                  title: a.conversationTitle,
                ),
            ],
      agents: agents == null
          ? null
          : [
              for (final a in agents)
                WatchedAgent(
                    id: a.id,
                    name: a.label,
                    health: a.health,
                    working: working.contains(a.id),
                    lastActive: org?.lastSessionAt[a.id]),
            ],
    );
  }
}

class WatchedConversation {
  const WatchedConversation({
    required this.sessionId,
    required this.sessionIds,
    required this.state,
    this.title,
    this.agentName = '',
  });

  /// The conversation's main session: what opens it.
  final String sessionId;

  /// Every session in it (one per agent).
  final Set<String> sessionIds;
  final String? title;
  final String agentName;
  final ActivityState state;
}

class WatchedApproval {
  const WatchedApproval({required this.id, required this.sessionId, this.agentName = '', this.title});
  final String id;
  final String sessionId;
  final String agentName;

  /// The conversation's title. Never the request itself: what an agent asks
  /// to run stays out of the menu bar and out of notifications.
  final String? title;
}

class WatchedAgent {
  const WatchedAgent(
      {required this.id, required this.name, required this.health, this.working = false, this.lastActive});
  final String id;
  final String name;
  final AgentHealth health;

  /// One of its recent conversations is running.
  final bool working;

  /// Its newest session activity, when known: the menu lists the agents in use first.
  final DateTime? lastActive;
}

enum NoticeKind {
  /// A conversation started waiting for the person (a question, a form…).
  waiting,

  /// An approval request arrived.
  approval,

  /// A running conversation finished.
  finished,

  /// An agent went offline.
  agentOffline,
}

/// One thing worth a notification.
class Notice {
  const Notice({required this.kind, required this.agentName, this.title, this.sessionId, this.agentId});
  final NoticeKind kind;
  final String agentName;

  /// The conversation's title, for the conversation kinds.
  final String? title;

  /// The conversation to open (its main session), for the conversation kinds.
  final String? sessionId;

  /// The agent to open, for [NoticeKind.agentOffline].
  final String? agentId;

  /// One notification per conversation or agent: a later one about the same
  /// conversation replaces the earlier one.
  String get id => sessionId != null ? 'conv:$sessionId' : 'agent:$agentId';

  @override
  String toString() => 'Notice(${kind.name}, $agentName, ${sessionId ?? agentId})';
}

/// Compares successive [AttentionState]s and says what changed that the
/// person should hear about:
///
///  * a conversation starts waiting for them,
///  * an approval request arrives,
///  * a running conversation finishes,
///  * an agent goes offline.
///
/// Nothing for what is already there when watching starts (each list's first
/// reading is only remembered), nothing twice for the same event, and nothing
/// for a conversation in [advance]'s `reading` set (the one open in front).
///
/// A waiting conversation and its approval request are one event seen
/// through two lists that refresh separately. So "waiting" is held back for
/// [hold]: if the conversation's approval request shows up meanwhile, only
/// that is announced.
class AttentionWatcher {
  AttentionWatcher({this.hold = const Duration(seconds: 3)});
  final Duration hold;

  Map<String, ActivityState>? _states;
  Set<String>? _approvals;
  Map<String, AgentHealth>? _health;

  /// Approval requests already announced (or there from the start), so one
  /// that drops out of a refresh and comes back is not announced again.
  final Set<String> _knownApprovals = {};

  /// Conversations that started waiting, with when, until [hold] has passed.
  final Map<String, DateTime> _held = {};

  /// When a held "waiting" is next due, for the caller's timer; null when none is held.
  DateTime? get nextDue {
    DateTime? first;
    for (final t in _held.values) {
      if (first == null || t.isBefore(first)) first = t;
    }
    return first?.add(hold);
  }

  /// Forgets everything: the next state is a fresh start (another organization).
  void reset() {
    _states = null;
    _approvals = null;
    _health = null;
    _knownApprovals.clear();
    _held.clear();
  }

  /// Moves to [next] and returns what to announce. [reading] holds the
  /// session ids of the conversation the person has open in front.
  List<Notice> advance(AttentionState next, {required DateTime now, Set<String> reading = const {}}) {
    final out = <Notice>[];
    final conversations = next.conversations;
    final approvals = next.approvals;
    bool beingRead(Set<String> ids) => ids.any(reading.contains);
    WatchedConversation? conversationOf(String sessionId) {
      for (final c in conversations ?? const <WatchedConversation>[]) {
        if (c.sessionIds.contains(sessionId)) return c;
      }
      return null;
    }

    // Approval requests.
    final announcedNow = <String>{};
    if (approvals != null) {
      final ids = {for (final a in approvals) a.id};
      if (_approvals != null) {
        for (final a in approvals) {
          if (!_knownApprovals.add(a.id)) continue;
          final c = conversationOf(a.sessionId);
          final key = c?.sessionId ?? a.sessionId;
          _held.remove(key);
          if (beingRead(c?.sessionIds ?? {a.sessionId}) || !announcedNow.add(key)) continue;
          out.add(Notice(
            kind: NoticeKind.approval,
            agentName: a.agentName.isNotEmpty ? a.agentName : (c?.agentName ?? ''),
            title: a.title ?? c?.title,
            sessionId: key,
          ));
        }
      } else {
        _knownApprovals.addAll(ids);
      }
      _approvals = ids;
    }
    bool hasApproval(WatchedConversation c) =>
        (approvals ?? const <WatchedApproval>[]).any((a) => c.sessionIds.contains(a.sessionId));

    // Conversations.
    if (conversations != null) {
      final before = _states;
      final states = {for (final c in conversations) c.sessionId: c.state};
      if (before != null) {
        for (final c in conversations) {
          final was = before[c.sessionId];
          if (c.state == ActivityState.awaiting && was != ActivityState.awaiting) {
            _held[c.sessionId] = now;
          } else if (c.state == ActivityState.idle && was == ActivityState.working && !beingRead(c.sessionIds)) {
            out.add(Notice(
                kind: NoticeKind.finished, agentName: c.agentName, title: c.title, sessionId: c.sessionId));
          }
        }
      }
      // A held "waiting" is announced once its time is up, unless the
      // conversation moved on or its approval request covers it.
      for (final key in _held.keys.toList()) {
        final c = conversations.where((c) => c.sessionId == key).firstOrNull;
        if (c == null || c.state != ActivityState.awaiting || hasApproval(c)) {
          _held.remove(key);
        } else if (!now.isBefore(_held[key]!.add(hold))) {
          _held.remove(key);
          if (!beingRead(c.sessionIds)) {
            out.add(Notice(
                kind: NoticeKind.waiting, agentName: c.agentName, title: c.title, sessionId: c.sessionId));
          }
        }
      }
      _states = states;
    }

    // Agents.
    final agents = next.agents;
    if (agents != null) {
      final before = _health;
      if (before != null) {
        for (final a in agents) {
          if (a.health == AgentHealth.offline && before[a.id] == AgentHealth.online) {
            out.add(Notice(kind: NoticeKind.agentOffline, agentName: a.name, agentId: a.id));
          }
        }
      }
      _health = {for (final a in agents) a.id: a.health};
    }
    return out;
  }
}

/// The words of the menu bar item, from the app's localized strings.
class MenuBarText {
  const MenuBarText({
    required this.appName,
    required this.signedOut,
    required this.allQuiet,
    required this.needYou,
    required this.running,
    required this.needsTitle,
    required this.needsEmpty,
    required this.needsMore,
    required this.approvalRow,
    required this.waitingRow,
    required this.untitled,
    required this.agentsTitle,
    required this.agentsEmpty,
    required this.agentsMore,
    required this.online,
    required this.paused,
    required this.offline,
    required this.working,
    required this.open,
    required this.quit,
  });
  final String appName, signedOut, allQuiet;
  final String Function(int count) needYou, running, needsMore, agentsMore;
  final String needsTitle, needsEmpty;

  /// "{agent} needs approval" / "{agent} is waiting".
  final String Function(String agent) approvalRow, waitingRow;
  final String untitled;
  final String agentsTitle, agentsEmpty;
  final String online, paused, offline, working;
  final String open, quit;
}

/// Most rows a section of the menu shows before "N more…".
const menuBarRows = 6;

/// What the native menu bar item draws (`statusItem` on the method channel).
/// [state] null: nobody is signed in.
///
/// `state` is `waiting` (something needs the person; `count` says how many),
/// `running` or `idle`; the native side gives each its own icon shape, so the
/// state never rests on color alone.
Map<String, Object?> menuBarSnapshot(AttentionState? state, {String? org, required MenuBarText text}) {
  if (state == null) {
    return {
      'signedIn': false,
      'state': 'idle',
      'count': 0,
      'org': text.appName,
      'summary': text.signedOut,
      'tooltip': '${text.appName}: ${text.signedOut}',
      'open': text.open,
      'quit': text.quit,
    };
  }
  final conversations = state.conversations ?? const <WatchedConversation>[];
  final approvals = state.approvals ?? const <WatchedApproval>[];
  String titleOf(String? t) => t == null || t.trim().isEmpty ? text.untitled : t.trim();

  // Needs you: approval requests first (one row per conversation), then
  // conversations that wait for something else.
  final needs = <Map<String, Object?>>[];
  final covered = <String>{};
  for (final a in approvals) {
    final c = conversations.where((c) => c.sessionIds.contains(a.sessionId)).firstOrNull;
    final key = c?.sessionId ?? a.sessionId;
    if (!covered.add(key)) continue;
    final agent = a.agentName.isNotEmpty ? a.agentName : (c?.agentName ?? '');
    needs.add({
      'kind': 'conversation',
      'id': key,
      'approval': true,
      'title': titleOf(a.title ?? c?.title),
      'subtitle': text.approvalRow(agent),
    });
  }
  for (final c in conversations) {
    if (c.state != ActivityState.awaiting || !covered.add(c.sessionId)) continue;
    needs.add({
      'kind': 'conversation',
      'id': c.sessionId,
      'approval': false,
      'title': titleOf(c.title),
      'subtitle': text.waitingRow(c.agentName),
    });
  }
  final count = needs.length;
  final running = conversations.where((c) => c.state == ActivityState.working).length;

  // Agents: the ones working first, then online, paused, offline; within
  // each, the most recently used first (an organization can have dozens).
  final agents = [...state.agents ?? const <WatchedAgent>[]];
  int rank(WatchedAgent a) => a.working ? -1 : a.health.index;
  agents.sort((x, y) {
    var c = rank(x).compareTo(rank(y));
    if (c != 0) return c;
    final a = x.lastActive, b = y.lastActive;
    c = a == null ? (b == null ? 0 : 1) : (b == null ? -1 : b.compareTo(a));
    return c != 0 ? c : x.name.toLowerCase().compareTo(y.name.toLowerCase());
  });
  String status(WatchedAgent a) {
    final health = switch (a.health) {
      AgentHealth.online => text.online,
      AgentHealth.paused => text.paused,
      AgentHealth.offline => text.offline,
    };
    return a.working ? '$health · ${text.working}' : health;
  }

  final summary = [
    if (count > 0) text.needYou(count),
    if (running > 0) text.running(running),
  ].join(' · ');
  return {
    'signedIn': true,
    'state': count > 0 ? 'waiting' : (running > 0 ? 'running' : 'idle'),
    'count': count,
    'org': org ?? text.appName,
    'summary': summary.isEmpty ? text.allQuiet : summary,
    'tooltip': '${text.appName}: ${summary.isEmpty ? text.allQuiet : summary}',
    'needsTitle': text.needsTitle,
    'needsEmpty': text.needsEmpty,
    'needs': [
      ...needs.take(menuBarRows),
      if (count > menuBarRows)
        {'kind': 'home', 'id': '', 'approval': false, 'title': text.needsMore(count - menuBarRows), 'subtitle': ''},
    ],
    'agentsTitle': text.agentsTitle,
    'agentsEmpty': text.agentsEmpty,
    'agents': [
      for (final a in agents.take(menuBarRows))
        {'kind': 'agent', 'id': a.id, 'title': a.name, 'subtitle': status(a), 'health': a.health.name},
    ],
    'agentsMore': agents.length > menuBarRows ? text.agentsMore(agents.length - menuBarRows) : '',
    'open': text.open,
    'quit': text.quit,
  };
}
