import 'dart:convert';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/core/webchat/chat_controller.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:agentconnect/features/chat/fill_card.dart';
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

const _req = '6f9c2f0e-0b7a-4c8e-9d61-2a3b4c5d6e7f';

Map<String, dynamic> _card({String? expiresAt}) => {
      'requestId': _req,
      'computerName': 'Work Mac',
      'website': {'origin': 'https://accounts.example.com', 'title': 'Sign in'},
      'kind': 'login',
      'reason': 'Need to sign in to download the report',
      'expiresAt': expiresAt ?? DateTime.now().add(const Duration(minutes: 10)).toUtc().toIso8601String(),
      'fields': [
        {'id': 'u', 'control': 'email', 'purpose': 'email', 'label': 'Email', 'required': true, 'secret': false, 'empty': true},
        {'id': 'p', 'control': 'password', 'purpose': 'current-password', 'label': 'Password', 'required': true, 'secret': true, 'empty': true},
        {'id': 'r', 'control': 'checkbox', 'purpose': 'unknown', 'label': 'Remember me', 'required': false, 'secret': false, 'empty': true},
      ],
    };

String _out(String turnId, int i, Map<String, dynamic> ev) => jsonEncode({
      'type': 'output',
      'output': {'turnId': turnId, 'index': i, 'event': ev}
    });

ChatController _chat(List<String> sent) =>
    ChatController(client: ApiClient('https://api.example.test/v1', _NoTokens()), orgId: 'o', agentId: 'a')
      ..debugConnect(sent.add);

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  test('decodes fill_request, fill_resolved and refused', () {
    final f = decodeFrame(_out('t', 1, {'kind': 'fill_request', 'card': _card()})) as OutputFrame;
    final card = (f.event as FillRequestEvent).card;
    expect(card.origin, 'https://accounts.example.com');
    expect(card.fields.map((x) => x.id), ['u', 'p', 'r']);
    expect(card.fields[1].masked, isTrue);
    expect(card.unmaskedOnPage, isFalse);
    final r = decodeFrame(_out('t', 2, {'kind': 'fill_resolved', 'requestId': _req, 'outcome': 'filled'})) as OutputFrame;
    expect((r.event as FillResolvedEvent).outcome, 'filled');
    final ref = decodeFrame('{"type":"refused","refused":{"op":"fill_submit","reason":"not yours"}}') as RefusedFrame;
    expect(ref.reason, 'not yours');
    // A one-time code shown as a text input is still masked, and the page may show it.
    final otp = FillField.fromJson({'id': 'c', 'control': 'text', 'purpose': 'one-time-code', 'secret': false})!;
    expect(otp.masked, isTrue);
  });

  test('a fill card from fill_open is shown outside any turn, once', () {
    final sent = <String>[];
    final c = _chat(sent);
    c.debugFrame(_out('fill:$_req', 0, {'kind': 'fill_request', 'card': _card()}));
    c.debugFrame(_out('fill:$_req', 0, {'kind': 'fill_request', 'card': _card()}));
    expect(c.items.where((i) => i.kind == LiveKind.fill).length, 1);
  });

  test('openFill asks for a linked card once the chat is ready', () {
    final sent = <String>[];
    final c = ChatController(client: ApiClient('https://api.example.test/v1', _NoTokens()), orgId: 'o', agentId: 'a');
    c.openFill(_req);
    c.debugConnect(sent.add);
    expect(sent, isEmpty);
    c.debugFrame('{"type":"ready","conversationId":"c"}');
    final frame = jsonDecode(sent.single) as Map<String, dynamic>;
    expect(frame, {'type': 'fill_open', 'requestId': _req, 'agentId': 'a'});
    // Already ready: straight onto the socket.
    c.openFill(_req);
    expect(sent.length, 2);
    // Someone other than the person who asked: the refusal is shown.
    c.debugFrame('{"type":"refused","refused":{"op":"fill_open","reason":"not yours"}}');
    expect(c.items.single.kind, LiveKind.notice);
    expect(c.items.single.text, 'not yours');
  });

  testWidgets('masks secrets, sends only what was entered, clears it, settles', (tester) async {
    final sent = <String>[];
    final c = _chat(sent);
    c.debugFrame(_out('t', 1, {'kind': 'fill_request', 'card': _card()}));
    final item = c.items.single;
    await tester.pumpWidget(_host(ListenableBuilder(
        listenable: c, builder: (_, _) => FillCardView(item: item, chat: c))));

    expect(find.text('https://accounts.example.com'), findsOneWidget);
    expect(find.text('Need to sign in to download the report'), findsOneWidget);
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.length, 2);
    expect(fields[0].obscureText, isFalse);
    expect(fields[1].obscureText, isTrue);

    await tester.enterText(find.byType(TextField).at(0), 'me@example.com');
    await tester.enterText(find.byType(TextField).at(1), 'hunter2');
    await tester.tap(find.text('Fill'));
    await tester.pump();

    final frame = jsonDecode(sent.single) as Map<String, dynamic>;
    expect(frame['type'], 'fill_submit');
    expect(frame['requestId'], _req);
    expect(frame['values'], [
      {'field': 'u', 'value': 'me@example.com'},
      {'field': 'p', 'value': 'hunter2'},
    ]);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Sent to the website…'), findsOneWidget);

    c.debugFrame(_out('t', 2, {'kind': 'fill_resolved', 'requestId': _req, 'outcome': 'filled'}));
    await tester.pump();
    expect(find.text('Filled.'), findsOneWidget);
  });

  testWidgets('cancel declines', (tester) async {
    final sent = <String>[];
    final c = _chat(sent);
    c.debugFrame(_out('t', 1, {'kind': 'fill_request', 'card': _card()}));
    await tester.pumpWidget(_host(ListenableBuilder(
        listenable: c, builder: (_, _) => FillCardView(item: c.items.single, chat: c))));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(jsonDecode(sent.single), {'type': 'fill_submit', 'requestId': _req, 'cancel': true, 'agentId': 'a'});
    expect(find.text('Cancelled; nothing was filled.'), findsOneWidget);
  });

  testWidgets('a refusal shows its reason; an expired card is read-only', (tester) async {
    final sent = <String>[];
    final c = _chat(sent);
    c.debugFrame(_out('t', 1, {'kind': 'fill_request', 'card': _card()}));
    await tester.pumpWidget(_host(ListenableBuilder(
        listenable: c, builder: (_, _) => FillCardView(item: c.items.single, chat: c))));
    await tester.enterText(find.byType(TextField).at(0), 'me@example.com');
    await tester.tap(find.text('Fill'));
    await tester.pump();
    c.debugFrame('{"type":"refused","refused":{"op":"fill_submit","reason":"Only the person who asked can fill this."}}');
    await tester.pump();
    expect(find.text('Only the person who asked can fill this.'), findsOneWidget);
    expect(find.text('Fill'), findsOneWidget);

    final c2 = _chat([]);
    c2.debugFrame(_out('t', 1, {
      'kind': 'fill_request',
      'card': _card(expiresAt: DateTime.now().subtract(const Duration(minutes: 1)).toUtc().toIso8601String())
    }));
    await tester.pumpWidget(_host(FillCardView(item: c2.items.single, chat: c2)));
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Expired; nothing was filled.'), findsOneWidget);
  });
}
