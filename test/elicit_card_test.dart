import 'dart:convert';

import 'package:agentconnect/core/api/api_client.dart';
import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/auth/oauth_session.dart';
import 'package:agentconnect/core/webchat/chat_controller.dart';
import 'package:agentconnect/core/webchat/elicit.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:agentconnect/features/chat/bubbles.dart';
import 'package:agentconnect/features/chat/elicit_card.dart';
import 'package:agentconnect/features/sessions/transcript.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/ui/theme.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart';
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

const _agent = '3b1f7c52-6f0e-4d0a-9a53-0c1d2e3f4a5b';

// The `elicitation` event shapes of protocol `ElicitCard` (frames/webchat.ts).
Map<String, dynamic> _single() => {
      'kind': 'elicitation',
      'requestId': 'elicit-1',
      'message': 'Which environment?\nThe deploy targets one of them.',
      'options': [
        {'value': 'staging', 'label': 'Staging'},
        {'value': 'prod', 'label': 'Production'},
      ],
    };

Map<String, dynamic> _multi() => {
      'kind': 'elicitation',
      'requestId': 'elicit-2',
      'message': 'Which checks should run?',
      'options': [
        {'value': 'lint', 'label': 'Lint'},
        {'value': 'unit', 'label': 'Unit tests'},
        {'value': 'e2e', 'label': 'End to end'},
      ],
      'multi': {'minItems': 1, 'maxItems': 2},
      'defaultValue': ['lint'],
    };

Map<String, dynamic> _number() => {
      'kind': 'elicitation',
      'requestId': 'elicit-3',
      'message': 'How many replicas?',
      'options': <dynamic>[],
      'number': {'integer': true, 'minimum': 1, 'maximum': 5},
    };

Map<String, dynamic> _text() => {
      'kind': 'elicitation',
      'requestId': 'elicit-4',
      'message': 'Who should be notified?',
      'options': <dynamic>[],
      'text': {'format': 'email', 'maxLength': 120},
    };

Map<String, dynamic> _form() => {
      'kind': 'elicitation',
      'requestId': 'elicit-5',
      'message': 'A few details before I start',
      'options': <dynamic>[],
      'fields': [
        {
          'propName': 'question_0',
          'label': 'Scope',
          'kind': 'enum',
          'required': true,
          'description': 'How much should change?',
          'options': [
            {'value': 'Small', 'label': 'Small'},
            {'value': 'Large', 'label': 'Large'},
          ],
        },
        {
          'propName': 'question_0_custom',
          'label': 'Other',
          'kind': 'text',
          'customAnswerFor': 'question_0',
          'options': <dynamic>[],
          'text': {'maxLength': 500},
        },
        {
          'propName': 'areas',
          'label': 'Areas',
          'kind': 'multi-enum',
          'options': [
            {'value': 'api', 'label': 'API'},
            {'value': 'web', 'label': 'Web'},
          ],
          'multi': {'maxItems': 2},
        },
        {
          'propName': 'count',
          'label': 'Reviewers',
          'kind': 'number',
          'required': true,
          'options': <dynamic>[],
          'number': {'integer': true, 'minimum': 1},
        },
        {
          'propName': 'note',
          'label': 'Note',
          'kind': 'text',
          'options': <dynamic>[],
          'text': {'maxLength': 200},
        },
      ],
    };

Map<String, dynamic> _url(String url) => {
      'kind': 'elicitation',
      'requestId': 'elicit-6',
      'message': 'Sign in to continue',
      'options': <dynamic>[],
      'url': url,
    };

String _out(String turnId, int i, Map<String, dynamic> ev) => jsonEncode({
      'type': 'output',
      'output': {'turnId': turnId, 'index': i, 'event': ev}
    });

Map<String, dynamic> _resolved(String id, String outcome, [String? label]) =>
    {'kind': 'elicitation_resolved', 'requestId': id, 'outcome': outcome, 'label': ?label};

