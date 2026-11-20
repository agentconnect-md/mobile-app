import 'dart:convert';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/api/capability_requests.dart';
import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/core/webchat/chat_controller.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:agentconnect/features/chat/bubbles.dart';
import 'package:agentconnect/features/chat/capability_card.dart';
import 'package:agentconnect/features/sessions/transcript.dart';
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

const _req = '7f3a1c56-8a2b-4c3d-9e4f-0a1b2c3d4e5f';
const _link = 'https://console.example.test/acme/requests/$_req';

// The `capability_request` event (protocol frames/webchat.ts).
Map<String, dynamic> _asked({int generation = 1}) => {
      'kind': 'capability_request',
      'requestId': _req,
      'generation': generation,
      'summary': 'add the MCP server "Linear"',
      'reason': 'filing the bug needs <b>Linear</b>',
      'link': _link,
    };

// `CapabilityRequestDto` as `GET /orgs/{org}/capability-requests/{id}` answers it.
Map<String, dynamic> _dto({
  String status = 'open',
  Map<String, dynamic>? viewer,
  Map<String, dynamic>? settledBy,
  String? note,
  String? outcome,
}) =>
    {
      'id': _req,
      'orgId': 'org-1',
      'agentId': 'agent-1',
      'agentName': 'pilot',
      'kind': 'mcp-server',
      'target': 'Linear',
      'want': {'server': 'Linear'},
      'summary': 'add the MCP server "Linear"',
      'reason': 'filing the bug needs <b>Linear</b>',
      'status': status,
      'generation': 1,
      'createdAt': '2026-10-26T09:00:00.000Z',
      'expiresAt': '2026-11-02T09:00:00.000Z',
      'settledAt': status == 'open' ? null : '2026-10-27T09:00:00.000Z',
      'settledBy': settledBy,
      'outcome': outcome,
      'differs': false,
      'note': note,
      'origins': <dynamic>[],
      'current': {'attached': false, 'exists': true},
      'warnings': <dynamic>[],
      'viewer': viewer ??
          {'canComplete': true, 'canDecline': true, 'canReopen': false, 'canForward': true, 'missing': null, 'whoCan': <dynamic>[]},
    };

String _out(int i, Map<String, dynamic> ev) => jsonEncode({
      'type': 'output',
      'output': {'turnId': 't', 'index': i, 'event': ev}
    });

ChatController _chat() =>
    ChatController(client: ApiClient('https://api.example.test/v1', _NoTokens()), orgId: 'o', agentId: 'a')
      ..debugConnect((_) {});

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

LiveItem _item({String? status, String? text}) => LiveItem(LiveKind.capability, '', requestId: _req)
  ..capability = CapabilityCard.fromJson(_asked())
  ..capabilityStatus = status
  ..capabilityText = text;

