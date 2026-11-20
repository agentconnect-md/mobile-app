import 'dart:convert';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/api/schedules.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/core/cron.dart';
import 'package:agentconnect/core/org_data.dart';
import 'package:agentconnect/features/schedules/schedule_detail_screen.dart';
import 'package:agentconnect/features/schedules/schedule_text.dart';
import 'package:agentconnect/features/schedules/schedules_screen.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Anonymized fixtures shaped like the control plane's CronDto (GET /orgs/{org}/crons,
// GET and PUT /orgs/{org}/crons/{id}) and CronRunDto (GET /orgs/{org}/crons/{id}/runs).
const cronsJson = '''
[
 {"id":"c-1","orgId":"org","agentId":"a1","name":"weekly-deploy-report","schedule":"0 9 * * 1-5",
  "timezone":"America/New_York","targetPlatform":"slack","targetChannel":"C0DEPLOYS",
  "targetIntegrationId":"int-1","trigger":"Summarize last week's deploys.","enabled":true,
  "lastRunAt":"2026-11-18T14:00:03.000Z","createdBy":"u-me","createdAt":"2026-10-01T08:00:00.000Z",
  "lastModifiedBy":"u-2","lastModifiedAt":"2026-11-02T10:30:00.000Z","visibility":"org","sharedWith":[],
  "canEdit":true,"canManageSharing":true},
 {"id":"c-2","orgId":"org","agentId":"a2","name":"nightly-audit","schedule":"30 2 * * *",
  "timezone":"UTC","targetPlatform":"slack","targetChannel":null,"targetIntegrationId":null,
  "trigger":"Audit open pull requests.","enabled":false,"lastRunAt":null,"createdBy":null,
  "createdAt":"2026-09-12T08:00:00.000Z","lastModifiedBy":null,"lastModifiedAt":"2026-09-12T08:00:00.000Z",
  "visibility":"restricted","sharedWith":["u-me","u-2"],"canEdit":false,"canManageSharing":false},
 {"id":"c-3","orgId":"org","agentId":"a1","name":"broken","schedule":"every tuesday",
  "timezone":"UTC","targetPlatform":"slack","targetChannel":null,"targetIntegrationId":null,
  "trigger":"Never fires.","enabled":true,"lastRunAt":null,"createdBy":null,
  "createdAt":"2026-09-12T08:00:00.000Z","lastModifiedBy":null,"lastModifiedAt":"2026-09-12T08:00:00.000Z",
  "visibility":"org","sharedWith":[],"canEdit":true,"canManageSharing":true},
 {"id":"c-4","orgId":"org","agentId":null,"name":null,"schedule":"*/20 * * * *",
  "timezone":"UTC","targetPlatform":"slack","targetChannel":null,"targetIntegrationId":null,
  "trigger":"Sweep the queue.","enabled":true,"lastRunAt":null,"createdBy":null,
  "createdAt":"2026-09-12T08:00:00.000Z","lastModifiedBy":null,"lastModifiedAt":"2026-09-12T08:00:00.000Z",
  "visibility":"org","sharedWith":[],"canEdit":true,"canManageSharing":true}
]''';

const runsJson = '''
[
 {"id":"r-3","startedAt":"2026-11-19T14:00:02.000Z","status":"running","durationMs":null,"sessionId":"s-3","reason":null},
 {"id":"r-2","startedAt":"2026-11-18T14:00:03.000Z","status":"success","durationMs":245000,"sessionId":"s-2","reason":null},
 {"id":"r-1","startedAt":"2026-11-17T14:00:01.000Z","status":"failed","durationMs":900,"sessionId":null,"reason":"daemon offline"}
]''';

const agentsJson = [
  {'id': 'a1', 'name': 'deploy-bot', 'displayName': 'Deploy bot', 'status': 'active'},
  {'id': 'a2', 'name': 'audit-bot', 'status': 'active'},
];

const integrationsJson = [
  {
    'id': 'int-1',
    'name': 'Slack',
    'platform': 'slack',
    'agentId': 'a1',
    'channels': [
      {'channelId': 'C0DEPLOYS', 'name': 'deploys', 'kind': 'channel', 'isPrivate': false},
      {'channelId': 'C0OTHER', 'name': null, 'kind': 'channel', 'isPrivate': false},
    ],
  },
  {
    'id': 'int-2',
    'name': 'Slack 2',
    'platform': 'slack',
    'agentId': 'a2',
    'channels': [
      {'channelId': 'C0DEPLOYS', 'name': 'elsewhere', 'kind': 'channel', 'isPrivate': false},
    ],
  },
];

class _NoTokens implements TokenProvider {
  @override
  Future<String> accessToken() async => 't';
  @override
  Future<bool> refreshAfter401(String rejected) async => false;
  @override
  bool get canWrite => true;
}

/// Answers from the fixtures and records every request.
class _FixtureClient extends ApiClient {
  _FixtureClient({String crons = cronsJson, this.listError, this.runError, this.saveError})
      : crons = (jsonDecode(crons) as List).cast<Map<String, dynamic>>(),
        super('https://api.example.test/v1', _NoTokens());
  final List<Map<String, dynamic>> crons;
  Object? listError;
  Object? runError;
  Object? saveError;
  final calls = <(String, String, Object?)>[];

  Iterable<(String, String, Object?)> writes() => calls.where((c) => c.$1 != 'GET');

  @override
  Future<dynamic> request(String method, String path, {Map<String, String?>? query, Object? body}) async {
    calls.add((method, path, body));
    if (method == 'GET') {
      if (path == '/orgs/org/crons') return listError != null ? throw listError! : crons;
      if (path == '/orgs/org/agents') return agentsJson;
      if (path == '/orgs/org/integrations') return integrationsJson;
      if (path.endsWith('/runs')) return jsonDecode(runsJson);
      if (path == '/orgs/org/sessions/s-2') {
        return {'sessionId': 's-2', 'agentId': 'a1', 'title': 'Deploy report', 'sessionKey': {'platform': 'cron'}};
      }
      return path.endsWith('/daemons') ? const [] : const <String, dynamic>{};
    }
    if (method == 'PUT') {
      if (saveError != null) throw saveError!;
      final id = path.split('/').last;
      return {...crons.firstWhere((c) => c['id'] == id), ...(body as Map).cast<String, dynamic>()};
    }
    if (runError != null) throw runError!;
    return null;
  }
}

void main() {
  final l = lookupAppLocalizations(const Locale('en'));

  /// Times as typed here: the formatter puts a narrow no-break space before AM / PM.
  String plain(String s) => s.replaceAll('\u202f', ' ');
  final schedules = Schedule.listFromJson(jsonDecode(cronsJson));

  group('models', () {
    test('the list decodes', () {
      expect(schedules.map((s) => s.id), ['c-1', 'c-2', 'c-3', 'c-4']);
      final s = schedules.first;
      expect(s.name, 'weekly-deploy-report');
      expect(s.agentId, 'a1');
      expect(s.expression, '0 9 * * 1-5');
      expect(s.timezone, 'America/New_York');
      expect(s.targetChannel, 'C0DEPLOYS');
      expect(s.enabled, isTrue);
      expect(s.lastRunAt!.toUtc(), DateTime.utc(2026, 11, 18, 14, 0, 3));
      expect(s.createdBy, 'u-me');
      expect(s.restricted, isFalse);
      expect(s.canEdit, isTrue);
      expect(schedules[1].restricted, isTrue);
      expect(schedules[1].sharedWith, ['u-me', 'u-2']);
      expect(schedules[1].canEdit, isFalse);
      expect(schedules[3].agentId, isNull);
      expect(schedules[3].name, isNull);
    });

    test('one schedule decodes, and what the server leaves out has a default', () {
      final s = Schedule.fromJson((jsonDecode(cronsJson) as List)[1])!;
      expect(s.prompt, 'Audit open pull requests.');
      expect(s.targetChannel, isNull);
      expect(s.lastRunAt, isNull);
      final bare = Schedule.fromJson({'id': 'x', 'schedule': '0 * * * *'})!;
      expect(bare.timezone, 'UTC');
      expect(bare.enabled, isFalse);
      expect(bare.canEdit, isFalse);
      expect(Schedule.fromJson({'id': 'x'}), isNull);
      expect(Schedule.fromJson(null), isNull);
      expect(Schedule.listFromJson({'not': 'a list'}), isEmpty);
    });

    test('runs decode', () {
      final runs = ScheduleRun.listFromJson(jsonDecode(runsJson));
      expect(runs.map((r) => r.status),
          [ScheduleRunStatus.running, ScheduleRunStatus.success, ScheduleRunStatus.failed]);
      expect(runs[0].durationMs, isNull);
      expect(runs[1].durationMs, 245000);
      expect(runs[1].sessionId, 's-2');
      expect(runs[1].startedAt!.toUtc(), DateTime.utc(2026, 11, 18, 14, 0, 3));
      expect(runs[2].sessionId, isNull);
      expect(runs[2].reason, 'daemon offline');
      // A status this build doesn't know makes no claim about the outcome.
      expect(ScheduleRun.fromJson({'id': 'r', 'status': 'queued'})!.status, ScheduleRunStatus.running);
      expect(ScheduleRun.listFromJson([{}, null]), isEmpty);
    });

    test('turning one on or off sends the whole definition back', () {
      expect(schedules.first.updateBody(enabled: false), {
        'agentId': 'a1',
        'name': 'weekly-deploy-report',
        'schedule': '0 9 * * 1-5',
        'timezone': 'America/New_York',
        'targetPlatform': 'slack',
        'targetChannel': 'C0DEPLOYS',
        'targetIntegrationId': 'int-1',
        'trigger': "Summarize last week's deploys.",
        'enabled': false,
      });
      // No channel, no integration: the keys are left out, not sent as null.
      expect(schedules[1].updateBody(enabled: true)!.keys,
          ['agentId', 'name', 'schedule', 'timezone', 'targetPlatform', 'trigger', 'enabled']);
      // Without an agent the server would refuse it.
      expect(schedules[3].updateBody(enabled: false), isNull);
    });

    test('a channel is named by the integration that posts to it', () {
      expect(integrationChannelName(integrationsJson, 'C0DEPLOYS', integrationId: 'int-1'), 'deploys');
      expect(integrationChannelName(integrationsJson, 'C0DEPLOYS', agentId: 'a2'), 'elsewhere');
      expect(integrationChannelName(integrationsJson, 'C0OTHER', integrationId: 'int-1'), isNull);
      expect(integrationChannelName(integrationsJson, 'C0DEPLOYS', integrationId: 'gone'), isNull);
      expect(integrationChannelName(null, 'C0DEPLOYS', agentId: 'a1'), isNull);
    });
  });

  group('schedule in words', () {
    test('the simple shapes read as words', () {
      expect(scheduleWords(l, '0 * * * *'), 'Every hour');
      expect(scheduleWords(l, '5 * * * *'), 'Every hour at :05');
      expect(scheduleWords(l, '0 9 * * *'), 'Every day at 09:00');
      expect(scheduleWords(l, '30 17 * * 1-5'), 'Weekdays at 17:30');
      expect(scheduleWords(l, '0 9 * * 1'), 'Every Monday at 09:00');
      expect(scheduleWords(l, '15 8 * * 0'), 'Every Sunday at 08:15');
      expect(scheduleWords(l, '  0   9  *  *  6 '), 'Every Saturday at 09:00');
    });

    test('anything else stays an expression', () {
      for (final e in [
        '*/20 * * * *',
        '0 9 1 * *',
        '0 9 * 1 *',
        '0 9 * * 1,3',
        '0 9 * * MON',
        '0 9-17 * * *',
        '5 * * * 1',
        '0 0 9 * * *',
        '@daily',
        '60 9 * * *',
        '0 24 * * *',
        '0 9 * * 7',
        'every tuesday',
        '',
      ]) {
        expect(scheduleWords(l, e), isNull, reason: e);
      }
    });

    test('next run reads as a time of this device', () {
      final now = DateTime(2026, 11, 19, 10, 0);
      expect(plain(nextRunText(l, now.add(const Duration(seconds: 20)), now: now)), 'now');
      expect(plain(nextRunText(l, now.add(const Duration(minutes: 14)), now: now)), 'in 14 min');
      expect(plain(nextRunText(l, DateTime(2026, 11, 19, 15, 0), now: now)), 'Today 3:00 PM');
      expect(plain(nextRunText(l, DateTime(2026, 11, 20, 9, 0), now: now)), 'Tomorrow 9:00 AM');
      expect(plain(nextRunText(l, DateTime(2026, 11, 23, 9, 0), now: now)), 'Mon 9:00 AM');
      expect(plain(nextRunText(l, DateTime(2026, 12, 3, 9, 0), now: now)), 'Dec 3 9:00 AM');
    });

    test('run times and durations', () {
      final now = DateTime(2026, 11, 19, 10, 0);
      expect(plain(runStartText(l, DateTime(2026, 11, 19, 9, 0), now: now)), 'Today 9:00 AM');
      expect(plain(runStartText(l, DateTime(2026, 11, 3, 14, 14), now: now)), 'Nov 3 2:14 PM');
      expect(plain(runStartText(l, DateTime(2025, 11, 3, 14, 14), now: now)), 'Nov 3, 2025 2:14 PM');
      expect(runStartText(l, null), '—');
      expect(runDurationText(245000), '4m 05s');
      expect(runDurationText(900), '1s');
      expect(runDurationText(null), '—');
    });

    test('a refused action shows what the server said', () {
      expect(scheduleActionError(l, ApiException(403, null, 'cannot run this cron')), 'Cannot run this cron.');
      expect(scheduleActionError(l, ApiException(409, null, 'agent move is in progress; retry the cron run')),
          'Agent move is in progress; retry the cron run.');
      expect(scheduleActionError(l, ApiException(503, null, 'daemon is offline')), 'Daemon is offline.');
      expect(scheduleActionError(l, ApiException(403)), l.error403);
      expect(scheduleActionError(l, ApiException(500, null, 'boom')), l.genericError);
      expect(scheduleActionError(l, NetworkException()), l.errNetwork);
    });
  });

  group('cron expressions', () {
    DateTime? next(String e, String zone, DateTime after) => nextCronRun(e, zone, after: after)?.toUtc();
    final thursday = DateTime.utc(2026, 11, 19, 15, 7, 10);

    test('the next run is worked out in the schedule\'s zone', () {
      // 15:07 UTC is 10:07 in New York: today's 09:00 has passed.
      expect(next('0 9 * * 1-5', 'America/New_York', thursday), DateTime.utc(2026, 11, 20, 14));
      expect(next('0 9 * * 1-5', 'Asia/Tokyo', thursday), DateTime.utc(2026, 11, 20, 0));
      expect(next('*/15 * * * *', 'UTC', thursday), DateTime.utc(2026, 11, 19, 15, 15));
      expect(next('0 9 * * *', 'UTC', DateTime.utc(2026, 11, 19, 9)), DateTime.utc(2026, 11, 20, 9));
      expect(next('0 9 * * 6', 'UTC', thursday), DateTime.utc(2026, 11, 21, 9));
      expect(next('0 0 1 1 *', 'UTC', thursday), DateTime.utc(2027, 1, 1));
    });

    test('seconds, years, names and nicknames', () {
      expect(next('30 0 9 * * *', 'UTC', thursday), DateTime.utc(2026, 11, 20, 9, 0, 30));
      expect(next('0 0 9 * * * 2028', 'UTC', thursday), DateTime.utc(2028, 1, 1, 9));
      expect(next('0 0 9 * * * 2020', 'UTC', thursday), isNull);
      expect(next('0 9 * JAN MON', 'UTC', thursday), DateTime.utc(2027, 1, 4, 9));
      expect(next('0 9 ? * sun', 'UTC', thursday), DateTime.utc(2026, 11, 22, 9));
      expect(next('0 9 * * 7', 'UTC', thursday), DateTime.utc(2026, 11, 22, 9));
      expect(next('@daily', 'UTC', thursday), DateTime.utc(2026, 11, 20));
      expect(next('@hourly', 'UTC', thursday), DateTime.utc(2026, 11, 19, 16));
      expect(next('5/20 * * * *', 'UTC', thursday), DateTime.utc(2026, 11, 19, 15, 25));
    });

    test('day of month and weekday together, as the daemon reads them', () {
      // Either one…
      expect(next('0 12 1 * MON', 'UTC', thursday), DateTime.utc(2026, 11, 23, 12));
      // …unless the weekday starts with "+": the 1st that is a Monday.
      expect(next('0 12 1 * +MON', 'UTC', thursday), DateTime.utc(2027, 2, 1, 12));
      expect(next('0 0 L * *', 'UTC', thursday), DateTime.utc(2026, 11, 30));
      expect(next('0 9 * * FRI#L', 'UTC', thursday), DateTime.utc(2026, 11, 27, 9));
      expect(next('0 9 * * 5#2', 'UTC', thursday), DateTime.utc(2026, 12, 11, 9));
      // The 15th is a Sunday: the nearest working day is Monday the 16th.
      expect(next('0 9 15W * *', 'UTC', DateTime.utc(2026, 11, 1)), DateTime.utc(2026, 11, 16, 9));
      // The last working day of November 2026 is Monday the 30th.
      expect(next('0 9 LW * *', 'UTC', thursday), DateTime.utc(2026, 11, 30, 9));
      expect(next('0 0 31 2 *', 'UTC', thursday), isNull);
    });

    test('a time the clocks skip does not run', () {
      // 14 March 2027: New York goes from 02:00 straight to 03:00.
      expect(next('30 2 * * *', 'America/New_York', DateTime.utc(2027, 3, 13, 12)), DateTime.utc(2027, 3, 15, 6, 30));
    });

    test('zones', () {
      expect(next('0 9 * * *', 'Asia/Calcutta', thursday), next('0 9 * * *', 'Asia/Kolkata', thursday));
      expect(next('0 9 * * *', 'Asia/Kolkata', thursday), DateTime.utc(2026, 11, 20, 3, 30));
      expect(next('0 9 * * *', 'Etc/UTC', thursday), DateTime.utc(2026, 11, 20, 9));
      expect(next('0 9 * * *', 'Mars/Phobos', thursday), isNull);
      expect(cronZoneMatchesDevice('Mars/Phobos'), isFalse);
    });

    test('what is not an expression', () {
      for (final e in [
        '',
        'every tuesday',
        '* * *',
        '* * * * * * * *',
        '60 * * * *',
        '0 24 * * *',
        '0 9 32 * *',
        '0 9 * 13 *',
        '0 9 * * 8',
        '0 9 * * +',
        '0 9 5-1 * *',
        '0 9 * * MON#6',
        '*/0 * * * *',
        '@reboot',
      ]) {
        expect(CronExpr.tryParse(e), isNull, reason: e);
      }
    });
  });

  Widget host(Widget child) => MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      );

  void phone(WidgetTester tester, {double height = 812}) {
    tester.view.physicalSize = Size(375, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Finder rich(String text) => find.textContaining(text, findRichText: true);

  group('list', () {
    testWidgets('enabled, paused and invalid schedules', (tester) async {
      phone(tester);
      final semantics = tester.ensureSemantics();
      final client = _FixtureClient();
      final data = OrgData(client, 'org', null);
      addTearDown(data.dispose);
      Schedule? opened;
      await tester.pumpWidget(host(SchedulesView(data: data, onOpen: (s) => opened = s)));
      // Nothing read yet.
      expect(find.text('weekly-deploy-report'), findsNothing);
      await data.refresh();
      await tester.pump();

      expect(find.text('Schedules'), findsOneWidget);
      expect(find.text('3 enabled'), findsOneWidget);
      // Enabled, simple expression: words, the agent's name, a next run.
      expect(find.text('weekly-deploy-report'), findsOneWidget);
      expect(rich('Deploy bot · Weekdays at 09:00'), findsOneWidget);
      // Paused: no next run, says when it last ran.
      expect(find.text('nightly-audit'), findsOneWidget);
      expect(rich('audit-bot · Every day at 02:30'), findsOneWidget);
      expect(find.text('paused'), findsOneWidget);
      expect(find.text('Never run'), findsNWidgets(2));
      expect(find.bySemanticsLabel(RegExp('Only selected members can see this schedule')), findsOneWidget);
      // Invalid: the expression as written, no next run.
      expect(find.text('broken'), findsOneWidget);
      expect(rich('Deploy bot · every tuesday'), findsOneWidget);
      expect(find.text('invalid'), findsOneWidget);
      // No name, no agent, an expression with no plain reading.
      expect(find.text('Unnamed schedule'), findsOneWidget);
      expect(rich('No agent · */20 * * * *'), findsOneWidget);
      expect(find.text('enabled'), findsNWidgets(2));
      expect(find.textContaining('Next run '), findsNWidgets(2));

      await tester.tap(find.text('nightly-audit'));
      expect(opened?.id, 'c-2');
      expect(client.writes(), isEmpty);
      semantics.dispose();
    });

    testWidgets('empty, and an error with a retry', (tester) async {
      phone(tester);
      final client = _FixtureClient(crons: '[]');
      final data = OrgData(client, 'org', null);
      addTearDown(data.dispose);
      await tester.pumpWidget(host(SchedulesView(data: data, onOpen: (_) {})));
      await data.refresh();
      await tester.pump();
      expect(find.text('No schedules yet'), findsOneWidget);
      expect(find.text('0 enabled'), findsNothing);

      final failing = _FixtureClient(listError: NetworkException());
      final data2 = OrgData(failing, 'org', null);
      addTearDown(data2.dispose);
      await tester.pumpWidget(host(SchedulesView(data: data2, onOpen: (_) {})));
      await data2.refresh();
      await tester.pump();
      expect(find.text("Couldn't load schedules"), findsOneWidget);
      failing.listError = null;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(find.text('weekly-deploy-report'), findsOneWidget);

      final forbidden = _FixtureClient(listError: ApiException(403));
      final data3 = OrgData(forbidden, 'org', null);
      addTearDown(data3.dispose);
      await tester.pumpWidget(host(SchedulesView(data: data3, onOpen: (_) {})));
      await data3.refresh();
      await tester.pump();
      expect(find.text("This sign-in can't view schedules."), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });
  });

  group('detail', () {
    Future<(_FixtureClient, OrgData)> open(
      WidgetTester tester, {
      int index = 0,
      bool canWrite = true,
      _FixtureClient? client,
      ValueChanged<SessionRow>? onOpenSession,
    }) async {
      phone(tester, height: 2400);
      final c = client ?? _FixtureClient();
      final data = OrgData(c, 'org', null);
      addTearDown(data.dispose);
      await data.refresh();
      await tester.pumpWidget(host(ScheduleDetailView(
        schedule: data.schedules![index],
        data: data,
        canWrite: canWrite,
        userId: 'u-me',
        onOpenSession: onOpenSession,
      )));
      await tester.pump();
      await tester.pump();
      return (c, data);
    }

    testWidgets('fields and recent runs', (tester) async {
      final semantics = tester.ensureSemantics();
      final opened = <String>[];
      final (client, _) = await open(tester, onOpenSession: (s) => opened.add(s.sessionId));
      expect(find.text('weekly-deploy-report'), findsOneWidget);
      expect(rich('Weekdays at 09:00'), findsOneWidget);
      expect(find.text("Summarize last week's deploys."), findsOneWidget);
      expect(find.text('0 9 * * 1-5'), findsOneWidget);
      expect(find.text('America/New_York'), findsOneWidget);
      // The channel's name comes from the integration that posts to it.
      expect(find.text('Slack · deploys'), findsOneWidget);
      expect(find.text('Everyone'), findsOneWidget);
      expect(find.text('You · Oct 1, 2026'), findsOneWidget);
      expect(find.text('Nov 2, 2026'), findsOneWidget);

      expect(find.text('3 runs'), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Success'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('4m 05s'), findsOneWidget);
      expect(rich('No session · daemon offline'), findsOneWidget);
      // Runs with a session open it; the one without does not.
      expect(find.bySemanticsLabel(RegExp('^Open session')), findsNWidgets(2));
      await tester.tap(find.text('Success'));
      await tester.pump();
      await tester.pump();
      expect(opened, ['s-2']);
      expect(client.writes(), isEmpty);
      semantics.dispose();
    });

    testWidgets('no switch and no Run now without write access', (tester) async {
      final (client, _) = await open(tester, canWrite: false);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Run now'), findsNothing);
      expect(find.textContaining('You can view this schedule, but not change or run it.'), findsOneWidget);
      // Still readable.
      expect(find.text("Summarize last week's deploys."), findsOneWidget);
      expect(find.text('Success'), findsOneWidget);
      expect(client.writes(), isEmpty);
    });

    testWidgets('no switch and no Run now on a schedule this member can\'t edit', (tester) async {
      await open(tester, index: 1);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Run now'), findsNothing);
      expect(find.text('Selected members'), findsOneWidget);
      expect(find.text('Nowhere (stays in its session)'), findsOneWidget);
    });

    testWidgets('Run now asks first, naming the schedule and its agent', (tester) async {
      final (client, _) = await open(tester);
      expect(find.byType(Switch), findsOneWidget);
      await tester.tap(find.text('Run now'));
      await tester.pumpAndSettle();
      expect(find.text('Run “weekly-deploy-report” now?'), findsOneWidget);
      expect(find.text('Deploy bot starts a run of this schedule right away.'), findsOneWidget);
      expect(client.writes(), isEmpty);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(client.writes(), isEmpty);

      await tester.tap(find.text('Run now'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Run now')));
      await tester.pumpAndSettle();
      expect(client.writes().map((c) => (c.$1, c.$2)), [('POST', '/orgs/org/crons/c-1/run')]);
      expect(find.text('Run requested. It shows under Recent runs once the daemon reports it.'), findsOneWidget);
    });

    testWidgets('a refused run shows the server\'s reason', (tester) async {
      final client = _FixtureClient(runError: ApiException(409, null, 'agent move is in progress; retry the cron run'));
      await open(tester, client: client);
      await tester.tap(find.text('Run now'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Run now')));
      await tester.pumpAndSettle();
      expect(find.text('Agent move is in progress; retry the cron run.'), findsOneWidget);
      expect(find.textContaining('Run requested'), findsNothing);
    });

    testWidgets('the switch turns the schedule off, sending the whole definition', (tester) async {
      final (client, data) = await open(tester);
      expect(find.text('enabled'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      final put = client.writes().single;
      expect((put.$1, put.$2), ('PUT', '/orgs/org/crons/c-1'));
      expect(put.$3, schedules.first.updateBody(enabled: false));
      expect(data.schedule('c-1')!.enabled, isFalse);
      // The pill, and "Next run".
      expect(find.text('paused'), findsNWidgets(2));
      expect(find.text('enabled'), findsNothing);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });

    testWidgets('a refused change leaves it as it was and says why', (tester) async {
      final client = _FixtureClient(saveError: ApiException(403, null, 'cannot edit this cron'));
      final (_, data) = await open(tester, client: client);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Cannot edit this cron.'), findsOneWidget);
      expect(data.schedule('c-1')!.enabled, isTrue);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('a schedule whose agent was deleted can\'t be switched or run', (tester) async {
      await open(tester, index: 3);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
      expect(find.textContaining('Its agent was deleted.'), findsOneWidget);
    });

    testWidgets('an invalid expression is called out', (tester) async {
      await open(tester, index: 2);
      expect(find.text('invalid'), findsNWidgets(2));
      expect(find.textContaining("This cron expression can't be read"), findsOneWidget);
    });
  });
}
