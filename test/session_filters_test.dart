import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/features/agents/agents_screen.dart';
import 'package:agentconnect/features/files/agent_workspace_screen.dart';
import 'package:agentconnect/features/sessions/session_filters.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Anonymized fixture shaped like GET /orgs/{org}/sessions/facets.
const facetsJson = {
  'agents': ['a1', 'a2', 'gone'],
  'agentNames': {'a1': 'deploy-bot', 'gone': 'old-bot'},
  'integrations': ['slack', 'webchat', 'github'],
  'channels': [
    {'value': 'C1', 'platform': 'slack', 'integration': 'slack', 'name': 'deploys', 'triggeredByName': null},
    {'value': 'D9', 'platform': 'slack', 'integration': 'slack', 'name': null, 'triggeredByName': 'Dana'},
    {'value': 'conv-1', 'platform': 'webchat', 'integration': 'webchat', 'name': null, 'triggeredByName': null},
    {'value': 'conv-2', 'platform': 'webchat', 'integration': 'webchat', 'name': null, 'triggeredByName': null},
    {'value': 'h1', 'platform': 'hook', 'integration': 'github', 'name': null, 'triggeredByName': null},
  ],
  'triggers': [
    {'value': 'u-me', 'integration': 'webchat', 'name': 'Me Myself', 'hookKind': null, 'githubRepoId': null},
    {'value': 'u-2', 'integration': 'slack', 'name': 'Bo', 'hookKind': null, 'githubRepoId': null},
    {'value': 'a2', 'integration': 'webchat', 'name': null, 'hookKind': null, 'githubRepoId': null},
    {'value': 'hook:h1', 'integration': 'github', 'name': 'acme/api', 'hookKind': 'github', 'githubRepoId': '42'},
    {'value': 'hook:h2', 'integration': 'github', 'name': 'acme/api', 'hookKind': 'github', 'githubRepoId': '42'},
    {'value': 'cron:0123456789ab', 'integration': 'schedule', 'name': null, 'hookKind': null, 'githubRepoId': null},
  ],
};

const agents = [
  Agent(id: 'a1', name: 'deploy-bot'),
  Agent(id: 'a2', name: 'review', displayName: 'Review bot'),
  Agent(id: 'a3', name: 'idle-bot'),
];

class _NoTokens implements TokenProvider {
  @override
  Future<String> accessToken() async => 't';
  @override
  Future<bool> refreshAfter401(String rejected) async => false;
  @override
  bool get canWrite => true;
}

/// Answers facets from the fixture instead of the network.
class _FixtureFilters extends SessionFilterController {
  _FixtureFilters() : super(ApiClient('https://api.example.test/v1', _NoTokens()), 'org');
  int loads = 0;
  @override
  Future<void> loadFacets() async {
    loads++;
    facets = SessionFacets.fromJson(facetsJson);
    notifyListeners();
  }
}

