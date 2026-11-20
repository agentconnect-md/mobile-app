import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/auth/app_state.dart';
import 'package:agentconnect/core/auth/native.dart';
import 'package:agentconnect/core/auth/token_store.dart';
import 'package:agentconnect/features/desktop/desktop_nav.dart';
import 'package:agentconnect/features/desktop/desktop_shell.dart';
import 'package:agentconnect/features/sessions/session_tile.dart';
import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/ui/adaptive.dart';
import 'package:agentconnect/ui/desktop_keys.dart';
import 'package:agentconnect/ui/icons.dart';
import 'package:agentconnect/ui/tab_bar.dart';
import 'package:agentconnect/ui/theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// iOS follows the Human Interface Guidelines; Android keeps the Material look.
void main() {
  Widget app(Widget Function(BuildContext) body, {int tab = 0, ValueChanged<int>? onTab}) => MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          appBar: AppBar(title: const Text('Title')),
          body: Builder(builder: (c) => Center(child: body(c))),
          bottomNavigationBar: AppTabBar(index: tab, onSelected: onTab ?? (_) {}, pendingApprovals: 2),
        ),
      );

  /// Runs [body] as [platform]; the override is cleared before the test ends.
  void on(String name, TargetPlatform platform, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  on('iOS: system tab bar, filled selected glyph, no ripple, centered 17 pt title', TargetPlatform.iOS, (tester) async {
    int? picked;
    await tester.pumpWidget(app((_) => const Spinner(), onTab: (i) => picked = i));
    expect(find.byType(CupertinoTabBar), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byIcon(CupertinoIcons.house_fill), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    final theme = Theme.of(tester.element(find.byType(Scaffold)));
    expect(theme.splashFactory, NoSplash.splashFactory);
    expect(theme.appBarTheme.centerTitle, isTrue);
    expect(theme.appBarTheme.titleTextStyle?.fontSize, 17);
    await tester.tap(find.text('Sessions'));
    expect(picked, 2);
  });

  on('Android: Material navigation bar, ripple, left 20 pt title', TargetPlatform.android, (tester) async {
    await tester.pumpWidget(app((_) => const Spinner()));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(CupertinoTabBar), findsNothing);
    expect(find.byIcon(Icons.home_outlined), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final theme = Theme.of(tester.element(find.byType(Scaffold)));
    expect(theme.splashFactory, InkSparkle.splashFactory);
    expect(theme.appBarTheme.centerTitle, isFalse);
    expect(theme.appBarTheme.titleTextStyle?.fontSize, 20);
    expect(AppIcons.iosShare, Icons.ios_share);
  });

  Future<bool?> confirm(BuildContext c) =>
      confirmDialog(c, title: 'Sign out?', body: 'Body', cancel: 'Cancel', confirm: 'Sign out', destructive: true);

  on('iOS: confirmation is a system alert', TargetPlatform.iOS, (tester) async {
    bool? result;
    await tester.pumpWidget(
        app((c) => TextButton(onPressed: () async => result = await confirm(c), child: const Text('go'))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  on('Android: confirmation is a Material dialog', TargetPlatform.android, (tester) async {
    bool? result;
    await tester.pumpWidget(
        app((c) => TextButton(onPressed: () async => result = await confirm(c), child: const Text('go'))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  Future<String?> menu(BuildContext c) => showActionMenu<String>(c, cancel: 'Cancel', note: 'One image', actions: [
        MenuAction('copy', AppIcons.copyOutlined, 'Copy text'),
        MenuAction('share', AppIcons.iosShare, 'Share'),
      ]);

  on('iOS: action menu is an action sheet with Cancel', TargetPlatform.iOS, (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(
        app((c) => TextButton(onPressed: () async => result = await menu(c), child: const Text('go'))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsOneWidget);
    expect(find.text('One image'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy text'));
    await tester.pumpAndSettle();
    expect(result, 'copy');
  });

  on('Android: action menu is a bottom sheet of rows with icons', TargetPlatform.android, (tester) async {
    String? result;
    await tester.pumpWidget(
        app((c) => TextButton(onPressed: () async => result = await menu(c), child: const Text('go'))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsNothing);
    expect(find.byType(ListTile), findsNWidgets(2));
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(result, 'share');
  });

  // --- The Mac: a desktop shell of its own; phones are untouched by it.

  on('macOS: pointer theme (no ripple, hover, 52 pt toolbar, left 15 pt title), SF glyphs, system spinner',
      TargetPlatform.macOS, (tester) async {
    await tester.pumpWidget(app((_) => const Spinner()));
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    final theme = Theme.of(tester.element(find.byType(Scaffold)));
    expect(theme.splashFactory, NoSplash.splashFactory);
    expect(theme.hoverColor, isNot(Colors.transparent));
    expect(theme.appBarTheme.centerTitle, isFalse);
    expect(theme.appBarTheme.toolbarHeight, desktopToolbarHeight);
    expect(theme.appBarTheme.titleTextStyle?.fontSize, 15);
    expect(AppIcons.homeOutlined, CupertinoIcons.house);
    expect(AppIcons.settingsOutlined, CupertinoIcons.gear);
  });

  on('Android: hover, transitions and tooltips are the Material defaults', TargetPlatform.android, (tester) async {
    await tester.pumpWidget(app((_) => const Spinner()));
    final theme = Theme.of(tester.element(find.byType(Scaffold)));
    final plain = ThemeData(useMaterial3: true);
    expect(theme.hoverColor, plain.hoverColor);
    expect(theme.pageTransitionsTheme, plain.pageTransitionsTheme);
    expect(theme.appBarTheme.toolbarHeight, isNull);
    expect(AppIcons.settingsOutlined, Icons.settings_outlined);
  });

  on('macOS: action menu is a menu at the pointer', TargetPlatform.macOS, (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(PointerTracker(
        child: app((c) => TextButton(onPressed: () async => result = await menu(c), child: const Text('go')))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('One image'), findsOneWidget);
    // It opens where the pointer went down (the button), not at a screen edge.
    final at = tester.getCenter(find.text('go'));
    final item = tester.getTopLeft(find.text('Copy text'));
    expect((item.dx - at.dx).abs(), lessThan(60));
    expect((item.dy - at.dy).abs(), lessThan(60));
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(result, 'share');
  });

  Future<String?> sheet(BuildContext c) => showAppSheet<String>(
        context: c,
        showDragHandle: true,
        useSafeArea: true,
        builder: (ctx) => TextButton(onPressed: () => Navigator.pop(ctx, 'picked'), child: const Text('In the sheet')),
      );

  on('macOS: a sheet is a dialog in the window, closed by its button', TargetPlatform.macOS, (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(
        app((c) => TextButton(onPressed: () async => result = await sheet(c), child: const Text('go'))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.tap(find.byIcon(CupertinoIcons.xmark));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('In the sheet'));
    await tester.pumpAndSettle();
    expect(result, 'picked');
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    on('${platform.name}: a sheet is a bottom sheet with a drag handle', platform, (tester) async {
      String? result;
      await tester.pumpWidget(
          app((c) => TextButton(onPressed: () async => result = await sheet(c), child: const Text('go'))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(find.text('In the sheet'));
      await tester.pumpAndSettle();
      expect(result, 'picked');
    });
  }

  /// A message box as the chat and Home build it, with what it sent.
  Future<(TextEditingController, List<String>)> messageBox(WidgetTester tester) async {
    final text = TextEditingController();
    addTearDown(text.dispose);
    final sent = <String>[];
    await tester.pumpWidget(app((_) => sendOnReturn(
          text: text,
          onSend: () {
            sent.add(text.text);
            text.clear();
          },
          child: TextField(controller: text, autofocus: true, maxLines: 5),
        )));
    await tester.pump();
    return (text, sent);
  }

  on('macOS: Return sends, Shift-Return does not, and Return while an input method composes is left to it',
      TargetPlatform.macOS, (tester) async {
    final (text, sent) = await messageBox(tester);
    expect(find.byType(Focus), findsWidgets);
    text.text = 'hello';
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, ['hello']);

    text.text = 'two lines';
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(sent, ['hello']);

    // Pinyin with "nihao" still marked: Return confirms the letters, it does not send.
    text.value = const TextEditingValue(
        text: 'nihao', selection: TextSelection.collapsed(offset: 5), composing: TextRange(start: 0, end: 5));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, ['hello']);
    // Once the input method has committed the text, Return sends it.
    text.value = const TextEditingValue(text: '你好', selection: TextSelection.collapsed(offset: 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, ['hello', '你好']);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    on('${platform.name}: the message box is unwrapped and Return never sends', platform, (tester) async {
      final field = TextField(controller: TextEditingController());
      expect(identical(sendOnReturn(text: field.controller!, onSend: () {}, child: field), field), isTrue);
      final (text, sent) = await messageBox(tester);
      text.text = 'hello';
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sent, isEmpty);
    });
  }

  Future<DesktopNav> sidebar(WidgetTester tester, {required bool compact}) async {
    final nav = DesktopNav();
    addTearDown(nav.dispose);
    final state = AppState(secrets: MemoryStore(), build: const BuildConfig(env: AppEnv.placeholder));
    addTearDown(state.dispose);
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Material(
          child: ListenableBuilder(
            listenable: nav,
            builder: (context, _) => Row(children: [DesktopSidebar(nav: nav, compact: compact)]),
          ),
        ),
      ),
    ));
    return nav;
  }

  on('macOS: a sidebar with the four destinations in place of the tab bar', TargetPlatform.macOS, (tester) async {
    final nav = await sidebar(tester, compact: false);
    expect(find.byType(CupertinoTabBar), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    for (final label in ['Home', 'Agents', 'Sessions', 'Infra', 'Settings']) {
      expect(find.text(label), findsOneWidget);
    }
    // The selected destination has the filled glyph, not only a tint.
    expect(find.byIcon(CupertinoIcons.house_fill), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.bubble_left_bubble_right), findsOneWidget);
    await tester.tap(find.text('Sessions'));
    await tester.pump();
    expect(nav.tab, DesktopNav.sessions);
    expect(find.byIcon(CupertinoIcons.bubble_left_bubble_right_fill), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.house), findsOneWidget);
    // Notifications start off, said in words beside the slashed bell.
    expect(find.text('Notifications are off'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.bell_slash), findsOneWidget);
  });

  on('macOS: a narrow window keeps the sidebar as icons with tooltips', TargetPlatform.macOS, (tester) async {
    await sidebar(tester, compact: true);
    expect(find.text('Sessions'), findsNothing);
    expect(find.byTooltip('Sessions'), findsOneWidget);
    expect(tester.getSize(find.byType(DesktopSidebar)).width, lessThan(80));
  });

  on('macOS: the approvals count shows on a sidebar item as a number', TargetPlatform.macOS, (tester) async {
    await tester.pumpWidget(app((_) => SizedBox(
          width: 200,
          child: SidebarItem(icon: AppIcons.homeOutlined, label: 'Home', badge: 3, compact: false, onTap: () {}),
        )));
    expect(find.text('3'), findsOneWidget);
  });

  test('macOS shell: opening an agent or a conversation shows it beside its list', () {
    final nav = DesktopNav();
    final agent = Agent.fromJson({'id': 'a1', 'name': 'deploy-bot', 'status': 'active'});
    final conversation = Conversation(key: 'k', platform: 'webchat', sessions: [
      SessionRow.fromJson({'sessionId': 's1', 'agentId': 'a1', 'agentName': 'deploy-bot', 'platform': 'webchat'}),
    ]);
    expect(nav.tab, DesktopNav.home);
    expect(nav.reading, isEmpty);
    nav.showAgent(agent);
    expect(nav.tab, DesktopNav.agents);
    expect(nav.showsAgent(agent), isTrue);
    expect(nav.reading, isEmpty);
    nav.showConversation(conversation);
    expect(nav.tab, DesktopNav.sessions);
    expect(nav.showsConversation(conversation), isTrue);
    // What notifications leave out: the conversation on screen, only while Sessions shows.
    expect(nav.reading, {'s1'});
    nav.go(DesktopNav.infra);
    expect(nav.reading, isEmpty);
    nav.reset();
    expect(nav.sessionsDetail, isNull);
    expect(nav.agentsDetail, isNull);
    nav.dispose();
  });

  test('the shell is routed through only on the Mac', () {
    final nav = DesktopNav();
    DesktopNav.current = nav;
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(desktopNav, isNull);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(desktopNav, isNull);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(desktopNav, same(nav));
    } finally {
      debugDefaultTargetPlatformOverride = null;
      DesktopNav.current = null;
      nav.dispose();
    }
  });

  Future<void> tile(WidgetTester tester, {required bool selected}) async {
    final state = AppState(secrets: MemoryStore(), build: const BuildConfig(env: AppEnv.placeholder));
    addTearDown(state.dispose);
    final conversation = Conversation(key: 'k', platform: 'webchat', sessions: [
      SessionRow.fromJson(
          {'sessionId': 's1', 'agentId': 'a1', 'agentName': 'deploy-bot', 'platform': 'webchat', 'title': 'Deploy'}),
    ]);
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Material(child: SessionTile(conversation: conversation, selected: selected)),
      ),
    ));
  }

  on('macOS: the conversation shown beside the list is marked with a bar and a tint', TargetPlatform.macOS,
      (tester) async {
    await tile(tester, selected: true);
    final box = tester.widget<DecoratedBox>(
        find.ancestor(of: find.text('Deploy'), matching: find.byType(DecoratedBox)).first);
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.color, Palette.light.brandSoft);
    expect((decoration.border as Border).left.width, 3);
  });

  on('Android: a conversation row has no selection mark', TargetPlatform.android, (tester) async {
    await tile(tester, selected: false);
    expect(find.ancestor(of: find.text('Deploy'), matching: find.byType(DecoratedBox)), findsNothing);
  });
}
