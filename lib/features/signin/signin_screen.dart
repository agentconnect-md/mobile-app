import 'package:flutter/material.dart';

import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/adaptive.dart';

/// Sign in, or add an organization (pushed from Settings when [asRoute]).
/// The server is built in (xcconfig); there is no address to type.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, this.asRoute = false});
  final bool asRoute;
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    final l = AppLocalizations.of(context);
    final app = AppScope.read(context);
    final nav = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final f = await app.signIn();
    if (!mounted) return;
    if (f == null) {
      if (widget.asRoute) nav.pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = signInFailureText(l, f);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return Scaffold(
      appBar: widget.asRoute ? AppBar(title: Text(l.addOrganization)) : null,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          children: [
            if (!widget.asRoute) ...[
              const SizedBox(height: 24),
              Text(
                l.signInTitle,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              l.signInIntro,
              style: TextStyle(fontSize: 16, color: p.secondary),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: p.error, fontSize: 15),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _signIn,
              child: _busy
                  ? Semantics(
                      label: l.signingIn,
                      child: const SizedBox(
                        width: 18,
                        height: 18,
                        child: Spinner(strokeWidth: 2, onAccent: true),
                      ),
                    )
                  : Text(l.signIn),
            ),
          ],
        ),
      ),
    );
  }
}

/// User-facing text for a failed sign-in; null when the user cancelled.
String? signInFailureText(AppLocalizations l, SignInFailure f) => switch (f) {
  SignInFailure.network => l.errNetwork,
  SignInFailure.cancelled => null,
  SignInFailure.noOrg => l.errNoOrg,
  SignInFailure.other => l.errSignIn,
};
