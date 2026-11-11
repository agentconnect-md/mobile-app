import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/auth/native.dart';
import 'package:agentconnect/core/share_links.dart';
import 'package:agentconnect/features/chat/bubbles.dart';
import 'package:agentconnect/features/sessions/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

const env = AppEnv(
  name: 'Test',
  apiBase: 'https://api.example.test/v1',
  callbackHost: 'console.example.test',
  callbackPath: '/mobile/oauth/callback',
  urlScheme: 'agentconnect-test',
);

void main() {
  test('parses console session links', () {
    final a = parseConsoleLink('https://console.example.test/acme/sessions/s-1#msg=42', env)!;
    expect(a.slug, 'acme');
    expect(a.sessionId, 's-1');
    expect(a.seq, 42);
    expect(a.thread, isNull);

    final b = parseConsoleLink('https://console.example.test/acme/sessions/s-1?thread=root-9#msg=7', env)!;
    expect(b.thread, 'root-9');
    expect(b.seq, 7);

    final c = parseConsoleLink('https://Console.Example.Test/acme/sessions/s-1?fill=f-1', env)!;
    expect(c.fill, 'f-1');
    expect(c.seq, isNull);

    expect(parseConsoleLink('https://console.example.test/acme/sessions/s-1#msg=x', env)!.seq, isNull);
    // Not this console, not a session page, or not https.
    expect(parseConsoleLink('https://evil.example/acme/sessions/s-1', env), isNull);
    expect(parseConsoleLink('https://console.example.test/acme/agents/a-1', env), isNull);
    expect(parseConsoleLink('https://console.example.test/mobile/oauth/callback?code=x', env), isNull);
    expect(parseConsoleLink('http://console.example.test/acme/sessions/s-1', env), isNull);
  });

  test('transcript messages carry the seq a link names', () {
    final entries = entriesFromTranscript(buildTranscript([
      ApiMessage.fromJson({'seq': 3, 'sender': 'u', 'kind': 'text', 'text': 'hi'}),
      ApiMessage.fromJson({'seq': 4, 'sender': 'a', 'kind': 'text', 'text': 'hello'}),
    ], {'a'}));
    expect(entries.map(entrySeq), [3, 4]);
    expect(entrySeq(const UserEntry('live', null)), isNull);
  });

  test('a thread link pages back until its message, not just the root', () {
    List<TranscriptItem> items(List<(int, String?)> rows) => buildTranscript([
          for (final (seq, post) in rows)
            ApiMessage.fromJson({'seq': seq, 'sender': 'u', 'kind': 'text', 'text': 'm$seq', 'postId': post}),
        ], {'a'});
    // The root (seq 2) is on the newest page with replies from seq 40 on.
    final newest = items([(2, 'root'), (40, null), (41, null)]);
    expect(threadReaches(newest, 'root', 12), isFalse);
    expect(threadReaches(newest, 'root', 41), isTrue);
    expect(threadReaches(newest, 'root', 2), isTrue);
    expect(threadReaches(items([(2, 'root'), (10, null), (40, null)]), 'root', 12), isTrue);
  });

  test('org slug', () {
    expect(Org.fromJson({'id': 'o', 'name': 'Acme', 'slug': 'acme'}).slug, 'acme');
  });
}
