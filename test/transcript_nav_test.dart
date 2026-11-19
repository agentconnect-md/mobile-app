import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/webchat/chat_controller.dart';
import 'package:agentconnect/features/chat/bubbles.dart';
import 'package:agentconnect/features/chat/live_turn.dart';
import 'package:agentconnect/features/chat/transcript_scroll.dart';
import 'package:agentconnect/features/sessions/transcript.dart';
import 'package:agentconnect/features/sessions/transcript_pager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A session's history as `GET /orgs/{org}/sessions/{id}/messages` pages it:
/// ascending by seq inside a page, `nextCursor` naming the older page and
/// null at the start of the conversation. `liveCursor` is the transcript's
/// revision; a read `after` one returns the rows added or changed since, a
/// forward page at a time (`liveMore`). [forward] false is a daemon without
/// forward reads: no `liveCursor`.
class FakeHistory {
  FakeHistory(int count, {this.pageSize = 3, this.forward = true}) {
    for (var i = 1; i <= count; i++) {
      add();
    }
  }
  final int pageSize;
  final bool forward;
  final rows = <Map<String, dynamic>>[];

  /// The revision each row (by seq) last changed at.
  final _changed = <int, int>{};
  int _revision = 0;

  /// What each read asked for: null (newest), a cursor, or `after:<revision>`.
  final asked = <String?>[];
  bool fail = false;
  bool refuseForward = false;

  void add({String sender = 'u', String kind = 'text', String? text, String? toolStatus}) {
    final seq = rows.length + 1;
    rows.add({
      'seq': seq,
      'sender': sender,
      'kind': kind,
      'text': text ?? 'm$seq',
      'ts': '2026-11-10T10:00:00.000Z',
      'postId': 'p$seq',
      'toolStatus': ?toolStatus,
    });
    _changed[seq] = ++_revision;
  }

  /// A row changes in place (a tool call finishes): same seq, new revision.
  void update(int seq, Map<String, dynamic> fields) {
    rows[seq - 1].addAll(fields);
    _changed[seq] = ++_revision;
  }

  Future<MessagePage> fetch({String? cursor, String? after}) async {
    asked.add(after != null ? 'after:$after' : cursor);
    if (fail) throw StateError('offline');
    if (after != null) {
      if (!forward || refuseForward) throw StateError('400');
      final since = rows.where((r) => _changed[r['seq']]! > int.parse(after)).toList()
        ..sort((a, b) => _changed[a['seq']]!.compareTo(_changed[b['seq']]!));
      final page = since.take(pageSize).toList();
      return MessagePage.fromJson({
        'sessionId': 's-1',
        'messages': page,
        'nextCursor': null,
        'liveCursor': page.isEmpty ? after : '${_changed[page.last['seq']]}',
        'liveMore': since.length > page.length,
      });
    }
    // The cursor names the lowest seq already sent; the page ends below it.
    final end = cursor == null ? rows.length : int.parse(cursor.substring('before-'.length)) - 1;
    final start = end - pageSize < 0 ? 0 : end - pageSize;
    return MessagePage.fromJson({
      'sessionId': 's-1',
      'messages': rows.sublist(start, end),
      'nextCursor': start > 0 ? 'before-${start + 1}' : null,
      'liveCursor': forward ? '$_revision' : null,
      'liveMore': false,
    });
  }
}

