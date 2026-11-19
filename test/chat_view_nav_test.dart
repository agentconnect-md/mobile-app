import 'package:agentconnect/core/auth/app_state.dart';
import 'package:agentconnect/features/chat/bubbles.dart';
import 'package:agentconnect/features/chat/chat_view.dart';
import 'package:agentconnect/features/chat/new_divider.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The conversation view as the session screen builds it: stored entries
/// only, no live chat (that opens on the first send).
void main() {
  List<Entry> turns(int from, int to) => [
        for (var seq = from; seq <= to; seq++)
          seq.isOdd ? UserEntry('question $seq', 'Sam', seq: seq) : AgentEntry('answer $seq', seq: seq),
      ];

  Widget host(AppState app,
          {required List<Entry> header,
          List<Entry> older = const [],
          Widget? earlier,
          ValueChanged<bool>? onAtLatest,
          int? focusSeq}) =>
      AppScope(
        state: app,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ChatView(
              agent: null,
              agentId: 'a',
              agentName: 'Agent',
              sessionId: 's-1',
              header: header,
              older: older,
              earlier: earlier,
              onAtLatest: onAtLatest,
              focusSeq: focusSeq,
            ),
          ),
        ),
      );

  double top(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

  testWidgets('opens on the latest message; an older page leaves the view in place', (tester) async {
    final app = AppState();
    final told = <bool>[];
    final header = [const TimeEntry('10:00'), ...turns(21, 60)];
    final earlier = TextButton(onPressed: () {}, child: const Text('Load earlier messages'));
    await tester.pumpWidget(host(app, header: header, earlier: earlier, onAtLatest: told.add));
    await tester.pumpAndSettle();
    expect(find.text('answer 60'), findsOneWidget);
    expect(find.text('question 21'), findsNothing);
    expect(find.byTooltip('Jump to latest'), findsNothing);
    expect(told, [true]);

    // Up to the start of what is loaded: the button is there.
    await tester.fling(find.text('answer 60'), const Offset(0, 4000), 8000);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 4000));
    await tester.pumpAndSettle();
    expect(find.text('Load earlier messages'), findsOneWidget);
    expect(find.byTooltip('Jump to latest'), findsOneWidget);
    expect(told, [true, false]);
    final before = top(tester, 'question 21');

    await tester.pumpWidget(host(app,
        header: header,
        older: [const TimeEntry('09:00'), ...turns(1, 20)],
        earlier: earlier,
        onAtLatest: told.add));
    await tester.pumpAndSettle();
    expect(top(tester, 'question 21'), before);
    expect(find.text('answer 20'), findsOneWidget);
    expect(tester.getBottomLeft(find.text('answer 20')).dy, lessThan(before));

    // A message arrives below meanwhile: the button counts it and leads to it.
    await tester.pumpWidget(host(app,
        header: [...header, const UserEntry('one more', 'Sam', seq: 61)],
        older: [const TimeEntry('09:00'), ...turns(1, 20)],
        earlier: earlier,
        onAtLatest: told.add));
    await tester.pumpAndSettle();
    expect(top(tester, 'question 21'), before);
    expect(find.bySemanticsLabel('1 new message'), findsOneWidget);
    await tester.tap(find.byTooltip('Jump to latest'));
    await tester.pumpAndSettle();
    expect(find.text('one more'), findsOneWidget);
    expect(find.byTooltip('Jump to latest'), findsNothing);
    expect(told, [true, false, true]);
  });

  testWidgets('opens on the New divider when the new messages do not fit the screen', (tester) async {
    final app = AppState();
    final told = <bool>[];
    await tester.pumpWidget(host(app,
        header: [const TimeEntry('10:00'), ...turns(1, 30), const NewDividerEntry(), ...turns(31, 60)],
        onAtLatest: told.add));
    await tester.pumpAndSettle();
    expect(find.byType(NewDivider), findsOneWidget);
    expect(tester.getTopLeft(find.byType(NewDivider)).dy, lessThan(40));
    expect(find.text('question 31'), findsOneWidget);
    expect(find.text('answer 60'), findsNothing);
    // Not read yet: the latest message has not been on screen.
    expect(told, [false]);
  });

  testWidgets('a linked message is landed on, not the latest', (tester) async {
    final app = AppState();
    await tester.pumpWidget(host(app, header: turns(1, 60), focusSeq: 12));
    await tester.pumpAndSettle();
    expect(find.text('answer 12'), findsOneWidget);
    expect(find.text('answer 60'), findsNothing);
    // The highlight on the linked message fades after two seconds.
    await tester.pump(const Duration(seconds: 3));
  });
}
