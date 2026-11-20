import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/capability_requests.dart';
import '../../core/auth/app_state.dart';
import '../../core/console_links.dart';
import '../../core/webchat/chat_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// The link the server gave for a request, if it is one to open in a browser.
Uri? capabilityLink(String link) {
  final u = Uri.tryParse(link);
  return u != null && u.scheme == 'https' && u.host.isNotEmpty ? u : null;
}

/// A capability request: the agent asks for something it lacks (a setting, an
/// MCP server, a repository, a secret, a scheduled task…). Shows what it asks
/// and why, where the request stands, and who can act on it.
///
/// Making the change, and declining, happen in the web console: the server
/// takes both only from an interactive console sign-in, which this app's
/// sign-in is not. So the card reads the request and offers Open in console.
class CapabilityCardView extends StatefulWidget {
  const CapabilityCardView({super.key, required this.item, this.load, this.open});
  final LiveItem item;

  /// Reads the request (default: the signed-in account's client).
  final Future<CapabilityRequest> Function(String requestId)? load;

  /// Opens the request's page in the web console (default: the browser).
  final Future<void> Function()? open;

  @override
  State<CapabilityCardView> createState() => _CapabilityCardViewState();
}

class _CapabilityCardViewState extends State<CapabilityCardView> with WidgetsBindingObserver {
  CapabilityRequest? _request;
  bool _failed = false;
  bool _loading = false;

  CapabilityCard get _card => widget.item.capability!;
  bool get _settledHere => widget.item.capabilityStatus != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // After the first frame: the default reader needs the account in scope.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(CapabilityCardView old) {
    super.didUpdateWidget(old);
    final was = old.item.capability;
    // Asked again (reopened), or settled meanwhile: what was read is stale.
    if (was?.requestId != _card.requestId || was?.generation != _card.generation) {
      _request = null;
      _failed = false;
      _load();
    }
  }

  /// Back from the console (or anywhere): the request may have been acted on.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// A settled card is final text; only an open one reads the request, which
  /// also says what this person may do.
  Future<void> _load() async {
    if (!mounted || _loading || _settledHere || (_request != null && !_request!.open)) return;
    final id = _card.requestId;
    final Future<CapabilityRequest> Function(String) load;
    if (widget.load != null) {
      load = widget.load!;
    } else {
      final app = AppScope.read(context);
      final org = app.current?.orgId;
      if (org == null) return;
      load = (id) => app.client.capabilityRequest(org, id);
    }
    _loading = true;
    try {
      final r = await load(id);
      if (mounted && id == _card.requestId) {
        setState(() {
          _request = r;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = _request == null);
    } finally {
      _loading = false;
    }
  }

  Future<void> _open() async {
    final custom = widget.open;
    if (custom != null) return custom();
    final app = AppScope.read(context);
    // The console this app signed in through; else the page the server named.
    final uri = consoleUri(app, await currentOrgSlug(app), 'requests/${_card.requestId}') ?? capabilityLink(_card.link);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  bool _canOpen(BuildContext context) =>
      widget.open != null ||
      capabilityLink(_card.link) != null ||
      consoleUri(AppScope.read(context), '-', 'requests') != null;

  static String _statusText(AppLocalizations l, String status, String? by) => switch (status) {
        'completed' => by == null || by.isEmpty ? l.capCompleted : l.capCompletedBy(by),
        'declined' => by == null || by.isEmpty ? l.capDeclined : l.capDeclinedBy(by),
        'expired' => l.capExpired,
        _ => l.capWithdrawn,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = context.pal;
    final card = _card;
    final item = widget.item;
    final r = _request;
    // The settled card's own line, else the wording of its status, else what the request says.
    final String? status = item.capabilityStatus ?? (r != null && !r.open ? r.status : null);
    final String? settledText = item.capabilityStatus != null
        ? ((item.capabilityText ?? '').isNotEmpty ? item.capabilityText! : _statusText(l, item.capabilityStatus!, null))
        : r != null && !r.open
            ? _statusText(l, r.status, r.settledBy)
            : null;
    final settled = settledText != null;
    final summary = (r?.summary ?? '').isNotEmpty ? r!.summary : card.summary;
    final reason = (r?.reason ?? '').isNotEmpty ? r!.reason : card.reason;
    final hint = TextStyle(color: p.secondary, fontSize: 13, height: 1.4);
    final expires = r?.expiresAt;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AppCard(
        leftBar: settled ? null : p.paused,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(AppIcons.keyOutlined, size: 14, color: p.tertiary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(l.capCrumb,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.tertiary, letterSpacing: 0.4)),
            ),
          ]),
          const SizedBox(height: 8),
          if (summary.isNotEmpty)
            Text(summary, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink, height: 1.4)),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            // The agent's reason: untrusted, plain text.
            Text(reason, style: TextStyle(color: p.secondary, fontSize: 14, height: 1.4)),
          ],
          const SizedBox(height: 10),
          if (settled) ...[
            Semantics(
              liveRegion: true,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                      switch (status) {
                        'completed' => AppIcons.checkCircleOutline,
                        'declined' => AppIcons.block,
                        _ => AppIcons.history,
                      },
                      size: 16,
                      color: status == 'completed' ? p.online : p.secondary),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(settledText,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: status == 'completed' ? p.online : p.secondary)),
                ),
              ]),
            ),
            if (r != null && r.status == 'completed' && (r.outcome ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(l.capOutcome(r.outcome!), style: hint),
            ],
            if (r != null && r.status == 'declined' && (r.note ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(l.capNote(r.note!), style: hint),
            ],
          ] else ...[
            Row(children: [
              Icon(AppIcons.timerOutlined, size: 16, color: p.paused),
              const SizedBox(width: 6),
              Expanded(
                child: Text(l.capWaiting,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: p.ink)),
              ),
            ]),
            if (expires != null) ...[
              const SizedBox(height: 2),
              Text(l.capExpires(DateFormat.MMMd().add_jm().format(expires.toLocal())), style: hint),
            ],
            if (r != null) ...[
              const SizedBox(height: 6),
              // Who can act: this person (in the console), or the people the server names.
              if (r.canComplete)
                Text(l.capYouCan, style: hint)
              else ...[
                if ((r.missing ?? '').isNotEmpty) Text(r.missing!, style: hint),
                Text(r.whoCan.isEmpty ? l.capNobodyCan : l.capWhoCan(r.whoCan.join(', ')), style: hint),
                if (r.canDecline) Text(l.capYouCanDecline, style: hint),
              ],
            ] else if (_failed) ...[
              const SizedBox(height: 6),
              Text(l.capStatusUnavailable, style: hint),
            ],
            if (_canOpen(context)) ...[
              const SizedBox(height: 10),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: _open,
                  icon: Icon(AppIcons.openInNew, size: 16),
                  label: Text(l.openInConsole),
                ),
              ),
            ],
          ],
        ]),
      ),
    );
  }
}
