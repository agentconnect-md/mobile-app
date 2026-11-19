import 'dart:convert';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/core/webchat/chat_controller.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:agentconnect/features/chat/chat_view.dart';
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

const _agent = '5f0c2f0e-6a57-4d0f-8a55-0a1d2c3b4e5f';

/// A connected chat; [sent] collects the decoded frames it writes.
ChatController _chat(List<Map<String, dynamic>> sent) =>
    ChatController(client: ApiClient('https://api.example.test/v1', _NoTokens()), orgId: 'o', agentId: _agent)
      ..debugConnect((s) => sent.add(jsonDecode(s) as Map<String, dynamic>));

/// The connection drops and a new one opens (`ready` on it).
void _reconnect(ChatController c, List<Map<String, dynamic>> sent, {int participants = 1}) {
  c.debugClosed();
  c.debugConnect((s) => sent.add(jsonDecode(s) as Map<String, dynamic>));
  c.debugFrame(_ready(participants: participants));
}

// Server frames, in the shapes the relay sends (packages/relay/src/relay-browser-connection.ts,
// packages/protocol/src/frames/webchat.ts; the daemon stamps `agentId` and `done.lastIndex`).
String _ready({int participants = 1}) => jsonEncode({
      'type': 'ready',
      'conversationId': 'c',
      'participants': [
        for (var i = 0; i < participants; i++) {'agentId': 'a$i', 'name': 'A$i'}
      ],
      'features': <String>[],
    });

String _ack(String turnId, {bool accepted = true, String? reason, bool steered = false}) => jsonEncode({
      'type': 'ack',
      'ack': {
        'accepted': accepted,
        'turnId': turnId,
        'agentId': _agent,
        'reason': ?reason,
        if (steered) 'steered': true,
      }
    });

/// `resumed`: an accepted verdict and the `stream_*` refusals name the turn;
/// `stream_not_found` and `no_agent` don't.
String _resumed(String? turnId, {bool accepted = true, String? reason}) => jsonEncode({
      'type': 'resumed',
      'ack': {'accepted': accepted, 'turnId': ?turnId, 'agentId': _agent, 'reason': ?reason}
    });

String _status(String turnId, {bool steerable = true}) => jsonEncode({
      'type': 'output',
      'output': {
        'conversationId': 'c',
        'turnId': turnId,
        'agentId': _agent,
        'index': 0,
        'status': {'model': 'm', if (steerable) 'steerable': true}
      }
    });

String _text(String turnId, int i, String text) => jsonEncode({
      'type': 'output',
      'output': {
        'conversationId': 'c',
        'turnId': turnId,
        'agentId': _agent,
        'index': i,
        'event': {'kind': 'message', 'text': text, 'segmentId': 's'}
      }
    });

String _done(String turnId, {int? lastIndex, String stopReason = 'end_turn'}) => jsonEncode({
      'type': 'done',
      'done': {
        'conversationId': 'c',
        'turnId': turnId,
        'agentId': _agent,
        'stopReason': stopReason,
        'lastIndex': ?lastIndex,
      }
    });

/// Starts a turn and returns its id, acked.
String _startTurn(ChatController c, List<Map<String, dynamic>> sent, String text) {
  c.send(text);
  final id = sent.last['turnId'] as String;
  c.debugFrame(_ack(id));
  return id;
}

List<String> _agentTexts(ChatController c) =>
    [for (final i in c.items) if (i.kind == LiveKind.agent) i.text];

List<Map<String, dynamic>> _resumes(List<Map<String, dynamic>> sent) =>
    [for (final f in sent) if (f['type'] == 'resume') f];

