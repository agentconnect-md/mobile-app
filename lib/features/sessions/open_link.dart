import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models.dart';
import '../../core/auth/app_state.dart';
import '../../core/console_links.dart';
import '../../core/share_links.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/errors.dart';
import '../../ui/widgets.dart';
import 'session_screen.dart';
import '../../ui/icons.dart';
import '../../ui/adaptive.dart';

/// Opens a console session link: the session, then the linked thread
/// (`?thread=`) and message (`#msg=`).
Future<void> openConsoleLink(BuildContext context, ConsoleLink link) {
  final app = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: app, child: _LinkedSession(link: link)),
  ));
}

/// Loads the linked session, then shows it; a link this sign-in can't
/// open shows the normal not-found state.
class _LinkedSession extends StatefulWidget {
  const _LinkedSession({required this.link});
  final ConsoleLink link;
  @override
  State<_LinkedSession> createState() => _LinkedSessionState();
}

class _LinkedSessionState extends State<_LinkedSession> {
  Conversation? _conv;
  Object? _error;
  bool _notFound = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    setState(() {
      _error = null;
      _notFound = false;
    });
    try {
      // A link into another organization isn't readable with this sign-in.
      final slug = widget.link.slug;
      if (slug != '-' && slug != await currentOrgSlug(app)) {
        if (mounted) setState(() => _notFound = true);
        return;
      }
      final (row, _) = await app.client.session(app.current!.orgId, widget.link.sessionId);
      if (!mounted) return;
      setState(() => _conv = Conversation(key: row.sessionId, platform: row.platform, sessions: [row]));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => e.status == 404 || e.status == 403 ? _notFound = true : _error = e);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final conv = _conv;
    if (conv != null) {
      return SessionScreen(
        conversation: conv,
        focusSeq: widget.link.seq,
        fillRequestId: widget.link.fill,
        threadRoot: widget.link.thread,
      );
    }
    return Scaffold(
      appBar: AppBar(),
      body: _notFound
          ? StateView(icon: AppIcons.linkOff, title: l.linkNotFoundTitle, body: l.linkNotFoundBody)
          : _error != null
              ? StateView(
                  icon: AppIcons.errorOutline, title: errorText(l, _error!), actionLabel: l.tryAgain, onAction: _load)
              : const Center(child: Spinner()),
    );
  }
}
