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
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) => MaterialApp(
        onGenerateTitle: (c) => AppLocalizations.of(c).appName,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: state.themeMode,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const _Root(),
      ),
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
    if (app.signInEnded) return const _SignedOut();
    return const HomeShell();
  }
}

/// The sign-in ended (revoked in the web console, or unused for too long).
class _SignedOut extends StatefulWidget {
  const _SignedOut();
  @override
  State<_SignedOut> createState() => _SignedOutState();
}

class _SignedOutState extends State<_SignedOut> {
  bool _busy = false;
  String? _error;

  Future<void> _again() async {
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final f = await AppScope.read(context).signInAgain();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = f == null ? null : signInFailureText(l, f);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = AppScope.of(context);
    final others = app.accounts.where((a) => a.id != app.current?.id).toList();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_clock_outlined,
                  size: 44,
                  color: context.pal.secondary,
                ),
                const SizedBox(height: 16),
                Text(
                  l.signInExpiredTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l.signInExpiredBody(app.current?.orgName ?? ''),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.pal.secondary),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.pal.error),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _again,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l.signInAgain),
                ),
                const SizedBox(height: 8),
                if (others.isNotEmpty)
                  for (final a in others)
                    TextButton(
                      onPressed: _busy ? null : () => app.select(a),
                      child: Text(a.orgName),
                    )
                else
                  TextButton(
                    onPressed: _busy ? null : app.dropEnded,
                    child: Text(l.signOut),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
