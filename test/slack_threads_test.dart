import 'dart:convert';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/auth/account.dart';
import 'package:agentconnect/core/auth/app_state.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/core/org_data.dart';
import 'package:agentconnect/core/webchat/attachments.dart';
import 'package:agentconnect/core/webchat/chat_controller.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:agentconnect/features/chat/chat_view.dart';
import 'package:agentconnect/features/sessions/session_screen.dart';
import 'package:agentconnect/features/sessions/thread_screen.dart';
import 'package:agentconnect/features/sessions/thread_widgets.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _root = '1765123456.000100';
const _base = 'https://example.test/v1';
const _session = SessionRow(
  sessionId: 'coordinator',
  agentId: 'agent',
  agentName: 'Agent',
  platform: 'slack',
  coordinator: true,
  channelId: 'C1',
);
const _rootRow = {
  'seq': 10,
  'sender': 'U1',
  'senderName': 'Sam',
  'text': 'Root question',
  'ts': _root,
};
const _reply = {
  'seq': 12,
  'sender': 'U2',
  'senderName': 'Lee',
  'text': 'Human reply',
  'thread': _root,
};
const _olderReply = {
  'seq': 11,
  'sender': 'U3',
  'senderName': 'Jo',
  'text': 'Older reply',
  'thread': _root,
};
const _summary = {
  'rootId': _root,
  'replies': 2,
  'readable': true,
  'task': {'state': 'open', 'title': 'Release task', 'sessionId': 'task'},
};
const _history = '/orgs/org/sessions/coordinator/messages';
const _thread = '/orgs/org/sessions/coordinator/threads/$_root/messages';

class _Tokens implements TokenProvider {
  @override
  bool get canWrite => false;
  @override
  Future<String> accessToken() async => 'test';
  @override
  Future<bool> refreshAfter401(String rejected) async => false;
}

class _Api extends ApiClient {
  _Api({
    this.rootsSupported = true,
    this.readable = true,
    this.taskOwned = true,
    this.canContinue = false,
    this.daemonSupportsThreads = false,
  }) : super(_base, _Tokens());
  final bool rootsSupported;
  final bool readable;
  final bool taskOwned;
  final bool canContinue;
  final bool daemonSupportsThreads;
  final calls = <(String, Map<String, String?>?)>[];

  @override
  Future<dynamic> request(
    String method,
    String path, {
    Map<String, String?>? query,
    Object? body,
  }) async {
    calls.add((path, query));
    return switch (path) {
      _history when query?['view'] == 'roots' =>
        rootsSupported
            ? {
                'messages': [_rootRow, _reply],
                'threads': [_summary],
              }
            : throw ApiException(409, 'DAEMON_FEATURE_MISSING'),
      _history => {
        'messages': [_rootRow, _reply],
      },
      _thread => {
        'messages': [
          _rootRow,
          if (query?['cursor'] == 'older') _olderReply,
          _reply,
        ],
        'summary': {
          ..._summary,
          'readable': readable,
          if (!taskOwned) 'task': null,
        },
        if (query?['cursor'] == null) 'nextCursor': 'older',
      },
      '/orgs/org/sessions/coordinator' => {
        'id': 'coordinator',
        'channel': 'C1',
        'tenantScope': 'T1',
        'daemonId': 'daemon',
        'agentId': 'agent',
        'canContinue': canContinue,
        'continuationAttachments': 'images',
      },
      '/orgs/org/sessions/task' => {
        'id': 'task',
        'agentId': 'agent',
        'canContinue': canContinue,
        'continuationAttachments': 'images_and_files',
      },
      '/orgs/org/sessions/coordinator/webchat/token' ||
      '/orgs/org/sessions/task/webchat/token' => throw ApiException(403),
      _ => <String, Object?>{},
    };
  }
}

