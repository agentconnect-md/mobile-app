import 'dart:convert';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/core/webchat/chat_controller.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoTokens implements TokenProvider {
  @override
  Future<String> accessToken() async => 'x';
  @override
  Future<bool> refreshAfter401(String rejected) async => false;
  @override
  bool get canWrite => true;
}

String _out(String turnId, int i, Map<String, dynamic> ev) => jsonEncode({
      'type': 'output',
      'output': {'turnId': turnId, 'index': i, 'event': ev}
    });

Map<String, dynamic> _notice(String text, {bool standing = false}) =>
    {'kind': 'notice', 'text': text, if (standing) 'standing': true};

ChatController _chat() =>
    ChatController(client: ApiClient('https://api.example.test/v1', _NoTokens()), orgId: 'o', agentId: 'a')
      ..debugConnect((_) {});

List<String> _notices(ChatController c) =>
    [for (final i in c.items) if (i.kind == LiveKind.notice) i.text];

/// A notice is the turn's one current wait unless it is standing, as in the
/// console (`LegacyPlaygroundProvider.tsx`, "One current wait per turn").
void main() {
  test('decodes standing', () {
    final wait = (decodeFrame(_out('t', 0, _notice('Starting agent…'))) as OutputFrame).event as NoticeEvent;
    expect(wait.standing, isFalse);
    final kept = (decodeFrame(_out('t', 1, _notice('Declined', standing: true))) as OutputFrame).event as NoticeEvent;
    expect(kept.standing, isTrue);
  });

  test('startup phases show one line, the latest', () {
    final c = _chat();
    final phases = [
      'Preparing workspace…', 'Starting sandbox…', 'Preparing workspace…', 'Starting agent…',
      'Starting sandbox…', 'Starting agent…', 'Starting sandbox…', 'Starting agent…',
    ];
    for (var i = 0; i < phases.length; i++) {
      c.debugFrame(_out('t', i, _notice(phases[i])));
      expect(_notices(c), [phases[i]]);
    }
  });

  test('empty text clears the wait', () {
    final c = _chat();
    c.debugFrame(_out('t', 0, _notice('Starting sandbox…')));
    c.debugFrame(_out('t', 1, _notice('')));
    expect(c.items, isEmpty);
  });

  test('the first output ends the wait', () {
    for (final event in [
      {'kind': 'message', 'text': '1', 'segmentId': 's'},
      {'kind': 'thinking', 'text': 'hm'},
      {'kind': 'tool_call', 'toolCallId': 'c1', 'title': 'Bash', 'status': 'pending'},
    ]) {
      final c = _chat();
      c.debugFrame(_out('t', 0, _notice('Starting agent…')));
      c.debugFrame(_out('t', 1, event));
      expect(_notices(c), isEmpty, reason: '${event['kind']}');
    }
  });

  test('a standing notice stays, and does not end the wait', () {
    final c = _chat();
    c.debugFrame(_out('t', 0, _notice('Starting sandbox…')));
    c.debugFrame(_out('t', 1, _notice('The answer was refused', standing: true)));
    expect(_notices(c), ['Starting sandbox…', 'The answer was refused']);
    c.debugFrame(_out('t', 2, _notice('Starting agent…')));
    expect(_notices(c), ['The answer was refused', 'Starting agent…']);
    c.debugFrame(_out('t', 3, {'kind': 'message', 'text': 'hi', 'segmentId': 's'}));
    expect(_notices(c), ['The answer was refused']);
  });

  test('a clean end retires the wait; an error leaves it', () {
    final clean = _chat();
    clean.debugFrame(_out('t', 0, _notice('Starting agent…')));
    clean.debugFrame('{"type":"done","done":{"turnId":"t","stopReason":"end_turn"}}');
    expect(_notices(clean), isEmpty);

    final failed = _chat();
    failed.debugFrame(_out('t', 0, _notice('Starting agent…')));
    failed.debugFrame('{"type":"done","done":{"turnId":"t","stopReason":"error","error":"boom"}}');
    expect(_notices(failed), contains('Starting agent…'));
  });
}
