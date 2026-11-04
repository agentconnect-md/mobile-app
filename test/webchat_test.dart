import 'dart:convert';

import 'package:agentconnect/core/webchat/chat_controller.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:agentconnect/features/chat/bubbles.dart';
import 'package:flutter_test/flutter_test.dart';

String out(int i, Map<String, dynamic> ev) => jsonEncode({
      'type': 'output',
      'output': {'turnId': 't', 'index': i, 'event': ev}
    });

void main() {
  test('decodes server frames', () {
    expect(decodeFrame('{"type":"ready","conversationId":"c"}'), isA<ReadyFrame>());
    final ack = decodeFrame('{"type":"ack","ack":{"accepted":true,"turnId":"t"}}') as AckFrame;
    expect(ack.turnId, 't');
    final m = decodeFrame(out(1, {'kind': 'message', 'text': 'hi', 'segmentId': 's'})) as OutputFrame;
    expect((m.event as MessageEvent).text, 'hi');
    final d = decodeFrame('{"type":"done","done":{"turnId":"t","stopReason":"end_turn"}}') as DoneFrame;
    expect(d.stopReason, 'end_turn');
    expect(decodeFrame('{"type":"error","message":"x"}'), isA<ErrorFrame>());
    expect(decodeFrame('{"type":"resync"}'), isA<OtherFrame>());
    expect(decodeFrame('garbage'), isNull);
    final u = decodeFrame(out(2, {'kind': 'app'})) as OutputFrame;
    expect(u.event, isA<UnsupportedEvent>());
    final p = decodeFrame(out(3, {'kind': 'permission', 'requestId': 'r', 'tool': 'bash', 'detail': 'ls'})) as OutputFrame;
    expect((p.event as PermissionEvent).requestId, 'r');
  });

  test('orders duplicated and out-of-order output by index', () {
    final o = OutputOrderer();
    OutputFrame f(int i) => decodeFrame(out(i, {'kind': 'notice', 'text': '$i'})) as OutputFrame;
    expect(o.add(f(1)).map((x) => x.index), [1]);
    expect(o.add(f(3)), isEmpty);
    expect(o.add(f(2)).map((x) => x.index), [2, 3]);
    expect(o.add(f(2)), isEmpty);
    expect(o.add(f(5)), isEmpty);
    expect(o.flush().map((x) => x.index), [5]);
  });

  test('turn ids are UUID v4', () {
    final re = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    expect(re.hasMatch(newTurnId()), isTrue);
    expect(newTurnId(), isNot(newTurnId()));
  });

  test('a live turn is settled once the transcript has it with a reply', () {
    final live = [
      LiveItem(LiveKind.user, 'Reply with ok.'),
      LiveItem(LiveKind.notice, 'Starting agent…'),
      LiveItem(LiveKind.agent, 'ok'),
    ];
    const before = [UserEntry('Earlier', 'me'), AgentEntry('Two')];
    const sentOnly = [...before, UserEntry('Reply with ok.', 'me')];
    const answered = [...sentOnly, AgentEntry('ok')];
    expect(transcriptHasLiveTurn(before, live), isFalse);
    // Saved before the reply: keep the live copy, it holds the answer.
    expect(transcriptHasLiveTurn(sentOnly, live), isFalse);
    expect(transcriptHasLiveTurn(answered, live), isTrue);
    expect(transcriptHasLiveTurn(answered, const []), isFalse);
  });
}
