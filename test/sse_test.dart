import 'dart:convert';

import 'package:agentconnect/core/streaming/live_updates.dart';
import 'package:agentconnect/core/streaming/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Stream<List<int>> chunks(List<String> parts) =>
    Stream.fromIterable(parts.map(utf8.encode));

void main() {
  test('parses events, comments and split chunks', () async {
    final events = await parseSse(chunks([
      ': connected\n\n',
      'event: session-state\nda',
      'ta: {"sessionId":"s1","state":"idle"}\n\n',
      'event: session\r\ndata: {"a":1}\r\ndata: more\r\n\r\n',
      'data: plain\n\n',
    ])).toList();
    expect(events.length, 3);
    expect(events[0].event, 'session-state');
    expect(events[1].data, '{"a":1}\nmore');
    expect(events[2].event, 'message');
  });

  test('decodes live events', () {
    final e = decodeLiveEvent(const SseEvent(
        'session-state', '{"sessionId":"s1","agentId":"a","state":"idle","ts":1}'));
    expect(e?.sessionId, 's1');
    expect(e?.state, 'idle');
    expect(decodeLiveEvent(const SseEvent('ping', '{}')), isNull);
    expect(decodeLiveEvent(const SseEvent('session', 'not json'))?.kind, 'session');
  });
}
