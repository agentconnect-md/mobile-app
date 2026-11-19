import 'package:agentconnect/l10n/app_localizations.dart';
import 'package:agentconnect/ui/adaptive.dart';
import 'package:agentconnect/ui/icons.dart';
import 'package:agentconnect/ui/tab_bar.dart';
import 'package:agentconnect/ui/theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
}