void main() {
  test('decodes the request, its settlement, and the request itself', () {
    final ev = (decodeFrame(_out(1, _asked())) as OutputFrame).event as CapabilityRequestEvent;
    expect((ev.card.requestId, ev.card.generation, ev.card.summary, ev.card.link),
        (_req, 1, 'add the MCP server "Linear"', _link));
    final done = (decodeFrame(_out(2, {
      'kind': 'capability_request_resolved',
      'requestId': _req,
      'status': 'declined',
      'text': 'Declined by Ben'
    })) as OutputFrame)
        .event as CapabilityResolvedEvent;
    expect((done.status, done.text), ('declined', 'Declined by Ben'));
    // A status this build doesn't know isn't read as a verdict.
    expect(
        (decodeFrame(_out(2, {'kind': 'capability_request_resolved', 'requestId': _req, 'status': 'vetoed', 'text': ''}))
                as OutputFrame)
            .event,
        isA<UnsupportedEvent>());

    final r = CapabilityRequest.fromJson(_dto(viewer: {
      'canComplete': false,
      'canDecline': false,
      'canReopen': false,
      'canForward': true,
      'missing': 'Only an editor of this agent can complete this request.',
      'whoCan': [
        {'userId': 'u1', 'name': 'Ana'},
        {'userId': 'u2', 'name': 'Ben'},
      ],
    }))!;
    expect((r.open, r.canComplete, r.missing), (true, false, 'Only an editor of this agent can complete this request.'));
    expect(r.whoCan, ['Ana', 'Ben']);
    expect(r.expiresAt!.toUtc(), DateTime.utc(2026, 11, 2, 9));
    expect(CapabilityRequest.fromJson({'summary': 'x'}), isNull);
    // Only an https page is opened from the server's link.
    expect(capabilityLink(_link), isNotNull);
    expect(capabilityLink('http://console.example.test/x'), isNull);
    expect(capabilityLink('javascript:alert(1)'), isNull);
    expect(capabilityLink(''), isNull);
  });

  test('the live card settles in place and opens again when the request is reopened', () {
    final c = _chat();
    c.debugFrame(_out(1, _asked()));
    expect(c.items.single.kind, LiveKind.capability);
    c.debugFrame(_out(2, {'kind': 'capability_request_resolved', 'requestId': _req, 'status': 'declined', 'text': 'Declined by Ben'}));
    expect((c.items.single.capabilityStatus, c.items.single.capabilityText), ('declined', 'Declined by Ben'));
    c.debugFrame(_out(3, _asked(generation: 2)));
    expect(c.items.length, 1);
    expect(c.items.single.capability!.generation, 2);
    expect(c.items.single.capabilityStatus, isNull);
  });

  test('a saved capability row is a card; the live copy stands in for it', () {
    TranscriptItem row(String status, [Map<String, dynamic> extra = const {}]) => buildTranscript([
          ApiMessage.fromJson({
            'seq': 1,
            'sender': 'agent-1',
            'ts': '1700000001',
            'kind': 'capability',
            'text': 'add the MCP server "Linear"',
            'body': jsonEncode({..._asked()..remove('kind'), 'status': status, ...extra}),
          })
        ], {
          'agent-1'
        }).single;
    final open = entriesFromTranscript([row('open')]).single as CapabilityEntry;
    expect(open.item.capability!.requestId, _req);
    expect(open.item.capabilityStatus, isNull);
    final declined = entriesFromTranscript([row('declined', {'text': 'Declined by Ben'})]).single as CapabilityEntry;
    expect((declined.item.capabilityStatus, declined.item.capabilityText), ('declined', 'Declined by Ben'));
    // A row of a kind this app draws no card for stays a pointer to the console.
    expect(entriesFromTranscript([TranscriptItem(seq: 2, kind: ItemKind.other, text: '', rawKind: 'app')]).single,
        isA<UnsupportedEntry>());
    expect(entriesFromTranscript([TranscriptItem(seq: 2, kind: ItemKind.other, text: '', rawKind: 'capability', body: '{}')]).single,
        isA<UnsupportedEntry>());

    final live = CapabilityEntry(_item());
    final shown = groupTools([const UserEntry('hi', null), open, const AgentEntry('ok'), live]);
    expect(shown.whereType<CapabilityEntry>().single, same(live));
  });

  testWidgets('open: what is asked and why, where it stands, and the way to the console', (tester) async {
    var opened = 0;
    final asked = <String>[];
    await tester.pumpWidget(_host(CapabilityCardView(
      item: _item(),
      load: (id) async {
        asked.add(id);
        return CapabilityRequest.fromJson(_dto())!;
      },
      open: () async => opened++,
    )));
    await tester.pump();
    expect(asked, [_req]);
    expect(find.text('add the MCP server "Linear"'), findsOneWidget);
    // The agent's reason is plain text: nothing in it is rendered.
    expect(find.text('filing the bug needs <b>Linear</b>'), findsOneWidget);
    expect(find.text('Waiting for someone to act'), findsOneWidget);
    expect(find.textContaining('Expires '), findsOneWidget);
    expect(find.text('You can make this change, or decline it, in the web console.'), findsOneWidget);
    await tester.tap(find.text('Open in console'));
    expect(opened, 1);
  });

  testWidgets('someone without authority sees what it needs and who can act', (tester) async {
    await tester.pumpWidget(_host(CapabilityCardView(
      item: _item(),
      load: (_) async => CapabilityRequest.fromJson(_dto(viewer: {
        'canComplete': false,
        'canDecline': false,
        'canReopen': false,
        'canForward': true,
        'missing': 'Only an editor of this agent can complete this request.',
        'whoCan': [
          {'userId': 'u1', 'name': 'Ana'},
          {'userId': 'u2', 'name': 'Ben'},
        ],
      }))!,
      open: () async {},
    )));
    await tester.pump();
    expect(find.text('Only an editor of this agent can complete this request.'), findsOneWidget);
    expect(find.text('People who can: Ana, Ben'), findsOneWidget);
    expect(find.textContaining('You can'), findsNothing);
    expect(find.text('Open in console'), findsOneWidget);
  });

  testWidgets('settled in the conversation: its line, read-only, nothing fetched', (tester) async {
    var loads = 0;
    await tester.pumpWidget(_host(CapabilityCardView(
      item: _item(status: 'declined', text: 'Declined by Ben'),
      load: (_) async {
        loads++;
        return CapabilityRequest.fromJson(_dto())!;
      },
      open: () async {},
    )));
    await tester.pump();
    expect(find.text('Declined by Ben'), findsOneWidget);
    expect(find.text('Open in console'), findsNothing);
    expect(find.text('Waiting for someone to act'), findsNothing);
    expect(loads, 0);

    // No line came with it: the status is worded here.
    await tester.pumpWidget(_host(CapabilityCardView(
        key: const ValueKey('expired'), item: _item(status: 'expired', text: ''), load: (_) async => throw 0, open: () async {})));
    await tester.pump();
    expect(find.text('Expired: nobody acted on it in 7 days'), findsOneWidget);
  });

  testWidgets('settled since: the request says by whom, with their note', (tester) async {
    await tester.pumpWidget(_host(CapabilityCardView(
      item: _item(),
      load: (_) async => CapabilityRequest.fromJson(
          _dto(status: 'declined', settledBy: {'kind': 'console', 'userId': 'u1', 'name': 'Ana'}, note: 'too risky'))!,
      open: () async {},
    )));
    await tester.pump();
    expect(find.text('Declined by Ana'), findsOneWidget);
    expect(find.text('Their note: too risky'), findsOneWidget);
    expect(find.text('Open in console'), findsNothing);

    await tester.pumpWidget(_host(CapabilityCardView(
      key: const ValueKey('done'),
      item: _item(),
      load: (_) async => CapabilityRequest.fromJson(_dto(
          status: 'completed',
          settledBy: {'kind': 'console', 'userId': 'u1', 'name': 'Ana'},
          outcome: 'the MCP server "Linear" is attached'))!,
      open: () async {},
    )));
    await tester.pump();
    expect(find.text('Completed by Ana'), findsOneWidget);
    expect(find.text('What changed: the MCP server "Linear" is attached'), findsOneWidget);
  });

  testWidgets('a request that can not be read still shows the ask; coming back reads it again', (tester) async {
    var fail = true;
    var loads = 0;
    await tester.pumpWidget(_host(CapabilityCardView(
      item: _item(),
      load: (_) async {
        loads++;
        if (fail) throw ApiException(404);
        return CapabilityRequest.fromJson(_dto(status: 'completed'))!;
      },
      open: () async {},
    )));
    await tester.pump();
    expect(find.text('add the MCP server "Linear"'), findsOneWidget);
    expect(find.text("Couldn't load where this request stands."), findsOneWidget);
    expect(find.text('Open in console'), findsOneWidget);

    // Back from the console, where it was completed.
    fail = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(loads, 2);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('Open in console'), findsNothing);
  });
}
