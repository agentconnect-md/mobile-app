import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/models.dart';
import '../../core/auth/account.dart';
import '../../core/auth/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'qr_scan_screen.dart';

/// Sign-in / add account. When [asRoute] is true it is pushed and pops on success.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, this.asRoute = false, this.expired = false});
  final bool asRoute;
  final bool expired;
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _base = TextEditingController();
  final _key = TextEditingController();
  bool _busy = false;
  bool _help = false;
  String? _error;
  SignInResult? _result;
  Org? _org;

  @override
  void dispose() {
    _base.dispose();
    _key.dispose();
    super.dispose();
  }

  String _failText(AppLocalizations l, SignInFailure f) => switch (f) {
        SignInFailure.key => l.errKey,
        SignInFailure.address => l.errAddress,
        SignInFailure.network => l.errNetwork,
        SignInFailure.other => l.genericError,
      };

  Future<void> _connect() async {
    final l = AppLocalizations.of(context);
    final app = AppScope.read(context);
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await app.validate(_base.text, _key.text);
    if (!mounted) return;
    if (r.failure != null) {
      setState(() {
        _busy = false;
        _error = _failText(l, r.failure!);
      });
      return;
    }
    if (r.orgs.length > 1) {
      setState(() {
        _busy = false;
        _result = r;
        _org = r.orgs.first;
      });
      return;
    }
    await _finish(r, r.orgs.first);
  }

  Future<void> _finish(SignInResult r, Org org) async {
    final app = AppScope.read(context);
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await app.addAccount(r, _base.text, _key.text, org);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppLocalizations.of(context).genericError;
        _result = null;
      });
      return;
    }
    if (!mounted) return;
    if (widget.asRoute) nav.pop();
  }

  Future<void> _scan() async {
    final l = AppLocalizations.of(context);
    final raw = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (!mounted || raw == null) return;
    if (raw == QrScanScreen.cameraDenied) {
      setState(() => _error = l.errCamera);
      return;
    }
    final q = parseQrPayload(raw);
    if (q == null) {
      setState(() => _error = l.errQr);
      return;
    }
    _base.text = q.apiBase;
    _key.text = q.key;
    await _connect();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) _key.text = d!.text!.trim();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final picking = _result != null;
    return Scaffold(
      appBar: widget.asRoute ? AppBar() : null,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          children: [
            if (!widget.asRoute) const SizedBox(height: 24),
            if (widget.expired) ...[
              AppCard(
                leftBar: p.error,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.keyExpiredTitle,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                  const SizedBox(height: 4),
                  Text(l.keyExpiredBody, style: TextStyle(color: p.secondary)),
                ]),
              ),
              const SizedBox(height: 20),
            ],
            Text(l.signInTitle,
                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(l.signInBody, style: TextStyle(fontSize: 16, color: p.secondary)),
            const SizedBox(height: 24),
            if (!picking) ...[
              SectionLabel(l.apiBaseUrl),
              TextField(
                controller: _base,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                decoration: const InputDecoration(hintText: 'https://api.example.test/v1'),
              ),
              SectionLabel(l.apiKey),
              TextField(
                controller: _key,
                enabled: !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                decoration: InputDecoration(
                  suffixIcon: IconButton(
                      onPressed: _paste, icon: const Icon(Icons.content_paste)),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(_error!, style: TextStyle(color: p.error, fontSize: 15)),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _connect,
                child: _busy
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Flexible(child: Text(l.checkingKey)),
                      ])
                    : Text(l.connect),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(l.scanQr),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() => _help = !_help),
                child: Text(l.whereKey),
              ),
              if (_help)
                Text(l.whereKeyHelp, style: TextStyle(color: p.secondary, fontSize: 15)),
            ] else ...[
              SectionLabel(l.chooseOrg),
              for (final o in _result!.orgs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AppCard(
                    onTap: () => setState(() => _org = o),
                    child: Row(children: [
                      Expanded(
                          child: Text(o.name,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600))),
                      Icon(_org?.id == o.id
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                          color: _org?.id == o.id ? p.accent : p.secondary),
                    ]),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : () => _finish(_result!, _org!),
                child: Text(l.continueLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
