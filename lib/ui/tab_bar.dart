import 'package:flutter/cupertino.dart' show CupertinoTabBar, CupertinoTheme;
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'icons.dart';
import 'platform.dart';
import 'theme.dart';

/// Home · Agents · Sessions · Infra. iOS: the system-style tab bar (49 pt above
/// the home indicator, a filled glyph and the brand color for the selected tab,
/// 10 pt labels). Elsewhere: the Material navigation bar.
class AppTabBar extends StatelessWidget {
  const AppTabBar({super.key, required this.index, required this.onSelected, this.pendingApprovals = 0});
  final int index;
  final ValueChanged<int> onSelected;

  /// Badge on Home: approval requests waiting.
  final int pendingApprovals;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final n = pendingApprovals;
    Widget home(IconData icon) => Badge(isLabelVisible: n > 0, label: Text('$n'), child: Icon(icon));
    if (isIOS) {
      final p = context.pal;
      final cupertino = CupertinoTheme.of(context);
      return CupertinoTheme(
        data: cupertino.copyWith(
          textTheme: cupertino.textTheme.copyWith(
            tabLabelTextStyle: const TextStyle(
                fontFamily: sansFamily, fontSize: 10, fontWeight: FontWeight.w500, letterSpacing: -0.1),
          ),
        ),
        child: CupertinoTabBar(
          currentIndex: index,
          onTap: onSelected,
          height: 49,
          iconSize: 25,
          backgroundColor: p.surface,
          activeColor: p.accent,
          inactiveColor: p.secondary,
          border: Border(top: BorderSide(color: p.hairline, width: 0.5)),
          items: [
            BottomNavigationBarItem(
                icon: home(AppIcons.homeOutlined), activeIcon: home(AppIcons.homeSelected), label: l.tabHome),
            BottomNavigationBarItem(icon: Icon(AppIcons.smartToyOutlined), label: l.tabAgents),
            BottomNavigationBarItem(
                icon: Icon(AppIcons.forumOutlined), activeIcon: Icon(AppIcons.forumSelected), label: l.tabSessions),
            BottomNavigationBarItem(
                icon: Icon(AppIcons.dnsOutlined), activeIcon: Icon(AppIcons.dnsSelected), label: l.tabInfra),
          ],
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
      child: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: onSelected,
        destinations: [
          NavigationDestination(
            icon: home(AppIcons.homeOutlined),
            selectedIcon: home(AppIcons.homeOutlined),
            label: l.tabHome,
          ),
          NavigationDestination(icon: Icon(AppIcons.smartToyOutlined), label: l.tabAgents),
          NavigationDestination(icon: Icon(AppIcons.forumOutlined), label: l.tabSessions),
          NavigationDestination(icon: Icon(AppIcons.dnsOutlined), label: l.tabInfra),
        ],
      ),
    );
  }
}
