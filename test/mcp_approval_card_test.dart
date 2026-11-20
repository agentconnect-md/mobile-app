import 'dart:convert';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/api/mcp_operations.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/features/chat/bubbles.dart';
import 'package:agentconnect/features/chat/mcp_approval_card.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/ui/theme.dart';
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
const _conv = '9d2a6c1e-4b7f-4e0a-8c35-1f2e3d4c5b6a';
const _op = 'e6229709-3d5a-432b-a7d3-613395a7d7ed';
const _base = '/orgs/$_org/agents/$_agent/webchat/$_conv/mcp-operations';

// `WebchatMcpOperationDto` as the control plane answers it.
Map<String, dynamic> _dto({String id = _op, String tool = 'createAgent', String status = 'awaiting_confirmation', Object? result}) => {
      'operationId': id,
      'toolName': tool,
      'arguments': {'name': 'code-reviewer'},
      'status': status,
      'createdAt': '2026-09-10T04:00:00.000Z',
      'confirmationExpiresAt': '2026-09-10T04:10:00.000Z',
      'completedAt': status == 'awaiting_confirmation' || status == 'executing' ? null : '2026-09-10T04:01:00.000Z',
      'result': ?result,
    };

/// Answers REST calls from [on]; records what was asked.
class _Api extends ApiClient {
  _Api(this.on) : super('https://api.example.test/v1', _NoTokens());
  final Object? Function(String method, String path, Object? body) on;
  final calls = <(String, String, Object?)>[];

  @override
  Future<dynamic> request(String method, String path, {Map<String, String?>? query, Object? body}) async {
    calls.add((method, path, body));
    final r = on(method, path, body);
    if (r is Exception) throw r;
    // Through JSON, as off the wire.
    return jsonDecode(jsonEncode(r));
  }
}

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Widget _strip(_Api api, {List<String>? notices, bool Function(String)? raisedHere}) => _host(McpApprovalStrip(
      client: api,
      orgId: _org,
      agentId: _agent,
      conversationId: _conv,
      raisedHere: raisedHere,
      onDecided: notices?.add,
    ));

