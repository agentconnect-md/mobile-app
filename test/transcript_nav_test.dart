import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/features/chat/transcript_scroll.dart';
import 'package:agentconnect/features/sessions/transcript.dart';
import 'package:agentconnect/features/sessions/transcript_pager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A session's history as `GET /orgs/{org}/sessions/{id}/messages` pages it:
/// ascending by seq inside a page, `nextCursor` naming the older page and
/// null at the start of the conversation.
class FakeHistory {
  FakeHistory(int count, {this.pageSize = 3}) {
    for (var i = 1; i <= count; i++) {
      add();
    }
  }
  final int pageSize;
  final rows = <Map<String, dynamic>>[];
  final cursors = <String?>[];
  bool fail = false;

  void add({String sender = 'u', String kind = 'text', String? text}) {
    final seq = rows.length + 1;
    rows.add({
      'seq': seq,
      'sender': sender,
      'kind': kind,
      'text': text ?? 'm$seq',
      'ts': '2026-11-10T10:00:00.000Z',
      'postId': 'p$seq',
    });
  }

  Future<MessagePage> fetch({String? cursor}) async {
    cursors.add(cursor);
    if (fail) throw StateError('offline');
    // The cursor names the lowest seq already sent; the page ends below it.
    final end = cursor == null ? rows.length : int.parse(cursor.substring('before-'.length)) - 1;
    final start = end - pageSize < 0 ? 0 : end - pageSize;
    return MessagePage.fromJson({
      'sessionId': 's-1',
      'messages': rows.sublist(start, end),
      'nextCursor': start > 0 ? 'before-${start + 1}' : null,
      'liveCursor': '${rows.length}',
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
      expect(history.cursors, [null, 'before-6', 'before-3']);

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
      final history = FakeHistory(8);
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
      final history = FakeHistory(6);
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
