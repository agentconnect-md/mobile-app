import 'dart:convert';

import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:agentconnect/features/chat/context_ring.dart';
import 'package:agentconnect/features/sessions/session_details.dart';
import 'package:agentconnect/features/sessions/transcript.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/l10n/app_localizations_en.dart';
import 'package:agentconnect/ui/format.dart';
import 'package:agentconnect/ui/theme.dart';
import 'package:agentconnect/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Anonymized fixtures in the server's shapes: a row of GET /orgs/{org}/sessions
// (SessionDto), GET /orgs/{org}/sessions/{id} (SessionDetailDto), and a web
// chat `output.status` frame (WebchatStatus).
const _daemonA = '11111111-1111-4111-8111-111111111111';
const _daemonB = '22222222-2222-4222-8222-222222222222';

const _listRow = '''
{"sessionId":"s1","sessionKey":{"platform":"webchat","channel":"c-1"},"agentId":"a1","agentName":"review-bot",
 "title":"Fix the thing","status":"idle","lastActivityAt":"2026-01-02T03:04:05.000Z",
 "usage":{"reportedAt":"2026-01-02T03:04:05.000Z","totalTokens":45267,"inputTokens":1200,"outputTokens":980,
  "thoughtTokens":310,"cachedReadTokens":41000,"cachedWriteTokens":1777,"contextUsed":84000,"contextSize":200000,
  "costAmount":0.4213,"costCurrency":"USD"},
 "triggeredBy":"u1","hookKind":null,"channelName":null,"triggeredByName":"Dana","threadUrl":null,
 "runtime":"claude-acp","model":"model-b","effort":"high","fastMode":false,"permissionMode":"auto",
 "outputMode":null,"daemonId":"$_daemonA","contentSetId":null,"workspaceIsolation":"shared",
 "visibility":"org","externalProvider":null,"externalResolution":null,"contentPurgedAt":null,
 "activityState":"idle"}''';

Map<String, dynamic> _detail({Object? usage, String? executor, String? stayed, String? runtime = 'claude-acp'}) => {
      'id': 's1',
      'parentSession': null,
      'siblingSessions': [],
      'childSessions': [],
      'agentId': 'a1',
      'agentName': 'review-bot',
      'platform': 'webchat',
      'channel': 'c-1',
      'thread': null,
      'title': 'Fix the thing',
      'status': 'idle',
      'lastActivityAt': '2026-01-02T03:04:05.000Z',
      'usage': usage,
      'runtime': runtime,
      'model': null,
      'effort': null,
      'fastMode': null,
      'permissionMode': null,
      'daemonId': _daemonA,
      'workspaceIsolation': 'shared',
      'executorDaemonId': executor,
      'stayedHomeReason': stayed,
      'activityState': 'idle',
      'visibility': 'org',
    };

Machine _machine(String id, String name) => Machine.fromJson({'daemonId': id, 'name': name, 'status': 'ready'});

TranscriptItem _item(int seq, ItemKind kind, String ts, {String? tool}) =>
    TranscriptItem(seq: seq, kind: kind, text: '', ts: DateTime.parse(ts), toolCallId: tool);

