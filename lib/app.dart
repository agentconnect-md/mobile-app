import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/auth/app_state.dart';
import 'features/home_shell.dart';
import 'features/signin/signin_screen.dart';
import 'l10n/app_localizations.dart';
import 'ui/theme.dart';

class AgentConnectApp extends StatelessWidget {
  const AgentConnectApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        onGenerateTitle: (c) => AppLocalizations.of(c).appName,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (!app.ready) return const Scaffold(body: SizedBox());
    if (!app.signedIn) return const SignInScreen(key: ValueKey('signin'));
    if (app.keyExpired) {
      return _Expired(onAdd: app.dropExpired, browser: app.current?.isBrowser ?? false);
    }
    return const HomeShell();
  }
}

class _Expired extends StatelessWidget {
  const _Expired({required this.onAdd, this.browser = false});
  final bool browser;
  final Future<void> Function() onAdd;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.vpn_key_off_outlined, size: 44, color: context.pal.secondary),
              const SizedBox(height: 16),
              Text(browser ? l.signInExpiredTitle : l.keyExpiredTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(browser ? l.signInExpiredBody : l.keyExpiredBody,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.pal.secondary)),
              const SizedBox(height: 24),
              FilledButton(onPressed: onAdd, child: Text(browser ? l.signInAgain : l.addNewKey)),
            ]),
          ),
        ),
      ),
    );
  }
}