void main() {
  test('decodes the resume verdict; the orderer names the last index applied', () {
    final ok = decodeFrame(_resumed('t')) as ResumedFrame;
    expect((ok.accepted, ok.turnId, ok.reason), (true, 't', null));
    final no = decodeFrame(_resumed(null, accepted: false, reason: 'stream_not_found')) as ResumedFrame;
    expect((no.accepted, no.turnId, no.reason), (false, null, 'stream_not_found'));

    final o = OutputOrderer();
    expect(o.applied, -1);
    o.add(decodeFrame(_text('t', 0, 'a')) as OutputFrame);
    o.add(decodeFrame(_text('t', 1, 'b')) as OutputFrame);
    expect(o.applied, 1);
    // A frame past a gap is held, not applied.
    o.add(decodeFrame(_text('t', 3, 'd')) as OutputFrame);
    expect(o.applied, 1);
  });

  group('reconnect mid-turn', () {
    test('resumes the running turn after the last output applied, and shows the replay once', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t = _startTurn(c, sent, 'go');
      c.debugFrame(_status(t, steerable: false));
      c.debugFrame(_text(t, 1, 'Hello'));
      c.debugFrame(_text(t, 2, ', wor'));

      c.debugClosed();
      expect((c.conn, c.busy), (ChatConn.lost, true));
      c.debugConnect((s) => sent.add(jsonDecode(s) as Map<String, dynamic>));
      c.debugFrame(_ready());

      expect(sent, hasLength(2));
      // Exactly the relay's `resume` op; no `agentId` means the conversation's agent.
      expect(sent[1], {'type': 'resume', 'turnId': t, 'generation': 1, 'afterIndex': 2});
      expect((c.conn, c.busy), (ChatConn.ready, true));

      // A replay that overlaps what is already shown, then the rest.
      c.debugFrame(_text(t, 2, ', wor'));
      c.debugFrame(_text(t, 3, 'ld'));
      c.debugFrame(_resumed(t));
      c.debugFrame(_text(t, 4, '!'));
      expect(_agentTexts(c), ['Hello, world!']);
      expect(c.busy, isTrue);
      expect(c.note, isNull);

      c.debugFrame(_done(t, lastIndex: 4));
      expect(c.busy, isFalse);
      expect(c.note, isNull);
      expect(sent, hasLength(2));
      c.dispose();
    });

    test('fills a hole the lost connection left, without repeating what was held behind it', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t = _startTurn(c, sent, 'go');
      c.debugFrame(_text(t, 0, 'a'));
      c.debugFrame(_text(t, 2, 'c'));
      expect(_agentTexts(c), ['a']);
      _reconnect(c, sent);
      expect(sent.last['afterIndex'], 0);
      c.debugFrame(_text(t, 1, 'b'));
      c.debugFrame(_text(t, 2, 'c'));
      c.debugFrame(_text(t, 3, 'd'));
      expect(_agentTexts(c), ['abcd']);
      c.dispose();
    });

    test('a turn that ended meanwhile comes back whole and ends', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t = _startTurn(c, sent, 'go');
      c.debugFrame(_text(t, 0, 'par'));
      _reconnect(c, sent);
      // The daemon replays before it answers: the rest, the `done`, then the verdict.
      c.debugFrame(_text(t, 1, 'tial'));
      c.debugFrame(_done(t, lastIndex: 1));
      expect(c.busy, isFalse);
      expect(_agentTexts(c), ['partial']);
      c.debugFrame(_resumed(t));
      expect((c.busy, c.note), (false, null));
      // The person can send again, as a turn of its own.
      c.send('next');
      expect(sent.last['text'], 'next');
      expect(c.busy, isTrue);
      c.dispose();
    });

    test('each resume of a turn carries a higher generation', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t = _startTurn(c, sent, 'go');
      _reconnect(c, sent);
      c.debugFrame(_resumed(t));
      c.debugFrame(_text(t, 0, 'a'));
      _reconnect(c, sent);
      expect(_resumes(sent).map((f) => (f['generation'], f['afterIndex'])), [(1, -1), (2, 0)]);
      // A second `ready` on the same connection asks for nothing.
      c.debugFrame(_ready());
      expect(_resumes(sent), hasLength(2));
      // The next turn counts from one again.
      c.debugFrame(_done(t));
      final t2 = _startTurn(c, sent, 'again');
      _reconnect(c, sent);
      expect(sent.last, {'type': 'resume', 'turnId': t2, 'generation': 1, 'afterIndex': -1});
      c.dispose();
    });

    test('a message queued after the reconnect goes out when the resumed turn ends', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t = _startTurn(c, sent, 'go');
      _reconnect(c, sent);
      c.debugFrame(_resumed(t));
      c.send('then this');
      expect(c.queue.single.text, 'then this');
      c.debugFrame(_done(t));
      expect(sent.last['text'], 'then this');
      expect(c.queue, isEmpty);
      c.dispose();
    });

    test('a turn the daemon no longer holds is over: it ends without a note', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t = _startTurn(c, sent, 'go');
      c.debugFrame(_text(t, 0, 'par'));
      c.debugFrame(_text(t, 1, 'tial'));
      var ended = 0;
      var wasBusy = c.busy;
      // What the chat view does to reload the transcript.
      c.addListener(() {
        if (wasBusy && !c.busy) ended++;
        wasBusy = c.busy;
      });
      _reconnect(c, sent);
      expect(c.busy, isTrue);
      c.debugFrame(_resumed(null, accepted: false, reason: 'stream_not_found'));
      expect((c.busy, c.statusLine, c.note), (false, null, null));
      expect(ended, 1);
      expect(sent, hasLength(2), reason: 'nothing is sent again');
      c.send('next');
      expect(sent.last['text'], 'next');
      c.dispose();
    });

    for (final reason in ['stream_gap', 'stream_stale', 'stream_cursor_invalid']) {
      test('a refused resume ($reason) ends the turn with a note', () {
        final sent = <Map<String, dynamic>>[];
        final c = _chat(sent);
        final t = _startTurn(c, sent, 'go');
        c.debugFrame(_text(t, 0, 'par'));
        _reconnect(c, sent);
        c.debugFrame(_resumed(t, accepted: false, reason: reason));
        expect(c.busy, isFalse);
        expect(c.statusLine, isNull);
        expect(c.note!.kind, ComposerNoteKind.turnLost);
        // What had arrived stays until the reloaded transcript replaces it.
        expect(_agentTexts(c), ['par']);
        expect(sent, hasLength(2), reason: 'nothing is sent again');
        // Sending works, and clears the note.
        c.send('next');
        expect(sent.last['text'], 'next');
        expect(c.note, isNull);
        c.dispose();
      });
    }

    test('a resume the relay cannot deliver (error frame) ends the turn with a note', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      _startTurn(c, sent, 'go');
      _reconnect(c, sent);
      c.debugFrame('{"type":"error","message":"agent daemon offline"}');
      expect(c.busy, isFalse);
      expect(c.note!.kind, ComposerNoteKind.turnLost);
      c.dispose();
    });

    test('a verdict for another turn, or one nobody waits for, changes nothing', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t = _startTurn(c, sent, 'go');
      c.debugFrame(_resumed(t, accepted: false, reason: 'stream_gap'));
      expect((c.busy, c.note), (true, null), reason: 'no resume was sent');
      _reconnect(c, sent);
      c.debugFrame(_resumed('0b0e7c1e-58a1-4b0e-9f0e-2f6f0a9d3c11', accepted: false, reason: 'stream_gap'));
      expect((c.busy, c.note), (true, null), reason: 'an older turn\'s verdict');
      c.debugFrame(_done(t));
      c.dispose();
    });

    test('in a room the turn ends with a note instead: its streams cannot be told apart here', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent)..debugFrame(_ready(participants: 2));
      _startTurn(c, sent, 'go');
      _reconnect(c, sent, participants: 2);
      expect(_resumes(sent), isEmpty);
      expect(sent, hasLength(1));
      expect(c.busy, isFalse);
      expect(c.note!.kind, ComposerNoteKind.turnLost);
      c.dispose();
    });
  });

  group('a turn nobody answered', () {
    test('is sent again on the next connection under the same turn id, once', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      c.send('go');
      final frame = sent.single;
      _reconnect(c, sent);
      expect(sent, hasLength(2));
      expect(sent[1], frame);
      c.debugFrame(_ready());
      expect(sent, hasLength(2), reason: 'not twice on one connection');
      // The first copy never arrived: this one is the turn.
      final t = frame['turnId'] as String;
      c.debugFrame(_ack(t));
      c.debugFrame(_text(t, 0, 'hi'));
      c.debugFrame(_done(t, lastIndex: 0));
      expect((c.busy, c.note), (false, null));
      expect(_agentTexts(c), ['hi']);
      expect(sent, hasLength(2));
      c.dispose();
    });

    test('answered busy, attaches to the turn the first copy started', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      c.send('go');
      final t = sent.single['turnId'] as String;
      _reconnect(c, sent);
      c.debugFrame(_ack(t, accepted: false, reason: 'busy'));
      expect(c.busy, isTrue);
      expect(sent.last, {'type': 'resume', 'turnId': t, 'generation': 1, 'afterIndex': -1});
      c.debugFrame(_text(t, 0, 'hi'));
      c.debugFrame(_resumed(t));
      expect((c.busy, c.note), (true, null));
      expect(_agentTexts(c), ['hi']);
      c.debugFrame(_done(t, lastIndex: 0));
      expect(c.busy, isFalse);
      c.dispose();
    });

    test('answered busy with no stream of its own, was refused: the agent is busy', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      c.send('go');
      final t = sent.single['turnId'] as String;
      _reconnect(c, sent);
      c.debugFrame(_ack(t, accepted: false, reason: 'busy'));
      c.debugFrame(_resumed(null, accepted: false, reason: 'stream_not_found'));
      expect(c.busy, isFalse);
      expect(c.note!.kind, ComposerNoteKind.turnBusy);
      c.dispose();
    });

    test('is not sent again once a copy could run it twice: it is resumed instead', () {
      final sent = <Map<String, dynamic>>[];
      var now = DateTime(2026, 11, 19, 12);
      final c = _chat(sent)..clock = () => now;
      c.send('go');
      final t = sent.single['turnId'] as String;
      // Long enough for the daemon to have run the turn and dropped its stream.
      now = now.add(const Duration(minutes: 6));
      _reconnect(c, sent);
      expect(sent.last, {'type': 'resume', 'turnId': t, 'generation': 1, 'afterIndex': -1});
      expect(sent.where((f) => f['text'] == 'go'), hasLength(1));
      c.debugFrame(_resumed(null, accepted: false, reason: 'stream_not_found'));
      expect(c.busy, isFalse);
      expect(c.note!.kind, ComposerNoteKind.turnUnconfirmed);
      c.dispose();
    });

    test('sent before the chat connected goes out once, on the connection that opens', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent)..debugClosed();
      c.send('go');
      expect(sent, isEmpty);
      c.debugConnect((s) => sent.add(jsonDecode(s) as Map<String, dynamic>));
      c.debugFrame(_ready());
      expect(sent.single['text'], 'go');
      c.dispose();
    });

    test('a first send answered busy is refused as before, with no resume', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      c.send('go');
      c.debugFrame(_ack(sent.single['turnId'] as String, accepted: false, reason: 'busy'));
      expect(c.busy, isFalse);
      expect(sent, hasLength(1));
      c.dispose();
    });
  });

  group('resync (the daemon relinked to the relay)', () {
    const resync = '{"type":"resync","agentIds":["$_agent"]}';

    test('asks for the running turn again on the same connection', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t = _startTurn(c, sent, 'go');
      c.debugFrame(_text(t, 0, 'a'));
      c.debugFrame(resync);
      expect(sent.last, {'type': 'resume', 'turnId': t, 'generation': 1, 'afterIndex': 0});
      c.debugFrame(_text(t, 1, 'b'));
      c.debugFrame(_resumed(t));
      expect(c.busy, isTrue);
      expect(_agentTexts(c), ['ab']);
      c.dispose();
    });

    test('"not now" verdicts and an error leave the turn running; a gap ends it', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t = _startTurn(c, sent, 'go');
      c.debugFrame(resync);
      c.debugFrame(_resumed(null, accepted: false, reason: 'no_agent'));
      expect((c.busy, c.note), (true, null));
      c.debugFrame(resync);
      c.debugFrame(_resumed(t, accepted: false, reason: 'stream_stale'));
      expect((c.busy, c.note), (true, null));
      c.debugFrame(resync);
      c.debugFrame('{"type":"error","message":"agent daemon offline"}');
      expect((c.busy, c.note), (true, null));
      c.debugFrame(resync);
      expect(sent.last['generation'], 4);
      c.debugFrame(_resumed(t, accepted: false, reason: 'stream_gap'));
      expect(c.busy, isFalse);
      expect(c.note!.kind, ComposerNoteKind.turnLost);
      c.dispose();
    });

    test('is ignored with nothing running, or before the turn is answered', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      c.debugFrame(resync);
      expect(sent, isEmpty);
      c.send('go');
      c.debugFrame(resync);
      expect(sent, hasLength(1));
      c.dispose();
    });
  });

  test('a steer the daemon ran as its own turn is resumed when its stream is on a lost connection', () {
    final sent = <Map<String, dynamic>>[];
    final c = _chat(sent);
    final t1 = _startTurn(c, sent, 'one');
    c.debugFrame(_status(t1));
    c.send('two');
    final steer = sent[1];
    final t2 = steer['turnId'] as String;
    expect(steer['steer'], isTrue);

    // Nobody answered the steer: on the new connection it goes out again and
    // the running turn is resumed.
    _reconnect(c, sent);
    expect(sent[2], steer);
    expect(sent[3], {'type': 'resume', 'turnId': t1, 'generation': 1, 'afterIndex': 0});
    c.debugFrame(_resumed(t1));
    // The first copy had become a turn of its own, streaming to the old connection.
    c.debugFrame(_ack(t2));
    expect(sent, hasLength(4));
    c.debugFrame(_done(t1, lastIndex: 0));
    expect(c.busy, isTrue);
    expect(sent.last, {'type': 'resume', 'turnId': t2, 'generation': 1, 'afterIndex': -1});
    c.debugFrame(_text(t2, 0, 'reply to two'));
    c.debugFrame(_resumed(t2));
    c.debugFrame(_done(t2, lastIndex: 0));
    expect((c.busy, c.note), (false, null));
    expect(_agentTexts(c), ['reply to two']);
    c.dispose();
  });

  test('a steer run as its own turn on this connection needs no resume', () {
    final sent = <Map<String, dynamic>>[];
    final c = _chat(sent);
    final t1 = _startTurn(c, sent, 'one');
    c.debugFrame(_status(t1));
    c.send('two');
    final t2 = sent[1]['turnId'] as String;
    c.debugFrame(_ack(t2));
    c.debugFrame(_done(t1, lastIndex: 0));
    expect(c.busy, isTrue);
    expect(_resumes(sent), isEmpty);
    c.debugFrame(_done(t2));
    c.dispose();
  });

  testWidgets('the note says the reply could not be resumed, and can be dismissed', (t) async {
    final sent = <Map<String, dynamic>>[];
    final c = _chat(sent);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
          body: ListenableBuilder(
              listenable: c, builder: (_, _) => ComposerNoteView(chat: c, agentName: 'Atlas'))),
    ));
    final turn = _startTurn(c, sent, 'go');
    _reconnect(c, sent);
    c.debugFrame(_resumed(turn, accepted: false, reason: 'stream_gap'));
    await t.pump();
    expect(
        find.text('The reply could not be resumed after reconnecting. Atlas may still be working. '
            'Reopen this conversation later to see the rest.'),
        findsOneWidget);
    await t.tap(find.byTooltip('Dismiss'));
    await t.pump();
    expect(find.textContaining('could not be resumed'), findsNothing);
    // The lost connection scheduled a retry: end it before the test does.
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