void main() {
  final l = AppLocalizationsEn();

  group('decoding', () {
    test('a session row carries its usage and the machine that holds it', () {
      final s = SessionRow.fromJson(jsonDecode(_listRow));
      final u = s.usage!;
      expect(u.totalTokens, 45267);
      expect(u.inputTokens, 1200);
      expect(u.outputTokens, 980);
      expect(u.thoughtTokens, 310);
      expect(u.cachedReadTokens, 41000);
      expect(u.cachedWriteTokens, 1777);
      expect(u.contextUsed, 84000);
      expect(u.contextSize, 200000);
      expect(u.costAmount, closeTo(0.4213, 1e-9));
      expect(u.costCurrency, 'USD');
      expect(s.daemonId, _daemonA);
      expect(s.executorDaemonId, isNull);
      expect(s.stayedHomeReason, isNull);
    });

    test('usage: null and a partly reported usage', () {
      expect(SessionRow.fromJson({'sessionId': 's', 'usage': null}).usage, isNull);
      expect(SessionRow.fromJson({'sessionId': 's'}).usage, isNull);
      final u = SessionRow.fromJson({
        'sessionId': 's',
        'usage': {'totalTokens': 60, 'costAmount': '1.5', 'contextSize': 'big'},
      }).usage!;
      expect(u.totalTokens, 60);
      expect(u.costAmount, isNull);
      expect(u.contextSize, isNull);
      expect(u.inputTokens, isNull);
    });

    test('the session detail carries the placement verdict', () {
      final moved = SessionRow.fromJson(_detail(executor: _daemonB));
      expect(moved.executorDaemonId, _daemonB);
      expect(moved.stayedHomeReason, isNull);
      final stayed = SessionRow.fromJson(_detail(stayed: 'candidates_full', usage: {'totalTokens': 9}));
      expect(stayed.executorDaemonId, isNull);
      expect(stayed.stayedHomeReason, 'candidates_full');
      expect(stayed.usage!.totalTokens, 9);
    });

    test('a status frame carries the context window; a later partial frame keeps the size', () {
      final f = decodeFrame('{"type":"output","output":{"turnId":"t","index":3,"status":'
          '{"model":"model-b","contextUsed":84000,"contextSize":200000,"totalTokens":45267,'
          '"costAmount":0.42,"costCurrency":"USD"}}}') as OutputFrame;
      final s = f.status!;
      expect(s.contextUsed, 84000);
      expect(s.contextSize, 200000);
      expect(s.totalTokens, 45267);
      expect(s.costAmount, closeTo(0.42, 1e-9));
      expect(s.costCurrency, 'USD');
      final merged = s.merge(const RunStatus(contextUsed: 91000));
      expect(merged.contextUsed, 91000);
      expect(merged.contextSize, 200000);
      expect(const RunStatus(model: 'm').contextSize, isNull);
    });
  });

  group('formatting', () {
    test('counts are compact, as on the web console', () {
      expect(compactCount(0), '0');
      expect(compactCount(60), '60');
      expect(compactCount(999), '999');
      expect(compactCount(1000), '1K');
      expect(compactCount(1234), '1.2K');
      expect(compactCount(45267), '45K');
      expect(compactCount(101817), '102K');
      expect(compactCount(2316000), '2.32M');
      expect(compactCount(10000000), '10M');
      expect(compactCount(1234567890), '1.23B');
      expect(compactCount(2500000000000), '2,500B');
    });

    test('cost is written with its currency', () {
      expect(costText(0.4213, 'USD'), r'$0.42');
      expect(costText(1234.5, 'usd'), r'$1,234.50');
      expect(costText(0.4, 'EUR'), '€0.40');
      expect(costText(0.004, 'USD'), r'$0.00');
      expect(costText(1, 'XTS'), 'XTS 1.00');
      expect(costText(2.5, 'credits'), 'CREDITS 2.50');
      expect(costText(0.4213, null), '0.42');
    });

    test('duration', () {
      expect(durationText(Duration.zero), '0s');
      expect(durationText(const Duration(seconds: 42)), '42s');
      expect(durationText(const Duration(minutes: 3, seconds: 7)), '3m 07s');
      expect(durationText(const Duration(hours: 1, minutes: 5, seconds: 59)), '1h 05m');
    });

    test('runtime names', () {
      expect(runtimeLabel('claude-acp'), 'Claude Code');
      expect(runtimeLabel('codex'), 'Codex');
      expect(runtimeLabel('opencode'), 'opencode');
      expect(runtimeLabel('some-runtime'), 'some-runtime');
    });

    test('context percent is clamped, and unknown without both numbers', () {
      expect(contextPercent(84000, 200000), 42);
      expect(contextPercent(250000, 200000), 100);
      expect(contextPercent(null, 200000), isNull);
      expect(contextPercent(10, null), isNull);
      expect(contextPercent(10, 0), isNull);
    });
  });

  group('facts', () {
    final row = SessionRow.fromJson(jsonDecode(_listRow));
    final machines = [_machine(_daemonA, 'build-box'), _machine(_daemonB, 'gpu-box')];

    test('the list row alone: usage, daemon by name, runtime and model', () {
      final f = SessionFacts.of(l, session: row, machines: machines);
      expect(f.rows(l), [
        ('Tokens', '45K'),
        ('Cost', r'$0.42'),
        ('Daemon', 'build-box'),
        ('Runtime', 'Claude Code'),
        ('Model', 'model-b'),
      ]);
      expect(f.usageRows(l), [
        ('Input', '1.2K'),
        ('Output', '980'),
        ('Thought', '310'),
        ('Cache read', '41K'),
        ('Cache write', '1.8K'),
        ('Context', '84K / 200K'),
      ]);
    });

    test('duration and tool calls come from a fully loaded transcript', () {
      final items = [
        _item(1, ItemKind.user, '2026-01-02T03:00:00Z'),
        _item(2, ItemKind.tool, '2026-01-02T03:00:10Z', tool: 't1'),
        _item(3, ItemKind.tool, '2026-01-02T03:00:20Z', tool: 't1'), // the same call, updated
        _item(4, ItemKind.tool, '2026-01-02T03:01:00Z'),
        _item(5, ItemKind.agent, '2026-01-02T03:03:07Z'),
      ];
      final f = SessionFacts.of(l, session: row, machines: machines, transcript: items);
      expect(f.duration, const Duration(minutes: 3, seconds: 7));
      expect(f.toolCalls, 2);
      expect(f.rows(l).first, ('Duration', '3m 07s'));
      expect(f.rows(l), contains(('Tool calls', '2')));
      // Older pages not loaded (null) or nothing in it: no such rows.
      for (final t in [null, <TranscriptItem>[]]) {
        final g = SessionFacts.of(l, session: row, machines: machines, transcript: t);
        expect(g.duration, isNull);
        expect(g.toolCalls, isNull);
      }
    });

    test('runs on: another member by name, else why it stayed', () {
      final moved =
          SessionFacts.of(l, session: row, detail: SessionRow.fromJson(_detail(executor: _daemonB)), machines: machines);
      expect(moved.runsOn, 'gpu-box');
      final unknown = SessionFacts.of(l, session: row, detail: SessionRow.fromJson(_detail(executor: _daemonB)));
      expect(unknown.runsOn, '22222222');
      expect(unknown.daemon, '11111111');
      final stayed = SessionFacts.of(l,
          session: row, detail: SessionRow.fromJson(_detail(stayed: 'candidates_full')), machines: machines);
      expect(stayed.runsOn, 'build-box · every member full');
      // No useful detail, a reason this build doesn't know, or no verdict: no row.
      for (final r in ['memory_daemon_homed', 'something_new', null]) {
        final f =
            SessionFacts.of(l, session: row, detail: SessionRow.fromJson(_detail(stayed: r)), machines: machines);
        expect(f.runsOn, isNull);
      }
    });

    test('the detail is preferred; without a reported model the runtime default ran', () {
      final f = SessionFacts.of(l,
          session: row,
          detail: SessionRow.fromJson(_detail(usage: {'totalTokens': 2316000})),
          machines: machines);
      expect(f.rows(l), contains(('Tokens', '2.32M')));
      expect(f.rows(l).where((r) => r.$1 == 'Cost'), isEmpty);
      final bare = SessionRow.fromJson({'sessionId': 's', 'agentId': 'a', 'runtime': 'codex'});
      expect(SessionFacts.of(l, session: bare).rows(l), [('Runtime', 'Codex'), ('Model', 'Default')]);
    });

    test('a legacy row falls back to the agent; a pool placement is not a machine', () {
      final legacy = SessionRow.fromJson({'sessionId': 's', 'agentId': 'a'});
      final agent = Agent.fromJson(
          {'id': 'a', 'name': 'bot', 'runtime': 'claude-acp', 'model': 'model-a', 'daemonId': _daemonA, 'daemonName': 'Dana\'s Mac'});
      expect(SessionFacts.of(l, session: legacy, agent: agent).rows(l),
          [('Daemon', 'Dana\'s Mac'), ('Runtime', 'Claude Code'), ('Model', 'model-a')]);
      final pooled = Agent.fromJson({'id': 'a', 'name': 'bot', 'daemonId': 'pool'});
      expect(SessionFacts.of(l, session: legacy, agent: pooled).rows(l), isEmpty);
    });
  });

  group('widgets', () {
    Widget host(Widget child) => MaterialApp(
          theme: buildTheme(Brightness.light),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        );

    testWidgets('the sheet shows the values it has and leaves out the rest', (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(const SessionDetailsSheet(
        facts: SessionFacts(
          duration: Duration(minutes: 3, seconds: 7),
          toolCalls: 12,
          usage: SessionUsage(totalTokens: 45267, costAmount: 0.4213, costCurrency: 'USD', inputTokens: 1200),
          runtime: 'Claude Code',
          model: 'a-rather-long-model-name-that-would-not-fit-on-one-line-of-a-narrow-phone',
        ),
      )));
      expect(find.text('Details'), findsOneWidget);
      for (final t in ['Duration', '3m 07s', 'Tokens', '45K', 'Cost', r'$0.42', 'Tool calls', '12', 'Runtime']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('Token usage'), findsOneWidget);
      expect(find.text('Input'), findsOneWidget);
      expect(find.text('1.2K'), findsOneWidget);
      for (final t in ['Daemon', 'Runs on', 'Output', 'Thought', 'Cache read', 'Cache write', 'Context', '—']) {
        expect(find.text(t), findsNothing, reason: t);
      }
      expect(find.byType(GroupCard), findsNWidgets(2));
      expect(tester.takeException(), isNull); // nothing overflows at 375 pt
    });

    testWidgets('no token breakdown without usage; a note when nothing is reported', (tester) async {
      await tester.pumpWidget(host(const SessionDetailsSheet(facts: SessionFacts(runtime: 'Codex', model: 'Default'))));
      expect(find.text('Runtime'), findsOneWidget);
      expect(find.text('Token usage'), findsNothing);
      expect(find.byType(GroupCard), findsOneWidget);

      await tester.pumpWidget(host(const SessionDetailsSheet(facts: SessionFacts())));
      expect(find.byType(GroupCard), findsNothing);
      expect(find.text("This session hasn't reported any details yet."), findsOneWidget);
    });

    testWidgets('the context ring says percent and tokens when tapped', (tester) async {
      await tester.pumpWidget(host(const Center(child: ContextRing(used: 84000, size: 200000))));
      expect(tester.getSize(find.byType(ContextRing)), const Size(44, 44));
      expect(find.textContaining('42% used'), findsNothing);
      await tester.tap(find.byType(ContextRing));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Context window:\n42% used (58% left)\n84K / 200K tokens used'), findsOneWidget);
    });

    testWidgets('the context ring without a used count', (tester) async {
      await tester.pumpWidget(host(const Center(child: ContextRing(used: null, size: 200000))));
      await tester.tap(find.byType(ContextRing));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Context window:\nUsage unavailable'), findsOneWidget);
    });
  });
}
