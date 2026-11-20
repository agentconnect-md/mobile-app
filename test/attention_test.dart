import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/desktop/attention.dart';
import 'package:agentconnect/core/desktop/presence.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

WatchedConversation conv(String id, ActivityState state, {String agent = 'deploy-bot', String? title}) =>
    WatchedConversation(sessionId: id, sessionIds: {id}, state: state, agentName: agent, title: title ?? 'Chat $id');

WatchedApproval approval(String id, String session, {String agent = 'deploy-bot'}) =>
    WatchedApproval(id: id, sessionId: session, agentName: agent, title: 'Chat $session');

WatchedAgent agent(String id, AgentHealth health, {bool working = false, DateTime? lastActive}) =>
    WatchedAgent(id: id, name: id, health: health, working: working, lastActive: lastActive);

AttentionState state({
  List<WatchedConversation>? conversations = const [],
  List<WatchedApproval>? approvals = const [],
  List<WatchedAgent>? agents = const [],
}) =>
    AttentionState(conversations: conversations, approvals: approvals, agents: agents);

void main() {
  final t0 = DateTime(2026, 11, 20, 9);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));
  const idle = ActivityState.idle, working = ActivityState.working, awaiting = ActivityState.awaiting;

  group('AttentionWatcher', () {
    test('nothing for what is already there when watching starts', () {
      final w = AttentionWatcher();
      final first = state(
        conversations: [conv('s1', awaiting), conv('s2', working)],
        approvals: [approval('a1', 's1')],
        agents: [agent('x', AgentHealth.offline)],
      );
      expect(w.advance(first, now: at(0)), isEmpty);
      // Long after, with nothing changed: still nothing (no held "waiting" either).
      expect(w.advance(first, now: at(60)), isEmpty);
      expect(w.nextDue, isNull);
    });

    test('a list read later is a starting point too, not a change', () {
      final w = AttentionWatcher();
      expect(w.advance(state(conversations: null, approvals: null, agents: null), now: at(0)), isEmpty);
      expect(
          w.advance(state(conversations: [conv('s1', awaiting)], approvals: null, agents: null), now: at(1)),
          isEmpty);
      expect(
          w.advance(
              state(
                conversations: [conv('s1', awaiting)],
                approvals: [approval('a1', 's1')],
                agents: [agent('x', AgentHealth.offline)],
              ),
              now: at(10)),
          isEmpty);
    });

    test('a conversation that starts waiting is announced once, after the hold', () {
      final w = AttentionWatcher(hold: const Duration(seconds: 3));
      w.advance(state(conversations: [conv('s1', working)]), now: at(0));
      final waiting = state(conversations: [conv('s1', awaiting)]);
      expect(w.advance(waiting, now: at(10)), isEmpty);
      expect(w.nextDue, at(13));
      expect(w.advance(waiting, now: at(12)), isEmpty);
      final notices = w.advance(waiting, now: at(13));
      expect(notices, hasLength(1));
      expect(notices.single.kind, NoticeKind.waiting);
      expect(notices.single.sessionId, 's1');
      expect(notices.single.id, 'conv:s1');
      expect(notices.single.agentName, 'deploy-bot');
      // The same state again: not announced twice.
      expect(w.advance(waiting, now: at(20)), isEmpty);
      expect(w.nextDue, isNull);
    });

    test('a new conversation that is already waiting counts as starting to wait', () {
      final w = AttentionWatcher(hold: Duration.zero);
      w.advance(state(), now: at(0));
      final notices = w.advance(state(conversations: [conv('new', awaiting)]), now: at(1));
      expect(notices.single.kind, NoticeKind.waiting);
    });

    test('waiting that ends within the hold is not announced', () {
      final w = AttentionWatcher(hold: const Duration(seconds: 3));
      w.advance(state(conversations: [conv('s1', working)]), now: at(0));
      w.advance(state(conversations: [conv('s1', awaiting)]), now: at(1));
      expect(w.advance(state(conversations: [conv('s1', working)]), now: at(2)), isEmpty);
      expect(w.advance(state(conversations: [conv('s1', working)]), now: at(10)), isEmpty);
    });

    test('an approval request is announced at once, and stands for its waiting conversation', () {
      final w = AttentionWatcher(hold: const Duration(seconds: 3));
      w.advance(state(conversations: [conv('s1', working)]), now: at(0));
      // The conversation list changes first…
      expect(w.advance(state(conversations: [conv('s1', awaiting)]), now: at(1)), isEmpty);
      // …then the approvals list catches up, inside the hold.
      final both = state(conversations: [conv('s1', awaiting)], approvals: [approval('a1', 's1')]);
      final notices = w.advance(both, now: at(2));
      expect(notices.single.kind, NoticeKind.approval);
      expect(notices.single.sessionId, 's1');
      // No "waiting" for the same event afterwards.
      expect(w.advance(both, now: at(30)), isEmpty);
    });

    test('approval first, conversation state second: still one announcement', () {
      final w = AttentionWatcher(hold: const Duration(seconds: 3));
      w.advance(state(conversations: [conv('s1', working)]), now: at(0));
      final first = state(conversations: [conv('s1', working)], approvals: [approval('a1', 's1')]);
      expect(w.advance(first, now: at(1)).single.kind, NoticeKind.approval);
      final second = state(conversations: [conv('s1', awaiting)], approvals: [approval('a1', 's1')]);
      expect(w.advance(second, now: at(2)), isEmpty);
      expect(w.advance(second, now: at(30)), isEmpty);
    });

    test('an approval request that drops out of a refresh and returns is not announced again', () {
      final w = AttentionWatcher();
      w.advance(state(), now: at(0));
      expect(w.advance(state(approvals: [approval('a1', 's1')]), now: at(1)), hasLength(1));
      expect(w.advance(state(approvals: []), now: at(2)), isEmpty);
      expect(w.advance(state(approvals: [approval('a1', 's1')]), now: at(3)), isEmpty);
      // A different request is new.
      expect(w.advance(state(approvals: [approval('a1', 's1'), approval('a2', 's9')]), now: at(4)), hasLength(1));
    });

    test('two requests of one conversation in one refresh are one announcement', () {
      final w = AttentionWatcher();
      w.advance(state(conversations: [conv('s1', working)]), now: at(0));
      final notices = w.advance(
          state(conversations: [conv('s1', awaiting)], approvals: [approval('a1', 's1'), approval('a2', 's1')]),
          now: at(1));
      expect(notices, hasLength(1));
    });

    test('a running conversation that finishes is announced; other ways to idle are not', () {
      final w = AttentionWatcher(hold: Duration.zero);
      w.advance(state(conversations: [conv('run', working), conv('ask', awaiting), conv('quiet', idle)]), now: at(0));
      final notices = w.advance(
          state(conversations: [conv('run', idle), conv('ask', idle), conv('quiet', working)]),
          now: at(5));
      expect(notices.map((n) => (n.kind, n.sessionId)), [(NoticeKind.finished, 'run')]);
      expect(w.advance(state(conversations: [conv('run', idle), conv('ask', idle), conv('quiet', working)]), now: at(6)),
          isEmpty);
    });

    test('an agent going offline is announced, each time it happens', () {
      final w = AttentionWatcher();
      w.advance(state(agents: [agent('a', AgentHealth.online), agent('b', AgentHealth.paused)]), now: at(0));
      final down = w.advance(
          state(agents: [agent('a', AgentHealth.offline), agent('b', AgentHealth.offline)]),
          now: at(1));
      // Only the one that was online: a paused agent was not taking work.
      expect(down.single.kind, NoticeKind.agentOffline);
      expect(down.single.agentId, 'a');
      expect(down.single.id, 'agent:a');
      expect(w.advance(state(agents: [agent('a', AgentHealth.offline)]), now: at(2)), isEmpty);
      expect(w.advance(state(agents: [agent('a', AgentHealth.online)]), now: at(3)), isEmpty);
      expect(w.advance(state(agents: [agent('a', AgentHealth.offline)]), now: at(4)), hasLength(1));
    });

    test('nothing for the conversation being read, then or later', () {
      final w = AttentionWatcher(hold: Duration.zero);
      const reading = {'open'};
      w.advance(state(conversations: [conv('open', working), conv('other', working)]), now: at(0));
      final finished = state(conversations: [conv('open', idle), conv('other', idle)]);
      expect(w.advance(finished, now: at(1), reading: reading).map((n) => n.sessionId), ['other']);
      // No catching up once it is no longer being read.
      expect(w.advance(finished, now: at(2)), isEmpty);

      final asks = state(
        conversations: [conv('open', awaiting), conv('other', awaiting)],
        approvals: [approval('a1', 'open')],
      );
      expect(w.advance(asks, now: at(3), reading: reading).map((n) => (n.kind, n.sessionId)),
          [(NoticeKind.waiting, 'other')]);
      expect(w.advance(asks, now: at(4)), isEmpty);
    });

    test('a conversation is read through any of its sessions', () {
      final w = AttentionWatcher(hold: Duration.zero);
      WatchedConversation multi(ActivityState s) =>
          WatchedConversation(sessionId: 'main', sessionIds: {'main', 'second'}, state: s, agentName: 'a');
      w.advance(state(conversations: [multi(working)]), now: at(0));
      expect(w.advance(state(conversations: [multi(idle)]), now: at(1), reading: {'second'}), isEmpty);
    });

    test('reset starts over (another organization)', () {
      final w = AttentionWatcher(hold: Duration.zero);
      w.advance(state(conversations: [conv('s1', working)]), now: at(0));
      w.reset();
      expect(w.advance(state(conversations: [conv('s1', awaiting)], approvals: [approval('a', 's1')]), now: at(1)),
          isEmpty);
    });
  });

  group('menu bar snapshot', () {
    final l = lookupAppLocalizations(const Locale('en'));
    final text = menuBarText(l);

    test('signed out', () {
      final s = menuBarSnapshot(null, text: text);
      expect(s['signedIn'], isFalse);
      expect(s['state'], 'idle');
      expect(s['summary'], 'Not signed in');
      expect(s['open'], 'Open AgentConnect');
      expect(s['quit'], 'Quit AgentConnect');
    });

    test('idle, running and waiting each have their own state, with a count', () {
      expect(menuBarSnapshot(state(conversations: [conv('a', idle)]), org: 'Acme', text: text)['state'], 'idle');
      final running = menuBarSnapshot(state(conversations: [conv('a', working), conv('b', working)]), text: text);
      expect(running['state'], 'running');
      expect(running['count'], 0);
      expect(running['summary'], '2 running');
      final waiting = menuBarSnapshot(
          state(conversations: [conv('a', working), conv('b', awaiting)], approvals: [approval('x', 'c')]),
          org: 'Acme',
          text: text);
      expect(waiting['state'], 'waiting');
      expect(waiting['count'], 2);
      expect(waiting['org'], 'Acme');
      expect(waiting['summary'], '2 need you · 1 running');
      expect(waiting['tooltip'], 'AgentConnect: 2 need you · 1 running');
      expect(menuBarSnapshot(state(), text: text)['summary'], 'All quiet');
    });

    test('needs you: approval requests first, one row per conversation, opened by session', () {
      final s = menuBarSnapshot(
          state(
            conversations: [conv('q', awaiting, title: 'Pick a region'), conv('d', awaiting, title: 'Deploy')],
            approvals: [approval('a1', 'd'), approval('a2', 'd')],
          ),
          text: text);
      final needs = (s['needs'] as List).cast<Map<String, Object?>>();
      expect(needs.map((n) => (n['id'], n['approval'], n['title'], n['subtitle'])), [
        ('d', true, 'Chat d', 'deploy-bot needs approval'),
        ('q', false, 'Pick a region', 'deploy-bot is waiting for you'),
      ]);
      expect(needs.every((n) => n['kind'] == 'conversation'), isTrue);
      expect(s['count'], 2);
    });

    test('long lists are cut with a row that says how many more', () {
      final many = [for (var i = 0; i < menuBarRows + 3; i++) conv('s$i', awaiting)];
      final agents = [for (var i = 0; i < menuBarRows + 2; i++) agent('agent$i', AgentHealth.online)];
      final s = menuBarSnapshot(state(conversations: many, agents: agents), text: text);
      final needs = (s['needs'] as List).cast<Map<String, Object?>>();
      expect(needs, hasLength(menuBarRows + 1));
      expect(needs.last['title'], '3 more in AgentConnect…');
      expect(s['count'], menuBarRows + 3);
      expect(s['agents'] as List, hasLength(menuBarRows));
      expect(s['agentsMore'], '2 more…');
    });

    test('agents: working first, then online (latest used first), paused, offline; each state in words', () {
      final s = menuBarSnapshot(
          state(agents: [
            agent('off', AgentHealth.offline),
            agent('held', AgentHealth.paused),
            agent('abe', AgentHealth.online),
            agent('zed', AgentHealth.online, lastActive: at(-600)),
            agent('mid', AgentHealth.online, lastActive: at(-60)),
            agent('busy', AgentHealth.online, working: true),
          ]),
          text: text);
      final rows = (s['agents'] as List).cast<Map<String, Object?>>();
      expect(rows.map((r) => (r['title'], r['health'], r['subtitle'])), [
        ('busy', 'online', 'online · working'),
        ('mid', 'online', 'online'),
        ('zed', 'online', 'online'),
        ('abe', 'online', 'online'),
        ('held', 'paused', 'paused'),
        ('off', 'offline', 'offline'),
      ]);
      expect(rows.every((r) => r['kind'] == 'agent'), isTrue);
    });
  });

  test('notification text names the agent and the conversation, nothing else', () {
    final l = lookupAppLocalizations(const Locale('en'));
    expect(noticeText(l, const Notice(kind: NoticeKind.waiting, agentName: 'deploy-bot', title: 'Deploy', sessionId: 's')),
        ('deploy-bot is waiting for you', 'Deploy'));
    expect(noticeText(l, const Notice(kind: NoticeKind.approval, agentName: 'deploy-bot', title: ' ', sessionId: 's')),
        ('deploy-bot needs your approval', 'Untitled conversation'));
    expect(noticeText(l, const Notice(kind: NoticeKind.finished, agentName: 'deploy-bot', title: 'Deploy', sessionId: 's')),
        ('deploy-bot finished', 'Deploy'));
    expect(noticeText(l, const Notice(kind: NoticeKind.agentOffline, agentName: 'deploy-bot', agentId: 'a')).$1,
        'deploy-bot went offline');
  });
}
