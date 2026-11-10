import 'dart:convert';

import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:agentconnect/features/chat/bubbles.dart';
import 'package:agentconnect/features/sessions/thread_widgets.dart';
import 'package:agentconnect/features/sessions/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

const root1 = '11111111-1111-4111-8111-111111111111';
const root2 = '22222222-2222-4222-8222-222222222222';

void main() {
  test('a roots page decodes thread marks, handed messages and footers', () {
    final p = MessagePage.fromJson({
      'messages': [
        {'seq': 2, 'sender': 'u', 'kind': 'text', 'text': 'reply', 'thread': root1},
        {'seq': 1, 'sender': 'u', 'kind': 'text', 'text': 'root', 'postId': root1},
        {'seq': 3, 'sender': 'u', 'kind': 'text', 'text': 'more', 'handedTo': root1},
      ],
      'threads': [
        {
          'rootId': root1,
          'rootExcerpt': 'Find what blocks',
          'replies': 3,
          'lastReplyAt': '2026-11-10T10:00:00.000Z',
          'lastReply': {'sender': 'a', 'senderName': 'coord', 'excerpt': 'Done'},
          'participants': [
            {'sender': 'a', 'senderName': 'coord'},
            {'sender': 'u'}
          ],
          'task': {'sessionId': 'task-1', 'title': 'Unblock api', 'state': 'open'},
          'running': true,
          'readable': true,
        },
        {'rootId': root2, 'replies': 1, 'participants': [], 'task': {'state': 'done'}, 'readable': false},
      ],
    }, roots: true);
    expect(p.roots, isTrue);
    expect(p.messages.map((m) => m.seq), [1, 2, 3]);
    expect(p.messages[1].thread, root1);
    expect(p.messages[2].handedTo, root1);
    final t = p.threads[root1]!;
    expect(t.replies, 3);
    expect(t.lastReply!.name, 'coord');
    expect(t.lastReplyExcerpt, 'Done');
    expect(t.participants.length, 2);
    expect(t.task!.sessionId, 'task-1');
    expect(t.task!.running, isTrue);
    final hidden = p.threads[root2]!;
    expect(hidden.readable, isFalse);
    expect(hidden.task!.title, isNull);
  });

  test('a flat page has no threads', () {
    final p = MessagePage.fromJson({'messages': []});
    expect(p.roots, isFalse);
    expect(p.threads, isEmpty);
  });

  test('a thread page puts the root first and carries its footer', () {
    final p = ThreadPage.fromJson({
      'rootId': root1,
      'messages': [
        {'seq': 7, 'sender': 'a', 'kind': 'text', 'text': 'answer', 'thread': root1},
        {'seq': 1, 'sender': 'u', 'kind': 'text', 'text': 'root', 'postId': root1},
      ],
      'nextCursor': 'c1',
      'summary': {'rootId': root1, 'replies': 1, 'participants': [], 'readable': true},
    });
    expect(p.messages.first.postId, root1);
    expect(p.nextCursor, 'c1');
    expect(p.summary!.replies, 1);
  });

  test('frames carry their thread; ready lists features', () {
    final r = decodeFrame(jsonEncode({
      'type': 'ready',
      'conversationId': 'c',
      'features': ['webchat-threads-v1', 3],
    })) as ReadyFrame;
    expect(r.features, [webchatThreadsFeature]);
    final o = decodeFrame(jsonEncode({
      'type': 'output',
      'output': {'turnId': 't', 'index': 1, 'thread': root1, 'event': {'kind': 'notice', 'text': 'x'}},
    })) as OutputFrame;
    expect(o.thread, root1);
    final post = decodeFrame(jsonEncode({
      'type': 'post',
      'post': {'postId': 'p', 'text': 'hi', 'author': {'kind': 'agent'}, 'thread': root1},
    })) as PostFrame;
    expect(post.thread, root1);
    final d = decodeFrame(jsonEncode({'type': 'done', 'done': {'turnId': 't', 'thread': root1}})) as DoneFrame;
    expect(d.thread, root1);
    final plain = decodeFrame('{"type":"done","done":{"turnId":"t"}}') as DoneFrame;
    expect(plain.thread, isNull);
  });

  test('the main timeline hides thread replies and draws footers and links', () {
    final page = MessagePage.fromJson({
      'messages': [
        {'seq': 1, 'sender': 'u', 'kind': 'text', 'text': 'root', 'postId': root1},
        {'seq': 2, 'sender': 'a', 'kind': 'text', 'text': 'in thread', 'thread': root1},
        {'seq': 3, 'sender': 'a', 'kind': 'tool', 'text': 'ls', 'thread': root1},
        {'seq': 4, 'sender': 'u', 'kind': 'text', 'text': 'follow-up', 'postId': root2, 'handedTo': root1},
        {'seq': 5, 'sender': 'a', 'kind': 'text', 'text': 'answer', 'postId': 'p5'},
      ],
      'threads': [
        {
          'rootId': root1,
          'rootExcerpt': 'root',
          'replies': 2,
          'participants': [],
          'task': {'sessionId': 'task-1', 'title': 'Unblock api', 'state': 'open'},
          'readable': true,
        },
      ],
    }, roots: true);
    final opened = <String>[];
    final entries = threadedEntries(buildTranscript(page.messages, {'a'}), page.threads, opened.add);
    expect(entries.map((e) => e.runtimeType), [
      UserEntry,
      ThreadFooterEntry,
      InThreadEntry, // one line for the run of rows written in the thread
      UserEntry,
      HandedEntry,
      AgentEntry,
    ]);
    final handed = entries[4] as HandedEntry;
    expect(handed.title, 'Unblock api');
    handed.onOpen();
    (entries[2] as InThreadEntry).onOpen();
    (entries[0] as UserEntry).onReplyInThread!();
    expect(opened, [root1, root1, root1]);
    // Every root offers Reply in thread, with or without replies yet.
    expect((entries[5] as AgentEntry).onReplyInThread, isNotNull);
  });
}
