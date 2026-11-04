import 'dart:convert';

import 'package:agentconnect/core/api/approvals.dart';
import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/auth/account.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('conversation page decodes and maps platforms', () {
    const json = '''
{"conversations":[{"key":"k1","platform":"hook","channel":"github:1","thread":"7",
 "sessions":[{"sessionId":"s1","agentId":"a1","agentName":"review-bot","title":"Fix the thing",
 "status":"idle","lastActivityAt":"2026-01-02T03:04:05.000Z","threadUrl":"https://example.test/t/7",
 "activityState":"awaiting_permission","sessionKey":{"platform":"hook"}}],"memberSessionIds":["s1"]}],
 "total":1,"nextCursor":"abc","accessSyncDegraded":true,"accessIssues":[]}''';
    final p = ConversationPage.fromJson(jsonDecode(json));
    expect(p.conversations.single.source, 'github');
    expect(p.conversations.single.state, ActivityState.awaiting);
    expect(p.conversations.single.title, 'Fix the thing');
    expect(p.nextCursor, 'abc');
    expect(p.degraded, isTrue);
  });

  test('a webchat session resumes its conversation; other origins and tasks do not', () {
    SessionRow row(String platform, {bool sub = false}) => SessionRow.fromJson({
          'sessionId': 's',
          'agentId': 'a',
          'sessionKey': {'platform': platform, 'channel': 'c-1', 'thread': 't'},
          if (sub) 'subsession': true,
        });
    expect(row('webchat').webchatConversationId, 'c-1');
    expect(row('webchat', sub: true).webchatConversationId, isNull);
    expect(row('hook').webchatConversationId, isNull);
    expect(row('slack').webchatConversationId, isNull);
  });

  test('messages are sorted by seq', () {
    final p = MessagePage.fromJson({
      'messages': [
        {'seq': 9, 'sender': 'a', 'kind': 'text', 'text': 'b'},
        {'seq': 3, 'sender': 'a', 'kind': 'tool', 'text': 'x', 'toolCallId': 't', 'bodyTruncated': true},
      ],
      'nextCursor': null,
    });
    expect(p.messages.map((m) => m.seq), [3, 9]);
    expect(p.messages.first.bodyTruncated, isTrue);
  });

  test('missing fields do not crash', () {
    expect(() => ConversationPage.fromJson({}), returnsNormally);
    expect(ConversationPage.fromJson(null).conversations, isEmpty);
    expect(() => Me.fromJson({}), throwsFormatException);
  });

  test('approval decoding and dedupe by id', () {
    final j = {
      'requests': [
        {'id': 'r1', 'agentId': 'a', 'sessionId': 's', 'createdAt': '2026-01-01T00:00:00Z',
         'command': 'ls', 'status': 'pending',
         'options': [{'optionId': 'o1', 'name': 'Allow once', 'kind': 'allow_once'},
                     {'optionId': 'o2', 'name': 'Always', 'kind': 'allow_always'}]},
        {'id': 'r1', 'agentId': 'a', 'sessionId': 's', 'command': 'ls', 'status': 'pending'},
        {'id': 'r2', 'agentId': 'a', 'sessionId': 's', 'createdAt': '2026-01-02T00:00:00Z', 'status': 'pending'},
      ]
    };
    final all = asList(j['requests']).map(Approval.fromJson).toList();
    final d = dedupeApprovals(all);
    expect(d.map((a) => a.id), ['r2', 'r1']);
    expect(d.last.options.last.isAlways, isTrue);
    expect(d.last.expiresAt, isNull);
  });

  test('webchat grant builds a wss url', () {
    final g = WebchatGrant.fromJson({
      'token': 'tok', 'relayUrl': 'https://relay.example.test', 'conversationId': 'c1'});
    final u = g.socketUri();
    expect(u.scheme, 'wss');
    expect(u.path, '/webchat');
    expect(u.queryParameters['conversation_id'], 'c1');
  });

  test('api base normalisation', () {
    expect(normalizeApiBase('api.example.test/v1/'), 'https://api.example.test/v1');
    expect(normalizeApiBase('api.example.test'), 'https://api.example.test/v1');
    expect(normalizeApiBase('https://api.example.test/'), 'https://api.example.test/v1');
    expect(normalizeApiBase('http://api.example.test/v1'), isNull);
    expect(normalizeApiBase('https://api.example.test/v1?x=1'), isNull);
    expect(normalizeApiBase('nonsense'), isNull);
  });
}
