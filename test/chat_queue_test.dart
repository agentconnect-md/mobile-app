import 'dart:convert';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/core/webchat/attachments.dart';
import 'package:agentconnect/core/webchat/chat_controller.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:agentconnect/features/chat/bubbles.dart';
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

/// A connected chat; [sent] collects the decoded frames it writes.
ChatController _chat(List<Map<String, dynamic>> sent, {String? thread}) => ChatController(
    client: ApiClient('https://api.example.test/v1', _NoTokens()), orgId: 'o', agentId: 'a', thread: thread)
  ..debugConnect((s) => sent.add(jsonDecode(s) as Map<String, dynamic>));

// Server frames, in the shapes the relay sends (packages/protocol/src/frames/webchat.ts).
String _ack(String turnId, {bool accepted = true, String? reason, bool steered = false}) => jsonEncode({
      'type': 'ack',
      'ack': {
        'accepted': accepted,
        'turnId': turnId,
        'agentId': 'a',
        'reason': ?reason,
        if (steered) 'steered': true,
      }
    });

String _done(String turnId, [String stopReason = 'end_turn']) => jsonEncode({
      'type': 'done',
      'done': {'conversationId': 'c', 'turnId': turnId, 'stopReason': stopReason}
    });

/// The status snapshot a steerable runtime sends at the start of a turn.
String _status(String turnId, {bool steerable = true}) => jsonEncode({
      'type': 'output',
      'output': {
        'turnId': turnId,
        'index': 0,
        'status': {'model': 'm', if (steerable) 'steerable': true}
      }
    });

String _text(String turnId, int i, String text, {String segment = 's'}) => jsonEncode({
      'type': 'output',
      'output': {
        'turnId': turnId,
        'index': i,
        'event': {'kind': 'message', 'text': text, 'segmentId': segment}
      }
    });

String _ready({int participants = 1, List<String> features = const []}) => jsonEncode({
      'type': 'ready',
      'conversationId': 'c',
      'participants': [
        for (var i = 0; i < participants; i++) {'agentId': 'a$i', 'name': 'A$i'}
      ],
      'features': features,
    });

/// Starts a turn and returns its id (acked, with a steerable status when asked).
String _startTurn(ChatController c, List<Map<String, dynamic>> sent, String text, {bool steerable = false}) {
  c.send(text);
  final id = sent.last['turnId'] as String;
  c.debugFrame(_ack(id));
  if (steerable) c.debugFrame(_status(id));
  return id;
}