void main() {
  group('paging back', () {
    test('every page is read until the start of the conversation', () async {
      final history = FakeHistory(8);
      final pager = TranscriptPager(history.fetch, {'a'});
      await pager.loadNewest();
      expect(pager.items.map((e) => e.seq), [6, 7, 8]);
      expect(pager.hasOlder, isTrue);
      expect(pager.anchorSeq, 6);

      expect(await pager.loadOlder(), isTrue);
      expect(pager.items.map((e) => e.seq), [3, 4, 5, 6, 7, 8]);
      expect(pager.hasOlder, isTrue);

      // The last page is short and has no cursor: that is the start.
      expect(await pager.loadOlder(), isTrue);
      expect(pager.items.map((e) => e.seq), [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(pager.hasOlder, isFalse);

      // Nothing is asked for past the start.
      expect(await pager.loadOlder(), isFalse);
      expect(history.asked, [null, 'before-6', 'before-3']);

      // Older pages are a part of their own; the opening page keeps its rows.
      expect(pager.earlier.map((e) => e.seq), [1, 2, 3, 4, 5]);
      expect(pager.recent.map((e) => e.seq), [6, 7, 8]);
    });

    test('a page that fails keeps its cursor, so it can be asked for again', () async {
      final history = FakeHistory(6);
      final pager = TranscriptPager(history.fetch, {'a'});
      await pager.loadNewest();
      history.fail = true;
      expect(await pager.loadOlder(), isFalse);
      expect(pager.hasOlder, isTrue);
      expect(pager.items.map((e) => e.seq), [4, 5, 6]);
      history.fail = false;
      expect(await pager.loadOlder(), isTrue);
      expect(pager.items.map((e) => e.seq), [1, 2, 3, 4, 5, 6]);
      expect(pager.hasOlder, isFalse);
    });

    test('a link to a message pages back until it is loaded', () async {
      final history = FakeHistory(20);
      final pager = TranscriptPager(history.fetch, {'a'});
      await pager.loadNewest();
      await pager.loadBackTo(11);
      expect(pager.items.first.seq, lessThanOrEqualTo(11));
      expect(pager.items.first.seq, 9);
      // A message before the start stops at the start.
      await pager.loadBackTo(0);
      expect(pager.items.first.seq, 1);
      expect(pager.hasOlder, isFalse);
    });

    test('a refresh keeps the older pages and adds what arrived', () async {
      final history = FakeHistory(8, forward: false);
      final pager = TranscriptPager(history.fetch, {'a'});
      await pager.loadNewest();
      await pager.loadOlder();
      history.add(sender: 'a', text: 'reply');
      await pager.refresh();
      expect(pager.items.map((e) => e.seq), [3, 4, 5, 6, 7, 8, 9]);
      expect(pager.items.last.kind, ItemKind.agent);
      // The older cursor still leads to the start.
      expect(await pager.loadOlder(), isTrue);
      expect(pager.items.map((e) => e.seq), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(pager.hasOlder, isFalse);
      // The opening page stays the anchor: new rows are not "earlier".
      expect(pager.recent.map((e) => e.seq), [6, 7, 8, 9]);
    });

    test('a refresh past what is loaded starts from the fresh page', () async {
      final history = FakeHistory(6, forward: false);
      final pager = TranscriptPager(history.fetch, {'a'});
      await pager.loadNewest();
      await pager.loadOlder();
      for (var i = 0; i < 5; i++) {
        history.add();
      }
      // Rows 7 and 8 are on no loaded page: keeping 1-6 would hide the hole.
      await pager.refresh();
      expect(pager.items.map((e) => e.seq), [9, 10, 11]);
      expect(pager.hasOlder, isTrue);
      await pager.loadOlder();
      expect(pager.items.map((e) => e.seq), [6, 7, 8, 9, 10, 11]);
    });
  });

  group('a finished turn joins the transcript', () {
    test('forward reads add the turn by seq, with no row twice', () async {
      final history = FakeHistory(8);
      final pager = TranscriptPager(history.fetch, {'a'});
      await pager.loadNewest();
      await pager.loadOlder();
      // A turn: the prompt, a tool call still running, then more than one forward page.
      history.add(text: 'do it');
      history.add(sender: 'a', kind: 'tool', text: 'ls', toolStatus: 'in_progress');
      await pager.refresh();
      expect(pager.items.map((e) => e.seq), [3, 4, 5, 6, 7, 8, 9, 10]);
      expect(pager.items.last.toolStatus, 'in_progress');

      history.update(10, {'toolStatus': 'completed'});
      for (var i = 0; i < 4; i++) {
        history.add(sender: 'a', kind: 'tool', text: 'step $i', toolStatus: 'completed');
      }
      history.add(sender: 'a', text: 'done');
      await pager.refresh();
      // Rows 9 and 10 were loaded already: they are updated, not added again.
      expect(pager.items.map((e) => e.seq), [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
      expect(pager.items.firstWhere((e) => e.seq == 10).toolStatus, 'completed');
      expect(pager.items.last.kind, ItemKind.agent);
      expect(pager.items.last.text, 'done');
      // One forward page for the first refresh and two for the second; the
      // newest page was not read again.
      expect(history.asked.where((a) => a == null).length, 1);
      expect(history.asked.where((a) => a != null && a.startsWith('after:')).length, 3);

      // Nothing new: nothing changes, and the older pages are still reachable.
      await pager.refresh();
      expect(pager.items.length, 13);
      await pager.loadOlder();
      expect(pager.items.first.seq, 1);
      expect(pager.hasOlder, isFalse);
    });

    test('a change to a row on a page not loaded yet is left for that page', () async {
      final history = FakeHistory(8);
      final pager = TranscriptPager(history.fetch, {'a'});
      await pager.loadNewest();
      history.update(2, {'text': 'edited'});
      history.add(sender: 'a', text: 'reply');
      await pager.refresh();
      expect(pager.items.map((e) => e.seq), [6, 7, 8, 9]);
    });

    test('a refused forward read falls back to the newest page', () async {
      final history = FakeHistory(8);
      final pager = TranscriptPager(history.fetch, {'a'});
      await pager.loadNewest();
      await pager.loadOlder();
      history.add(sender: 'a', text: 'reply');
      history.refuseForward = true;
      await pager.refresh();
      expect(pager.items.map((e) => e.seq), [3, 4, 5, 6, 7, 8, 9]);
    });

    List<LiveItem> live(List<(LiveKind, String)> rows) => [for (final (k, t) in rows) LiveItem(k, t)];

    test('stored rows of the live turn stay hidden while it streams', () {
      final stored = <Entry>[
        const UserEntry('hi', 'me', seq: 4),
        const AgentEntry('hello', seq: 5),
        const ToolEntry(title: 'left over'),
      ];
      final mark = lastSeq(stored)!;
      expect(mark, 5);
      expect(storedBefore(stored, mark), stored.length);
      // The turn's own rows arrive in the stored transcript while it runs.
      final during = <Entry>[
        ...stored,
        const UserEntry('do it', 'me', seq: 6),
        const ToolEntry(title: 'ls'),
        const AgentEntry('done', seq: 9),
      ];
      expect(storedBefore(during, mark), 3);
      // Shown: what was stored before the turn, then the live copy. No row twice.
      final shown = [
        ...during.sublist(0, storedBefore(during, mark)),
        ...entriesFromLive(live([(LiveKind.user, 'do it'), (LiveKind.tool, 'ls'), (LiveKind.agent, 'done')]), 'me'),
      ];
      expect(shown.whereType<UserEntry>().map((e) => e.text), ['hi', 'do it']);
      expect(shown.whereType<AgentEntry>().map((e) => e.text), ['hello', 'done']);
      // A conversation with nothing stored yet hides everything stored later.
      expect(storedBefore(const [UserEntry('first', 'me', seq: 1)], lastSeq(const []) ?? -1), 0);
    });

    test('a message someone else adds during the turn still shows', () {
      final turn = live([(LiveKind.user, 'do it'), (LiveKind.agent, 'on it')]);
      const stored = <Entry>[
        AgentEntry('hello', seq: 5),
        UserEntry('do it', 'me', seq: 6),
        ToolEntry(title: 'ls'),
        UserEntry('also check b', 'Sam', seq: 8),
        AgentEntry('on it', seq: 9),
      ];
      final shown = storedBesideLive(stored, 5, turn);
      expect(shown.map((e) => entrySeq(e)), [5, 8]);
      // Nothing of the turn stored yet: the stored transcript shows as it is.
      expect(storedBesideLive(stored.sublist(0, 1), 5, turn), hasLength(1));
    });

    test('the live copy goes once the stored transcript holds the reply', () {
      final turn = live([(LiveKind.user, 'do it'), (LiveKind.tool, 'ls'), (LiveKind.agent, 'done ')]);
      // Not stored yet.
      expect(liveTurnStored(const [], turn, waited: true), isFalse);
      // The prompt and a tool call are stored, the reply is not: an early swap
      // would take the reply off the screen.
      const partial = <Entry>[UserEntry('do it', 'me', seq: 6), ToolEntry(title: 'ls')];
      expect(liveTurnStored(partial, turn, waited: false), isFalse);
      const whole = <Entry>[...partial, AgentEntry('done', seq: 9)];
      expect(liveTurnStored(whole, turn, waited: false), isTrue);
      // An older identical reply before the mark is not in the tail, so it can't count.
      // A reply stored with other text is taken once the chat has been quiet.
      const other = <Entry>[...partial, AgentEntry('done.', seq: 9)];
      expect(liveTurnStored(other, turn, waited: false), isFalse);
      expect(liveTurnStored(other, turn, waited: true), isTrue);
    });

    test('a second turn waits for its own reply', () {
      final turns = live([
        (LiveKind.user, 'one'),
        (LiveKind.agent, 'first'),
        (LiveKind.user, 'two'),
      ]);
      const stored = <Entry>[UserEntry('one', 'me', seq: 6), AgentEntry('first', seq: 7)];
      expect(liveTurnStored(stored, turns, waited: false), isFalse);
      // Answered in a thread: the prompt is stored with a line after it.
      final inThread = <Entry>[...stored, const UserEntry('two', 'me', seq: 8), InThreadEntry('root', () {})];
      expect(liveTurnStored(inThread, turns, waited: false), isTrue);
      // Stopped before any reply: only the prompt is stored.
      const stopped = <Entry>[...stored, UserEntry('two', 'me', seq: 8)];
      expect(liveTurnStored(stopped, turns, waited: false), isFalse);
      expect(liveTurnStored(stopped, turns, waited: true), isTrue);
    });

    test('cards and notices alone are not a turn', () {
      expect(hasTurnContent(live([(LiveKind.fill, ''), (LiveKind.notice, 'x')])), isFalse);
      expect(hasTurnContent(live([(LiveKind.fill, ''), (LiveKind.thinking, 'hm')])), isTrue);
    });
  });

  group('mergeNewestPage', () {
    TranscriptItem item(int seq, [String? status]) =>
        TranscriptItem(seq: seq, kind: ItemKind.tool, text: 't$seq', toolStatus: status);

    test('rows on the fresh page replace the loaded ones', () {
      final m = mergeNewestPage([item(1), item(2), item(3, 'running')], [item(3, 'completed'), item(4)],
          freshHasOlder: true);
      expect(m.items.map((e) => e.seq), [1, 2, 3, 4]);
      expect(m.items[2].toolStatus, 'completed');
      expect(m.keptOlder, isTrue);
    });

    test('a page that is the whole conversation stands alone', () {
      final m = mergeNewestPage([item(1), item(2)], [item(1), item(2), item(3)], freshHasOlder: false);
      expect(m.items.map((e) => e.seq), [1, 2, 3]);
      expect(m.keptOlder, isFalse);
    });

    test('an emptied conversation shows nothing', () {
      final m = mergeNewestPage([item(1)], const [], freshHasOlder: false);
      expect(m.items, isEmpty);
      expect(m.keptOlder, isFalse);
    });
  });

  group('TranscriptScroll', () {
    Widget row(String name, {double height = 100}) =>
        SizedBox(key: ValueKey(name), height: height, child: Text(name, textDirection: TextDirection.ltr));

    Widget host(List<Widget> earlier, List<Widget> rows, {bool openAtLatest = true}) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 400,
              child: TranscriptScroll(
                key: const ValueKey('list'),
                earlier: earlier,
                rows: rows,
                openAtLatest: openAtLatest,
              ),
            ),
          ),
        );

    double top(WidgetTester tester, String name) => tester.getTopLeft(find.byKey(ValueKey(name))).dy;

    testWidgets('opens on the latest row', (tester) async {
      await tester.pumpWidget(host(const [], [for (var i = 1; i <= 30; i++) row('r$i')]));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('r30')), findsOneWidget);
      expect(find.byKey(const ValueKey('r1')), findsNothing);
      // 16 pt of padding under the last row.
      expect(tester.getBottomLeft(find.byKey(const ValueKey('r30'))).dy, 400 - 16);
    });

    testWidgets('a short conversation starts at the top', (tester) async {
      await tester.pumpWidget(host(const [], [row('r1'), row('r2')]));
      await tester.pumpAndSettle();
      expect(top(tester, 'r1'), 8);
    });

    testWidgets('an older page added above leaves the rows on screen in place', (tester) async {
      final rows = [for (var i = 11; i <= 30; i++) row('r$i')];
      await tester.pumpWidget(host([row('load', height: 48)], rows));
      await tester.pumpAndSettle();
      // Scroll up to the start of what is loaded.
      await tester.drag(find.byKey(const ValueKey('list')), const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('load')), findsOneWidget);
      final before = top(tester, 'r11');

      await tester.pumpWidget(host([
        row('load', height: 48),
        for (var i = 1; i <= 10; i++) row('r$i', height: 60 + i * 7),
      ], rows));
      await tester.pumpAndSettle();
      expect(top(tester, 'r11'), before);
      // The new rows are right above, the newest of them first.
      expect(tester.getBottomLeft(find.byKey(const ValueKey('r10'))).dy, lessThanOrEqualTo(before));

      // And the page before that, further up, just the same.
      await tester.drag(find.byKey(const ValueKey('list')), const Offset(0, 200));
      await tester.pumpAndSettle();
      final again = top(tester, 'r9');
      await tester.pumpWidget(host([
        for (var i = -5; i <= 0; i++) row('r$i'),
        for (var i = 1; i <= 10; i++) row('r$i', height: 60 + i * 7),
      ], rows));
      await tester.pumpAndSettle();
      expect(top(tester, 'r9'), again);
    });

    testWidgets('new rows are followed at the latest row, and left alone when scrolled up', (tester) async {
      var rows = [for (var i = 1; i <= 30; i++) row('r$i')];
      await tester.pumpWidget(host(const [], rows));
      await tester.pumpAndSettle();

      rows = [...rows, row('r31', height: 220)];
      await tester.pumpWidget(host(const [], rows));
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(find.byKey(const ValueKey('r31'))).dy, 400 - 16);

      await tester.drag(find.byKey(const ValueKey('list')), const Offset(0, 600));
      await tester.pumpAndSettle();
      final reading = find.byKey(const ValueKey('r25'));
      expect(reading, findsOneWidget);
      final before = tester.getTopLeft(reading).dy;
      rows = [...rows, row('r32'), row('r33')];
      await tester.pumpWidget(host(const [], rows));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(reading).dy, before);
      expect(find.byKey(const ValueKey('r33')), findsNothing);

      // Asking for the latest row goes there and follows again.
      final state = tester.state<TranscriptScrollState>(find.byType(TranscriptScroll));
      state.toLatest();
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(find.byKey(const ValueKey('r33'))).dy, 400 - 16);
      rows = [...rows, row('r34')];
      await tester.pumpWidget(host(const [], rows));
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(find.byKey(const ValueKey('r34'))).dy, 400 - 16);
    });

    testWidgets('a view that lands elsewhere does not open on the latest row', (tester) async {
      await tester.pumpWidget(host(const [], [for (var i = 1; i <= 30; i++) row('r$i')], openAtLatest: false));
      await tester.pumpAndSettle();
      expect(top(tester, 'r1'), 8);
    });
  });
}
