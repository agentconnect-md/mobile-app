import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/account.dart';
import '../../core/auth/app_state.dart';
import '../../core/auth/native.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/icons.dart';
import '../../ui/platform.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../signin/signin_screen.dart';
import '../../ui/adaptive.dart';

/// The navigator showing the menu, so a second shake doesn't stack another.
NavigatorState? _shownIn;

/// The developer menu of packages for testers (xcconfig `AC_DEBUG_MENU`):
/// which server the next sign-in uses. Does nothing in other packages, or
/// while the menu is already up. [offerSignIn] is false where the sign-in
/// screen is what the menu was opened from.
Future<void> showDeveloperMenu(BuildContext context, {bool offerSignIn = true}) async {
  final app = AppScope.read(context);
  if (!app.debugMenu || (_shownIn?.mounted ?? false)) return;
  _shownIn = Navigator.of(context);
  try {
    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => AppScope(state: app, child: DeveloperMenu(offerSignIn: offerSignIn)),
    );
  } finally {
    _shownIn = null;
  }
}

/// Opens the developer menu when the phone is shaken. The native side only
/// reports shakes in packages that have the menu.
class DeveloperShake extends StatefulWidget {
  const DeveloperShake({super.key, required this.child});
  final Widget child;
  @override
  State<DeveloperShake> createState() => _DeveloperShakeState();
}

class _DeveloperShakeState extends State<DeveloperShake> {
  StreamSubscription<void>? _shakes;

  @override
  void initState() {
    super.initState();
    _shakes = Native.shakes.listen((_) {
      if (mounted) showDeveloperMenu(context);
    });
  }

  @override
  void dispose() {
    _shakes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The sheet's content: the servers on offer, a custom one, and a way to sign in.
class DeveloperMenu extends StatefulWidget {
  const DeveloperMenu({super.key, this.offerSignIn = true});

  /// Offer "Add organization" (to someone signed in).
  final bool offerSignIn;
  @override
  State<DeveloperMenu> createState() => _DeveloperMenuState();
}

class _DeveloperMenuState extends State<DeveloperMenu> {
  bool _editing = false;

  void _use(AppEnv e) {
    final app = AppScope.read(context);
    if (app.env.sameAs(e)) return;
    Haptics.selection();
    app.useEnvironment(e);
  }

  void _addOrganization() {
    final nav = Navigator.of(context);
    final app = AppScope.read(context);
    nav.pop();
    nav.push(MaterialPageRoute<void>(
        builder: (_) => AppScope(state: app, child: const SignInScreen(asRoute: true))));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final app = AppScope.of(context);
    final p = context.pal;
    final custom = app.customEnv;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.developer, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(l.devServerIntro, style: TextStyle(color: p.secondary, fontSize: 14)),
          const SizedBox(height: 16),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (i, e) in app.environments.indexed) ...[
                  if (i > 0) Divider(height: 1, color: p.hairline),
                  _EnvRow(
                    env: e,
                    selected: app.env.sameAs(e),
                    note: e.sameAs(app.buildEnv) ? l.devThisPackage : null,
                    onTap: () => _use(e),
                    onEdit: custom != null && e.sameAs(custom) && !_editing
                        ? () => setState(() => _editing = true)
                        : null,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_editing)
            _CustomForm(
              initial: custom,
              onCancel: () => setState(() => _editing = false),
              onSaved: (e) {
                Haptics.selection();
                app.useCustomEnvironment(e);
                setState(() => _editing = false);
              },
            )
          else ...[
            if (custom == null)
              OutlinedButton.icon(
                onPressed: () => setState(() => _editing = true),
                icon: Icon(AppIcons.add),
                label: Text(l.devCustomAdd),
              ),
            if (widget.offerSignIn && app.signedIn) ...[
              const SizedBox(height: 8),
              FilledButton(onPressed: _addOrganization, child: Text(l.addOrganization)),
            ],
          ],
        ],
      ),
    );
  }
}