void main() {
  final l = lookupAppLocalizations(const Locale('en'));
  final f = SessionFacets.fromJson(facetsJson);

  List<String> labels(SessionFacet facet, {String? selected}) => filterOptions(l, facet, f,
          agents: agents, userId: 'u-me', userName: 'Me Myself', selected: selected)
      .map((o) => o.label)
      .toList();

  test('filters map to the console query parameters', () {
    expect(const SessionFilters().query, isEmpty);
    expect(const SessionFilters().active, isFalse);
    expect(
      const SessionFilters(agent: 'a1', integration: 'slack', channel: 'C1', trigger: 'u-2').query,
      {'agentId': 'a1', 'integration': 'slack', 'channel': 'C1', 'triggeredBy': 'u-2'},
    );
    // Web chat channels collapse to one value, sent as a platform filter.
    expect(const SessionFilters(channel: 'webchat').query, {'platform': 'webchat'});
    // GitHub triggers are per repository.
    expect(const SessionFilters(trigger: 'github-repo:42').query, {'githubRepoId': '42'});
    expect(const SessionFilters(trigger: 'github-repo:x').query, {'triggeredBy': 'github-repo:x'});
    expect(const SessionFilters().with_(SessionFacet.channel, 'C1'), const SessionFilters(channel: 'C1'));
  });

  test('facets decode and tolerate missing fields', () {
    expect(f.agents, ['a1', 'a2', 'gone']);
    expect(f.channels, hasLength(5));
    expect(f.triggers.firstWhere((t) => t.value == 'hook:h1').filterValue, 'github-repo:42');
    expect(() => SessionFacets.fromJson(null), returnsNormally);
    expect(SessionFacets.fromJson({'channels': [{}]}).channels, isEmpty);
  });

  test('page total is read', () {
    expect(ConversationPage.fromJson({'conversations': [], 'total': 7}).total, 7);
    expect(ConversationPage.fromJson({'conversations': []}).total, isNull);
  });

  test('agent pills: roster agents in the facet, then named facet-only ids', () {
    expect(labels(SessionFacet.agent), ['deploy-bot', 'Review bot', 'old-bot']);
  });

  test('integration and channel pills use console names', () {
    expect(labels(SessionFacet.integration), ['Slack', 'Web chat', 'GitHub']);
    expect(labels(SessionFacet.channel), ['#deploys', '@Dana', 'Web chat', 'GitHub']);
    final webchat = filterOptions(l, SessionFacet.channel, f).where((o) => o.label == 'Web chat');
    expect(webchat.single.value, 'webchat');
  });

  test('trigger options: agents, people (me marked), schedules, events per repo', () {
    expect(labels(SessionFacet.trigger),
        ['Review bot', 'Bo', 'Me Myself (me)', 'Schedule 01234567', 'GitHub · acme/api']);
    final groups = filterOptions(l, SessionFacet.trigger, f, agents: agents).map((o) => o.group).toSet();
    expect(groups, {TriggerGroup.agents, TriggerGroup.people, TriggerGroup.schedules, TriggerGroup.events});
  });

  test('agents sort by last session, name and status', () {
    final now = DateTime(2026, 11, 4, 12);
    const list = [
      Agent(id: 'a', name: 'alpha', status: 'inactive'),
      Agent(id: 'b', name: 'beta', status: 'active'),
      Agent(id: 'c', name: 'gamma', status: 'active', paused: true),
      Agent(id: 'd', name: 'delta', status: 'active'),
    ];
    final last = {'a': now, 'c': now.subtract(const Duration(hours: 1)), 'd': now.subtract(const Duration(days: 2))};
    List<String> ids(AgentSort s) => sortAgents(list, s, last).map((a) => a.id).toList();
    expect(ids(AgentSort.lastSession), ['a', 'c', 'd', 'b']);
    expect(ids(AgentSort.name), ['a', 'b', 'd', 'c']);
    // online (d has a session, b none) · paused · offline
    expect(ids(AgentSort.status), ['d', 'b', 'c', 'a']);
  });

  test('agent repo label and session worktrees', () {
    expect(AgentRepo.fromJson({'mode': 'git', 'gitRepo': 'https://github.com/acme/infra.git'})!.label, 'acme/infra');
    expect(AgentRepo.fromJson({'mode': 'git', 'gitRepo': 'git@github.com:acme/api.git'})!.label, 'acme/api');
    expect(AgentRepo.fromJson({'mode': 'scratch'}), isNull);
    final rows = [
      for (final (id, iso, purged) in [('s1', 'session', null), ('s2', 'shared', null), ('s3', 'session', 'x')])
        SessionRow.fromJson({
          'sessionId': id,
          'agentId': 'a1',
          'workspaceIsolation': iso,
          'contentPurgedAt': purged,
          'sessionKey': {'platform': 'webchat'},
        }),
    ];
    expect(worktreeSessions(rows, 'a1').map((r) => r.sessionId), ['s1']);
  });

  test('a selected value the facets no longer list still has a pill', () {
    expect(labels(SessionFacet.channel, selected: 'C404'), contains('C404'));
  });

  testWidgets('filter bar: a dropdown opens its sheet, a pick applies and closes it', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final ctl = _FixtureFilters()..setTotal(12);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SessionFilterBar(ctl: ctl, who: const FilterContext(agents: agents, userId: 'u-me')),
        ),
      ),
    ));
    for (final s in ['Agent', 'Integration', 'Channel', 'Trigger']) {
      expect(find.text(s), findsOneWidget);
    }
    expect(find.text('12 sessions'), findsOneWidget);
    expect(find.text('Clear all'), findsNothing);

    await tester.tap(find.text('Channel'));
    await tester.pumpAndSettle();
    expect(find.text('Filter by channel'), findsOneWidget);
    expect(find.text('All channels'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'dep');
    await tester.pumpAndSettle();
    expect(find.text('@Dana'), findsNothing);
    await tester.tap(find.text('#deploys'));
    await tester.pumpAndSettle();
    expect(ctl.filters, const SessionFilters(channel: 'C1'));
    expect(find.text('Filter by channel'), findsNothing);
    // The dropdown now shows the pick; "Clear all" drops it.
    expect(find.text('#deploys'), findsOneWidget);
    await tester.tap(find.text('Clear all'));
    await tester.pumpAndSettle();
    expect(ctl.filters.active, isFalse);

    await tester.tap(find.text('Trigger'));
    await tester.pumpAndSettle();
    for (final h in ['AGENTS', 'PEOPLE', 'SCHEDULES', 'EVENTS']) {
      expect(find.text(h), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}
