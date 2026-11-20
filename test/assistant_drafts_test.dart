import 'dart:convert';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/api/assistant_drafts.dart';
import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/assistant_drafts_controller.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/features/approvals/assistant_draft_card.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/ui/theme.dart';
import 'package:flutter/cupertino.dart' show CupertinoAlertDialog;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoTokens implements TokenProvider {
  @override
  Future<String> accessToken() async => 'x';
  @override
  Future<bool> refreshAfter401(String rejected) async => false;
  @override
  bool get canWrite => true;
}

const _org = 'org_1';
const _agent = '3b1f7c52-6f0e-4d0a-9a53-0c1d2e3f4a5b';
const _integration = 'int-1';

// `AssistantActivityDraft` shapes (protocol frames/assistant-activity.ts), as the web console's tests use them.
Map<String, dynamic> _message({String id = 'draft-1'}) => {
      'id': id,
      'kind': 'elsewhere',
      'target': {
        'platform': 'slack',
        'integrationId': _integration,
        'channel': 'C0SUPPORT',
        'thread': '1700000000.000100',
        'name': 'support',
        'dm': false,
        'external': false
      },
      'text': 'The release is out.\n\nNotes are in the docs.',
      'approver': {
        'kind': 'member',
        'integrationId': _integration,
        'channel': 'D0ADA',
        'userId': 'U0ADA',
        'consoleUserId': null,
        'name': 'Ada'
      },
      'createdAt': '2026-10-09T09:00:00.000Z',
      'expiresAt': '2026-10-10T09:00:00.000Z'
    };

Map<String, dynamic> _proposal({String id = 'proposal-1', Map<String, dynamic>? followUp}) => {
      'id': id,
      'kind': 'task',
      'target': {
        'platform': 'slack',
        'integrationId': _integration,
        'channel': 'C0SUPPORT',
        'thread': null,
        'name': 'support',
        'dm': false,
        'external': false
      },
      'text': followUp == null ? 'Rebase PR #12 onto main and push.' : 'The 2.6 release date',
      'approver': {
        'kind': 'conversation',
        'integrationId': _integration,
        'channel': 'C0SUPPORT',
        'userId': null,
        'consoleUserId': null,
        'name': null
      },
      'proposal': {
        'sentence': 'I want to rebase PR #12 because it conflicts with main.',
        'why': 'The check found a merge conflict.',
        'itemId': 'item-1',
        'itemTitle': 'Ship the release notes',
        'followUp': ?followUp,
      },
      'createdAt': '2026-10-09T09:00:00.000Z',
      'expiresAt': '2026-10-10T08:00:00.000Z'
    };

const _followUp = {'title': 'The 2.6 release date', 'doneWhen': 'A date is posted.', 'nextCheck': null};

/// Answers REST calls from [on]; records what was asked.
class _Api extends ApiClient {
  _Api(this.on) : super('https://api.example.test/v1', _NoTokens());
  Object? Function(String method, String path, Object? body) on;
  final calls = <(String, String, Object?)>[];

  @override
  Future<dynamic> request(String method, String path, {Map<String, String?>? query, Object? body}) async {
    calls.add((method, path, body));
    final r = on(method, path, body);
    if (r is Exception) throw r;
    return jsonDecode(jsonEncode(r));
  }
}

List<Agent> _agents() => [
      Agent.fromJson({'id': _agent, 'name': 'pilot', 'displayName': 'Pilot', 'assistantMode': {'enabled': true}}),
      Agent.fromJson({'id': 'plain', 'name': 'plain', 'assistantMode': null}),
      Agent.fromJson({'id': 'off', 'name': 'off', 'assistantMode': {'enabled': false}}),
    ];

const _draftsPath = '/orgs/$_org/agents/$_agent/assistant/drafts';

AssistantDraftsController _controller(_Api api) => AssistantDraftsController(api, _org, _agents);

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// The posted decision of the last call.
Object? _decision(_Api api) => api.calls.lastWhere((c) => c.$1 == 'POST').$3;