List<String> _userTexts(ChatController c) =>
    [for (final i in c.items) if (i.kind == LiveKind.user) i.text];

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  test('decodes the ack verdict and the steerable status', () {
    final a = decodeFrame(_ack('t', steered: true)) as AckFrame;
    expect(a.steered, isTrue);
    final r = decodeFrame(_ack('t', accepted: false, reason: 'busy')) as AckFrame;
    expect((r.accepted, r.reason, r.steered), (false, 'busy', false));
    expect((decodeFrame(_status('t')) as OutputFrame).status!.steerable, isTrue);
    expect((decodeFrame(_status('t', steerable: false)) as OutputFrame).status!.steerable, isNull);
  });

  group('queue', () {
    test('messages sent while a turn runs wait, then go out one per turn, in order', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t1 = _startTurn(c, sent, 'one');
      c.send('two');
      c.send('three');
      expect(sent, hasLength(1), reason: 'nothing goes on the wire while the turn runs');
      expect(c.queue.map((q) => q.text), ['two', 'three']);
      expect(_userTexts(c), ['one'], reason: 'a queued message is not in the conversation yet');

      c.debugFrame(_done(t1));
      expect(sent, hasLength(2));
      expect(sent[1]['text'], 'two');
      expect(sent[1].containsKey('steer'), isFalse);
      expect(c.busy, isTrue);
      expect(c.queue.map((q) => q.text), ['three']);
      expect(_userTexts(c), ['one', 'two']);

      c.debugFrame(_ack(sent[1]['turnId'] as String));
      c.debugFrame(_done(sent[1]['turnId'] as String));
      expect(sent[2]['text'], 'three');
      c.debugFrame(_done(sent[2]['turnId'] as String));
      expect(c.busy, isFalse);
      expect(c.queue, isEmpty);
      expect(sent, hasLength(3));
      c.dispose();
    });

    test('a cancelled message never goes out', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t1 = _startTurn(c, sent, 'one');
      c.send('two');
      c.send('three');
      c.cancelQueued(c.queue.first);
      expect(c.queue.map((q) => q.text), ['three']);
      c.debugFrame(_done(t1));
      expect(sent.map((f) => f['text']), ['one', 'three']);
      c.dispose();
    });

    test('attachments wait with their message', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t1 = _startTurn(c, sent, 'one');
      c.send('look', images: const [
        ImageAttachment(name: 'a.png', mimeType: 'image/png', data: 'AAAA')
      ], files: const [
        UploadedFile(uploadId: 'u1', name: 'notes.pdf', mimeType: 'application/pdf', size: 3, sha256: 'h')
      ]);
      expect(c.queue.single.images.single.name, 'a.png');
      expect(c.queue.single.files.single.uploadId, 'u1');
      c.debugFrame(_done(t1));
      expect(sent[1]['text'], 'look');
      expect((sent[1]['attachments'] as List).single['name'], 'a.png');
      expect((sent[1]['files'] as List).single['uploadId'], 'u1');
      c.dispose();
    });

    test('a refused turn or an error also lets the next one out', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      c.send('one');
      c.send('two');
      c.debugFrame(_ack(sent[0]['turnId'] as String, accepted: false, reason: 'no_agent'));
      expect(sent.map((f) => f['text']), ['one', 'two']);
      c.send('three');
      c.debugFrame('{"type":"error","message":"x"}');
      expect(sent.map((f) => f['text']), ['one', 'two', 'three']);
      c.dispose();
    });

    test('is dropped with a note when the connection is lost', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      _startTurn(c, sent, 'one');
      c.send('two');
      c.send('three');
      c.debugClosed();
      expect(c.conn, ChatConn.lost);
      expect(c.queue, isEmpty);
      expect((c.note!.kind, c.note!.count), (ComposerNoteKind.queueLost, 2));
      // Back online: nothing of the dropped queue is sent.
      c.debugConnect((s) => sent.add(jsonDecode(s) as Map<String, dynamic>));
      c.debugFrame(_ready());
      c.debugFrame(_done(sent[0]['turnId'] as String));
      expect(sent.where((f) => f.containsKey('text')), hasLength(1));
      // The next send clears the note.
      c.send('four');
      expect(c.note, isNull);
      c.dispose();
    });

    test('is dropped with a note when the conversation turns read-only', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent, thread: '0b0e7c1e-58a1-4b0e-9f0e-2f6f0a9d3c11');
      c.send('one');
      c.send('two');
      expect(c.queue, hasLength(1));
      // A relay without thread support: this thread can't be written to.
      c.debugFrame(_ready());
      expect(c.conn, ChatConn.readOnly);
      expect(c.queue, isEmpty);
      expect((c.note!.kind, c.note!.count), (ComposerNoteKind.queueReadOnly, 1));
      c.dismissNote();
      expect(c.note, isNull);
      c.dispose();
    });
  });

  group('steer', () {
    test('goes into the running turn when the status says steerable, else queues', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t1 = _startTurn(c, sent, 'one');
      expect(c.steerable, isFalse);
      c.send('wait');
      expect(sent, hasLength(1));
      expect(c.queue.single.text, 'wait');
      c.cancelQueued(c.queue.single);

      c.debugFrame(_status(t1));
      expect(c.steerable, isTrue);
      c.send('use the other file');
      expect(c.queue, isEmpty);
      expect(sent, hasLength(2));
      final steer = sent[1];
      expect(steer['text'], 'use the other file');
      expect(steer['steer'], isTrue);
      expect(steer['turnId'], isNot(t1));
      final item = c.items.last;
      expect((item.kind, item.steer, item.steered), (LiveKind.user, true, false));

      c.debugFrame(_ack(steer['turnId'] as String, steered: true));
      expect(item.steered, isTrue);
      // Its own stream ends at once; the running turn goes on.
      c.debugFrame(_done(steer['turnId'] as String, 'steered_into_turn'));
      expect(c.busy, isTrue);
      c.debugFrame(_text(t1, 1, 'ok, switching', segment: 's2'));
      expect(c.items.last.text, 'ok, switching');
      c.debugFrame(_done(t1));
      expect(c.busy, isFalse);
      expect(c.steerable, isFalse);
      c.dispose();
    });

    test('is confirmed by its own done when that comes before the ack', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t1 = _startTurn(c, sent, 'one', steerable: true);
      c.send('faster');
      final id = sent[1]['turnId'] as String;
      c.debugFrame(_done(id, 'steered_into_turn'));
      expect(c.items.last.steered, isTrue);
      expect(c.busy, isTrue);
      c.debugFrame(_ack(id, steered: true));
      expect(c.busy, isTrue);
      c.debugFrame(_done(t1));
      expect(c.busy, isFalse);
      c.dispose();
    });

    test('steerability belongs to one turn', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t1 = _startTurn(c, sent, 'one', steerable: true);
      c.debugFrame(_done(t1));
      _startTurn(c, sent, 'two');
      c.send('three');
      expect(c.queue.single.text, 'three');
      expect(sent, hasLength(2));
      c.dispose();
    });

    test('never with attachments, behind a queued message, in a room or in a thread', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      _startTurn(c, sent, 'one', steerable: true);
      c.send('see', images: const [ImageAttachment(name: 'a.png', mimeType: 'image/png', data: 'AAAA')]);
      expect(c.queue, hasLength(1));
      // First in, first out: text behind a queued message waits too.
      c.send('and this');
      expect(c.queue.map((q) => q.text), ['see', 'and this']);
      expect(sent, hasLength(1));
      c.dispose();

      final sent2 = <Map<String, dynamic>>[];
      final room = _chat(sent2)..debugFrame(_ready(participants: 2));
      _startTurn(room, sent2, 'one', steerable: true);
      room.send('two');
      expect(room.queue, hasLength(1));
      room.dispose();

      final sent3 = <Map<String, dynamic>>[];
      const root = '0b0e7c1e-58a1-4b0e-9f0e-2f6f0a9d3c11';
      final thread = _chat(sent3, thread: root)..debugFrame(_ready(features: [webchatThreadsFeature]));
      thread.send('one');
      thread.debugFrame(jsonEncode({
        'type': 'output',
        'output': {
          'turnId': sent3[0]['turnId'],
          'index': 0,
          'thread': root,
          'status': {'steerable': true}
        }
      }));
      thread.send('two');
      expect(thread.queue, hasLength(1));
      expect(sent3, hasLength(1));
      thread.dispose();
    });

    test('refused as busy goes back to the queue, at the place it was sent', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t1 = _startTurn(c, sent, 'one', steerable: true);
      c.send('first');
      c.send('second');
      expect(sent.skip(1).map((f) => f['steer']), [true, true]);
      final a = sent[1]['turnId'] as String;
      final b = sent[2]['turnId'] as String;
      // The later one is refused first.
      c.debugFrame(_ack(b, accepted: false, reason: 'busy'));
      c.debugFrame(_ack(a, accepted: false, reason: 'busy'));
      expect(c.queue.map((q) => q.text), ['first', 'second']);
      expect(_userTexts(c), ['one']);
      expect(c.busy, isTrue);

      c.debugFrame(_done(t1));
      expect(sent[3]['text'], 'first');
      expect(sent[3].containsKey('steer'), isFalse);
      expect(sent[3]['turnId'], isNot(a));
      c.dispose();
    });

    test('refused otherwise is not sent, with a note', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      _startTurn(c, sent, 'one', steerable: true);
      c.send('hello?');
      c.debugFrame(_ack(sent[1]['turnId'] as String, accepted: false, reason: 'paused'));
      expect(_userTexts(c), ['one']);
      expect(c.queue, isEmpty);
      expect(c.note!.kind, ComposerNoteKind.steerPaused);
      expect(c.busy, isTrue);
      c.dispose();
    });

    test('that arrives after the turn ended runs as a turn of its own', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t1 = _startTurn(c, sent, 'one', steerable: true);
      c.send('also this');
      final id = sent[1]['turnId'] as String;
      // Accepted, not steered: the daemon runs it once the running turn is over.
      c.debugFrame(_ack(id));
      final item = c.items.last;
      expect((item.steer, item.steered), (false, false));
      c.send('queued behind it');
      expect(c.queue, hasLength(1));

      c.debugFrame(_done(t1));
      expect(c.busy, isTrue, reason: 'its turn is now the running one');
      expect(sent, hasLength(2), reason: 'the queue waits for that turn too');
      c.debugFrame(_text(id, 1, 'second answer'));
      expect(c.items.last.text, 'second answer');
      c.debugFrame(_done(id));
      expect(sent[2]['text'], 'queued behind it');
      c.dispose();
    });

    test('a verdict that comes after the turn ended still settles it', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      final t1 = _startTurn(c, sent, 'one', steerable: true);
      c.send('also this');
      final id = sent[1]['turnId'] as String;
      c.debugFrame(_done(t1));
      expect(c.busy, isFalse);
      // Nothing overtakes a message whose fate isn't known yet.
      c.send('later');
      expect(c.queue.single.text, 'later');
      expect(sent, hasLength(2));
      c.debugFrame(_ack(id));
      expect(c.busy, isTrue);
      c.debugFrame(_done(id));
      expect(sent[2]['text'], 'later');
      c.dispose();
    });

    test('unanswered, is sent again on the next connection under the same turn id', () {
      final sent = <Map<String, dynamic>>[];
      final c = _chat(sent);
      _startTurn(c, sent, 'one', steerable: true);
      c.send('hurry');
      final frame = sent[1];
      c.debugFrame(_ready());
      expect(sent, hasLength(2), reason: 'not twice on the connection it went out on');
      c.debugClosed();
      c.debugConnect((s) => sent.add(jsonDecode(s) as Map<String, dynamic>));
      c.debugFrame(_ready());
      // (The running turn is resumed after it: see chat_resume_test.dart.)
      expect(sent.where((f) => f['steer'] == true), hasLength(2));
      expect(sent[2], frame);
      c.debugFrame(_ack(frame['turnId'] as String, steered: true));
      expect(c.items.last.steered, isTrue);
      c.debugClosed();
      c.debugConnect((s) => sent.add(jsonDecode(s) as Map<String, dynamic>));
      c.debugFrame(_ready());
      expect(sent.where((f) => f['steer'] == true), hasLength(2), reason: 'a settled steer is not sent again');
      c.dispose();
    });
  });

  test('the transcript settles a live turn by the message that started it, not a steered one', () {
    final sent = <Map<String, dynamic>>[];
    final c = _chat(sent);
    final t1 = _startTurn(c, sent, 'build it', steerable: true);
    c.debugFrame(_text(t1, 1, 'on it'));
    c.send('in Rust');
    c.debugFrame(_ack(sent[1]['turnId'] as String, steered: true));
    c.debugFrame(_done(t1));
    expect(lastTurnMessage(c.items)!.text, 'build it');
    // The agent said nothing after the steered message.
    const saved = [UserEntry('build it', 'me'), AgentEntry('on it'), UserEntry('in Rust', 'me')];
    expect(transcriptHasLiveTurn(saved, c.items, seenBefore: 0), isTrue);
    c.dispose();
  });

  testWidgets('queued messages show above the box, each with a cancel control', (t) async {
    final sent = <Map<String, dynamic>>[];
    final c = _chat(sent);
    addTearDown(c.dispose);
    await t.pumpWidget(_host(ListenableBuilder(listenable: c, builder: (_, _) => QueuedMessages(chat: c))));
    expect(find.byTooltip('Cancel queued message'), findsNothing);

    _startTurn(c, sent, 'one');
    c.send('second message');
    c.send('', files: const [
      UploadedFile(uploadId: 'u1', name: 'notes.pdf', mimeType: 'application/pdf', size: 3, sha256: 'h'),
      UploadedFile(uploadId: 'u2', name: 'more.pdf', mimeType: 'application/pdf', size: 3, sha256: 'h'),
    ]);
    await t.pump();
    expect(find.text('second message'), findsOneWidget);
    expect(find.text('2 attachments'), findsOneWidget);
    expect(find.byTooltip('Cancel queued message'), findsNWidgets(2));
    // A finger-sized target.
    expect(t.getSize(find.byTooltip('Cancel queued message').first).height, greaterThanOrEqualTo(44));

    await t.tap(find.byTooltip('Cancel queued message').first);
    await t.pump();
    expect(find.text('second message'), findsNothing);
    expect(c.queue.single.files, hasLength(2));
    expect(sent, hasLength(1));
  });

  testWidgets('the note about dropped messages can be dismissed', (t) async {
    final sent = <Map<String, dynamic>>[];
    final c = _chat(sent);
    await t.pumpWidget(_host(
        ListenableBuilder(listenable: c, builder: (_, _) => ComposerNoteView(chat: c, agentName: 'Atlas'))));
    _startTurn(c, sent, 'one');
    c.send('two');
    c.debugClosed();
    await t.pump();
    expect(find.text('A queued message was not sent because the connection was lost.'), findsOneWidget);
    await t.tap(find.byTooltip('Dismiss'));
    await t.pump();
    expect(find.textContaining('queued message'), findsNothing);
    // The lost connection scheduled a retry: end it before the test does.
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('the main button stops an empty box mid-turn and sends a draft', (t) async {
    var stops = 0, sends = 0;
    Widget button({required bool busy, required bool draft}) => _host(SendOrStopButton(
        busy: busy, hasDraft: draft, canSend: draft, onSend: () => sends++, onStop: () => stops++));

    await t.pumpWidget(button(busy: true, draft: false));
    expect(find.bySemanticsLabel('Stop'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Stop'));
    expect((stops, sends), (1, 0));

    await t.pumpWidget(button(busy: true, draft: true));
    expect(find.bySemanticsLabel('Stop'), findsNothing);
    await t.tap(find.bySemanticsLabel('Send'));
    expect((stops, sends), (1, 1));

    await t.pumpWidget(button(busy: false, draft: false));
    expect(find.bySemanticsLabel('Stop'), findsNothing);
    await t.tap(find.bySemanticsLabel('Send'), warnIfMissed: false);
    expect((stops, sends), (1, 1), reason: 'nothing to send');
  });

  testWidgets('a steered message is tagged Steering… until confirmed, then Steered', (t) async {
    final sent = <Map<String, dynamic>>[];
    final c = _chat(sent);
    addTearDown(c.dispose);
    await t.pumpWidget(_host(ListenableBuilder(
        listenable: c,
        builder: (_, _) => Column(children: [
              for (final e in entriesFromLive(c.items, 'me')) EntryView(entry: e, agent: null),
            ]))));
    _startTurn(c, sent, 'one', steerable: true);
    await t.pump();
    expect(find.text('Steering…'), findsNothing);
    expect(find.text('Steered'), findsNothing);

    c.send('other way');
    await t.pump();
    expect(find.text('Steering…'), findsOneWidget);
    c.debugFrame(_ack(sent[1]['turnId'] as String, steered: true));
    await t.pump();
    expect(find.text('Steering…'), findsNothing);
    expect(find.text('Steered'), findsOneWidget);
  });
}