ChatController _chat(List<String> sent) =>
    ChatController(client: ApiClient('https://api.example.test/v1', _NoTokens()), orgId: 'o', agentId: _agent)
      ..debugConnect(sent.add);

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Future<ChatController> _pump(WidgetTester tester, List<String> sent, Map<String, dynamic> event,
    {Future<bool> Function(Uri)? openUrl}) async {
  final c = _chat(sent);
  c.debugFrame(_out('t', 1, event));
  await tester.pumpWidget(_host(ListenableBuilder(
      listenable: c, builder: (_, _) => ElicitCardView(item: c.items.first, chat: c, openUrl: openUrl))));
  return c;
}

Finder _field(String propName) => find.byKey(ValueKey('elicit-field:$propName'));

/// A form is taller than the default test surface.
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Map<String, dynamic> _frame(List<String> sent) => jsonDecode(sent.single) as Map<String, dynamic>;

void main() {
  group('decoding', () {
    test('reads every card shape and the resolution', () {
      ElicitCard card(Map<String, dynamic> ev) =>
          ((decodeFrame(_out('t', 1, ev)) as OutputFrame).event as ElicitationEvent).card;
      expect(card(_single()).mode, ElicitMode.single);
      expect(card(_single()).headLine, 'Which environment?');
      expect(card(_single()).preamble, 'The deploy targets one of them.');
      expect(card(_multi()).mode, ElicitMode.multi);
      expect(card(_multi()).pickedDefault, ['lint']);
      expect(card(_number()).mode, ElicitMode.typed);
      expect(card(_text()).text!.format, 'email');
      final form = card(_form());
      expect(form.mode, ElicitMode.form);
      expect(form.fields!.map((f) => f.propName), ['question_0', 'question_0_custom', 'areas', 'count', 'note']);
      expect(card(_url('https://login.example.com/device?code=AB')).mode, ElicitMode.url);
      // Only http and https are something to open; anything else can only be dismissed.
      expect(card(_url('javascript:alert(1)')).mode, ElicitMode.unanswerable);
      // A field kind this build doesn't know: the card can't be half-answered.
      final unknown = _form();
      ((unknown['fields'] as List)[0] as Map)['kind'] = 'color';
      expect(card(unknown).mode, ElicitMode.unanswerable);

      final r = (decodeFrame(_out('t', 2, _resolved('elicit-1', 'accepted', 'Staging'))) as OutputFrame).event
          as ElicitationResolvedEvent;
      expect((r.requestId, r.outcome, r.label), ('elicit-1', 'accepted', 'Staging'));
      // An outcome this build doesn't know isn't read as a verdict.
      expect((decodeFrame(_out('t', 2, _resolved('elicit-1', 'vetoed'))) as OutputFrame).event, isA<UnsupportedEvent>());
      expect((decodeFrame(_out('t', 1, {'kind': 'elicitation', 'message': 'x'})) as OutputFrame).event,
          isA<UnsupportedEvent>());
    });

    test('a saved question row is a read-only card; the live copy stands in for it', () {
      TranscriptItem row(Map<String, dynamic> extra) => buildTranscript([
            ApiMessage.fromJson({
              'seq': 3,
              'sender': 'agent-1',
              'kind': 'elicit',
              'text': 'Which environment?',
              'body': jsonEncode({..._single()..remove('kind'), ...extra}),
            })
          ], {
            'agent-1'
          }).single;
      final answered = entriesFromTranscript([row({'outcome': 'accepted', 'answerLabel': 'Staging'})]).single as ElicitEntry;
      expect(answered.item.elicit!.message, 'Which environment?');
      expect((answered.item.elicitOutcome, answered.item.elicitLabel), ('accepted', 'Staging'));
      // Nothing recorded how it ended: read-only all the same.
      final open = entriesFromTranscript([row({})]).single as ElicitEntry;
      expect(open.item.elicitOutcome, 'unanswered');
      expect((entriesFromTranscript([row({'outcome': 'unrenderable'})]).single as ElicitEntry).item.elicitOutcome,
          'unrenderable');
      expect(entriesFromTranscript([TranscriptItem(seq: 4, kind: ItemKind.other, text: 'q', rawKind: 'elicit')]).single,
          isA<UnsupportedEntry>());

      final c = _chat([]);
      c.debugFrame(_out('t', 1, _single()));
      final shown = groupTools([open, ...entriesFromLive(c.items, null)]);
      expect((shown.single as ElicitEntry).item, same(c.items.single));
    });

    testWidgets('a saved card shows how it ended and offers nothing to tap', (tester) async {
      for (final (outcome, label, text) in [
        ('accepted', 'Staging', 'Staging'),
        ('unanswered', null, 'Not answered'),
        ('unrenderable', null, "Couldn't be answered here"),
      ]) {
        final item = LiveItem(LiveKind.elicit, '', requestId: 'elicit-1')
          ..elicit = ElicitCard.fromJson(_single())
          ..elicitOutcome = outcome
          ..elicitLabel = label;
        await tester.pumpWidget(_host(ElicitCardView(key: ValueKey(outcome), item: item, chat: null)));
        expect(find.text(text), findsOneWidget);
        expect(find.text('Production'), findsNothing);
        expect(find.byTooltip('Decline without answering'), findsNothing);
      }
    });

    test('a card is listed once, and a question can not outlive its turn', () {
      final c = _chat([]);
      c.debugFrame(_out('t', 1, _single()));
      c.debugFrame(_out('t', 1, _single()));
      expect(c.items.where((i) => i.kind == LiveKind.elicit).length, 1);
      c.debugFrame('{"type":"done","done":{"turnId":"other"}}');
      expect(c.items.single.elicitOutcome, isNull);
      c.debugFrame('{"type":"done","done":{"turnId":"t"}}');
      expect(c.items.single.elicitOutcome, 'cancelled');
    });
  });

  group('rules', () {
    test('typed answers are checked as the daemon checks them', () {
      const n = ElicitSpec(number: ElicitNumber(integer: true, minimum: 1, maximum: 5));
      expect(typedProblem(n, ''), const ElicitNote('number'));
      expect(typedProblem(n, 'abc'), const ElicitNote('number'));
      expect(typedProblem(n, '2.5'), const ElicitNote('whole'));
      expect(typedProblem(n, '0'), const ElicitNote('min', '1'));
      expect(typedProblem(n, '6'), const ElicitNote('max', '5'));
      expect(typedProblem(n, '3'), isNull);
      expect(parseNumber('3'), isA<int>());
      expect(parseNumber('3.0'), 3);
      expect(parseNumber('2.5'), 2.5);
      expect(parseNumber('Infinity'), isNull);

      ElicitNote? text(ElicitText t, String v) => typedProblem(ElicitSpec(text: t), v);
      expect(text(const ElicitText(), ''), const ElicitNote('answer'));
      expect(text(const ElicitText(minLength: 3), 'ab'), const ElicitNote('minLength', 3));
      expect(text(const ElicitText(maxLength: 3), 'abcd'), const ElicitNote('maxLength', 3));
      expect(text(const ElicitText(format: 'email'), 'me@example'), const ElicitNote('email'));
      expect(text(const ElicitText(format: 'email'), 'me@example.com'), isNull);
      expect(text(const ElicitText(format: 'uri'), 'example.com'), const ElicitNote('uri'));
      expect(text(const ElicitText(format: 'uri'), 'https://example.com'), isNull);
      expect(text(const ElicitText(format: 'date'), '2025-13-01'), const ElicitNote('date'));
      expect(text(const ElicitText(format: 'date'), '2025-02-30'), const ElicitNote('date'));
      expect(text(const ElicitText(format: 'date'), '2025-02-28'), isNull);
      expect(text(const ElicitText(format: 'date-time'), '2025-01-31 09:00'), const ElicitNote('dateTime'));
      expect(text(const ElicitText(format: 'date-time'), '2025-01-31T09:00:00Z'), isNull);
      expect(text(const ElicitText(format: 'date-time'), '2025-01-31T09:00:00.5+08:00'), isNull);
      expect(text(const ElicitText(pattern: r'^[A-Z]{3}$'), 'ab'), const ElicitNote('pattern', r'^[A-Z]{3}$'));
      expect(text(const ElicitText(pattern: r'^[A-Z]{3}$'), 'ABC'), isNull);
      expect(text(const ElicitText(pattern: '('), 'x'), const ElicitNote('cannot'));
      // No descriptor, no constraint.
      expect(typedProblem(const ElicitSpec(), ''), isNull);
    });

    test('selection hints follow the bounds', () {
      expect(selectionHint(const ElicitMulti(minItems: 2, maxItems: 2)), const ElicitNote('selectExactly', 2));
      expect(selectionHint(const ElicitMulti(minItems: 1, maxItems: 3)), const ElicitNote('selectRange', 1, 3));
      expect(selectionHint(const ElicitMulti(minItems: 1)), const ElicitNote('selectAtLeast', 1));
      expect(selectionHint(const ElicitMulti(maxItems: 2)), const ElicitNote('selectUpTo', 2));
      expect(selectionHint(null), const ElicitNote('selectAny'));
      expect(selectionFits(const ElicitMulti(minItems: 1, maxItems: 2), 0), isFalse);
      expect(selectionFits(const ElicitMulti(minItems: 1, maxItems: 2), 2), isTrue);
      expect(selectionFits(const ElicitMulti(minItems: 1, maxItems: 2), 3), isFalse);
    });

    test('an unbound "Other" box is folded into its question by name', () {
      ElicitField f(String name, String kind, {String label = '', bool required = false, List<String> options = const []}) =>
          ElicitField(
              propName: name,
              label: label,
              kind: kind,
              required: required,
              defaultValue: kind == 'enum' ? 'Other' : null,
              options: [for (final o in options) ElicitOption(o, o)]);
      final folded = foldCustomAnswers([
        f('need_type', 'enum', label: 'Need', options: ['Bug', 'Feature', 'Other']),
        f('need_type__other', 'text', label: 'Other'),
        f('size', 'enum', label: 'Size', options: ['S', 'L']),
        f('size_custom', 'text', label: 'Something else', required: true),
        f('other', 'text', label: 'Other'),
      ]);
      expect(folded[1].customAnswerFor, 'need_type');
      // The box replaces the enum's own "Other" choice, and a default naming it goes too.
      expect(folded[0].options.map((o) => o.value), ['Bug', 'Feature']);
      expect(folded[0].defaultValue, isNull);
      // A required box is a question of its own, whatever it is named.
      expect(folded[3].customAnswerFor, isNull);
      expect(folded[4].customAnswerFor, isNull);
    });

    test('a form answers each field in its schema type and leaves blanks out', () {
      final fields = ElicitCard.fromJson(_form())!.fields!;
      final q = fields[0], box = fields[1];
      expect(rowProblem(q, box, {}, {}), const ElicitNote('chooseOne'));
      // A required question's own control must be answered; the box alone doesn't stand in.
      expect(rowProblem(q, box, {'question_0_custom': 'Medium'}, {}), const ElicitNote('chooseOne'));
      expect(rowProblem(q, box, {}, {'question_0': ['Small']}), isNull);
      expect(rowProblem(fields[2], null, {}, {}), isNull);
      expect(rowProblem(fields[3], null, {}, {}), const ElicitNote('number'));
      expect(rowProblem(fields[4], null, {}, {}), isNull);
      expect(rowAnswered(q, box, {}, {}), isFalse);
      expect(rowAnswered(q, box, {}, {'question_0': ['Small']}), isTrue);
      expect(
          formAnswer(fields, {'count': '2', 'note': '  ', 'question_0_custom': 'Medium'}, {
            'question_0': ['Small'],
            'areas': ['api', 'web'],
          }),
          {
            'question_0': 'Small',
            'question_0_custom': 'Medium',
            'areas': ['api', 'web'],
            'count': 2,
          });
    });

    test('a consent URL is split as written and warns about its host', () {
      final ok = readConsentUrl('https://login.example.com/device?code=AB')!;
      expect((ok.scheme, ok.host, ok.rest), ('https://', 'login.example.com', '/device?code=AB'));
      expect(ok.warnings, isEmpty);
      expect(readConsentUrl('http://example.com')!.warnings, [const ElicitNote('http')]);
      final at = readConsentUrl('https://login.example.com@evil.test/x')!;
      expect(at.host, 'login.example.com@evil.test');
      expect(at.warnings, [const ElicitNote('userinfo', 'evil.test')]);
      expect(readConsentUrl('https://xn--pple-43d.com/')!.warnings, [const ElicitNote('lookalike')]);
      expect(readConsentUrl('https://аpple.com/')!.warnings, [const ElicitNote('lookalike')]);
      expect(readConsentUrl('ftp://example.com'), isNull);
      expect(readConsentUrl('javascript:alert(1)'), isNull);
      expect(readConsentUrl('not a url'), isNull);
    });
  });

  group('card', () {
    testWidgets('a single choice answers on the tap and settles with its label', (tester) async {
      final sent = <String>[];
      final c = await _pump(tester, sent, _single());
      expect(find.text('Which environment?'), findsOneWidget);
      expect(find.text('The deploy targets one of them.'), findsOneWidget);

      await tester.tap(find.text('Staging'));
      await tester.pump();
      expect(_frame(sent), {'type': 'elicitation_choice', 'requestId': 'elicit-1', 'value': 'staging', 'agentId': _agent});
      // Not optimistic: the daemon settles the card.
      expect(find.text('Sent. Waiting for the agent…'), findsOneWidget);
      expect(find.text('Production'), findsNothing);

      c.debugFrame(_out('t', 2, _resolved('elicit-1', 'accepted', 'Staging')));
      await tester.pump();
      expect(find.text('Staging'), findsOneWidget);
      expect(find.text('Sent. Waiting for the agent…'), findsNothing);
      expect(find.byTooltip('Decline without answering'), findsNothing);
    });

    testWidgets('the corner button declines; a refused answer opens the card again', (tester) async {
      final sent = <String>[];
      final c = await _pump(tester, sent, _single());
      await tester.tap(find.byTooltip('Decline without answering'));
      await tester.pump();
      expect(_frame(sent)['value'], isNull);
      expect(_frame(sent).containsKey('value'), isTrue);
      // The daemon says a refusal in a notice and leaves the question open.
      c.debugFrame(_out('t', 2, {'kind': 'notice', 'text': "That answer wasn't accepted — the question is still open."}));
      await tester.pump();
      expect(find.text('Production'), findsOneWidget);

      await tester.tap(find.text('Production'));
      await tester.pump();
      expect(sent.length, 2);
      // No verdict at all: the person can open it again.
      await tester.tap(find.text('Answer again'));
      await tester.pump();
      expect(find.text('Staging'), findsOneWidget);

      c.debugFrame(_out('t', 3, _resolved('elicit-1', 'dismissed')));
      await tester.pump();
      expect(find.text('Dismissed'), findsOneWidget);
      expect(find.text('Staging'), findsNothing);
    });

    testWidgets('a multi-select holds its picks until Confirm, within its bounds', (tester) async {
      final sent = <String>[];
      await _pump(tester, sent, _multi());
      expect(find.text('Select 1–2'), findsOneWidget);
      // Starts with the schema default (Lint); a second pick reaches the cap.
      await tester.tap(find.text('End to end'));
      await tester.pump();
      await tester.tap(find.text('Unit tests'));
      await tester.pump();
      expect(sent, isEmpty);
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      expect(_frame(sent)['value'], ['lint', 'e2e']);
    });

    testWidgets('Confirm waits for the minimum', (tester) async {
      final sent = <String>[];
      await _pump(tester, sent, _multi()..remove('defaultValue'));
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      expect(sent, isEmpty);
    });

    testWidgets('a number is sent as a number, once it fits', (tester) async {
      final sent = <String>[];
      final c = await _pump(tester, sent, _number());
      expect(find.text('Enter a number'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '9');
      await tester.pump();
      expect(find.text('Enter 5 or less'), findsOneWidget);
      await tester.tap(find.text('Submit'));
      await tester.pump();
      expect(sent, isEmpty);

      await tester.enterText(find.byType(TextField), '3');
      await tester.pump();
      await tester.tap(find.text('Submit'));
      await tester.pump();
      expect(_frame(sent)['value'], 3);
      expect(_frame(sent)['value'], isA<int>());

      c.debugFrame(_out('t', 2, _resolved('elicit-3', 'accepted')));
      await tester.pump();
      expect(find.text('Answered'), findsOneWidget);
    });

    testWidgets('typed text is checked, sent, and cleared from the card', (tester) async {
      final sent = <String>[];
      final c = await _pump(tester, sent, _text());
      await tester.enterText(find.byType(TextField), 'ada');
      await tester.pump();
      expect(find.text('Enter an email address'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'ada@example.com');
      await tester.pump();
      await tester.tap(find.text('Submit'));
      await tester.pump();
      expect(_frame(sent)['value'], 'ada@example.com');
      // Opened again, the card holds nothing of what was typed.
      await tester.tap(find.text('Answer again'));
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);

      await tester.tap(find.text('Dismiss'));
      await tester.pump();
      expect(jsonDecode(sent.last), {'type': 'elicitation_choice', 'requestId': 'elicit-4', 'value': null, 'agentId': _agent});
      c.debugFrame('{"type":"done","done":{"turnId":"t"}}');
      await tester.pump();
      expect(find.text('Cancelled'), findsOneWidget);
    });

    testWidgets('a form sends a value per answered field', (tester) async {
      _tall(tester);
      final sent = <String>[];
      await _pump(tester, sent, _form());
      expect(find.text('0/4 answered'), findsOneWidget);
      expect(find.text('How much should change?'), findsOneWidget);
      expect(find.text('Choose one'), findsOneWidget);
      // The "Other" box is part of its question, not a question of its own.
      expect(find.text('Other'), findsNothing);
      await tester.tap(find.text('Submit answers'));
      await tester.pump();
      expect(sent, isEmpty);

      await tester.tap(find.text('Large'));
      await tester.pump();
      await tester.tap(find.text('Small'));
      await tester.pump();
      await tester.tap(find.text('Other…'));
      await tester.pump();
      await tester.enterText(_field('question_0_custom'), 'Only the tests');
      await tester.tap(find.text('API'));
      await tester.pump();
      await tester.enterText(_field('count'), '2');
      await tester.pump();
      expect(find.text('3/4 answered'), findsOneWidget);
      await tester.tap(find.text('Submit answers'));
      await tester.pump();
      expect(_frame(sent)['value'], {
        'question_0': 'Small',
        'question_0_custom': 'Only the tests',
        'areas': ['api'],
        'count': 2,
      });
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('closing "Other" drops what it held', (tester) async {
      _tall(tester);
      final sent = <String>[];
      await _pump(tester, sent, _form());
      await tester.tap(find.text('Small'));
      await tester.tap(find.text('Other…'));
      await tester.pump();
      await tester.enterText(_field('question_0_custom'), 'hidden');
      await tester.tap(find.text('Other…'));
      await tester.pump();
      await tester.enterText(_field('count'), '1');
      await tester.pump();
      await tester.tap(find.text('Submit answers'));
      await tester.pump();
      expect(_frame(sent)['value'], {'question_0': 'Small', 'count': 1});
    });

    testWidgets('a link is shown as written, warned about, and opened only on consent', (tester) async {
      final sent = <String>[];
      final opened = <Uri>[];
      const url = 'http://login.example.com@evil.test/device?code=AB';
      final c = await _pump(tester, sent, _url(url), openUrl: (u) async {
        opened.add(u);
        return true;
      });
      expect(find.textContaining('login.example.com@evil.test', findRichText: true), findsOneWidget);
      expect(find.textContaining('Not encrypted (http)'), findsOneWidget);
      expect(find.text('This link goes to evil.test. The text before the @ is not the destination.'), findsOneWidget);
      expect(opened, isEmpty);

      await tester.tap(find.text('Open link'));
      await tester.pump();
      // Consent echoes the card's own URL back.
      expect(_frame(sent)['value'], url);
      expect(opened.single.toString(), url);

      c.debugFrame(_out('t', 2, _resolved('elicit-6', 'accepted', 'Opened')));
      await tester.pump();
      expect(find.text('Opened'), findsOneWidget);
      c.debugFrame(_out('t', 3, _resolved('elicit-6', 'completed')));
      await tester.pump();
      expect(find.text('Completed'), findsOneWidget);
    });

    testWidgets('Decline refuses a link without opening it', (tester) async {
      final sent = <String>[];
      final opened = <Uri>[];
      await _pump(tester, sent, _url('https://login.example.com/device'), openUrl: (u) async {
        opened.add(u);
        return true;
      });
      expect(find.byTooltip('Refuse without opening'), findsOneWidget);
      await tester.tap(find.text('Decline'));
      await tester.pump();
      expect(_frame(sent)['value'], isNull);
      expect(opened, isEmpty);
    });

    testWidgets('nothing is sent or opened while the chat is not connected', (tester) async {
      final opened = <Uri>[];
      final c = ChatController(client: ApiClient('https://api.example.test/v1', _NoTokens()), orgId: 'o', agentId: _agent);
      c.debugFrame(_out('t', 1, _url('https://login.example.com/device')));
      await tester.pumpWidget(_host(ListenableBuilder(
          listenable: c,
          builder: (_, _) => ElicitCardView(
              item: c.items.first,
              chat: c,
              openUrl: (u) async {
                opened.add(u);
                return true;
              }))));
      await tester.tap(find.text('Open link'));
      await tester.pump();
      expect(opened, isEmpty);
      expect(find.text('Not connected to this conversation; nothing was sent. Try again.'), findsOneWidget);
      expect(find.text('Open link'), findsOneWidget);
    });

    testWidgets('a card this build can not read can only be dismissed', (tester) async {
      final sent = <String>[];
      await _pump(tester, sent, _url('javascript:alert(1)'));
      expect(find.text('Open link'), findsNothing);
      expect(find.textContaining("can't be answered in this app"), findsOneWidget);
      await tester.tap(find.text('Dismiss'));
      await tester.pump();
      expect(_frame(sent)['value'], isNull);
    });
    testWidgets('fits the narrowest phone on both platforms, with each platform\'s glyphs', (tester) async {
      tester.view.physicalSize = const Size(375, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          for (final ev in [_form(), _multi(), _url('http://login.example.com@evil.test/a/very/long/path?with=a&long=query')]) {
            await _pump(tester, [], ev);
            expect(tester.takeException(), isNull);
          }
          await _pump(tester, [], _multi());
          final ios = platform == TargetPlatform.iOS;
          expect(find.byIcon(CupertinoIcons.checkmark_square_fill), ios ? findsOneWidget : findsNothing);
          expect(find.byIcon(Icons.check_box), ios ? findsNothing : findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });
  });
}
