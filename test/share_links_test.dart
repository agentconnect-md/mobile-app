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

  test('org slug', () {
    expect(Org.fromJson({'id': 'o', 'name': 'Acme', 'slug': 'acme'}).slug, 'acme');
  });
}