void main() {
  test('reads a message draft, a proposal and a follow-up form', () {
    final m = AssistantDraft.fromJson(_message())!;
    expect((m.kind, m.isProposal, m.targetName, m.thread, m.approverName, m.approverKind),
        ('elsewhere', false, 'support', '1700000000.000100', 'Ada', 'member'));
    expect(m.expiresAt!.toUtc(), DateTime.utc(2026, 10, 10, 9));
    final p = AssistantDraft.fromJson(_proposal())!;
    expect((p.isProposal, p.isFollowUp, p.proposal!.sentence, p.proposal!.itemTitle, p.text),
        (true, false, 'I want to rebase PR #12 because it conflicts with main.', 'Ship the release notes', 'Rebase PR #12 onto main and push.'));
    final f = AssistantDraft.fromJson(_proposal(followUp: _followUp))!;
    expect((f.isFollowUp, f.proposal!.followUp!.title, f.proposal!.followUp!.nextCheck),
        (true, 'The 2.6 release date', null));
    expect(AssistantDraft.fromJson({'id': 'x'}), isNull);
    expect(_agents().map((a) => a.assistant), [true, false, false]);
  });

  test('lists what assistant-mode agents wait on: messages first, then proposals', () async {
    final api = _Api((method, path, body) => {
          'drafts': [_proposal(), _message()],
          'truncated': true,
          'permissionRequests': <dynamic>[],
        });
    final c = _controller(api);
    await c.refresh();
    // Only the agent in assistant mode is asked.
    expect(api.calls.map((x) => x.$2), [_draftsPath]);
    expect(c.rows.map((d) => d.id), ['draft-1', 'proposal-1']);
    expect((c.rows.first.agentId, c.rows.first.agentName), (_agent, 'Pilot'));
    expect((c.waitingCount, c.truncated), (2, true));

    // Not this person's to decide (not an editor), or the agent is away: nothing listed.
    api.on = (method, path, body) => ApiException(403, null, 'cannot edit this agent');
    await c.refresh();
    expect(c.rows, isEmpty);
  });

  testWidgets('Approve posts a message after a confirmation, and says what happened', (tester) async {
    var listed = [_message()];
    final api = _Api((method, path, body) {
      if (method == 'GET') return {'drafts': listed, 'truncated': false, 'permissionRequests': <dynamic>[]};
      listed = [];
      return {'status': 'succeeded', 'failure': null};
    });
    final c = _controller(api);
    await c.refresh();
    await tester.pumpWidget(_host(AssistantDraftsSection(controller: c)));
    expect(find.text('Waiting for you'), findsOneWidget);
    expect(find.text('Pilot'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Message to #support · in a thread'), findsOneWidget);
    expect(find.text('The release is out.\n\nNotes are in the docs.'), findsOneWidget);
    expect(find.textContaining('Ada approves · Expires '), findsOneWidget);

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(find.text('Post this message?'), findsOneWidget);
    expect(find.text('It goes to #support now, exactly as written.'), findsOneWidget);
    // Not yet: nothing is sent before the confirmation.
    expect(api.calls.where((x) => x.$1 == 'POST'), isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Approve'));
    await tester.pumpAndSettle();
    expect(api.calls.last.$2, '$_draftsPath/draft-1/decision');
    expect(_decision(api), {'decision': 'approve'});
    expect(find.text('Posted.'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
    expect(c.waitingCount, 0);

    // The server no longer lists it; the outcome stays until dismissed.
    await c.refresh();
    await tester.pump();
    expect(find.text('Posted.'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(find.text('Waiting for you'), findsNothing);
  });

  testWidgets('Discard drops a message; cancelling the confirmation sends nothing', (tester) async {
    final api = _Api((method, path, body) => method == 'GET'
        ? {'drafts': [_message()], 'truncated': false}
        : {'status': 'denied', 'failure': null});
    final c = _controller(api);
    await c.refresh();
    await tester.pumpWidget(_host(AssistantDraftsSection(controller: c)));
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Discard this draft?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.calls.where((x) => x.$1 == 'POST'), isEmpty);

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await tester.pumpAndSettle();
    expect(_decision(api), {'decision': 'discard'});
    expect(find.text('Discarded. Nothing was posted.'), findsOneWidget);
  });

  testWidgets('a suggested task: Approve starts it, Deny drops it', (tester) async {
    var status = 'executing';
    final api = _Api((method, path, body) => method == 'GET'
        ? {'drafts': [_proposal(), _proposal(id: 'proposal-2')], 'truncated': false}
        : {'status': status, 'failure': null});
    final c = _controller(api);
    await c.refresh();
    await tester.pumpWidget(_host(AssistantDraftsSection(controller: c)));
    expect(find.text('Suggested task'), findsNWidgets(2));
    expect(find.text('I want to rebase PR #12 because it conflicts with main.'), findsNWidgets(2));
    expect(find.text('Why: The check found a merge conflict.'), findsNWidgets(2));
    expect(find.text('For Ship the release notes'), findsNWidgets(2));
    expect(find.text('Rebase PR #12 onto main and push.'), findsNWidgets(2));

    await tester.tap(find.text('Approve').first);
    await tester.pumpAndSettle();
    expect(find.text('Run this now?'), findsOneWidget);
    expect(find.text('It runs as a task and reports back in #support.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Approve'));
    await tester.pumpAndSettle();
    expect(api.calls.last.$2, '$_draftsPath/proposal-1/decision');
    expect(_decision(api), {'decision': 'approve'});
    expect(find.text('Approved. It runs as a task and reports back in #support.'), findsOneWidget);

    status = 'denied';
    await tester.tap(find.text('Deny'));
    await tester.pumpAndSettle();
    expect(find.text('Deny this proposal?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Deny'));
    await tester.pumpAndSettle();
    // A proposal's Deny is the drafts route's `discard`.
    expect(api.calls.last.$2, '$_draftsPath/proposal-2/decision');
    expect(_decision(api), {'decision': 'discard'});
    expect(find.text('Denied. Nothing was run.'), findsOneWidget);
  });

  testWidgets('a suggested follow-up shows what approving takes', (tester) async {
    final api = _Api((method, path, body) => method == 'GET'
        ? {'drafts': [_proposal(followUp: _followUp)], 'truncated': false}
        : {'status': 'succeeded', 'failure': null, 'followUp': {'id': 'item-taken', 'conversation': null}});
    final c = _controller(api);
    await c.refresh();
    await tester.pumpWidget(_host(AssistantDraftsSection(controller: c)));
    expect(find.text('Suggested follow-up'), findsOneWidget);
    expect(find.text('Takes this follow-up'), findsOneWidget);
    expect(find.text('The 2.6 release date'), findsOneWidget);
    expect(find.text('A date is posted.'), findsOneWidget);
    expect(find.text('No check until it is messaged'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(find.text('Take this follow-up?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Approve'));
    await tester.pumpAndSettle();
    expect(find.text('Approved. The follow-up was taken; it reports back in #support.'), findsOneWidget);
  });

  test('refusals: expired, decided elsewhere, gone, busy, unconfirmed, a failure with its reason', () async {
    Object? answer;
    var listed = <dynamic>[_proposal()];
    final api = _Api((method, path, body) => method == 'GET' ? {'drafts': listed, 'truncated': false} : answer);
    Future<(DraftCardState, AssistantDraftsController, AssistantDraft)> run(Object? a) async {
      answer = a;
      final c = _controller(api);
      await c.refresh();
      final d = c.rows.single;
      await c.decide(d, approve: true);
      return (c.stateOf(d), c, d);
    }

    var (st, c, d) = await run(ApiException(409, 'DRAFT_EXPIRED', 'the draft expired; nothing was posted'));
    expect((st.result!.refusal, c.canDecide(d)), ('expired', false));
    (st, c, d) = await run(ApiException(409, 'DRAFT_ALREADY_DECIDED', 'the draft was already decided'));
    expect(st.result!.refusal, 'decided');
    (st, c, d) = await run(ApiException(404, 'NOT_FOUND', 'draft not found'));
    expect(st.result!.refusal, 'gone');
    // The agent runs as many tasks as it may: nothing is decided, the buttons stay.
    (st, c, d) = await run(ApiException(409, 'SUBSESSION_LIMIT', 'the agent already runs as many tasks as it may'));
    expect((st.result, st.notice, c.canDecide(d)), (null, 'busy', true));
    (st, c, d) = await run(ApiException(409, 'DAEMON_FEATURE_MISSING', 'upgrade its daemon'));
    expect((st.result, st.notice), (null, 'upgrade'));
    (st, c, d) = await run(ApiException(503, 'DAEMON_OFFLINE', 'owning daemon is offline'));
    expect((st.result, st.notice), (null, 'offline'));
    (st, c, d) = await run(ApiException(500));
    expect((st.result, st.notice, c.canDecide(d)), (null, 'failed', true));
    // Sent but not confirmed: still listed, so it can be decided again.
    (st, c, d) = await run(ApiException(503, 'DECISION_UNCONFIRMED', 'the decision was sent but not confirmed'));
    expect((st.result!.unconfirmed, c.isWaiting(d), c.canDecide(d)), (true, true, true));
    // …or no longer listed: it may have gone through.
    answer = ApiException(503, 'DECISION_UNCONFIRMED', 'x');
    c = _controller(api);
    await c.refresh();
    d = c.rows.single;
    listed = [];
    await c.decide(d, approve: true);
    expect((c.stateOf(d).result!.unconfirmed, c.isWaiting(d), c.canDecide(d)), (true, false, false));
    expect(c.rows.single.id, 'proposal-1');
    listed = [_proposal()];
    (st, c, d) = await run({'status': 'failed', 'failure': 'the agent is no longer enabled in that conversation'});
    expect((st.result!.outcome!.status, st.result!.outcome!.failure),
        ('failed', 'the agent is no longer enabled in that conversation'));
  });

  testWidgets('what could not be decided is said on the card', (tester) async {
    Object? answer = ApiException(409, 'SUBSESSION_LIMIT', 'busy');
    final api = _Api((method, path, body) => method == 'GET' ? {'drafts': [_proposal()], 'truncated': false} : answer);
    final c = _controller(api);
    await c.refresh();
    await tester.pumpWidget(_host(AssistantDraftsSection(controller: c)));
    final d = c.rows.single;
    await c.decide(d, approve: true);
    await tester.pump();
    expect(find.text('The agent already runs as many tasks as it may. The proposal is still waiting.'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);

    answer = {'status': 'failed', 'failure': 'the agent is no longer enabled in that conversation'};
    await c.decide(d, approve: true);
    await tester.pump();
    expect(find.text("Couldn't run: the agent is no longer enabled in that conversation. Nothing was run."), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Dismiss'), findsOneWidget);
  });

  testWidgets('iOS confirms with a system alert, and the card fits the narrowest phone', (tester) async {
    tester.view.physicalSize = const Size(375, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final api = _Api((method, path, body) => {
            'drafts': [_message(), _proposal(followUp: _followUp)],
            'truncated': false
          });
      final c = _controller(api);
      await c.refresh();
      await tester.pumpWidget(_host(AssistantDraftsSection(controller: c)));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