void main() {
  test('reads an operation and words the notice the agent is sent', () {
    final o = McpOperation.fromJson(_dto())!;
    expect((o.operationId, o.toolName, o.status, o.awaiting, o.hasResult), (_op, 'createAgent', 'awaiting_confirmation', true, false));
    expect(o.arguments, {'name': 'code-reviewer'});
    expect(McpOperation.fromJson({'toolName': 'x'}), isNull);
    final done = McpOperation.fromJson(_dto(status: 'completed', result: {'statusCode': 200, 'body': '{}'}))!;
    expect(done.hasResult, isTrue);
    expect(mcpApprovalNotice(o, approved: true, outcome: done),
        '[approval] createAgent (operation $_op) is now completed. Read it with getOperation and continue from there.');
    // A denial lands as `failed`: the decision is what tells the two apart.
    final failed = McpOperation.fromJson(_dto(status: 'failed'))!;
    expect(mcpApprovalNotice(o, approved: false, outcome: failed), contains('is now denied.'));
    expect(mcpApprovalNotice(o, approved: true, outcome: failed), contains('is now failed.'));
  });

  test('raisedIn finds an operation id in the conversation\'s own rows', () {
    final here = mcpRaisedIn([
      const UserEntry('hi', null),
      ToolEntry(title: 'updateAgent', body: jsonEncode({'output': jsonEncode({'status': 'awaiting_confirmation', 'operationId': _op})})),
    ]);
    expect(here(_op), isTrue);
    expect(here('0b6c9d2e-5f8a-4c1b-8e3d-7a9f2c4e6b11'), isFalse);
  });

  testWidgets('lists what is pending; Approve and run settles it and tells the agent', (tester) async {
    var pending = true;
    final api = _Api((method, path, body) {
      if (method == 'GET' && path == _base) return pending ? [_dto()] : <dynamic>[];
      if (method == 'POST' && path == '$_base/$_op/decision') {
        pending = false;
        return _dto(status: 'completed', result: {'statusCode': 200, 'body': '{"id":"agent_9"}'});
      }
      return ApiException(404);
    });
    final notices = <String>[];
    await tester.pumpWidget(_strip(api, notices: notices));
    await tester.pump();
    expect(find.text('APPROVAL REQUIRED'), findsOneWidget);
    expect(find.text('createAgent'), findsOneWidget);
    expect(find.textContaining('"name": "code-reviewer"'), findsOneWidget);

    await tester.tap(find.text('Approve and run'));
    await tester.pump();
    await tester.pump();
    final post = api.calls.where((c) => c.$1 == 'POST').single;
    expect(post.$2, '$_base/$_op/decision');
    expect(post.$3, {'decision': 'approve'});
    expect(find.text('COMPLETED'), findsOneWidget);
    expect(find.textContaining('"statusCode": 200'), findsOneWidget);
    expect(find.text('Approve and run'), findsNothing);
    expect(notices.single, contains('createAgent (operation $_op) is now completed'));

    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(find.text('createAgent'), findsNothing);
  });

  testWidgets('Deny reads Denied, and nothing ran', (tester) async {
    final api = _Api((method, path, body) => method == 'POST' ? _dto(status: 'failed') : [_dto()]);
    final notices = <String>[];
    await tester.pumpWidget(_strip(api, notices: notices));
    await tester.pump();
    await tester.tap(find.text('Deny'));
    await tester.pump();
    await tester.pump();
    expect(api.calls.where((c) => c.$1 == 'POST').single.$3, {'decision': 'deny'});
    expect(find.text('DENIED'), findsOneWidget);
    expect(notices.single, contains('is now denied'));
  });

  testWidgets('an operation still running offers Check status, then its result', (tester) async {
    var status = 'executing';
    final api = _Api((method, path, body) {
      if (method == 'POST') return _dto(status: 'executing');
      if (path == '$_base/$_op') return _dto(status: status);
      return [_dto()];
    });
    final notices = <String>[];
    await tester.pumpWidget(_strip(api, notices: notices));
    await tester.pump();
    await tester.tap(find.text('Approve and run'));
    await tester.pump();
    await tester.pump();
    expect(find.text('EXECUTING…'), findsOneWidget);
    expect(find.text('The operation is still running. Check the status again for its final result.'), findsOneWidget);
    // Not settled yet: the agent isn't told.
    expect(notices, isEmpty);

    status = 'ambiguous';
    await tester.tap(find.text('Check status'));
    await tester.pump();
    await tester.pump();
    expect(find.text('OUTCOME UNCERTAIN'), findsOneWidget);
    expect(find.textContaining('may or may not have run'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
    // Settled now: the agent, which ended its turn waiting, is told.
    expect(notices.single, contains('createAgent (operation $_op) is now ambiguous'));
  });

  testWidgets('a lost response found still running tells the agent once, when a later check sees it done', (tester) async {
    var status = 'executing';
    final api = _Api((method, path, body) {
      if (method == 'POST') return ApiException(503);
      if (path == '$_base/$_op') return _dto(status: status);
      return [_dto()];
    });
    final notices = <String>[];
    await tester.pumpWidget(_strip(api, notices: notices));
    await tester.pump();
    await tester.tap(find.text('Approve and run'));
    await tester.pump();
    await tester.pump();
    // The decision's answer was lost; the read says it is running.
    expect(find.text('EXECUTING…'), findsOneWidget);
    expect(notices, isEmpty);

    // Checked while still running: nothing to tell yet.
    await tester.tap(find.text('Check status'));
    await tester.pump();
    await tester.pump();
    expect(find.text('EXECUTING…'), findsOneWidget);
    expect(notices, isEmpty);

    status = 'completed';
    await tester.tap(find.text('Check status'));
    await tester.pump();
    await tester.pump();
    expect(find.text('COMPLETED'), findsOneWidget);
    expect(notices.single, contains('is now completed'));
    // Settled rows offer no further check, so it is told once.
    expect(find.text('Check status'), findsNothing);
    expect(find.text('Dismiss'), findsOneWidget);
  });

  testWidgets('an unknown outcome checked while running, then done, tells the agent once', (tester) async {
    Object? single = ApiException(503);
    final api = _Api((method, path, body) {
      if (method == 'POST') return ApiException(503);
      if (path == '$_base/$_op') return single;
      return [_dto()];
    });
    final notices = <String>[];
    await tester.pumpWidget(_strip(api, notices: notices));
    await tester.pump();
    await tester.tap(find.text('Approve and run'));
    await tester.pump();
    await tester.pump();
    expect(find.text('OUTCOME UNKNOWN'), findsOneWidget);

    single = _dto(status: 'executing');
    await tester.tap(find.text('Check status'));
    await tester.pump();
    await tester.pump();
    expect(find.text('EXECUTING…'), findsOneWidget);
    expect(notices, isEmpty);

    single = _dto(status: 'completed');
    await tester.tap(find.text('Check status'));
    await tester.pump();
    await tester.pump();
    expect(notices.single, contains('is now completed'));
  });

  testWidgets('a lost response is checked: not applied keeps it pending, unknown says so', (tester) async {
    Object? single = _dto();
    final api = _Api((method, path, body) {
      if (method == 'POST') return ApiException(409, null, 'operation is no longer pending');
      if (path == '$_base/$_op') return single;
      return [_dto()];
    });
    final notices = <String>[];
    await tester.pumpWidget(_strip(api, notices: notices));
    await tester.pump();
    await tester.tap(find.text('Approve and run'));
    await tester.pump();
    await tester.pump();
    expect(find.text('The decision was not applied. Try again.'), findsOneWidget);
    expect(find.text('Approve and run'), findsOneWidget);

    // Neither the decision nor the read came back.
    single = ApiException(503);
    await tester.tap(find.text('Approve and run'));
    await tester.pump();
    await tester.pump();
    expect(find.text('OUTCOME UNKNOWN'), findsOneWidget);
    expect(find.text('The decision response was lost. Check the status to verify whether the operation ran.'), findsOneWidget);
    expect(notices, isEmpty);

    // Checked: it did run. Now the agent hears about it.
    single = _dto(status: 'completed');
    await tester.tap(find.text('Check status'));
    await tester.pump();
    await tester.pump();
    expect(find.text('COMPLETED'), findsOneWidget);
    expect(notices.single, contains('is now completed'));
  });

  testWidgets('shows only what this conversation raised; nothing for someone else\'s conversation', (tester) async {
    const other = '0b6c9d2e-5f8a-4c1b-8e3d-7a9f2c4e6b11';
    final api = _Api((method, path, body) => [_dto(tool: 'updateAgent'), _dto(id: other, tool: 'deleteCron')]);
    await tester.pumpWidget(_strip(api, raisedHere: (id) => id == _op));
    await tester.pump();
    expect(find.text('updateAgent'), findsOneWidget);
    expect(find.text('deleteCron'), findsNothing);

    final notMine = _Api((method, path, body) => ApiException(404));
    await tester.pumpWidget(_host(McpApprovalStrip(
        key: const ValueKey('other'), client: notMine, orgId: _org, agentId: _agent, conversationId: _conv)));
    await tester.pump();
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('asks again every few seconds, and when the agent\'s turn ends', (tester) async {
    var listed = <dynamic>[];
    final api = _Api((method, path, body) => listed);
    Widget strip(bool running) => _host(McpApprovalStrip(
        client: api, orgId: _org, agentId: _agent, conversationId: _conv, turnRunning: running));
    await tester.pumpWidget(strip(true));
    await tester.pump();
    expect(api.calls.length, 1);
    listed = [_dto()];
    await tester.pumpWidget(strip(false));
    await tester.pump();
    expect(api.calls.length, 2);
    expect(find.text('createAgent'), findsOneWidget);
    listed = [];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(api.calls.length, 3);
    expect(find.text('createAgent'), findsNothing);
  });
}
