import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/auth/app_state.dart';
import '../../core/auth/native.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../chat/agent_picker.dart';
import '../nav.dart';
import 'desktop_nav.dart';

/// The Mac's menu bar: the app menu (Settings… ⌘,), File (New Chat ⌘N, Close
/// Window ⌘W), Edit, View (the four destinations ⌘1–⌘4, Back ⌘[) and Window.
/// The shortcuts are the menu items' own, so they work wherever the focus is,
/// and with the window closed.
class DesktopMenus extends StatelessWidget {
  const DesktopMenus({super.key, required this.child});
  final Widget child;

  /// Sends a text-editing intent to whatever has the focus.
  static void _edit(Intent intent) {
    final c = primaryFocus?.context;
    if (c != null) Actions.maybeInvoke(c, intent);
  }

  /// The shell, with its window in front: a menu item can be chosen while
  /// the window is closed.
  static DesktopNav? _shell() {
    Native.showWindow();
    return DesktopNav.current;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = AppScope.of(context);
    // Signed out there is no shell: its items are dimmed.
    final signedIn = app.ready && app.signedIn && !app.signInEnded;
    const cause = SelectionChangedCause.keyboard;
    PlatformMenuItem go(String label, int tab, LogicalKeyboardKey key) => PlatformMenuItem(
          label: label,
          shortcut: SingleActivator(key, meta: true),
          onSelected: signedIn ? () => _shell()?.go(tab) : null,
        );
    return PlatformMenuBar(
      menus: [
        PlatformMenu(label: l.appName, menus: [
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l.menuSettings,
              shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
              onSelected: signedIn
                  ? () {
                      final c = _shell()?.context;
                      if (c != null) openSettings(c);
                    }
                  : null,
            ),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
          ]),
        ]),
        PlatformMenu(label: l.menuFile, menus: [
          PlatformMenuItem(
            label: l.menuNewChat,
            shortcut: const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
            onSelected: signedIn ? desktopNewChat : null,
          ),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l.menuCloseWindow,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyW, meta: true),
              onSelected: Native.closeWindow,
            ),
          ]),
        ]),
        PlatformMenu(label: l.menuEdit, menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l.menuUndo,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
              onSelected: () => _edit(const UndoTextIntent(cause)),
            ),
            PlatformMenuItem(
              label: l.menuRedo,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true),
              onSelected: () => _edit(const RedoTextIntent(cause)),
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l.menuCut,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyX, meta: true),
              onSelected: () => _edit(const CopySelectionTextIntent.cut(cause)),
            ),
            PlatformMenuItem(
              label: l.menuCopy,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyC, meta: true),
              onSelected: () => _edit(CopySelectionTextIntent.copy),
            ),
            PlatformMenuItem(
              label: l.menuPaste,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyV, meta: true),
              onSelected: () => _edit(const PasteTextIntent(cause)),
            ),
            PlatformMenuItem(
              label: l.menuSelectAll,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyA, meta: true),
              onSelected: () => _edit(const SelectAllTextIntent(cause)),
            ),
          ]),
        ]),
        PlatformMenu(label: l.menuView, menus: [
          PlatformMenuItemGroup(members: [
            go(l.tabHome, DesktopNav.home, LogicalKeyboardKey.digit1),
            go(l.tabAgents, DesktopNav.agents, LogicalKeyboardKey.digit2),
            go(l.tabSessions, DesktopNav.sessions, LogicalKeyboardKey.digit3),
            go(l.tabInfra, DesktopNav.infra, LogicalKeyboardKey.digit4),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l.menuBack,
              shortcut: const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true),
              onSelected: signedIn ? () => DesktopNav.current?.back() : null,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l.menuSwitchAppearance,
              onSelected: () {
                final c = primaryFocus?.context ?? DesktopNav.current?.context;
                app.toggleTheme(c == null
                    ? WidgetsBinding.instance.platformDispatcher.platformBrightness
                    : Theme.of(c).brightness);
              },
            ),
            const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
          ]),
        ]),
        PlatformMenu(label: l.menuWindow, menus: [
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l.appName,
              shortcut: const SingleActivator(LogicalKeyboardKey.digit0, meta: true),
              onSelected: Native.showWindow,
            ),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
          ]),
        ]),
      ],
      child: child,
    );
  }
}

/// New chat (⌘N, the Sessions list's button): choose an agent, then the chat
/// opens beside the list.
Future<void> desktopNewChat() async {
  final nav = DesktopNav.current;
  final c = nav?.context;
  if (nav == null || c == null) return;
  await Native.showWindow();
  if (!c.mounted) return;
  final agent = await pickAgent(c);
  if (agent != null) nav.showNewChat(agent);
}

/// Keeps the window's title bar (drawn by the system) in the app's theme:
/// light or dark as chosen in the app, in the sidebar's color.
class WindowChrome extends StatefulWidget {
  const WindowChrome({super.key, required this.child});
  final Widget child;
  @override
  State<WindowChrome> createState() => _WindowChromeState();
}

class _WindowChromeState extends State<WindowChrome> {
  int? _color;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final color = context.pal.sunken.toARGB32();
    if (color == _color) return;
    _color = color;
    Native.setWindowStyle(dark: Theme.of(context).brightness == Brightness.dark, color: color);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
