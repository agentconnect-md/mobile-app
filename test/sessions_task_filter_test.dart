import 'dart:async';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/auth/account.dart';
import 'package:agentconnect/core/auth/app_state.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/core/share_links.dart';
import 'package:agentconnect/core/streaming/live_updates.dart';
import 'package:agentconnect/features/sessions/open_link.dart';
import 'package:agentconnect/features/sessions/sessions_screen.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _base = 'https://example.test/v1';
const _list = '/orgs/org/sessions';
const _facets = '/orgs/org/sessions/facets';

class _Tokens implements TokenProvider {
  @override
  bool get canWrite => true;

  @override
  Future<String> accessToken() async => 'test';

  @override
  Future<bool> refreshAfter401(String rejected) async => false;
}

class _Api extends ApiClient {
  _Api() : super(_base, _Tokens());

  final calls = <(String, Map<String, String?>)>[];
  int revision = 0;

  List<Map<String, String?>> queriesFor(String path) => [
    for (final (url, query) in calls)
      if (url == path) query,
  ];

  @override
  Future<dynamic> request(
    String method,
    String path, {
    Map<String, String?>? query,
    Object? body,
  }) async {
    calls.add((path, query ?? const {}));
    final showTasks = query?['tasks'] != 'exclude';
    switch (path) {
      case _list:
        final first = query?['cursor'] == null;
        return {
          'conversations': first
              ? [
                  _conversation(
                    'coordinator',
                    'Release planning',
                    coordinator: true,
                  ),
                  _conversation('ordinary', 'Ordinary discussion'),
                  for (var i = 0; i < 13; i++)
                    _conversation('filler-$i', 'Discussion $i'),
                ]
              : [
                  if (showTasks)
                    _conversation('task-1', 'Release task', task: true),
                  _conversation('last', 'Earlier conversation'),
                ],
          'total': 16 + (showTasks ? 1 : 0) + revision,
          if (first) 'nextCursor': showTasks ? 'with-tasks' : 'without-tasks',
        };
      case _facets:
        return {
          'integrations': ['slack', if (showTasks) 'github'],
        };
      case '$_list/task-1':
        return {
          'id': 'task-1',
          'agentId': 'agent',
          'platform': 'slack',
          'title': 'Release task',
          'task': true,
        };
      case '$_list/task-1/messages':
        return {
          'messages': [
            {'seq': 1, 'sender': 'user', 'text': 'Task transcript'},
          ],
        };
      default:
        return <String, Object?>{};
    }
  }

  Map<String, Object?> _conversation(
    String id,
    String title, {
    bool coordinator = false,
    bool task = false,
  }) => {
    'key': id,
    'platform': 'slack',
    'sessions': [
      {
        'sessionId': id,
        'agentId': 'agent',
        'agentName': 'Same agent',
        'title': title,
        'coordinator': coordinator,
        'subsession': task,
      },
    ],
  };
}

class _Live extends LiveUpdates {
  _Live(ApiClient client) : super(client, 'org');

  final updates = StreamController<LiveEvent>.broadcast();

  @override
  Stream<LiveEvent> get events => updates.stream;
}

class _App extends AppState {
  _App(this.client, this.live) {
    current = const Account(
      id: 'account',
      apiBase: _base,
      orgId: 'org',
      orgName: 'Org',
      userId: 'u',
      userName: 'Me',
      auth: AuthInfo(issuer: 'test', tokenEndpoint: 'test', clientId: 'test'),
    );
  }

  @override
  final _Api client;

  @override
  final _Live live;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'task mode applies to list, totals, facets, paging, refresh and direct links',
    (tester) async {
      tester.view.physicalSize = const Size(375, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = _Api();
      final live = _Live(api);
      addTearDown(live.updates.close);
      final app = _App(api, live);
      late BuildContext screenContext;
      await tester.pumpWidget(
        AppScope(
          state: app,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                screenContext = context;
                return const SessionsScreen();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(api.queriesFor(_list).single['tasks'], 'exclude');
      expect(api.queriesFor(_facets).single['tasks'], 'exclude');
      expect(find.text('16 sessions'), findsOneWidget);
      expect(find.text('Coordinator'), findsOneWidget);
      expect(find.text('Ordinary discussion'), findsOneWidget);
      expect(find.text('Release task'), findsNothing);

      await tester.tap(find.text('Integration'));
      await tester.pumpAndSettle();
      expect(find.text('GitHub'), findsNothing);
      await tester.tap(find.text('Slack'));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      expect(api.queriesFor(_list).last['cursor'], 'without-tasks');
      expect(api.queriesFor(_list).last['tasks'], 'exclude');
      expect(find.text('Earlier conversation'), findsOneWidget);
      expect(find.text('Release task'), findsNothing);

      await tester.drag(find.byType(ListView), const Offset(0, 1500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show tasks'));
      await tester.pumpAndSettle();
      expect(api.queriesFor(_list).last['cursor'], isNull);
      expect(api.queriesFor(_list).last['tasks'], isNull);
      expect(api.queriesFor(_list).last['integration'], 'slack');
      expect(api.queriesFor(_facets).last['tasks'], isNull);
      expect(api.queriesFor(_facets).last['integration'], 'slack');
      expect(find.text('17 sessions'), findsOneWidget);
      await tester.tap(find.text('Slack'));
      await tester.pumpAndSettle();
      expect(find.text('GitHub'), findsOneWidget);
      Navigator.of(screenContext).pop();
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      expect(api.queriesFor(_list).last['cursor'], 'with-tasks');
      expect(api.queriesFor(_list).last['tasks'], isNull);
      expect(find.text('Release task'), findsOneWidget);

      api.revision++;
      live.updates.add(const LiveEvent('connected'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));
      await tester.pumpAndSettle();
      expect(api.queriesFor(_list).last['tasks'], isNull);
      expect(api.queriesFor(_facets).last['tasks'], isNull);

      await tester.drag(find.byType(ListView), const Offset(0, 1500));
      await tester.pumpAndSettle();
      expect(find.text('18 sessions'), findsOneWidget);
      await tester.tap(find.text('Show tasks'));
      await tester.pumpAndSettle();
      expect(api.queriesFor(_list).last['tasks'], 'exclude');
      expect(api.queriesFor(_facets).last['tasks'], 'exclude');
      expect(find.text('17 sessions'), findsOneWidget);
      expect(find.text('Release task'), findsNothing);

      unawaited(
        openConsoleLink(
          screenContext,
          const ConsoleLink(slug: '-', sessionId: 'task-1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.queriesFor('$_list/task-1').map((query) => query['tasks']), everyElement(isNull));
      expect(find.text('Task transcript'), findsOneWidget);
    },
  );
}