class _EnvRow extends StatelessWidget {
  const _EnvRow({required this.env, required this.selected, required this.onTap, this.note, this.onEdit});
  final AppEnv env;
  final bool selected;
  final String? note;
  final VoidCallback onTap;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                // The check keeps its place when absent, so rows line up.
                SizedBox(
                  width: 28,
                  child: selected ? Icon(AppIcons.check, size: 20, color: p.accent) : null,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(
                            env.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (note != null) ...[
                          const SizedBox(width: 8),
                          Chip8(note!, fg: p.secondary),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      Text(
                        env.apiHost,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono(context, color: p.secondary),
                      ),
                    ],
                  ),
                ),
                if (onEdit != null)
                  TextButton(
                    style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                    onPressed: onEdit,
                    child: Text(l.devCustomEdit),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A console host as typed (`https://` and a trailing `/` are forgiven); null unless a host name.
String? normalizeConsoleHost(String input) {
  var s = input.trim().toLowerCase();
  if (s.startsWith('https://')) s = s.substring(8);
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  final label = r'[a-z0-9]([a-z0-9-]*[a-z0-9])?';
  return RegExp('^$label(\\.$label)+\$').hasMatch(s) ? s : null;
}

/// A URL scheme as typed (`://` after it is forgiven); null unless a valid scheme.
String? normalizeUrlScheme(String input) {
  var s = input.trim().toLowerCase();
  if (s.endsWith('://')) s = s.substring(0, s.length - 3);
  return RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(s) ? s : null;
}

class _CustomForm extends StatefulWidget {
  const _CustomForm({required this.initial, required this.onCancel, required this.onSaved});
  final AppEnv? initial;
  final VoidCallback onCancel;
  final ValueChanged<AppEnv> onSaved;
  @override
  State<_CustomForm> createState() => _CustomFormState();
}

class _CustomFormState extends State<_CustomForm> {
  late final TextEditingController _api;
  late final TextEditingController _host;
  late final TextEditingController _scheme;
  bool _tried = false;

  @override
  void initState() {
    super.initState();
    final build = AppScope.read(context).buildEnv;
    final e = widget.initial;
    _api = TextEditingController(text: e == null ? '' : e.apiBase.replaceFirst('https://', ''));
    _host = TextEditingController(text: e?.callbackHost ?? '');
    _scheme = TextEditingController(text: e?.urlScheme ?? build.urlScheme);
  }

  @override
  void dispose() {
    _api.dispose();
    _host.dispose();
    _scheme.dispose();
    super.dispose();
  }

  void _save() {
    final api = normalizeApiBase(_api.text);
    final host = normalizeConsoleHost(_host.text);
    final scheme = normalizeUrlScheme(_scheme.text);
    if (api == null || host == null || scheme == null) {
      setState(() => _tried = true);
      return;
    }
    final l = AppLocalizations.of(context);
    widget.onSaved(AppEnv(
      name: l.devCustom,
      apiBase: api,
      callbackHost: host,
      callbackPath: AppScope.read(context).buildEnv.callbackPath,
      urlScheme: scheme,
    ));
  }

  Widget _field(TextEditingController c, String label, String? error, {TextInputAction? action}) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: TextField(
          controller: c,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          textCapitalization: TextCapitalization.none,
          textInputAction: action ?? TextInputAction.next,
          onChanged: _tried ? (_) => setState(() {}) : null,
          onSubmitted: action == TextInputAction.done ? (_) => _save() : null,
          style: mono(context, size: 14, color: context.pal.ink),
          decoration: InputDecoration(labelText: label, errorText: error, errorMaxLines: 2),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    String? err(bool bad, String text) => _tried && bad ? text : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(_api, l.devApiAddress, err(normalizeApiBase(_api.text) == null, l.devErrApi)),
        _field(_host, l.devConsoleHost, err(normalizeConsoleHost(_host.text) == null, l.devErrHost)),
        _field(_scheme, l.devUrlScheme, err(normalizeUrlScheme(_scheme.text) == null, l.devErrScheme),
            action: TextInputAction.done),
        Text(l.devCustomNote, style: TextStyle(color: p.secondary, fontSize: 13)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: widget.onCancel, child: Text(l.cancel))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: _save, child: Text(l.devUseServer))),
        ]),
      ],
    );
  }
}
