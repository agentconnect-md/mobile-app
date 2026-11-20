import 'package:agentconnect/core/auth/app_state.dart';
import 'package:agentconnect/core/auth/token_store.dart';
import 'package:agentconnect/features/chat/bubbles.dart';
import 'package:agentconnect/features/chat/message_markdown.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/ui/theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Chat messages render Markdown the way the web console's transcript does.
void main() {
  Widget host(Widget child, {Brightness brightness = Brightness.light}) => MaterialApp(
        theme: buildTheme(brightness),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(padding: const EdgeInsets.all(16), child: child),
          ),
        ),
      );

  /// Every text run drawn inside the message.
  List<TextSpan> spans(WidgetTester tester) {
    final out = <TextSpan>[];
    final texts = find.descendant(of: find.byType(MessageMarkdown), matching: find.byType(RichText));
    for (final r in tester.widgetList<RichText>(texts)) {
      r.text.visitChildren((s) {
        if (s is TextSpan && s.text != null) out.add(s);
        return true;
      });
    }
    return out;
  }

  TextSpan span(WidgetTester tester, String text) => spans(tester).firstWhere((s) => s.text == text);
  String shown(WidgetTester tester) => spans(tester).map((s) => s.text).join('\n');

  testWidgets('bold, a code block and a link render as rich text', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(host(MessageMarkdown(
      'Here is **bold** and `inline`.\n\n'
      '```dart\nfinal x = 1;\n```\n\n'
      'See [the docs](https://example.com/docs).',
      onOpenLink: opened.add,
    )));
    expect(shown(tester), isNot(contains('**')));
    expect(shown(tester), isNot(contains('```')));
    expect(span(tester, 'bold').style!.fontWeight, FontWeight.w600);
    expect(span(tester, 'inline').style!.fontFamily, monoFamily);
    expect(span(tester, 'inline').style!.backgroundColor, Palette.light.sunken);

    // The code block: monospace, on the sunken surface, scrolling sideways.
    final code = span(tester, 'final x = 1;');
    expect(code.style!.fontFamily, monoFamily);
    final codeText = find.textContaining('final x = 1;', findRichText: true);
    final scroll = tester.widget<SingleChildScrollView>(
        find.ancestor(of: codeText, matching: find.byType(SingleChildScrollView)).first);
    expect(scroll.scrollDirection, Axis.horizontal);
    final box = tester.widget<Container>(find.ancestor(of: codeText, matching: find.byType(Container)).first);
    expect((box.decoration! as BoxDecoration).color, Palette.light.sunken);

    // The link is colored and opens its target.
    expect(span(tester, 'the docs').style!.color, Palette.light.link);
    await tester.tapOnText(find.textRange.ofSubstring('the docs'));
    expect(opened, [Uri.parse('https://example.com/docs')]);
  });

  testWidgets('only http, https and mailto links can be tapped', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(host(MessageMarkdown(
      '[run](javascript:alert) and [hosts](/etc/hosts) and [notes](docs/notes.md) and <tel:123> '
      'and [app](myapp://open) and [mail](mailto:a@example.com) and [upper](HTTPS://EXAMPLE.COM/x)',
      onOpenLink: opened.add,
    )));
    final tappable = spans(tester).where((s) => s.recognizer != null).toList();
    expect(tappable.map((s) => s.text), ['mail', 'upper']);
    // The others still show, as their labels, in the body color.
    final text = shown(tester);
    for (final label in ['run', 'hosts', 'notes', 'tel:123', 'app']) {
      expect(text, contains(label));
    }
    expect(spans(tester).where((s) => s.style?.color == Palette.light.link).length, 2);
    await tester.tapOnText(find.textRange.ofSubstring('hosts'));
    await tester.tapOnText(find.textRange.ofSubstring('run'));
    expect(opened, isEmpty);
    await tester.tapOnText(find.textRange.ofSubstring('mail'));
    await tester.tapOnText(find.textRange.ofSubstring('upper'));
    expect(opened.map((u) => u.scheme), ['mailto', 'https']);
  });

  testWidgets('a reply streaming in never throws, even mid-fence', (tester) async {
    const full = '# Plan\n\n'
        'Some **bold**, _italic_, ~~gone~~ and `code`.\n'
        'Second line.\n\n'
        '- [x] one\n- [ ] two\n  1. nested\n\n'
        '> quoted [link](https://example.com)\n\n'
        '| a | b |\n|---|:-:|\n| 1 | 2 |\n\n'
        '<details>\n<summary>More</summary>\n</details>\n\n'
        '```sh\necho "hi" | cat\n```\n\n'
        'Done ![alt](not-a-url) [dangling](';
    final text = ValueNotifier('');
    await tester.pumpWidget(host(ValueListenableBuilder(
      valueListenable: text,
      builder: (_, value, _) => MessageMarkdown(value),
    )));
    for (var i = 1; i <= full.length; i++) {
      text.value = full.substring(0, i);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'after $i characters');
      // Parsed at every step: the plain-text fallback would mean the parser gave up.
      expect(find.byType(SelectableText), findsNothing, reason: 'after $i characters');
    }
    expect(find.byType(Table), findsOneWidget);
    expect(shown(tester), contains('<summary>More</summary>'));

    // An unclosed fence: what has arrived so far shows as code.
    text.value = 'Running:\n\n```sh\necho "hi"';
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(span(tester, 'echo "hi"').style!.fontFamily, monoFamily);
    expect(shown(tester), isNot(contains('```')));
  });

  testWidgets('a single newline breaks the line', (tester) async {
    await tester.pumpWidget(host(const MessageMarkdown('one\ntwo')));
    expect(span(tester, 'one\ntwo').text, 'one\ntwo');
  });

  testWidgets('over the size limit the message is plain text', (tester) async {
    final long = '**a** ' * (maxMarkdownChars ~/ 6 + 1);
    expect(long.length, greaterThan(maxMarkdownChars));
    await tester.pumpWidget(host(MessageMarkdown(long)));
    expect(tester.takeException(), isNull);
    expect(find.byType(SelectionArea), findsNothing);
    expect(tester.widget<SelectableText>(find.byType(SelectableText)).data, long);

    // A message of ordinary length is parsed.
    await tester.pumpWidget(host(const MessageMarkdown('**a**')));
    expect(find.byType(SelectableText), findsNothing);
    expect(span(tester, 'a').style!.fontWeight, FontWeight.w600);
  });

  testWidgets('colors follow the palette in dark', (tester) async {
    await tester.pumpWidget(host(
      const MessageMarkdown('text\n\n```\ncode\n```'),
      brightness: Brightness.dark,
    ));
    expect(span(tester, 'text').style!.color, Palette.dark.ink);
    expect(span(tester, 'code').style!.color, Palette.dark.ink);
    final codeText = find.textContaining('code', findRichText: true);
    final box = tester.widget<Container>(find.ancestor(of: codeText, matching: find.byType(Container)).first);
    expect((box.decoration! as BoxDecoration).color, Palette.dark.sunken);
  });

  testWidgets('task list boxes use each platform\'s glyph', (tester) async {
    for (final (platform, icon) in [
      (TargetPlatform.iOS, CupertinoIcons.checkmark_square_fill),
      (TargetPlatform.android, Icons.check_box),
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await tester.pumpWidget(host(MessageMarkdown('- [x] done', key: ValueKey(platform))));
        expect(find.byIcon(icon), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }
  });

  testWidgets('agent messages render Markdown, user messages stay as typed, the menu still opens', (tester) async {
    final app = AppState(secrets: MemoryStore());
    await tester.pumpWidget(AppScope(
      state: app,
      child: host(const Column(children: [
        EntryView(entry: UserEntry('**mine**', 'Me'), agent: null),
        EntryView(entry: AgentEntry('**theirs** and more'), agent: null),
      ])),
    ));
    expect(find.text('**mine**'), findsOneWidget);
    expect(span(tester, 'theirs').style!.fontWeight, FontWeight.w600);

    // Long press on the bubble: the message menu, which copies the source text.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await tester.longPressAt(tester.getTopLeft(find.byType(MessageMarkdown)) - const Offset(6, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy text'));
    await tester.pumpAndSettle();
    expect(copied, '**theirs** and more');
  });
}
