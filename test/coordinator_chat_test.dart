import 'dart:convert';
import 'dart:io';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/core/coordinator.dart';
import 'package:agentconnect/core/org_data.dart';
import 'package:agentconnect/core/webchat/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoTokens implements TokenProvider {
  @override
  Future<String> accessToken() async => 'x';
  @override
  Future<bool> refreshAfter401(String rejected) async => false;
  @override
  bool get canWrite => true;
}

const _agentId = '5f0c2f0e-6a57-4d0f-8a55-0a1d2c3b4e5f';
const _conv = '7d1e0c55-1b2a-4c3d-9e8f-0a1b2c3d4e5f';

// Anonymized shapes of GET /orgs/{org}/agents and /daemons rows.
Agent _agent({bool disabled = false, String kind = 'daemon', String? setId}) => Agent.fromJson({
      'id': _agentId,
      'name': 'helper',
      'status': 'active',
      'daemonId': 'd-1',
      'placementKind': kind,
      'setId': ?setId,
      'coordinatorDisabled': disabled,
    });

Machine _daemon(String id, {bool auto = true, bool cloud = false, String? set, String status = 'ready'}) =>
    Machine.fromJson({
      'daemonId': id,
      'name': id,
      'status': status,
      'health': 'ok',
      'cloud': cloud,
      'memberSetId': ?set,
      'capabilities': {
        'features': [if (auto) sessionModeAutoFeature, 'webchat-v1']
      },
    });

/// A local API that records each webchat mint. A coordinator mint answers
/// with the conversation (and [session] when it has one); any other mint
/// answers 503 (no relay), so a chat stops right after asking.
class _Api {
  late HttpServer server;
  final mints = <Map<String, dynamic>>[];
  String? session;
  int coordinatorStatus = 200;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final text = await utf8.decoder.bind(req).join();
      final body = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
      if (req.uri.path.endsWith('/token')) mints.add({'path': req.uri.path, ...body});
      req.response.headers.contentType = ContentType.json;
      if (body['coordinator'] == true && coordinatorStatus == 200) {
        req.response.write(jsonEncode({
          'protocol': 'legacy',
          'token': 't',
          'relayUrl': 'https://relay.example.test',
          'conversationId': _conv,
          'expiresAt': '2026-11-23T00:05:00.000Z',
          'sessionId': ?session,
        }));
      } else {
        req.response.statusCode = body['coordinator'] == true ? coordinatorStatus : 503;
        req.response.write(jsonEncode({'statusCode': req.response.statusCode, 'message': 'refused'}));
      }
      await req.response.close();
    });
  }

  ApiClient get client => ApiClient('http://127.0.0.1:${server.port}/v1', _NoTokens());
}

void main() {
  late _Api api;
  setUp(() async {
    api = _Api();
    await api.start();
  });
  tearDown(() => api.server.close(force: true));

  // The bug: chatting with an agent from the app started a plain chat; the web
  // console opens the member's coordinator conversation (mint with `coordinator: true`).
  test('chatting with a coordinator agent opens the coordinator conversation', () async {
    final target = await resolveChatTarget(api.client, 'o', _agent(), [_daemon('d-1')]);
    expect(api.mints.single['coordinator'], isTrue, reason: 'mint was ${api.mints.single}');
    expect(api.mints.single['path'], '/v1/orgs/o/agents/$_agentId/webchat/token');
    expect(target, isA<CoordinatorConversation>().having((t) => t.conversationId, 'conversationId', _conv));

    // The chat then resumes that conversation by id, not a fresh one.
    final chat = ChatController(client: api.client, orgId: 'o', agentId: _agentId, conversationId: _conv);
    await chat.connect();
    chat.dispose();
    expect(api.mints.last['conversationId'], _conv);
    expect(api.mints.last.containsKey('coordinator'), isFalse);
  });

  test('a coordinator conversation with a session opens that session', () async {
    api.session = 'sess-1';
    final target = await resolveChatTarget(api.client, 'o', _agent(), [_daemon('d-1')]);
    expect(target, isA<CoordinatorSession>().having((t) => t.sessionId, 'sessionId', 'sess-1'));
  });

  test('no coordinator: turned off, or the daemon does not read Auto → plain chat, no coordinator mint', () async {
    expect(await resolveChatTarget(api.client, 'o', _agent(disabled: true), [_daemon('d-1')]), isA<PlainChat>());
    expect(await resolveChatTarget(api.client, 'o', _agent(), [_daemon('d-1', auto: false)]), isA<PlainChat>());
    expect(await resolveChatTarget(api.client, 'o', _agent(), null), isA<PlainChat>());
    expect(api.mints, isEmpty);
  });

  test('a refused coordinator mint falls back to a plain chat, like the console', () async {
    api.coordinatorStatus = 409;
    expect(await resolveChatTarget(api.client, 'o', _agent(), [_daemon('d-1')]), isA<PlainChat>());
    expect(api.mints.single['coordinator'], isTrue);
  });

  test('capability source: own daemon, member set, or the cloud pool (an online member first)', () {
    final machines = [
      _daemon('d-1', auto: false),
      _daemon('s-1', set: 'set-a', status: 'offline', auto: false),
      _daemon('s-2', set: 'set-a'),
      _daemon('p-1', cloud: true),
    ];
    expect(capabilitySource(_agent(), machines)?.id, 'd-1');
    expect(capabilitySource(_agent(kind: 'set', setId: 'set-a'), machines)?.id, 's-2');
    expect(capabilitySource(_agent(kind: 'pool'), machines)?.id, 'p-1');
    expect(opensCoordinator(_agent(kind: 'set', setId: 'set-a'), machines), isTrue);
    expect(opensCoordinator(_agent(), machines), isFalse);
  });

  // The second cause: GET /daemons is liveness only; what a daemon can run
  // (its features) comes from GET /daemons/capabilities, which the app never
  // read, so no daemon ever looked like it reads Auto.
  test('the org data reads daemon features from /daemons/capabilities', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      await utf8.decoder.bind(req).join();
      final path = req.uri.path;
      req.response.headers.contentType = ContentType.json;
      if (path == '/v1/orgs/o/daemons') {
        req.response.write(jsonEncode([
          {'daemonId': 'd-1', 'name': 'd-1', 'status': 'ready', 'health': 'ok', 'cloud': false}
        ]));
      } else if (path == '/v1/orgs/o/daemons/capabilities') {
        req.response.write(jsonEncode([
          {
            'daemonId': 'd-1',
            'capabilities': {
              'features': [sessionModeAutoFeature, 'file-transfer-v2']
            }
          }
        ]));
      } else if (path == '/v1/orgs/o/agents') {
        req.response.write(jsonEncode([
          {'id': _agentId, 'name': 'helper', 'status': 'active', 'daemonId': 'd-1', 'placementKind': 'daemon'}
        ]));
      } else {
        req.response.statusCode = 404;
        req.response.write('{}');
      }
      await req.response.close();
    });
    final data = OrgData(ApiClient('http://127.0.0.1:${server.port}/v1', _NoTokens()), 'o', null);
    addTearDown(data.dispose);
    await data.refresh();
    expect(data.machines?.single.features, contains(sessionModeAutoFeature));
    expect(opensCoordinator(data.agent(_agentId)!, data.machines), isTrue);
  });
}