class _App extends AppState {
  _App(this.client) {
    orgData = OrgData(client, 'org', null)
      ..machines = [
        Machine(
          id: 'daemon',
          name: 'Daemon',
          status: 'online',
          health: 'online',
          cloud: false,
          features: {
            if (client.daemonSupportsThreads) continuationThreadsFeature,
          },
        ),
      ];
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
}

Widget _sessionPage(_Api api, {String? threadRoot}) => AppScope(
  state: _App(api),
  child: MaterialApp(
    theme: buildTheme(Brightness.light),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SessionScreen(
      conversation: const Conversation(
        key: 'coordinator',
        platform: 'slack',
        sessions: [_session],
      ),
      threadRoot: threadRoot,
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Slack roots open a paged thread with people and the task status',
    (tester) async {
      final api = _Api();
      await tester.pumpWidget(_sessionPage(api));
      await tester.pumpAndSettle();
      expect(
        api.calls.where((call) => call.$1 == _history).single.$2?['view'],
        'roots',
      );
      expect(find.text('Root question'), findsOneWidget);
      expect(find.text('Human reply'), findsNothing);
      expect(find.byType(ThreadFooter), findsOneWidget);
      expect(find.text('Release task'), findsOneWidget);

      await tester.tap(find.byType(ThreadFooter));
      await tester.pumpAndSettle();
      expect(api.calls.where((call) => call.$1 == _thread), hasLength(1));
      expect(find.byTooltip('Open in Slack'), findsOneWidget);
      expect(find.text('Human reply'), findsOneWidget);
      expect(find.text('Lee'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Load earlier messages'));
      await tester.pumpAndSettle();
      expect(
        api.calls.where((call) => call.$1 == _thread).last.$2?['cursor'],
        'older',
      );
      expect(find.text('Older reply'), findsOneWidget);
      expect(find.text('Human reply'), findsOneWidget);
      expect(find.text('Lee'), findsOneWidget);
      expect(find.text('Root question'), findsOneWidget);
    },
  );

  testWidgets('direct links respect unreadable Slack threads', (tester) async {
    final api = _Api(readable: false);
    await tester.pumpWidget(_sessionPage(api, threadRoot: _root));
    await tester.pumpAndSettle();
    expect(api.calls.where((call) => call.$1 == _thread), hasLength(1));
    expect(find.text('Human reply'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('Open in Slack'), findsNothing);
  });

  testWidgets(
    'a Slack coordinator falls back to flat history on an older daemon',
    (tester) async {
      final api = _Api(rootsSupported: false);
      await tester.pumpWidget(_sessionPage(api, threadRoot: _root));
      await tester.pumpAndSettle();
      expect(
        api.calls
            .where((call) => call.$1 == _history)
            .map((call) => call.$2?['view']),
        ['roots', null],
      );
      expect(find.text('Human reply'), findsOneWidget);
      expect(find.byType(ThreadScreen), findsNothing);
    },
  );

  test(
    'Slack thread link uses the original timestamp and session detail shape',
    () {
      final detail = SessionRow.fromJson({
        'id': 'coordinator',
        'platform': 'slack',
        'channel': 'C1',
        'tenantScope': 'T1',
        'thread': 'append:coordinator-1',
      });
      expect(detail.sessionId, 'coordinator');
      expect(detail.coordinator, isTrue);
      expect(
        slackThreadUrl(detail.tenantScope, detail.channelId, _root).toString(),
        'https://app.slack.com/client/T1/C1/thread/C1-$_root',
      );
    },
  );

  testWidgets(
    'held Slack thread uses the task grant and task attachment policy',
    (tester) async {
      final api = _Api(canContinue: true);
      await tester.pumpWidget(_sessionPage(api, threadRoot: _root));
      await tester.pumpAndSettle();
      final chat = tester.widget<ChatView>(find.byType(ChatView));
      expect(chat.sessionId, 'task');
      expect(chat.thread, isNull);
      expect(chat.linkThread, _root);
      expect(chat.attachPolicy, AttachPolicy.imagesAndFiles);
      expect(
        api.calls.map((call) => call.$1),
        contains('/orgs/org/sessions/task/webchat/token'),
      );
      expect(
        api.calls.map((call) => call.$1),
        isNot(contains('/orgs/org/sessions/coordinator/webchat/token')),
      );
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets(
    'an unowned Slack thread requires the daemon capability before requesting a grant',
    (tester) async {
      final old = _Api(taskOwned: false, canContinue: true);
      await tester.pumpWidget(_sessionPage(old, threadRoot: _root));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(
        old.calls.map((call) => call.$1),
        isNot(contains('/orgs/org/sessions/coordinator/webchat/token')),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      final current = _Api(
        taskOwned: false,
        canContinue: true,
        daemonSupportsThreads: true,
      );
      await tester.pumpWidget(_sessionPage(current, threadRoot: _root));
      await tester.pumpAndSettle();
      final chat = tester.widget<ChatView>(find.byType(ChatView));
      expect(chat.sessionId, 'coordinator');
      expect(chat.thread, _root);
      expect(chat.attachPolicy, AttachPolicy.images);
      expect(
        current.calls.map((call) => call.$1),
        contains('/orgs/org/sessions/coordinator/webchat/token'),
      );
    },
  );

  test('a platform thread sends only when the relay supports native thread continuations', () {
    final api = _Api();
    final sent = <Map<String, dynamic>>[];
    ChatController chat() => ChatController(
      client: api,
      orgId: 'org',
      agentId: 'agent',
      sessionId: 'coordinator',
      thread: _root,
      continuationThread: true,
    )..debugConnect((raw) => sent.add(jsonDecode(raw) as Map<String, dynamic>));
    String ready(String feature) => jsonEncode({
      'type': 'ready',
      'features': [feature],
    });

    final old = chat();
    old.debugFrame(ready(webchatThreadsFeature));
    expect(old.conn, ChatConn.readOnly);
    old.send('Stay in the thread');
    expect(sent, isEmpty);
    old.dispose();

    final current = chat();
    current.debugFrame(ready(continuationThreadsFeature));
    current.send('Stay in the thread');
    expect(sent.single['thread'], _root);
    expect(sent.single['text'], 'Stay in the thread');
    current.dispose();
  });
}
